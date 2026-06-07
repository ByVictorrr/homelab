#!/usr/bin/env bash
# Pull the k3s kubeconfig from the control-plane Pi to this laptop and
# rewrite the server address so it works remotely.
#
# Usage:   ./03-fetch-kubeconfig.sh <cp-host> [username]
# Example: ./03-fetch-kubeconfig.sh rpi-control.local victord
#
# Writes to: ~/.kube/config-homelab
# Use with:  export KUBECONFIG=~/.kube/config-homelab

set -euo pipefail

CP_HOST="${1:-}"
SSH_USER="${2:-$USER}"

if [[ -z "$CP_HOST" ]]; then
  echo "usage: $0 <cp-host> [username]"
  echo "example: $0 rpi-control.local victord"
  exit 1
fi

DEST="$HOME/.kube/config-homelab"
mkdir -p "$HOME/.kube"

echo "[1/3] copying kubeconfig from $SSH_USER@$CP_HOST..."
scp "$SSH_USER@$CP_HOST:/etc/rancher/k3s/k3s.yaml" "$DEST"

echo "[2/3] rewriting server address to $CP_HOST..."
sed -i.bak "s|server: https://127.0.0.1:6443|server: https://$CP_HOST:6443|" "$DEST"
rm -f "$DEST.bak"
chmod 600 "$DEST"

echo "[3/3] verifying connection..."
KUBECONFIG="$DEST" kubectl get nodes -o wide

echo
echo "================================================================"
echo " kubeconfig saved to $DEST"
echo "================================================================"
echo "  Activate it for this shell:"
echo "    export KUBECONFIG=$DEST"
echo "  Or persist in ~/.zshrc:"
echo "    echo 'export KUBECONFIG=$DEST' >> ~/.zshrc"
echo "================================================================"
