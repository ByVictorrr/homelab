# rpi-cluster

k3s + Rancher homelab on 4× Raspberry Pi 5 (8GB), growing to 5.
Single control plane. Ansible-driven. Ubuntu Server 24.04 arm64.

> Full design + commentary lives in [`plan.pdf`](./plan.pdf). This README is the quickstart.

## Layout

```
.
├── scripts/
│   ├── 01-flash-pi.sh                  # flash Ubuntu to an SD card + bake in user-data
│   ├── 02-setup-control-plane.sh       # legacy: per-host bash, superseded by Ansible
│   ├── 02-setup-worker.sh              # legacy
│   ├── 03-fetch-kubeconfig.sh          # legacy
│   └── 04-install-rancher.sh           # legacy
├── ansible/
│   ├── ansible.cfg
│   ├── inventory.ini           # hosts: rpi-control + rpi-node1..3
│   ├── group_vars/all.yml      # vars: k3s args, kubeconfig path, Rancher knobs
│   └── site.yml                # 5 plays: prep, k3s server, k3s agents, kubeconfig, Rancher
├── plan.py                     # PDF generator (regenerate plan.pdf after edits)
└── plan.pdf
```

## Prerequisites (on your laptop)

```bash
sudo apt -y install ansible
ansible-galaxy collection install kubernetes.core community.general
curl -fsSL https://raw.githubusercontent.com/helm/helm/main/scripts/get-helm-3 | bash
```

## Quickstart

### 1. Flash each SD card

```bash
sudo ./scripts/01-flash-pi.sh rpi-control /dev/mmcblk0
sudo ./scripts/01-flash-pi.sh rpi-node1   /dev/mmcblk0
sudo ./scripts/01-flash-pi.sh rpi-node2   /dev/mmcblk0
sudo ./scripts/01-flash-pi.sh rpi-node3   /dev/mmcblk0
```

The script downloads + caches the Ubuntu image, dd's it, and writes cloud-init `user-data` (your hostname, SSH key, and the cgroup_memory kernel param).

### 2. Boot each Pi, wait ~90 s, smoke-test SSH

```bash
cd ansible
ansible all -m ping        # expect 'pong' from all 4
```

### 3. Run the playbook

```bash
# Everything except Rancher:
ansible-playbook site.yml --skip-tags rancher

# Then Rancher (override the bootstrap password):
ansible-playbook site.yml --tags rancher \
  -e rancher_bootstrap_password='something-long-and-yours'
```

### 4. Use kubectl from your laptop

```bash
export KUBECONFIG=~/.kube/config-homelab
kubectl get nodes -o wide
```

## Hostnames

The inventory addresses each Pi as `rpi-control.local`, `rpi-node1.local`, etc. The playbook makes this work three different ways so you're not depending on any single resolver:

1. **mDNS / Avahi.** `avahi-daemon` + `libnss-mdns` are installed in the prep play, so every Pi answers to `<host>.local` queries broadcast over the LAN.
2. **`/etc/hosts` (managed).** The prep play also writes a managed block in `/etc/hosts` on every Pi mapping all cluster nodes to their IPs. Survives any DNS / mDNS outage.
3. **Configurable endpoint.** `cluster_endpoint` in `group_vars/all.yml` is what ends up in the kubeconfig and in each worker's k3s join URL. Defaults to the CP's inventory hostname. Override with an IP or a real DNS name if you prefer:
   ```bash
   ansible-playbook site.yml -e cluster_endpoint=192.168.1.10
   # or
   ansible-playbook site.yml -e cluster_endpoint=rpi-control.lan
   ```

## Using hostnames on eero

eero doesn't expose a "Local DNS" tab — you can't add A records in the eero app. Two reliable ways to make hostnames work on an eero network:

### Option A — mDNS (zero config, works out of the box)
eero forwards mDNS / Bonjour by default. Once the playbook installs `avahi-daemon` on each Pi, `rpi-control.local` resolves from your laptop, phone, and other Pis without any eero changes.

### Option B — DHCP reservations (recommended for stability)
In the **eero app** → Settings → Network Settings → DHCP & NAT → Reservations & Port Forwarding → **Add a reservation**. Pick each Pi from the connected-devices list and pin its IP (e.g. `192.168.1.10` for rpi-control). Do this for all 4 (or 5) Pis. IPs now never change across reboots / leases.

> The Pi's "Name" shown in the eero app is display-only — it does **not** create a DNS record. That's why we use the `/etc/hosts` block on every Pi and Avahi for cross-device name resolution.

### Option C — real DNS via a local resolver
If you want `rpi-control` (no `.local`, no `/etc/hosts`) to resolve from *every* device on the network, run a DNS server on the cluster (Pi-hole, AdGuard Home, unbound, dnsmasq) with A records for your Pis, then point eero at it: **eero app → Settings → Network Settings → DNS → Custom → Primary = `<pi-ip>`**. This also gets you LAN-wide ad blocking.

## Storage tiers

Two NFS shares back the cluster's persistent data:

| Tier | Server | Path | Size | Use |
|---|---|---|---|---|
| `nfs-1` | rpi-control (192.168.4.27) | `/mnt/nfs` | ~900 GB | Original SSD-backed share — Jellyfin, Audiobookshelf, Frigate, http-fileserver, PXE/TFTP |
| `nfs-tank` | rpi-node4 (192.168.4.32) | `/mnt/tank` | ~24 TB (→ 72 TB) | Bulk tier — TerraMaster D4-320U DAS, SnapRAID + mergerfs, family Samba share |

`tank` is the big one for photos, media, backups, and anything that needs more
than 900 GB. Macs/iPhones get `smb://192.168.4.32/family`. Pods bind to PVs in
[`manifests/tank-storage.yaml`](manifests/tank-storage.yaml). Full design + ops in
[`docs/bulk-storage.md`](docs/bulk-storage.md). For the bigger picture of all
disks across the cluster — SD, SSD, tank — and what each is best at, see
[`docs/storage-tiers.md`](docs/storage-tiers.md). For pulling iCloud Photo
Libraries into the tank so Immich indexes them, see
[`docs/icloud-backup.md`](docs/icloud-backup.md).

## Adding the 5th Pi later

```bash
# 1. Uncomment the rpi-node4 line in ansible/inventory.ini
# 2. Flash the card:
sudo ./scripts/01-flash-pi.sh rpi-node4 /dev/mmcblk0
# 3. Boot, then:
cd ansible
ansible-playbook site.yml --skip-tags rancher --limit rpi-node4
```

The playbook is idempotent — existing nodes are no-ops, only the new one gets provisioned.

## Useful Ansible commands

```bash
ansible all -m ping                                # SSH smoke test
ansible-playbook site.yml --check --diff           # dry run
ansible-playbook site.yml --tags prep              # OS prep only
ansible-playbook site.yml --tags kubeconfig        # refetch kubeconfig
ansible-playbook site.yml --limit rpi-node2        # one host only
```

## Regenerating plan.pdf

```bash
python3 plan.py     # needs `reportlab` on the host
```

## Legacy / standalone scripts

`scripts/02-setup-control-plane.sh`, `02-setup-worker.sh`, `03-fetch-kubeconfig.sh`, and `04-install-rancher.sh` are the per-host bash equivalents of the Ansible plays. Kept as standalone fallbacks if you want to provision one Pi by hand without Ansible. The Ansible flow is the recommended path; delete them if you don't want the clutter.
