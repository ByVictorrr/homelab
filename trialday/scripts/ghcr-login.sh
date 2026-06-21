#!/usr/bin/env bash
# Create / refresh the imagePullSecret the Deployment uses to pull from GHCR.
# Re-run any time the PAT rotates.
#
# Required env:
#   GHCR_USERNAME — your GitHub username (e.g. byvictorrr)
#   GHCR_TOKEN    — a classic PAT with read:packages, or a fine-grained token
#                   with "Read access to packages" on this repo
set -euo pipefail

: "${GHCR_USERNAME:?GHCR_USERNAME is required}"
: "${GHCR_TOKEN:?GHCR_TOKEN is required}"

NS="trialday"
kubectl get ns "$NS" >/dev/null 2>&1 || kubectl create namespace "$NS"

kubectl -n "$NS" create secret docker-registry ghcr-pull \
  --docker-server=ghcr.io \
  --docker-username="$GHCR_USERNAME" \
  --docker-password="$GHCR_TOKEN" \
  --docker-email="$GHCR_USERNAME@users.noreply.github.com" \
  --dry-run=client -o yaml | kubectl apply -f -

echo "ghcr-pull secret applied in namespace $NS"
