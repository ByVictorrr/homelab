#!/usr/bin/env bash
# Flash Ubuntu Server 24.04 arm64 to an SD card and preconfigure it for headless K8s.
# Writes hostname, your SSH key, and the cgroup_memory kernel param.
#
# Usage:   sudo ./01-flash-pi.sh <hostname> <device>
# Example: sudo ./01-flash-pi.sh rpi-control /dev/mmcblk0
#
# Optional env overrides:
#   USERNAME       (default: the invoking user)
#   SSH_KEY_FILE   (default: ~/.ssh/id_ed25519.pub, falls back to id_rsa.pub)
#   TIMEZONE       (default: system tz)
#   IMAGE_CACHE    (default: ~/.cache/pi-images)

set -euo pipefail

HOSTNAME_ARG="${1:-}"
DEVICE="${2:-}"

if [[ -z "$HOSTNAME_ARG" || -z "$DEVICE" ]]; then
  echo "usage: sudo $0 <hostname> <device>"
  echo "example: sudo $0 rpi-control /dev/mmcblk0"
  exit 1
fi

if [[ $EUID -ne 0 ]]; then
  echo "must run as root (use sudo) — needs to write to $DEVICE"
  exit 1
fi

INVOKER="${SUDO_USER:-$USER}"
USERNAME="${USERNAME:-$INVOKER}"
TIMEZONE="${TIMEZONE:-$(timedatectl show -p Timezone --value 2>/dev/null || echo UTC)}"
IMAGE_CACHE="${IMAGE_CACHE:-/home/$INVOKER/.cache/pi-images}"

# Resolve SSH key
if [[ -z "${SSH_KEY_FILE:-}" ]]; then
  for f in "/home/$INVOKER/.ssh/id_ed25519.pub" "/home/$INVOKER/.ssh/id_rsa.pub"; do
    [[ -f "$f" ]] && SSH_KEY_FILE="$f" && break
  done
fi
if [[ -z "${SSH_KEY_FILE:-}" || ! -f "$SSH_KEY_FILE" ]]; then
  echo "no SSH public key found — set SSH_KEY_FILE=/path/to/key.pub"
  exit 1
fi
SSH_KEY=$(cat "$SSH_KEY_FILE")

# Sanity-check the device
if [[ ! -b "$DEVICE" ]]; then
  echo "$DEVICE is not a block device"
  exit 1
fi
DEVICE_SIZE=$(lsblk -bdno SIZE "$DEVICE")
DEVICE_MODEL=$(lsblk -dno MODEL,TRAN "$DEVICE" | tr -s ' ')
DEVICE_SIZE_H=$(numfmt --to=iec --suffix=B "$DEVICE_SIZE")

echo
echo "================================================================"
echo " FLASH PLAN"
echo "================================================================"
echo "  Hostname:  $HOSTNAME_ARG"
echo "  Device:    $DEVICE ($DEVICE_SIZE_H, $DEVICE_MODEL)"
echo "  Username:  $USERNAME"
echo "  SSH key:   $SSH_KEY_FILE"
echo "  Timezone:  $TIMEZONE"
echo "  Cache:     $IMAGE_CACHE"
echo "================================================================"
echo
echo "!! ALL DATA ON $DEVICE WILL BE ERASED !!"
read -rp "Type the device path again to confirm ($DEVICE): " CONFIRM
if [[ "$CONFIRM" != "$DEVICE" ]]; then
  echo "abort: device path did not match"
  exit 1
fi

mkdir -p "$IMAGE_CACHE"
chown "$INVOKER:" "$IMAGE_CACHE"

# Find the latest Ubuntu 24.04 arm64 raspi image
echo
echo "[1/5] resolving latest Ubuntu Server 24.04 arm64 image..."
INDEX_URL="https://cdimage.ubuntu.com/releases/noble/release/"
IMG_NAME=$(curl -sf "$INDEX_URL" \
  | grep -oE 'ubuntu-24\.04\.[0-9]+-preinstalled-server-arm64\+raspi\.img\.xz' \
  | sort -V | tail -1)
if [[ -z "$IMG_NAME" ]]; then
  echo "could not resolve image name from $INDEX_URL — check connectivity"
  exit 1
fi
IMG_URL="$INDEX_URL$IMG_NAME"
IMG_PATH="$IMAGE_CACHE/$IMG_NAME"
RAW_PATH="${IMG_PATH%.xz}"
echo "    image: $IMG_NAME"

# Download if not cached
if [[ ! -f "$RAW_PATH" ]]; then
  if [[ ! -f "$IMG_PATH" ]]; then
    echo "[2/5] downloading $IMG_URL"
    curl -L --progress-bar -o "$IMG_PATH.partial" "$IMG_URL"
    mv "$IMG_PATH.partial" "$IMG_PATH"
  else
    echo "[2/5] using cached $IMG_PATH"
  fi
  echo "[3/5] decompressing..."
  unxz --keep "$IMG_PATH"
else
  echo "[2/5] using cached $RAW_PATH"
  echo "[3/5] decompression skipped"
fi

# Unmount any auto-mounted partitions
echo "[4/5] unmounting any existing partitions on $DEVICE..."
for p in $(lsblk -lnpo NAME "$DEVICE" | tail -n +2); do
  umount "$p" 2>/dev/null || true
done

# Flash
echo "[5/5] writing image to $DEVICE (this takes 5-15 minutes)..."
dd if="$RAW_PATH" of="$DEVICE" bs=4M conv=fsync status=progress
sync

# Reread partition table and wait for partitions
partprobe "$DEVICE"
sleep 3
BOOT_PART=$(lsblk -lnpo NAME "$DEVICE" | sed -n '2p')
if [[ -z "$BOOT_PART" ]]; then
  echo "could not find boot partition on $DEVICE after flash"
  exit 1
fi

# Mount boot partition
MNT=$(mktemp -d)
mount "$BOOT_PART" "$MNT"
echo
echo "boot partition mounted at $MNT"

# 1) cmdline.txt: append cgroup params if not already there
CMDLINE="$MNT/cmdline.txt"
if [[ -f "$CMDLINE" ]]; then
  if ! grep -q 'cgroup_memory=1' "$CMDLINE"; then
    # cmdline.txt must stay a single line
    sed -i 's|$| cgroup_memory=1 cgroup_enable=memory|' "$CMDLINE"
    echo "  + appended cgroup params to cmdline.txt"
  else
    echo "  = cmdline.txt already has cgroup params"
  fi
fi

# 2) user-data: write cloud-init config
cat > "$MNT/user-data" <<EOF
#cloud-config
hostname: $HOSTNAME_ARG
manage_etc_hosts: true

users:
  - name: $USERNAME
    groups: [adm, sudo]
    shell: /bin/bash
    sudo: ALL=(ALL) NOPASSWD:ALL
    ssh_authorized_keys:
      - $SSH_KEY

ssh_pwauth: false
chpasswd:
  expire: false

timezone: $TIMEZONE
package_update: true
package_upgrade: false

runcmd:
  - swapoff -a
  - sed -i '/ swap / s/^/#/' /etc/fstab
EOF
echo "  + wrote user-data (hostname=$HOSTNAME_ARG, user=$USERNAME)"

sync
umount "$MNT"
rmdir "$MNT"

# Eject so the user can pull the card cleanly
eject "$DEVICE" 2>/dev/null || true

echo
echo "================================================================"
echo " DONE"
echo "================================================================"
echo "  Card ready. Insert in the Pi, power on, wait ~90s, then:"
echo "    ssh $USERNAME@$HOSTNAME_ARG.local"
echo "================================================================"
