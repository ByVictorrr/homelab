#!/usr/bin/env bash
# Roll out a new image tag to the cluster:
#   1. Run the prisma migrate Job at the new tag and wait for it to succeed.
#   2. Apply the kustomize bundle with the new tag pinned.
#
# Usage:
#   ./deploy/scripts/deploy.sh <image-tag>
#
# <image-tag> is anything you've pushed under ghcr.io/byvictorrr/trialday,
# typically the short commit SHA produced by .github/workflows/deploy-image.yml.
set -euo pipefail

TAG="${1:?usage: $0 <image-tag>}"
NS="trialday"
IMAGE="ghcr.io/byvictorrr/trialday:${TAG}"

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
KUSTOMIZE_DIR="$ROOT/deploy/k8s"

# --- 1. migrate job at the new tag --------------------------------------
echo ">> running migrations against $IMAGE"
kubectl -n "$NS" delete job trialday-migrate --ignore-not-found

# Patch the image and a unique run-id in-place before applying.
sed \
  -e "s#ghcr.io/byvictorrr/trialday:latest#${IMAGE}#g" \
  -e "s#set-by-deploy-script#${TAG}-$(date +%s)#" \
  "$KUSTOMIZE_DIR/app/migrate-job.yaml" \
  | kubectl apply -f -

kubectl -n "$NS" wait --for=condition=complete job/trialday-migrate --timeout=10m

# --- 2. roll the Deployment ---------------------------------------------
echo ">> deploying app at $IMAGE"
( cd "$KUSTOMIZE_DIR" && kubectl kustomize \
    --load-restrictor LoadRestrictionsNone . \
    | sed "s#ghcr.io/byvictorrr/trialday:latest#${IMAGE}#g" \
    | kubectl apply -f - )

kubectl -n "$NS" rollout status deploy/trialday --timeout=10m
echo ">> done"
