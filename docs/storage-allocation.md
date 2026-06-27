# Storage allocation

Inventory of every disk, pool, and PVC in the cluster with the actual sizes
allocated to each. Snapshot as of 2026-06-25. For *which tier to pick for
what*, see [`storage-tiers.md`](./storage-tiers.md); for the bulk-tier
internals see [`bulk-storage.md`](./bulk-storage.md).

To refresh the numbers below:

```sh
# PVC sizes (every namespace)
kubectl get pvc -A -o custom-columns=\
NS:.metadata.namespace,NAME:.metadata.name,SC:.spec.storageClassName,\
SIZE:.spec.resources.requests.storage --no-headers | sort

# Physical usage per node
ansible -i ansible/inventory.ini all -b -m shell \
  -a "df -h --output=source,size,used,avail,target | grep -E '/mnt|/var/lib/longhorn|mmcblk0p2'"
```

## 1. Physical capacity

| Node | Device | Raw | Mount | Role |
|---|---|---|---|---|
| rpi-control | mmcblk0p2 | 940 GB | `/` | OS + local-path |
| rpi-control | sda (USB SSD) | 938 GB | `/mnt/nfs` | `nfs-1` NFS pool |
| rpi-node1 | mmcblk0p2 | 114 GB | `/` | OS + local-path |
| rpi-node1 | sda (USB SSD) | 938 GB | `/mnt/nextcloud` | Nextcloud hostPath |
| rpi-node2 | mmcblk0p2 | 114 GB | `/` | OS + local-path |
| rpi-node2 | sda (USB SSD) | 938 GB | `/var/lib/longhorn` | Longhorn replica |
| rpi-node3 | mmcblk0p2 | 114 GB | `/` | OS + local-path |
| rpi-node3 | sda (USB SSD) | 938 GB | `/var/lib/longhorn` | Longhorn replica |
| rpi-node4 | mmcblk0p2 | 114 GB | `/` | OS + local-path |
| rpi-node4 | sda (USB SSD) | 469 GB | `/var/lib/longhorn` | Longhorn replica |
| rpi-node4 | sdb1 (DAS HDD) | 24 TB | `/mnt/d1` | tank data |
| rpi-node4 | sdc1 (DAS HDD) | 24 TB | `/mnt/parity1` | tank parity |

**Totals:** ~1.5 TB SD, ~4.2 TB SSD, 48 TB HDD raw (24 TB usable after parity).

## 2. Pool-level allocation

### Bulk tier — `/mnt/tank` (rpi-node4, NFS + Samba)

24 TB usable. Used: 1.4 GB. Subdirs are not quota'd — first writer to fill wins.

| Subdir | Exposed as | Cap | Used by |
|---|---|---|---|
| `/mnt/tank/family` | Samba `\\rpi-node4\family` + PV `tank-family` | none | Family Macs/iPhones |
| `/mnt/tank/photos` | PV `tank-photos` | none | Immich library |
| `/mnt/tank/media` | PV `tank-media` | none | Future Jellyfin migration |
| `/mnt/tank/backups` | PV `tank-backups` | none | DB dumps, Longhorn backup target, restic |
| `/mnt/tank/backups/timemachine` | Samba `\\rpi-node4\timemachine` | **6 TB advised** (see §6) | Time Machine sparsebundles |
| `/mnt/tank/k8s` | PV `tank-k8s` | none | Catch-all for new app PVs |

See §6 for how the Time Machine sub-share actually divides space between
Macs — `fruit:time machine max size` is advisory; modern macOS often
ignores it and sizes each sparsebundle off the share's free space at the
moment of bundle creation.

### Legacy NFS tier — `/mnt/nfs` (rpi-control)

938 GB usable. Used: 50 MB. Apps slowly migrating to tank.

| Subdir | PV | Used by |
|---|---|---|
| `/mnt/nfs/media` | `nfs-media` | Jellyfin (4 KB) |
| `/mnt/nfs/audiobooks` | `nfs-audiobooks` | Audiobookshelf (48 MB) |
| `/mnt/nfs/shared` | `nfs-shared` | (empty — http-fileserver moved to tank) |
| `/mnt/nfs/backups` | `nfs-backups` | (empty) |
| `/mnt/nfs/pxe-tftp` | `nfs-pxe` | PXE/TFTP (1.7 MB) |
| `/mnt/nfs/frigate` | `nfs-frigate` | Frigate recordings (32 KB) |

### Longhorn pool (rpi-node2 + node3 + node4 SSDs)

Raw: ~2.3 TB across three nodes. Default 2 replicas → ~1.15 TB usable.
Used: ~6 GB raw.

### Nextcloud hostPath — `/mnt/nextcloud` (rpi-node1)

938 GB. Used: 730 MB. Single-node, no replication.

## 3. PVC reservations by storage class

`SIZE` is what each PVC requested; it's a Kubernetes accounting figure, not
always a real quota.

### `local-path` (SD card on each node) — 171 Gi reserved

| Namespace | PVC | Size |
|---|---|---|
| adguard | adguard-conf | 2 Gi |
| adguard | adguard-work | 5 Gi |
| audiobookshelf | audiobookshelf-config | 5 Gi |
| audiobookshelf | audiobookshelf-metadata | 10 Gi |
| chat | webui-data | 10 Gi |
| home-assistant | home-assistant-config | 10 Gi |
| immich | data-immich-postgresql-0 | 8 Gi |
| immich | immich-postgres-data | 20 Gi |
| immich | redis-data-immich-redis-master-0 | 8 Gi |
| jellyfin | jellyfin-config | 10 Gi |
| mealie | mealie-data | 5 Gi |
| monitoring | kube-prometheus-stack-grafana | 5 Gi |
| monitoring | prometheus-…-prometheus-0 | 20 Gi |
| mosquitto | mosquitto-data | 1 Gi |
| nextcloud | nextcloud-postgres | 10 Gi |
| ollama | ollama-models | 30 Gi |
| sandbox | sandbox-home | 5 Gi |
| uptime-kuma | uptime-kuma-data | 2 Gi |
| vaultwarden | vaultwarden-data | 5 Gi |

local-path PVCs land on whichever node the pod schedules to, so reservations
compete with everything else on that node's SD card. The 171 Gi total is
divided across 5 SDs (≥114 GB each), so headroom is fine even with worst-case
co-scheduling.

### `longhorn` (SSD, replicated 2×) — 203 Gi reserved (~406 Gi raw)

| Namespace | PVC | Size |
|---|---|---|
| auth | authelia-data | 1 Gi |
| forgejo | forgejo-data | 30 Gi |
| frigate | frigate-config-pvc | 2 Gi |
| jupyter | jupyter-work | 40 Gi |
| kerneldev | kerneldev-home | 80 Gi |
| registry | registry-data | 50 Gi |

Pool is ~1.15 TB usable, so Longhorn is ~35% reserved at 2× replication. Lots
of room to add stateful apps or bump critical PVs to 3 replicas.

### `nfs-1` (rpi-control NFS) — 2010 Gi *requested*, 938 GB actual

| Namespace | PVC | Requested |
|---|---|---|
| audiobookshelf | audiobookshelf-media | 900 Gi |
| frigate | frigate-media | 200 Gi |
| jellyfin | jellyfin-media | 900 Gi |
| pxe | tftp-root | 10 Gi |

Requests sum to more than the pool — that's intentional. NFS PVs don't
enforce quotas, so each PVC carries the full pool size as a ceiling. Whichever
app writes most first wins the disk.

### `nfs-tank` (rpi-node4 bulk NFS) — 48 Ti *requested*, 24 TB actual

| Namespace | PVC | Requested |
|---|---|---|
| http-fileserver | files | 24 Ti |
| immich | immich-library | 24 Ti |

Same story — 24 Ti per PVC is the pool ceiling, not a quota.

### `nextcloud-local` (rpi-node1 hostPath) — 900 Gi

| Namespace | PVC | Size |
|---|---|---|
| nextcloud | nextcloud-data | 900 Gi |

## 4. Headroom summary

| Tier | Usable | Used | % full |
|---|---|---|---|
| SD (per-node OS + local-path) | ~570 GB across 5 SDs | ~165 GB | ~29% |
| Longhorn (SSD, replicated) | ~1.15 TB | 6 GB raw | <1% |
| `nfs-1` (rpi-control SSD) | 938 GB | 50 MB | <1% |
| Nextcloud hostPath (rpi-node1) | 938 GB | 730 MB | <1% |
| `nfs-tank` (bulk) | 24 TB | 1.4 GB | <1% |

The only tier with meaningful pressure is the SD cards on the older nodes
(rpi-node3 is at ~43%). Everything else has years of headroom at current
growth rates.

## 5. Where the hard limits actually exist

Most pools don't enforce quotas — sizes are accounting, not gates. The only
true caps in the cluster today:

- **Time Machine sparsebundle**: 2 TB per Mac, enforced by smb.conf
  `fruit:time machine max size`.
- **Longhorn volume**: each PVC is sized at the block layer; writing past
  the requested size fails as ENOSPC inside the pod even if the host has
  room.
- **SD card per node**: the physical card is the hard ceiling — local-path
  PVCs that overrun it will crash whichever pod tries to write.

Everything on `nfs-1`, `nfs-tank`, and the Nextcloud hostPath is a soft
allocation: the requested size is bookkeeping, the disk fills until the
whole pool is full.

## 6. Time Machine — per-Mac sizing & isolation

Path layout under the timemachine share:

```
/mnt/tank/backups/timemachine/
├── Marilyn’s MacBook Air.sparsebundle/      ← mom’s Mac
├── Victors-MacBook-Pro.sparsebundle/        ← victord’s Mac (when added)
└── …                                        ← one bundle per Mac
```

Each bundle is named from the Mac's hostname (System Settings → General →
About → Name), so two Macs *cannot* collide on the same path — macOS will
either pick a name with a numeric suffix or refuse.

**Per-Mac sizing.** `fruit:time machine max size` in `smb.conf` is advisory
on modern macOS. The actual cap is baked into each sparsebundle's
`Info.plist` (`size` key) at creation time, derived from whatever the share
reported as free space. Current bundle states:

| Bundle | Bundle `size` | Created |
|---|---|---|
| Marilyn's MacBook Air | 16 TB | 2026-06-25 |

In practice this means: don't worry about the cap unless the pool starts
filling up. If a future bundle needs to be smaller (or larger), the
honest way to change it is delete-and-recreate from the Mac side.

**Write isolation (verified).** Each sparsebundle directory is owned by
the connecting Samba user (mom logs in as `mom`, etc.). Another family
member cannot `touch` or `mkdir` inside someone else's bundle — confirmed
with a `sudo -u victord touch` test on rpi-node4.

**Read privacy (gap, not catastrophic).** Band files inside a sparsebundle
end up mode `0644` instead of the configured `0600` — vfs_fruit overrides
Samba's `create mask` for Time Machine writes. Practical impact:
1. Another samba_users member who mounts the timemachine share *can* list
   and read raw band files of someone else's backup.
2. Anyone with shell + sudo on rpi-node4 can read them (i.e. victord).

If you encrypt the backup from the Mac side (System Settings → Time Machine
→ pick *Encrypt backups* on add), the bands themselves are AES-encrypted
and unreadable without the passphrase, which closes this gap regardless of
file perms. **Recommended for any Mac that holds personal data.**

If hard SMB-layer isolation between family members matters more than
shared-pool simplicity, the alternative is one share per user
(`[timemachine_mom]`, `[timemachine_victord]`, …) each with
`valid users = SINGLE_USER`. Not currently configured — ask if you want it.

## Related

- [`storage-tiers.md`](./storage-tiers.md) — what to put where, and why
- [`bulk-storage.md`](./bulk-storage.md) — tank tier design + ops
- [`manifests/tank-storage.yaml`](../manifests/tank-storage.yaml)
- [`manifests/nfs-storage.yaml`](../manifests/nfs-storage.yaml)
- [`ansible/playbooks/tank.yml`](../ansible/playbooks/tank.yml)
- [`ansible/playbooks/storage.yml`](../ansible/playbooks/storage.yml)
