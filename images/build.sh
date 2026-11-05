#!/usr/bin/env bash
# Build and push nrg-worker and nrg-loadgen to the ECR repos Terraform created.
#   images/build.sh            # tag 1.0.0
#   TAG=1.0.1 images/build.sh
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
. "$ROOT/scripts/lib.sh"
ensure_account
REGION="$(terraform -chdir="$ROOT/terraform" output -raw region)"
REGISTRY="$(terraform -chdir="$ROOT/terraform" output -raw ecr_registry)"

aws ecr get-login-password --region "$REGION" | docker login --username AWS --password-stdin "$REGISTRY"

for img in nrg-worker nrg-loadgen; do
  echo "==> $img:$TAG"
  # Managed nodes are m6i (amd64); arm64 too in case CAST AI picks Graviton.
  docker buildx build --platform linux/amd64,linux/arm64 --push \
    -t "$REGISTRY/$img:$TAG" "$ROOT/images/$img"
done
