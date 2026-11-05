"""nrg-worker — Northwind Retail Group's generic service image.

MODE=http   CPU-burning HTTP service (checkout-api, notifications, label-renderer)
MODE=queue  Redis job worker (routing-engine)
"""

import json
import logging
import multiprocessing as mp
import os
import signal
import sys
import threading
import time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

logging.basicConfig(
    level=logging.INFO,
    format="%(asctime)s %(levelname)s %(name)s %(message)s",
    stream=sys.stdout,
)

SERVICE = os.environ.get("SERVICE_NAME", "nrg-worker")
log = logging.getLogger(SERVICE)
PORT = int(os.environ.get("PORT", "8080"))


def burn_cpu(ms: float) -> None:
    """Consume `ms` of *CPU time* (not wall time) on this thread."""
    deadline = time.thread_time() + ms / 1000.0
    x = 0
    while time.thread_time() < deadline:
        for i in range(500):
            x += i * i
    return None


def hold_ballast() -> list:
    mb = int(os.environ.get("BALLAST_MB", "0"))
    if mb <= 0:
        return []
    # Touch every page so it's actually resident.
    return [bytearray(b"\x01" * 1024 * 1024) for _ in range(mb)]


class Stats:
    def __init__(self):
        self.lock = threading.Lock()
        self.counters = {}

    def inc(self, name, value=1):
        with self.lock:
            self.counters[name] = self.counters.get(name, 0) + value

    def render(self, extra=None) -> str:
        with self.lock:
            items = dict(self.counters)
        items.update(extra or {})
        return "".join(f"nrg_{k} {v}\n" for k, v in sorted(items.items()))


STATS = Stats()


def make_handler(on_root, extra_metrics=lambda: {}):
    class Handler(BaseHTTPRequestHandler):
        protocol_version = "HTTP/1.1"

        def _send(self, code, body, ctype="application/json"):
            data = body.encode()
            self.send_response(code)
            self.send_header("Content-Type", ctype)
            self.send_header("Content-Length", str(len(data)))
            self.end_headers()
            self.wfile.write(data)

        def do_GET(self):
            if self.path in ("/healthz", "/readyz"):
                return self._send(200, '{"ok":true}')
            if self.path == "/metrics":
                return self._send(200, STATS.render(extra_metrics()), "text/plain; version=0.0.4")
            return on_root(self)

        def log_message(self, *args):  # keep logs quiet; metrics carry the signal
            pass

    return Handler


def serve(handler) -> ThreadingHTTPServer:
    srv = ThreadingHTTPServer(("0.0.0.0", PORT), handler)
    srv.daemon_threads = True
    threading.Thread(target=srv.serve_forever, daemon=True).start()
    log.info("listening on :%d", PORT)
    return srv


# --------------------------------------------------------------------------- http


def run_http():
    cpu_ms = float(os.environ.get("REQUEST_CPU_MS", "20"))
    _ballast = hold_ballast()  # noqa: F841

    config_file = os.environ.get("CONFIG_FILE")
    if config_file:
        # notifications: the init container decrypted this with KMS.
        with open(config_file) as f:
            cfg = json.load(f)
        log.info("loaded config for %s (%d keys)", cfg.get("service", "?"), len(cfg))

    def on_root(h):
        start = time.perf_counter()
        burn_cpu(cpu_ms)
        STATS.inc("requests_total")
        STATS.inc("request_seconds_sum", round(time.perf_counter() - start, 6))
        h._send(200, json.dumps({"service": SERVICE, "ok": True}))

    serve(make_handler(on_root))
    wait_forever()


# -------------------------------------------------------------------------- queue


def queue_worker(idx: int, stop: "mp.Event"):
    import redis

    r = redis.Redis(
        host=os.environ.get("REDIS_HOST", "redis-queue"),
        port=int(os.environ.get("REDIS_PORT", "6379")),
        socket_timeout=30,
    )
    key = os.environ.get("QUEUE_KEY", "routing:jobs")
    job_cpu_ms = float(os.environ.get("JOB_CPU_MS", "100"))
    job_io_ms = float(os.environ.get("JOB_IO_MS", "900"))
    wlog = logging.getLogger(f"{SERVICE}.w{idx}")

    while not stop.is_set():
        try:
            item = r.brpop(key, timeout=5)
            if item is None:
                continue
            job = json.loads(item[1])
            burn_cpu(job_cpu_ms)            # route optimisation
            time.sleep(job_io_ms / 1000.0)  # geocoder / carrier API round-trips
            pipe = r.pipeline()
            pipe.incr("routing:processed")
            latency_ms = int((time.time() - job.get("enqueued_at", time.time())) * 1000)
            pipe.set("routing:last_latency_ms", latency_ms)
            pipe.execute()
        except Exception as e:  # keep the worker alive through redis blips
            wlog.warning("job loop error: %s", e)
            time.sleep(1)


def run_queue():
    from concurrency import worker_count

    retune_every = float(os.environ.get("RETUNE_SECONDS", "30"))
    pool = []  # [(process, stop_event)]

    def spawn(i):
        ev = mp.Event()
        p = mp.Process(target=queue_worker, args=(i, ev), daemon=True)
        p.start()
        return p, ev

    def resize(target):
        while len(pool) < target:
            pool.append(spawn(len(pool)))
        while len(pool) > target:
            p, ev = pool.pop()
            ev.set()  # finishes its current job, then exits

    resize(worker_count())
    log.info("routing-engine worker pool started (workers=%d)", len(pool))

    serve(make_handler(
        lambda h: h._send(200, json.dumps({"service": SERVICE, "workers": len(pool)})),
        lambda: {"workers": len(pool)},
    ))

    def shutdown(*_):
        for p, ev in pool:
            ev.set()
        for p, _ in pool:
            p.join(timeout=10)
        sys.exit(0)

    signal.signal(signal.SIGTERM, shutdown)
    last_tune = time.monotonic()
    while True:
        for i, (p, ev) in enumerate(pool):
            if not p.is_alive():
                log.warning("worker %d exited (code %s); restarting", i, p.exitcode)
                pool[i] = spawn(i)
        # Follow in-place CPU resizes (K8s >= 1.33): cpu.weight changes under a running pod.
        if time.monotonic() - last_tune >= retune_every:
            last_tune = time.monotonic()
            target = worker_count(quiet=True)
            if target != len(pool):
                log.info("cpu allocation changed; resizing worker pool %d -> %d", len(pool), target)
                resize(target)
        time.sleep(2)


def wait_forever():
    signal.signal(signal.SIGTERM, lambda *_: sys.exit(0))
    while True:
        time.sleep(3600)


if __name__ == "__main__":
    mode = os.environ.get("MODE", sys.argv[1] if len(sys.argv) > 1 else "http")
    {"http": run_http, "queue": run_queue}[mode]()
