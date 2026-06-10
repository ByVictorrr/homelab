#!/usr/bin/env bash
# Flash Ubuntu Server 24.04.4 LTS (preinstalled-server arm64+raspi) to an SD card
# and preconfigure it for headless K8s via cloud-init: hostname, user, SSH key,
# Wi-Fi (optional), and the cgroup_memory kernel param.
#
# Usage:   sudo ./01-flash-pi.sh <hostname> <device>
# Example: sudo ./01-flash-pi.sh rpi-control /dev/mmcblk0
#
# Optional env overrides:
#   USERNAME       (default: the invoking user)
#   PASSWORD       (required: prompted securely if not set — for console login)
#   SSH_KEY_FILE   (default: ~/.ssh/id_ed25519.pub, falls back to id_rsa.pub)
#   TIMEZONE       (default: system tz)
#   IMAGE_CACHE    (default: ~/.cache/pi-images)
#   IMG_URL        (default: Ubuntu 24.04.4 preinstalled arm64+raspi)
#   WIFI_SSID      (optional: configure Wi-Fi auto-connect on boot)
#   WIFI_PASSWORD  (optional: prompted securely if WIFI_SSID set and this isn't)
#   WIFI_COUNTRY   (default: US — regulatory domain, 2-letter code)

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
IMG_URL="${IMG_URL:-https://cdimage.ubuntu.com/releases/24.04/release/ubuntu-24.04.4-preinstalled-server-arm64+raspi.img.xz}"
WIFI_SSID="${WIFI_SSID:-}"
WIFI_COUNTRY="${WIFI_COUNTRY:-US}"

# Prompt for login password (for console access when SSH/Wi-Fi is unavailable)
if [[ -z "${PASSWORD:-}" ]]; then
  read -rsp "Login password for user '$USERNAME': " PASSWORD
  echo
  read -rsp "Confirm password: " PASSWORD_CONFIRM
  echo
  if [[ -z "$PASSWORD" ]]; then
    echo "no password entered — aborting"
    exit 1
  fi
  if [[ "$PASSWORD" != "$PASSWORD_CONFIRM" ]]; then
    echo "passwords did not match — aborting"
    exit 1
  fi
  unset PASSWORD_CONFIRM
fi

# Hash the password — cloud-init's chpasswd accepts SHA-512 crypt
if ! command -v openssl >/dev/null 2>&1; then
  echo "openssl is required to hash the password — install it and retry"
  exit 1
fi
PASSWORD_HASH=$(openssl passwd -6 "$PASSWORD")

# Prompt for Wi-Fi password if SSID provided but no password given
if [[ -n "$WIFI_SSID" && -z "${WIFI_PASSWORD:-}" ]]; then
  read -rsp "Wi-Fi password for SSID '$WIFI_SSID': " WIFI_PASSWORD
  echo
  if [[ -z "$WIFI_PASSWORD" ]]; then
    echo "no Wi-Fi password entered — aborting"
    exit 1
  fi
fi

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
echo "  Image:     $(basename "$IMG_URL")"
if [[ -n "$WIFI_SSID" ]]; then
  echo "  Wi-Fi:     $WIFI_SSID (country=$WIFI_COUNTRY)"
fi
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

IMG_NAME=$(basename "$IMG_URL")
IMG_PATH="$IMAGE_CACHE/$IMG_NAME"
RAW_PATH="${IMG_PATH%.xz}"
echo
echo "[1/4] image: $IMG_NAME"

# Download if not cached
if [[ ! -f "$RAW_PATH" ]]; then
  if [[ ! -f "$IMG_PATH" ]]; then
    echo "[2/4] downloading $IMG_URL"
    curl -L --progress-bar -o "$IMG_PATH.partial" "$IMG_URL"
    mv "$IMG_PATH.partial" "$IMG_PATH"
  else
    echo "[2/4] using cached $IMG_PATH"
  fi
  echo "[3/4] decompressing..."
  unxz --keep "$IMG_PATH"
else
  echo "[2/4] using cached $RAW_PATH"
  echo "[3/4] decompression skipped"
fi

# Unmount any auto-mounted partitions
echo "[4/4] unmounting any existing partitions on $DEVICE..."
for p in $(lsblk -lnpo NAME "$DEVICE" | tail -n +2); do
  umount "$p" 2>/dev/null || true
done

# Flash
echo "writing image to $DEVICE (this takes 5-15 minutes)..."
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

# Mount boot partition (system-boot, FAT)
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

# 2) cloud-init user-data: hostname, user, SSH key, timezone
# YAML literal blocks (|-) preserve newlines/special chars without per-field escaping
cat > "$MNT/user-data" <<EOF
#cloud-config
hostname: $HOSTNAME_ARG
manage_etc_hosts: true
timezone: $TIMEZONE

users:
  - name: $USERNAME
    gecos: $USERNAME
    groups: [adm, sudo, users, audio, video, plugdev, dialout, netdev]
    sudo: ALL=(ALL) NOPASSWD:ALL
    shell: /bin/bash
    lock_passwd: false
    passwd: |-
$(printf '      %s\n' "$PASSWORD_HASH")
    ssh_authorized_keys:
      - |-
$(printf '        %s\n' "$SSH_KEY")

ssh_pwauth: false
disable_root: true
EOF
chmod 600 "$MNT/user-data"
echo "  + wrote user-data (hostname=$HOSTNAME_ARG, user=$USERNAME)"

# 3) cloud-init network-config: ethernet DHCP + optional Wi-Fi
{
  echo 'version: 2'
  echo 'ethernets:'
  echo '  eth0:'
  echo '    dhcp4: true'
  echo '    optional: true'
  if [[ -n "$WIFI_SSID" ]]; then
    echo 'wifis:'
    echo '  wlan0:'
    echo '    dhcp4: true'
    echo '    optional: true'
    echo "    regulatory-domain: \"$WIFI_COUNTRY\""
    echo '    access-points:'
    # Single-quoted YAML — escape any single quotes by doubling them
    SSID_ESC=${WIFI_SSID//\'/\'\'}
    PASS_ESC=${WIFI_PASSWORD//\'/\'\'}
    echo "      '$SSID_ESC':"
    echo "        password: '$PASS_ESC'"
  fi
} > "$MNT/network-config"
chmod 600 "$MNT/network-config"
echo "  + wrote network-config"
if [[ -n "$WIFI_SSID" ]]; then
  echo "  + Wi-Fi configured (SSID=$WIFI_SSID, country=$WIFI_COUNTRY)"
fi

# 4) meta-data: NoCloud requires this file to exist (instance-id triggers
#    cloud-init to re-run user-data if it changes)
cat > "$MNT/meta-data" <<EOF
instance-id: $HOSTNAME_ARG-$(date +%s)
local-hostname: $HOSTNAME_ARG
EOF
echo "  + wrote meta-data"

sync
umount "$MNT"
rmdir "$MNT"

# Eject so the user can pull the card cleanly
eject "$DEVICE" 2>/dev/null || true

echo
echo "================================================================"
echo " DONE"
echo "================================================================"
echo "  Card ready. Insert in the Pi, power on, wait ~2-3 min for"
echo "  first-boot cloud-init, then:"
echo "    ssh $USERNAME@$HOSTNAME_ARG.local"
echo "================================================================"
