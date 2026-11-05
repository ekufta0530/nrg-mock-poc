#!/usr/bin/env bash
# Toggle the workload-side traps independently. GitOps: this edits the Kustomize overlay
# (manifests/overlays/staging/kustomization.yaml); Argo CD does the apply. A bare `kubectl apply`
# would be reverted by Argo's self-heal.
#
#   scripts/trap.sh list
#   scripts/trap.sh <trap> on|off [--push]
#
# trap:  1      redis zero-disruption PDB
#        2      notifications KMS init container (workload half of traps 2+3)
#        3      (Cast AI node config IMDS hop limit: not in Git; see castai/terraform)
#        4      checkout-api CPU HPA ("off" comments the line out; there is no safe variant)
#        5      routing-engine self-sizing worker, Super level (cgroup cpu.weight)
#        5-hard routing-engine self-sizing worker, Hard level (Downward API)
#        zone   label-renderer strict zone spread (the 2-AZ subnet half is castai/terraform)
#        all    1, 2, 4, 5 (workload-side traps; the Cast AI side is castai/terraform)
#
# --push commits the overlay change, pushes it, and asks Argo CD to refresh.
. "$(dirname "$0")/lib.sh"

usage() { sed -n '2,17p' "$0" | sed 's/^# \{0,1\}//'; exit 1; }
cast_side() { warn "$1: the Cast AI half is not in Git. Run castai/terraform (guides/02-node-configuration-traps.md): $2"; }
KFILE="$OVERLAY/kustomization.yaml"

# set_line <tag> <dir> | set_line <tag> off   (rewrites the "# trap:<tag>" line)
set_line() {
  python3 -I - "$KFILE" "$1" "$2" <<'PY'
import re, sys
path, tag, target = sys.argv[1:4]
lines = open(path).read().split("\n")
pat = re.compile(r"^(\s*)#?\s*-\s+\.\./\.\./\S+(\s+# trap:%s)\s*$" % re.escape(tag))
hit = False
for i, l in enumerate(lines):
    m = pat.match(l)
    if not m: continue
    hit = True
    if target == "off":
        old = re.search(r"-\s+(\.\./\.\./\S+)", l).group(1)
        lines[i] = "%s# - %s%s" % (m.group(1), old, m.group(2))
    else:
        lines[i] = "%s- ../../%s%s" % (m.group(1), target, m.group(2))
if not hit: sys.exit("no '# trap:%s' line in %s" % (tag, path))
open(path, "w").write("\n".join(lines))
PY
}

toggle() {
  case "$1:$2" in
    1:on)       set_line 1 traps/01-redis-pdb ;;
    1:off)      set_line 1 safe/01-redis-pdb ;;
    2:on)       set_line 2 traps/02-notifications-kms ;;
    2:off)      set_line 2 safe/02-notifications-kms ;;
    3:on)       cast_side "trap 3" "-var trap3_hop_limit_1=true" ;;
    3:off)      cast_side "trap 3" "-var trap3_hop_limit_1=false" ;;
    4:on)       set_line 4 traps/04-checkout-hpa ;;
    4:off)      set_line 4 off ;;
    5:on)       set_line 5 traps/05-routing-worker ;;
    5-hard:on)  set_line 5 traps/05-routing-worker-hard ;;
    5:off|5-hard:off) set_line 5 safe/05-routing-worker ;;
    zone:on)    set_line zone traps/99-label-zone-spread; cast_side zone "-var zone_two_subnets=true" ;;
    zone:off)   set_line zone safe/99-label-zone-spread; cast_side zone "-var zone_two_subnets=false" ;;
    all:on|all:off) for t in 1 2 4 5; do toggle "$t" "$2"; done ;;
    *) usage ;;
  esac
}

show_state() {
  grep -E '^[[:space:]]*#?[[:space:]]*- .*# trap:' "$KFILE" | sed -E 's/^[[:space:]]*//' | awk '{
    tag=$NF; sub(/trap:/,"",tag); line=$0
    if (line ~ /^#/) st="off (no resource)"; else if (line ~ /\/safe\//) st="off (defused)"; else if (line ~ /-hard/) st="ARMED (hard)"; else st="ARMED"
    printf "  trap %-5s %s\n", tag, st }'
}

case "${1:-}" in
  list)
    echo "Git state ($KFILE):"
    show_state
    echo "Cast AI side (2/3/zone): castai/terraform (terraform output armed)"
    echo "Live cluster:"
    echo "  PDB (1):          $(kubectl -n cache get pdb redis-pdb -o jsonpath='{.spec.minAvailable}{"/"}{.spec.maxUnavailable}' 2>/dev/null || echo n/a)  (minAvailable/maxUnavailable; '1/' = armed)"
    echo "  checkout HPA (4): $(kubectl -n checkout get hpa checkout-api >/dev/null 2>&1 && echo present || echo absent)"
    echo "  Argo workloads:   $(kubectl -n "$ARGO_NS" get application nrg-workloads -o jsonpath='{.status.sync.status}/{.status.health.status}' 2>/dev/null || echo n/a)"
    ;;
  "") usage ;;
  *)
    [[ $# -ge 2 ]] || usage
    PUSH=false; [[ "${3:-}" == "--push" ]] && PUSH=true
    toggle "$1" "$2"
    $PUSH && { git_push_paths "trap $1 $2" "$KFILE"; argo_refresh nrg-workloads; }
    $PUSH || log "overlay edited locally. Commit + push it (or re-run with --push) for Argo CD to apply it."
    ;;
esac
