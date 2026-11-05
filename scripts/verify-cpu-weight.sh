#!/usr/bin/env bash
# Spec open item (trap 5): confirm how this AMI maps requests.cpu -> cgroup v2 cpu.weight,
# and that a container sees its own cgroup at /sys/fs/cgroup.
#
#   scripts/verify-cpu-weight.sh [node-name]
#
# Runs a pod requesting exactly 2 CPUs and reads cpu.weight:
#   173/174 -> quadratic formula (runc >= 1.3; EKS 1.35 AL2023 ships runc 1.3.6).
#              Matches the nrg-worker image default (CGROUP_WEIGHT_MODEL=quadratic).
#   79      -> legacy formula (older runc): rebuild nrg-worker with CGROUP_WEIGHT_MODEL=legacy,
#              or the trap 5 numbers will be off
# Run it on a node-group node AND later on a CAST AI node; both should agree.
set -euo pipefail

NODE="${1:-}"
NAME="cpu-weight-probe-$RANDOM"
NODE_SEL=""
[[ -n "$NODE" ]] && NODE_SEL="nodeName: $NODE"

cat <<EOF | kubectl apply -f - >/dev/null
apiVersion: v1
kind: Pod
metadata: { name: $NAME, namespace: default }
spec:
  restartPolicy: Never
  $NODE_SEL
  containers:
    - name: probe
      image: public.ecr.aws/docker/library/busybox:1.36
      command: ["sh", "-c", "echo weight=\$(cat /sys/fs/cgroup/cpu.weight); echo fs=\$(stat -fc %T /sys/fs/cgroup); echo cgroup=\$(cat /proc/self/cgroup)"]
      resources:
        requests: { cpu: "2", memory: 16Mi }
        limits: { memory: 16Mi }
EOF

kubectl wait --for=jsonpath='{.status.phase}'=Succeeded "pod/$NAME" --timeout=120s >/dev/null
out="$(kubectl logs "$NAME")"
node="$(kubectl get pod "$NAME" -o jsonpath='{.spec.nodeName}')"
kubectl delete pod "$NAME" --wait=false >/dev/null
echo "$out"
echo "node=$node"

weight="$(sed -n 's/^weight=//p' <<<"$out")"
fs="$(sed -n 's/^fs=//p' <<<"$out")"
[[ "$fs" == "cgroup2fs" ]] || echo "WARNING: /sys/fs/cgroup is '$fs', not cgroup2fs — trap 5 needs cgroup v2 (AL2023)."
cg="$(sed -n 's/^cgroup=//p' <<<"$out")"
[[ "$cg" == "0::/" ]] && echo "OK: private cgroup namespace (container sees its own cgroup at /sys/fs/cgroup)." \
                      || echo "WARNING: /proc/self/cgroup is '$cg' — container may not see its own cpu.weight."
case "$weight" in
  17[0-9]) echo "RESULT: quadratic formula. nrg-worker default (quadratic) is correct: 2000m -> 8 workers." ;;
  79)      echo "RESULT: legacy formula. Rebuild nrg-worker with ENV CGROUP_WEIGHT_MODEL=legacy." ;;
  *)       echo "RESULT: unexpected weight '$weight' — check the formula before running trap 5." ;;
esac
