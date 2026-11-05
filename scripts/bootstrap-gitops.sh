#!/usr/bin/env bash
# Hand the cluster to Argo CD: apply the root app-of-apps and wait for the platform + workloads to sync.
# Prereqs: terraform apply done, images built (scripts/deploy.sh --build --push), and the repo
# (including terraform's generated files under gitops/ and manifests/overlays/staging/generated/) pushed.
#
#   scripts/bootstrap-gitops.sh [--no-wait]
. "$(dirname "$0")/lib.sh"

WAIT=true; [[ "${1:-}" == "--no-wait" ]] && WAIT=false
ensure_context

ROOT_APP="$ROOT/gitops/bootstrap/root-app.yaml"
[[ -f "$ROOT_APP" ]] || die "$ROOT_APP missing: run terraform apply (write_gitops_files = true)"
REPO="$(tf_out gitops_repo_url)"
[[ "$REPO" != *CHANGE-ME* ]] || die "set gitops_repo_url in terraform.tfvars to the pushed repo, re-run terraform apply"

# Argo can only deploy what is on the remote.
if git -C "$ROOT" rev-parse --is-inside-work-tree >/dev/null 2>&1; then
  if [[ -n "$(git -C "$ROOT" status --porcelain -- gitops manifests)" ]]; then
    die "uncommitted changes under gitops/ or manifests/: commit and push first, Argo CD only sees the remote"
  fi
  git -C "$ROOT" fetch -q origin 2>/dev/null || warn "could not fetch origin"
  [[ -z "$(git -C "$ROOT" log @{u}.. --oneline 2>/dev/null)" ]] || die "unpushed commits: git push first"
else
  warn "$ROOT is not a git repo; make sure $REPO has this tree before continuing"
fi

if [[ "$REPO" == git@* || "$REPO" == ssh://* || -n "${ARGOCD_REPO_SECRET_FROM_GH_TOKEN:-}" ]]; then
  warn "private repo? register credentials first, e.g.: argocd repo add $REPO --ssh-private-key-path ~/.ssh/id_ed25519"
fi

log "applying root app-of-apps"
kubectl apply -f "$ROOT_APP"
argo_refresh nrg-root

if $WAIT; then
  log "waiting for Argo CD to create + sync the applications (workloads wait on ECR images and EBS)"
  for _ in $(seq 1 30); do kubectl -n "$ARGO_NS" get application nrg-workloads >/dev/null 2>&1 && break; sleep 5; done
  kubectl -n "$ARGO_NS" wait --for=jsonpath='{.status.sync.status}'=Synced application/nrg-workloads --timeout=900s
  kubectl -n "$ARGO_NS" wait --for=jsonpath='{.status.health.status}'=Healthy application/nrg-workloads --timeout=900s
  kubectl -n "$ARGO_NS" get applications
fi
log "done. UI: $(tf_out argocd_port_forward | cut -d'#' -f1)"
