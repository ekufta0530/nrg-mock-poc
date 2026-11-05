"""nrg-loadgen — steady, fixed-rate load for the Northwind Retail Group mock.

MODE=http   GET TARGET_URL at RPS requests/second (checkout-api)
MODE=queue  LPUSH jobs to Redis at JOBS_PER_SEC (routing-engine) and report queue health

Both modes serve:
  /metrics  Prometheus text
  /status   JSON (handy for the facilitator: curl it and read the backlog)
"""

import json
import logging
import os
import sys
import threading
import time
import urllib.request
import uuid
from collections import deque
from concurrent.futures import ThreadPoolExecutor
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

logging.basicConfig(level=logging.INFO, stream=sys.stdout,
                    format="%(asctime)s %(levelname)s nrg-loadgen %(message)s")
log = logging.getLogger()

PORT = int(os.environ.get("PORT", "8080"))
STATUS = {}
STATUS_LOCK = threading.Lock()


def set_status(**kw):
    with STATUS_LOCK:
        STATUS.update(kw)


def get_status():
    with STATUS_LOCK:
        return dict(STATUS)


class Handler(BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"

    def _send(self, code, body, ctype):
        data = body.encode()
        self.send_response(code)
        self.send_header("Content-Type", ctype)
        self.send_header("Content-Length", str(len(data)))
        self.end_headers()
        self.wfile.write(data)

    def do_GET(self):
        st = get_status()
        if self.path == "/metrics":
            lines = [f"nrg_loadgen_{k} {v}\n" for k, v in sorted(st.items()) if isinstance(v, (int, float))]
            return self._send(200, "".join(lines), "text/plain; version=0.0.4")
        if self.path in ("/healthz", "/readyz"):
            return self._send(200, '{"ok":true}', "application/json")
        return self._send(200, json.dumps(st, indent=2) + "\n", "application/json")

    def log_message(self, *args):
        pass


def ticker(rate: float, fn):
    """Call fn() `rate` times per second on a fixed schedule (no coordinated omission)."""
    interval = 1.0 / rate
    nxt = time.monotonic()
    while True:
        nxt += interval
        fn()
        delay = nxt - time.monotonic()
        if delay > 0:
            time.sleep(delay)
        elif delay < -5:  # fell way behind; resync instead of bursting
            nxt = time.monotonic()


# --------------------------------------------------------------------------- http


def run_http():
    url = os.environ.get("TARGET_URL", "http://checkout-api.checkout.svc.cluster.local/")
    rps = float(os.environ.get("RPS", "30"))
    timeout = float(os.environ.get("TIMEOUT_SECONDS", "5"))
    pool = ThreadPoolExecutor(max_workers=int(os.environ.get("MAX_INFLIGHT", "64")))
    counts = {"sent": 0, "ok": 0, "errors": 0}
    lat = deque(maxlen=2000)
    lock = threading.Lock()

    def one():
        start = time.perf_counter()
        try:
            with urllib.request.urlopen(url, timeout=timeout) as r:
                r.read()
            ok = True
        except Exception:
            ok = False
        with lock:
            counts["ok" if ok else "errors"] += 1
            lat.append(time.perf_counter() - start)

    def fire():
        with lock:
            counts["sent"] += 1
        pool.submit(one)

    def report():
        while True:
            time.sleep(5)
            with lock:
                s = sorted(lat)
                c = dict(counts)
            p = lambda q: round(s[int(q * (len(s) - 1))] * 1000, 1) if s else 0  # noqa: E731
            set_status(mode="http", target=url, target_rps=rps,
                       requests_sent_total=c["sent"], requests_ok_total=c["ok"],
                       requests_error_total=c["errors"],
                       latency_p50_ms=p(0.5), latency_p95_ms=p(0.95), latency_p99_ms=p(0.99))

    threading.Thread(target=report, daemon=True).start()
    log.info("http load: %s @ %.1f rps", url, rps)
    ticker(rps, fire)


# -------------------------------------------------------------------------- queue


def run_queue():
    import redis

    r = redis.Redis(host=os.environ.get("REDIS_HOST", "redis-queue"),
                    port=int(os.environ.get("REDIS_PORT", "6379")), socket_timeout=10)
    key = os.environ.get("QUEUE_KEY", "routing:jobs")
    jps = float(os.environ.get("JOBS_PER_SEC", "6"))
    max_depth = int(os.environ.get("MAX_QUEUE_DEPTH", "2000000"))
    produced = {"n": 0, "dropped": 0}

    def push():
        try:
            job = json.dumps({"id": uuid.uuid4().hex[:12], "enqueued_at": time.time(),
                              "stops": 18, "depot": "BOS-3"})
            if r.llen(key) >= max_depth:
                produced["dropped"] += 1
                return
            r.lpush(key, job)
            produced["n"] += 1
        except Exception as e:
            log.warning("push failed: %s", e)

    def report():
        window = deque(maxlen=13)  # (t, processed) samples, ~60s at 5s cadence
        while True:
            try:
                depth = r.llen(key)
                processed = int(r.get("routing:processed") or 0)
                oldest = r.lindex(key, -1)  # LPUSH + BRPOP: tail is the oldest job
                oldest_age = round(time.time() - json.loads(oldest)["enqueued_at"], 1) if oldest else 0.0
                last_latency = int(r.get("routing:last_latency_ms") or 0)
                now = time.time()
                window.append((now, processed))
                t0, p0 = window[0]
                throughput = round((processed - p0) / (now - t0), 2) if now > t0 else 0.0
                set_status(mode="queue", queue=key, arrival_rate_per_sec=jps,
                           queue_depth=depth, oldest_job_age_seconds=oldest_age,
                           throughput_per_sec_1m=throughput, last_job_latency_ms=last_latency,
                           jobs_produced_total=produced["n"], jobs_dropped_total=produced["dropped"],
                           jobs_processed_total=processed,
                           healthy=depth < jps * 30)
            except Exception as e:
                log.warning("status refresh failed: %s", e)
            time.sleep(5)

    threading.Thread(target=report, daemon=True).start()
    log.info("queue producer: %s @ %.1f jobs/s", key, jps)
    ticker(jps, push)


if __name__ == "__main__":
    srv = ThreadingHTTPServer(("0.0.0.0", PORT), Handler)
    srv.daemon_threads = True
    threading.Thread(target=srv.serve_forever, daemon=True).start()
    mode = os.environ.get("MODE", sys.argv[1] if len(sys.argv) > 1 else "http")
    {"http": run_http, "queue": run_queue}[mode]()
