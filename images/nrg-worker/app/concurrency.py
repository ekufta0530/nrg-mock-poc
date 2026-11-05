"""Worker-pool auto-tuning.

We size the pool to the CPU the scheduler actually gives us, so the same image
behaves sensibly in prod (big requests) and staging (small requests) without
anyone hand-tuning WORKERS per environment. One worker per 250m of CPU.
"""

import logging
import math
import os

log = logging.getLogger("routing-engine")

MILLICORES_PER_WORKER = 250
CGROUP_ROOT = "/sys/fs/cgroup"


def _weight_to_millicores_legacy(weight: int) -> float:
    # Inverse of the classic kubelet/runc mapping:
    #   shares = millicores * 1024 / 1000
    #   weight = 1 + ((shares - 2) * 9999) / 262142
    shares = (weight - 1) * 262142 / 9999 + 2
    return shares * 1000 / 1024


def _weight_to_millicores_quadratic(weight: int) -> float:
    # Inverse of the newer runc/crun mapping (shares 1024 -> weight 100):
    #   weight = 10 ** (L^2/612 + 125L/612 - 7/34), L = log2(shares)
    rhs = math.log10(weight) + 7 / 34
    l2 = (-125 + math.sqrt(125**2 + 4 * 612 * rhs)) / 2
    shares = 2**l2
    return shares * 1000 / 1024


def _read_int(path: str):
    try:
        with open(path) as f:
            return int(f.read().strip())
    except (OSError, ValueError):
        return None


def _cpu_millicores_from_cgroup() -> float:
    weight = _read_int(os.path.join(CGROUP_ROOT, "cpu.weight"))
    if weight is not None:
        model = os.environ.get("CGROUP_WEIGHT_MODEL", "quadratic")
        if model == "quadratic":
            return _weight_to_millicores_quadratic(weight)
        return _weight_to_millicores_legacy(weight)

    # cgroup v1 fallback
    shares = _read_int(os.path.join(CGROUP_ROOT, "cpu", "cpu.shares"))
    if shares is not None:
        return shares * 1000 / 1024

    return float(os.cpu_count() or 1) * 1000


def worker_count(quiet: bool = False) -> int:
    """How many job workers to run. Re-evaluated periodically so in-place resizes are honoured."""
    explicit = os.environ.get("WORKERS")
    if explicit:
        n = max(1, int(explicit))
        if not quiet:
            log.info("worker pool size fixed by config: %d", n)
        return n

    request_milli = os.environ.get("CPU_REQUEST_MILLI")
    if request_milli:
        milli = float(request_milli)
        source = "downward-api"
    else:
        milli = _cpu_millicores_from_cgroup()
        source = "cgroup"

    n = max(1, round(milli / MILLICORES_PER_WORKER))
    if not quiet:
        log.info("worker pool auto-tuned: %d workers (cpu≈%dm via %s)", n, milli, source)
    return n
