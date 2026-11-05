#!/usr/bin/env bash
# Reset the environment for the next trainee, or tear it all down.
#
#   ./reset.sh reset [--delete-cast-iam] [--yes] [--push]
#       1. Delete the Argo CD "castai" Application (if the trainee handed CAST AI to Argo), so Argo
#          doesn't reinstall what we're about to remove
#       2. Disconnect + delete nrg-stag-us-east-1 from CAST AI (deletes CAST-provisioned nodes)
#       3. Remove leftover CAST AI in-cluster components (agent, WOOP, webhooks, CRDs)
#       4. Optionally delete the IAM role/instance profile castctl created
#       5. Restore the three self-managed ASGs (general/memory/burst) to their Terraform sizes, uncordon nodes
#       6. Re-arm every trap in the Git overlay (--push commits + pushes it; otherwise commit it yourself),
#          wait for Argo CD to sync, flush the routing queue, restart pods
#     Target: < 30 min (mostly waiting on node drain/launch).
#
#   ./reset.sh teardown [--yes]
#       Remove Argo apps, CAST AI disconnect/delete, release EBS volumes, terraform destroy.
#
# Env: CASTAI_API_TOKEN (skips CAST AI API steps if unset), CASTAI_API_URL
ROOT="$(cd "$(dirname "$0")" && pwd)"
. "$ROOT/scripts/lib.sh"

API="${CASTAI_API_URL:-https://api.cast.ai}"
CMD="${1:-}"; shift || true
DELETE_CAST_IAM=false; YES=false; PUSH=false
for a in "$@"; do
  case "$a" in
    --delete-cast-iam) DELETE_CAST_IAM=true ;;
    --yes) YES=true ;;
    --push) PUSH=true ;;
    *) die "unknown flag $a" ;;
  esac
done

confirm() {
  $YES && return 0
  read -r -p "$1 [y/N] " ans; [[ "$ans" == [yY]* ]]
}

tf_out_json() { terraform -chdir="$TF_DIR" output -json "$1"; }
CLUSTER="$(tf_out cluster_name)"
REGION="$(tf_out region)"

castai_api() {
  local method="$1" path="$2" body="${3:-}"
  local args=(-sS -f -X "$method" -H "X-API-Key: $CASTAI_API_TOKEN" -H "Accept: application/json")
  [[ -n "$body" ]] && args+=(-H "Content-Type: application/json" --data "$body")
  curl "${args[@]}" "$API$path"
}

castai_offboard() {
  if [[ -z "${CASTAI_API_TOKEN:-}" ]]; then
    warn "CASTAI_API_TOKEN not set — skipping CAST AI disconnect. Do it in the console if the cluster is connected."
    return
  fi
  local ids
  ids="$(castai_api GET /v1/kubernetes/external-clusters | jq -r --arg n "$CLUSTER" '.items[] | select(.name == $n) | .id')"
  if [[ -z "$ids" ]]; then log "no CAST AI cluster named $CLUSTER"; return; fi
  for id in $ids; do
    log "CAST AI: disconnecting $id (deleting CAST-provisioned nodes)"
    castai_api POST "/v1/kubernetes/external-clusters/$id/disconnect" \
      '{"deleteProvisionedNodes": true, "keepKubernetesResources": false}' >/dev/null || warn "disconnect call failed for $id"
    log "CAST AI: waiting for disconnect"
    for _ in $(seq 1 60); do
      st="$(castai_api GET "/v1/kubernetes/external-clusters/$id" | jq -r '.status // empty' || true)"
      [[ "$st" == "disconnected" || -z "$st" ]] && break
      sleep 10
    done
    log "CAST AI: deleting cluster record $id"
    castai_api DELETE "/v1/kubernetes/external-clusters/$id" >/dev/null || warn "delete failed for $id (may need console)"
  done
}

remove_castai_in_cluster() {
  log "removing leftover CAST AI components"
  helm list -A -o json 2>/dev/null | jq -r '.[] | select(.name | test("castai|cast-ai")) | "\(.namespace) \(.name)"' \
    | while read -r ns name; do helm uninstall -n "$ns" "$name" --wait=false || true; done
  kubectl get mutatingwebhookconfigurations,validatingwebhookconfigurations -o name 2>/dev/null \
    | grep -Ei 'cast' | xargs -r kubectl delete --ignore-not-found
  kubectl delete namespace castai-agent --ignore-not-found --wait=false
  kubectl get crd -o name | grep -E 'cast\.ai' | xargs -r kubectl delete --ignore-not-found --wait=false

  # Any CAST AI node the disconnect didn't clean up.
  local instances
  instances="$(kubectl get nodes -l provisioner.cast.ai/managed-by=cast.ai \
      -o jsonpath='{range .items[*]}{.spec.providerID}{"\n"}{end}' | sed 's#.*/##' | grep '^i-' || true)"
  if [[ -n "$instances" ]]; then
    warn "CAST AI nodes still present: $(echo $instances)"
    if confirm "Terminate them?"; then
      aws ec2 terminate-instances --region "$REGION" --instance-ids $instances >/dev/null
      kubectl delete nodes -l provisioner.cast.ai/managed-by=cast.ai --wait=false
    fi
  fi
}

delete_cast_iam() {
  log "looking for onboarding-created IAM (cast-*${CLUSTER}*)"
  local profiles roles
  profiles="$(aws iam list-instance-profiles --output json | jq -r --arg c "$CLUSTER" '.InstanceProfiles[] | select(.InstanceProfileName | startswith("cast-") and contains($c)) | .InstanceProfileName')"
  roles="$(aws iam list-roles --output json | jq -r --arg c "$CLUSTER" '.Roles[] | select(.RoleName | startswith("cast-") and contains($c)) | .RoleName')"
  [[ -z "$profiles$roles" ]] && { log "none found"; return; }
  echo "instance profiles: $profiles"; echo "roles: $roles"
  confirm "Delete these?" || return
  for p in $profiles; do
    for r in $(aws iam get-instance-profile --instance-profile-name "$p" --query 'InstanceProfile.Roles[].RoleName' --output text); do
      aws iam remove-role-from-instance-profile --instance-profile-name "$p" --role-name "$r"
    done
    aws iam delete-instance-profile --instance-profile-name "$p"
  done
  for r in $roles; do
    for arn in $(aws iam list-attached-role-policies --role-name "$r" --query 'AttachedPolicies[].PolicyArn' --output text); do
      aws iam detach-role-policy --role-name "$r" --policy-arn "$arn"
    done
    for pol in $(aws iam list-role-policies --role-name "$r" --query 'PolicyNames' --output text); do
      aws iam delete-role-policy --role-name "$r" --policy-name "$pol"
    done
    aws iam delete-role --role-name "$r"
  done
}

remove_argo_castai() {
  if kubectl -n "$ARGO_NS" get application castai >/dev/null 2>&1; then
    log "deleting Argo application castai (non-cascading: its resources are removed by the CAST AI offboarding below)"
    kubectl -n "$ARGO_NS" patch application castai --type merge -p '{"metadata":{"finalizers":null}}' >/dev/null || true
    kubectl -n "$ARGO_NS" delete application castai --cascade=orphan --ignore-not-found
  fi
}

restore_platform() {
  local pool asg min max desired
  for pool in $(tf_out_json node_pools | jq -r 'keys[]'); do
    asg="$(tf_out_json asg_names | jq -r --arg p "$pool" '.[$p]')"
    min="$(tf_out_json node_pools | jq -r --arg p "$pool" '.[$p].min_size')"
    max="$(tf_out_json node_pools | jq -r --arg p "$pool" '.[$p].max_size')"
    desired="$(tf_out_json node_pools | jq -r --arg p "$pool" '.[$p].desired_size')"
    log "ASG $asg ($pool) -> min=$min max=$max desired=$desired"
    aws autoscaling update-auto-scaling-group --region "$REGION" --auto-scaling-group-name "$asg" \
      --min-size "$min" --max-size "$max" --desired-capacity "$desired" || warn "ASG update failed for $asg"
  done
  # Cluster Autoscaler is an Argo application: self-heal restores replicas. If the trainee fixed the
  # "CA still running" extra in Git (replicaCount: 0), put it back there.
  if grep -qE '^\s*replicaCount: 0' "$ROOT/gitops/apps/platform/cluster-autoscaler.yaml" 2>/dev/null; then
    warn "gitops/apps/platform/cluster-autoscaler.yaml has replicaCount: 0 (trainee's fix). Revert it in Git to re-arm the extra."
  fi
  log "waiting for self-managed nodes to be Ready"
  local want=0; for pool in $(tf_out_json node_pools | jq -r 'keys[]'); do want=$(( want + $(tf_out_json node_pools | jq -r --arg p "$pool" '.[$p].desired_size') )); done
  for _ in $(seq 1 60); do
    [[ "$(kubectl get nodes -l 'nrg.io/pool' --no-headers 2>/dev/null | grep -c ' Ready')" -ge "$want" ]] && break
    sleep 10
  done
  kubectl get nodes -o name | xargs -r kubectl uncordon >/dev/null
}

restore_workloads() {
  log "re-arming every trap in the Git overlay"
  "$ROOT/scripts/trap.sh" zone off >/dev/null 2>&1 || true
  for t in 1 2 4 5; do "$ROOT/scripts/trap.sh" "$t" on >/dev/null; done
  if [[ -n "$(git -C "$ROOT" status --porcelain -- "$OVERLAY" 2>/dev/null)" ]]; then
    if $PUSH; then git_push_paths "reset: re-arm traps" "$OVERLAY/kustomization.yaml"
    else warn "overlay changed locally. Commit + push it (or use --push) so Argo CD re-arms the traps; waiting here would time out."; return; fi
  fi
  argo_refresh nrg-workloads
  kubectl -n "$ARGO_NS" wait --for=jsonpath='{.status.sync.status}'=Synced application/nrg-workloads --timeout=600s || warn "nrg-workloads not Synced yet"
  log "flushing routing queue"
  kubectl -n routing exec deploy/redis-queue -- redis-cli DEL routing:jobs routing:processed routing:last_latency_ms >/dev/null || true
  log "restarting workloads (drops any WOOP-mutated requests now that the webhook is gone)"
  for ns in checkout routing notifications cache label; do
    kubectl -n "$ns" rollout restart deploy
  done
  kubectl -n db rollout restart statefulset postgres
  kubectl -n search rollout restart statefulset elasticsearch
  for ns in checkout routing notifications cache label; do
    for d in $(kubectl -n "$ns" get deploy -o name); do kubectl -n "$ns" rollout status "$d" --timeout=300s; done
  done
  "$ROOT/scripts/trap.sh" list
}

case "$CMD" in
  reset)
    start=$(date +%s)
    ensure_context
    remove_argo_castai
    castai_offboard
    remove_castai_in_cluster
    $DELETE_CAST_IAM && delete_cast_iam
    restore_platform
    restore_workloads
    log "reset complete in $(( ($(date +%s) - start) / 60 )) min. Next: Chris connects in phase 2; after he enables automation, arm the node configuration (guides/02-node-configuration-traps.md)"
    ;;
  teardown)
    confirm "Destroy $CLUSTER and everything in it?" || exit 1
    ensure_context || true
    remove_argo_castai || true
    castai_offboard
    remove_castai_in_cluster || true
    log "deleting workload namespaces (releases EBS volumes and any LoadBalancers)"
    kubectl -n "$ARGO_NS" delete applications --all --ignore-not-found --wait=true || true
    kubectl delete namespace checkout routing notifications cache label db search ingress-nginx --ignore-not-found --timeout=10m || true
    delete_cast_iam
    log "terraform destroy"
    terraform -chdir="$TF_DIR" destroy -auto-approve
    ;;
  *) sed -n '2,17p' "$0" | sed 's/^# \{0,1\}//'; exit 1 ;;
esac
