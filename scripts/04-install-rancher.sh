#!/usr/bin/env bash
# Install Rancher Manager on the rpi-control cluster.
# Runs LOCALLY on your laptop — needs kubectl + helm pointed at the cluster.
#
# Installs (in order):
#   1. ingress-nginx        (since we disabled Traefik in 02-setup-control-plane.sh)
#   2. cert-manager          (Rancher needs it for TLS)
#   3. Rancher (cattle-system)
#
# Usage:
#   ./04-install-rancher.sh
#
# Optional env:
#   KUBECONFIG          (default: ~/.kube/config-homelab)
#   RANCHER_HOSTNAME    (default: rancher.<rpi-control-ip>.nip.io  — no DNS setup needed)
#   BOOTSTRAP_PASSWORD  (default: 'rancher-init-change-me')
#   RANCHER_VERSION     (default: latest stable from chart repo)

set -euo pipefail

: "${KUBECONFIG:=$HOME/.kube/config-homelab}"
export KUBECONFIG

if ! command -v kubectl &>/dev/null; then
  echo "kubectl not found. Install it (e.g. via apt or 'curl -LO https://dl.k8s.io/release/...kubectl')."
  exit 1
fi

if ! command -v helm &>/dev/null; then
  echo "helm not found. Install it:"
  echo "  curl https://raw.githubusercontent.com/helm/helm/main/scripts/get-helm-3 | bash"
  exit 1
fi

if ! kubectl get nodes &>/dev/null; then
  echo "kubectl can't reach the cluster (KUBECONFIG=$KUBECONFIG). Fix that first."
  exit 1
fi

# Find rpi-control's IP for the nip.io hostname (avoids /etc/hosts editing)
CP_IP=$(kubectl get node rpi-control \
  -o jsonpath='{.status.addresses[?(@.type=="InternalIP")].address}' 2>/dev/null || true)
if [[ -z "$CP_IP" ]]; then
  echo "could not find node 'rpi-control' — list nodes with: kubectl get nodes"
  exit 1
fi

RANCHER_HOSTNAME="${RANCHER_HOSTNAME:-rancher.${CP_IP}.nip.io}"
BOOTSTRAP_PASSWORD="${BOOTSTRAP_PASSWORD:-rancher-init-change-me}"

echo
echo "================================================================"
echo " RANCHER INSTALL PLAN"
echo "================================================================"
echo "  Cluster:     $(kubectl config current-context)"
echo "  CP node IP:  $CP_IP"
echo "  Hostname:    https://$RANCHER_HOSTNAME"
echo "  Bootstrap:   $BOOTSTRAP_PASSWORD  (CHANGE on first login)"
echo "  Version:     ${RANCHER_VERSION:-latest stable}"
echo "================================================================"
read -rp "Proceed? [y/N] " ANS
[[ "$ANS" == "y" || "$ANS" == "Y" ]] || { echo "abort"; exit 1; }

echo
echo "[1/5] adding Helm repos..."
helm repo add jetstack       https://charts.jetstack.io --force-update
helm repo add ingress-nginx  https://kubernetes.github.io/ingress-nginx --force-update
helm repo add rancher-stable https://releases.rancher.com/server-charts/stable --force-update
helm repo update

echo
echo "[2/5] installing ingress-nginx (cattle-system needs an ingress controller)..."
kubectl create namespace ingress-nginx --dry-run=client -o yaml | kubectl apply -f -
helm upgrade --install ingress-nginx ingress-nginx/ingress-nginx \
  --namespace ingress-nginx \
  --set controller.service.type=LoadBalancer \
  --set controller.publishService.enabled=true \
  --wait --timeout 5m

echo
echo "[3/5] installing cert-manager (with CRDs)..."
kubectl create namespace cert-manager --dry-run=client -o yaml | kubectl apply -f -
helm upgrade --install cert-manager jetstack/cert-manager \
  --namespace cert-manager \
  --set installCRDs=true \
  --wait --timeout 5m

echo
echo "[4/5] installing Rancher into cattle-system..."
kubectl create namespace cattle-system --dry-run=client -o yaml | kubectl apply -f -

RANCHER_ARGS=(
  --namespace cattle-system
  --set "hostname=$RANCHER_HOSTNAME"
  --set "bootstrapPassword=$BOOTSTRAP_PASSWORD"
  --set replicas=1
  --set "ingress.ingressClassName=nginx"
)
[[ -n "${RANCHER_VERSION:-}" ]] && RANCHER_ARGS+=(--version "$RANCHER_VERSION")

helm upgrade --install rancher rancher-stable/rancher "${RANCHER_ARGS[@]}" \
  --wait --timeout 15m

echo
echo "[5/5] waiting for the rancher Deployment to roll out..."
kubectl -n cattle-system rollout status deploy/rancher --timeout=15m

echo
echo "================================================================"
echo " RANCHER READY"
echo "================================================================"
echo "  Open:        https://$RANCHER_HOSTNAME"
echo "  Bootstrap:   $BOOTSTRAP_PASSWORD"
echo
echo "  First load will show a self-signed cert warning — accept it."
echo "  Set a real admin password on the welcome screen."
echo
echo "  If the page doesn't load:"
echo "    kubectl -n cattle-system get pods"
echo "    kubectl -n ingress-nginx get svc"
echo "  The ingress-nginx service should have an EXTERNAL-IP. Make sure"
echo "  that IP is reachable from your laptop (same LAN)."
echo "================================================================"
