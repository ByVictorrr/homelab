#!/usr/bin/env bash
# Bootstrap (or refresh) the observability stack: Pushgateway, Prometheus,
# Grafana with the Trialday Cron dashboard auto-provisioned.
#
# Required env:
#   GRAFANA_ADMIN_PASSWORD — password for the grafana "admin" user.
#                            Generate with `openssl rand -hex 24` and save it
#                            somewhere safe; you'll log in with admin/<this>.
#
# Optional env:
#   GRAFANA_ADMIN_USER     — defaults to "admin"
set -euo pipefail

: "${GRAFANA_ADMIN_PASSWORD:?GRAFANA_ADMIN_PASSWORD is required}"
GRAFANA_ADMIN_USER="${GRAFANA_ADMIN_USER:-admin}"
NS="observability"

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"

# Namespace first so the Secret has somewhere to land.
kubectl apply -f "$ROOT/deploy/k8s/observability/namespace.yaml"

kubectl -n "$NS" create secret generic grafana-admin \
  --from-literal=admin-user="$GRAFANA_ADMIN_USER" \
  --from-literal=admin-password="$GRAFANA_ADMIN_PASSWORD" \
  --dry-run=client -o yaml | kubectl apply -f -

kubectl apply -k "$ROOT/deploy/k8s/observability"

kubectl -n "$NS" rollout status deploy/pushgateway --timeout=5m
kubectl -n "$NS" rollout status deploy/prometheus  --timeout=5m
kubectl -n "$NS" rollout status deploy/grafana     --timeout=5m

echo
echo ">> observability stack ready"
echo "   grafana:    https://grafana.trialday.app  (admin / <your password>)"
echo "   prometheus: kubectl -n observability port-forward svc/prometheus 9090"
echo "   pushgateway:kubectl -n observability port-forward svc/pushgateway 9091"
