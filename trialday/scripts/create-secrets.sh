#!/usr/bin/env bash
# Create / refresh the two Secrets the app needs from local env files.
# Safe to re-run: --dry-run=client | apply replaces existing secrets in place.
#
# Usage:
#   ./deploy/scripts/create-secrets.sh path/to/app.env path/to/postgres.env
#
# app.env should contain DATABASE_URL plus every NEXT_PUBLIC_*/Clerk/Stripe/etc
# key listed in deploy/k8s/app/secret.example.yaml.
# postgres.env should contain POSTGRES_USER / POSTGRES_PASSWORD / POSTGRES_DB.
set -euo pipefail

APP_ENV="${1:-.env.production}"
PG_ENV="${2:-.env.postgres}"
NS="trialday"

for f in "$APP_ENV" "$PG_ENV"; do
  if [[ ! -f "$f" ]]; then
    echo "error: env file not found: $f" >&2
    exit 1
  fi
done

kubectl get ns "$NS" >/dev/null 2>&1 || kubectl create namespace "$NS"

kubectl -n "$NS" create secret generic trialday-env \
  --from-env-file="$APP_ENV" \
  --dry-run=client -o yaml | kubectl apply -f -

kubectl -n "$NS" create secret generic postgres-credentials \
  --from-env-file="$PG_ENV" \
  --dry-run=client -o yaml | kubectl apply -f -

echo "secrets applied in namespace $NS"
