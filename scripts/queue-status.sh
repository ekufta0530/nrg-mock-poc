#!/usr/bin/env bash
# The facilitator's "business metric" for trap 5: routing queue depth, oldest job age, throughput.
#   scripts/queue-status.sh          # one shot
#   scripts/queue-status.sh -w       # refresh every 10s
set -euo pipefail

show() {
  kubectl -n routing exec deploy/routing-producer -- \
    python -c "import urllib.request;print(urllib.request.urlopen('http://localhost:8080/status').read().decode())"
  printf 'routing-engine: '
  kubectl -n routing get deploy routing-engine \
    -o jsonpath='{.spec.template.spec.containers[0].resources.requests.cpu} cpu requested (template)'; echo
  kubectl -n routing get pods -l app=routing-engine \
    -o jsonpath='{range .items[*]}  pod {.metadata.name}: {.spec.containers[0].resources.requests.cpu} cpu (live, incl. WOOP mutation){"\n"}{end}'
  kubectl -n routing logs deploy/routing-engine 2>/dev/null | grep -m1 'worker pool' || true
}

if [[ "${1:-}" == "-w" ]]; then
  while true; do clear; date; show; sleep 10; done
else
  show
fi
