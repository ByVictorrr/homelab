#!/usr/bin/env bash
# Run ON each worker Pi (rpi-node1, rpi-node2, ...) over SSH.
# Does OS prep, installs k3s agent, joins the cluster.
#
# Usage (from your laptop):
#   scp 02-setup-worker.sh victord@rpi-node1.local:~/
#   ssh victord@rpi-node1.local \
#     'K3S_URL=https://rpi-control.local:6443 K3S_TOKEN=<token> bash ~/02-setup-worker.sh'
#
# Required env:
#   K3S_URL     e.g. https://rpi-control.local:6443
#   K3S_TOKEN   the token printed by 02-setup-control-plane.sh
#
# Optional env:
#   K3S_VERSION=v1.31.0+k3s1   pin to match the server version

set -euo pipefail

if [[ $EUID -eq 0 ]]; then
  echo "run as your regular user; the script will sudo as needed"
  exit 1
fi

: "${K3S_URL:?must set K3S_URL=https://<cp-host>:6443}"
: "${K3S_TOKEN:?must set K3S_TOKEN=<server-token>}"

echo "[1/5] apt update + base packages..."
sudo apt-get update
sudo DEBIAN_FRONTEND=noninteractive apt-get -y upgrade
sudo DEBIAN_FRONTEND=noninteractive apt-get -y install \
  curl ca-certificates open-iscsi nfs-common

echo "[2/5] enabling iscsid (for future Longhorn use)..."
sudo systemctl enable --now iscsid

echo "[3/5] disabling swap..."
sudo swapoff -a
sudo sed -i '/ swap / s/^/#/' /etc/fstab

echo "[4/5] verifying memory cgroups are enabled..."
if [[ "$(awk '/^memory/ {print $4}' /proc/cgroups)" != "1" ]]; then
  echo "memory cgroup is NOT enabled. Add 'cgroup_memory=1 cgroup_enable=memory'"
  echo "to /boot/firmware/cmdline.txt and reboot."
  exit 1
fi
echo "    memory cgroups ok"

echo "[5/5] installing k3s agent, joining $K3S_URL ..."
CURL_ENV=("K3S_URL=$K3S_URL" "K3S_TOKEN=$K3S_TOKEN")
[[ -n "${K3S_VERSION:-}" ]] && CURL_ENV+=("INSTALL_K3S_VERSION=$K3S_VERSION")

env "${CURL_ENV[@]}" sh -c 'curl -sfL https://get.k3s.io | sh -'

echo
echo "================================================================"
echo " WORKER JOINED"
echo "================================================================"
echo "  Run on the control plane (or laptop with kubeconfig):"
echo "    kubectl get nodes -o wide"
echo "  Expect to see $(hostname) in Ready state within ~30s."
echo "================================================================"
