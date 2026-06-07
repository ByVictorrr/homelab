#!/usr/bin/env bash
# Run ON the control-plane Pi (rpi-control) over SSH.
# Does OS prep, installs k3s server, prints the node-token for joining workers.
#
# Usage (from your laptop):
#   scp 02-setup-control-plane.sh victord@rpi-control.local:~/
#   ssh victord@rpi-control.local 'bash ~/02-setup-control-plane.sh'
#
# Optional env:
#   DISABLE_TRAEFIK=1   skip the bundled Traefik ingress (default: 1)
#   K3S_VERSION=v1.31.0+k3s1   pin a specific k3s version

set -euo pipefail

if [[ $EUID -eq 0 ]]; then
  echo "run as your regular user; the script will sudo as needed"
  exit 1
fi

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
  echo "memory cgroup is NOT enabled. Did you add 'cgroup_memory=1 cgroup_enable=memory'"
  echo "to /boot/firmware/cmdline.txt? Fix it and reboot before re-running."
  exit 1
fi
echo "    memory cgroups ok"

echo "[5/5] installing k3s server..."
K3S_INSTALL_ARGS="server --write-kubeconfig-mode 644"
if [[ "${DISABLE_TRAEFIK:-1}" == "1" ]]; then
  K3S_INSTALL_ARGS+=" --disable traefik"
fi

CURL_ENV=()
[[ -n "${K3S_VERSION:-}" ]] && CURL_ENV+=("INSTALL_K3S_VERSION=$K3S_VERSION")

env "${CURL_ENV[@]}" sh -c "curl -sfL https://get.k3s.io | sh -s - $K3S_INSTALL_ARGS"

echo
echo "waiting for node to become Ready..."
for i in {1..30}; do
  if sudo kubectl get nodes 2>/dev/null | grep -q ' Ready '; then
    break
  fi
  sleep 2
done

echo
echo "================================================================"
echo " CONTROL PLANE READY"
echo "================================================================"
sudo kubectl get nodes -o wide
echo
echo "JOIN TOKEN (use this on every worker):"
echo "----------------------------------------------------------------"
sudo cat /var/lib/rancher/k3s/server/node-token
echo "----------------------------------------------------------------"
echo
echo "From your laptop, fetch kubeconfig with:"
echo "  ./03-fetch-kubeconfig.sh $(hostname)"
echo "================================================================"
