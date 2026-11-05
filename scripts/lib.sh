# Shared helpers. Source me: . "$(dirname "$0")/lib.sh"
set -euo pipefail

ROOT="${ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")/.." && pwd)}"
TF_DIR="$ROOT/terraform"
MANIFESTS="$ROOT/manifests"
OVERLAY="$MANIFESTS/overlays/staging"
TAG="${TAG:-1.0.0}"
ARGO_NS="${ARGO_NS:-argocd}"

log()  { printf '\033[1;34m==>\033[0m %s\n' "$*" >&2; }
warn() { printf '\033[1;33m!!\033[0m %s\n' "$*" >&2; }
die()  { printf '\033[1;31mxx\033[0m %s\n' "$*" >&2; exit 1; }

# Same guard rail as the Terraform provider: refuse to touch any other account.
EXPECTED_ACCOUNT="${EXPECTED_ACCOUNT:-445567108000}"
ensure_account() {
  local acct; acct="$(aws sts get-caller-identity --query Account --output text)"
  [[ "$acct" == "$EXPECTED_ACCOUNT" ]] || die "AWS credentials point at account $acct, expected $EXPECTED_ACCOUNT (set AWS_PROFILE or EXPECTED_ACCOUNT)"
}

tf_out() { terraform -chdir="$TF_DIR" output -raw "$1"; }

ensure_context() {
  ensure_account
  local cluster region
  cluster="$(tf_out cluster_name)"; region="$(tf_out region)"
  if [[ "$(kubectl config current-context 2>/dev/null)" != "$cluster" ]]; then
    log "switching kubectl context to $cluster"
    aws eks update-kubeconfig --region "$region" --name "$cluster" --alias "$cluster" >/dev/null
  fi
}

# Ask Argo CD to re-read Git now instead of waiting for the ~3 min poll.
argo_refresh() {
  local app
  for app in "$@"; do
    kubectl -n "$ARGO_NS" annotate application "$app" argocd.argoproj.io/refresh=hard --overwrite >/dev/null 2>&1 \
      || warn "could not refresh Argo application $app (not bootstrapped yet?)"
  done
}

# Commit + push the given paths. Pushing is the "deploy" in GitOps, so it is always explicit (--push).
git_push_paths() {
  local msg="$1"; shift
  git -C "$ROOT" rev-parse --is-inside-work-tree >/dev/null 2>&1 || die "$ROOT is not a git repository; init it and add the Argo CD remote first"
  git -C "$ROOT" add -- "$@"
  if git -C "$ROOT" diff --cached --quiet; then log "nothing to commit"; return; fi
  git -C "$ROOT" commit -q -m "$msg"
  git -C "$ROOT" push
}
