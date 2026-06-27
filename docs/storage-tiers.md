# Storage tiers

A quick map of every disk in the cluster, what's on it today, and what each
tier is best at. Sister doc: [`bulk-storage.md`](./bulk-storage.md) for the
26 TB tier's design and ops.

## Physical layout (as of 2026-06-25)

| Node | Disk | Capacity | Used | Mount | Tier / role |
|---|---|---|---|---|---|
| rpi-control | SSD (Sabrent USB) | 938 GB | 50 MB | `/mnt/nfs` | `nfs-1` — first NFS tier |
| rpi-node1 | SSD (Sabrent USB) | 938 GB | 730 MB | `/mnt/nextcloud` | Nextcloud hostPath |
| rpi-node2 | SSD (Sabrent USB) | 938 GB | 3.4 GB | `/var/lib/longhorn` | Longhorn pool |
| rpi-node3 | SSD (Sabrent USB) | 938 GB | 2.4 GB | `/var/lib/longhorn` | Longhorn pool |
| rpi-node4 | SSD (Sabrent USB) | 469 GB | 42 MB | `/var/lib/longhorn` | Longhorn pool |
| rpi-node4 | 2× 26 TB (TerraMaster DAS) | 52 TB raw | 290 MB | `/mnt/tank` (mergerfs) | `nfs-tank` — bulk tier, SnapRAID-protected |

**SSD total: ~4.2 TB, used ~7 GB (~0.2%).** Massive headroom.

## The three tiers

### 1. SD card (root filesystem on each Pi)

`/dev/mmcblk0p2` on each node. ~115 GB. Holds the OS, k3s, container images,
and any PV provisioned by **local-path** (the cluster's default storage class).

**Use it for:** the OS, container images, ephemeral state.

**Avoid for:** anything with high write churn. SD cards wear out. Immich's
library used to live here (via `local-path`) before being moved to tank.

### 2. SSD tier (Longhorn + dedicated hostPaths)

5× SSDs across the nodes. Most are 99% empty.

**Currently used for:**
- **`nfs-1`** (rpi-control:/mnt/nfs, ~900 GB) — original NFS share. Now mostly
  empty after http-fileserver migrated to tank. Still serves: Jellyfin (4 KB),
  Audiobookshelf (48 MB), Frigate (32 KB), PXE (1.7 MB), reports (20 KB).
- **Nextcloud hostPath** (rpi-node1:/mnt/nextcloud, ~900 GB) — single-node,
  730 MB used.
- **Longhorn pool** (rpi-node2, rpi-node3, rpi-node4) — ~2.3 TB raw, replicated
  2–3×, ~1 TB usable. Holds stateful app data: Forgejo, Authelia, Jupyter,
  registry, mealie, sandbox, home-assistant, mosquitto, monitoring (Grafana),
  audiobookshelf metadata.

**Use it for:** anything that needs **fast IOPS** — databases, hot caches, build
scratch, frequently-mutated state. The 26 TB tier is FUSE-mounted over USB, so
NFS-over-fuse single-file random read/write is slow compared to local SSD.

### 3. Bulk tier (`nfs-tank`, the 26 TB pool)

rpi-node4:/mnt/tank, exported as NFS. SnapRAID + mergerfs. See
[`bulk-storage.md`](./bulk-storage.md) for the full design.

**Use it for:** photos, video, audio, backups, anything large-and-cold.

**Avoid for:** PostgreSQL data dirs, container build caches, anything doing
random small-block writes. The latency would be terrible.

## What to put where, by app type

| App pattern | Storage class | Why |
|---|---|---|
| App config files (`/config`) | `local-path` (SD) | Small, infrequent writes |
| App database (`/var/lib/postgresql/data`, redis dumps) | `longhorn` (SSD) | Needs IOPS + replication |
| Build cache, image registry, scratch | `longhorn` (SSD) | Speed |
| Photo/video library | `nfs-tank` → `tank-photos` | Volume |
| Audio library (music, audiobooks) | `nfs-tank` → `tank-media` | Volume |
| Video recordings (Frigate, security cams) | `nfs-tank` → `tank-media` (when ready) | Volume |
| Family file drop / shared folder | `nfs-tank` → `tank-family` (Samba) | Volume + access |
| Long-term backups (DB dumps, Longhorn snapshots) | `nfs-tank` → `tank-backups` | Volume + parity |
| Hot data needing both speed and durability | `longhorn` (SSD), with restic backup to `tank-backups` | Both |

## Underutilized SSD — what to do with it

Roughly **4 TB of SSD sits empty**. Practical ways to use it:

### Easy wins (recommended)

1. **Move container images / k3s data off SD onto SSD on each node.** SD card
   wear is real; container images are write-heavy. Bind-mount
   `/var/lib/rancher` to a directory on the SSD. Frees ~30 GB on each SD card
   and speeds up pod cold starts.
2. **Migrate Nextcloud from hostPath to Longhorn.** Currently pinned to
   rpi-node1, single replica, no failover. Moving to Longhorn gives 2-replica
   redundancy and node mobility, and frees `/mnt/nextcloud` (or repurposes it
   for Longhorn). 730 MB to copy — trivial.
3. **Decommission the `nfs-1` tier.** After the remaining ~50 MB across
   Jellyfin / Audiobookshelf / Frigate / PXE is moved to `nfs-tank`, the
   rpi-control SSD can either:
   - Join the Longhorn pool (adds ~900 GB to fast tier), or
   - Become a dedicated backup target (separate physical disk from tank).
4. **Bump Longhorn replica count.** Critical PVs (databases) can move from
   2 → 3 replicas for survival of a 2-node failure.

### Specific PVCs that should be on Longhorn (SSD) but probably aren't

Most stateful apps default to `local-path` (SD card) unless told otherwise.
Worth auditing:

```sh
kubectl get pvc -A -o custom-columns=NS:.metadata.namespace,NAME:.metadata.name,SC:.spec.storageClassName,SIZE:.status.capacity.storage \
  | grep -E "local-path|^NS"
```

Anything that's a **database** or has **frequent small writes** should move to
`longhorn`. PVC migration is non-trivial (delete-recreate-restore) so plan one
at a time.

### Things NOT to do

- **Don't** mix SSDs into the `nfs-tank` mergerfs pool. They're tiny relative
  to the 26 TB drives and you'd waste their speed advantage.
- **Don't** use SSDs as snapshot storage for the tank tier — keeping snapshots
  next to data (current setup) is fine and saves the SSD for hot stuff.
- **Don't** try to RAID across USB SSDs spread across 5 different Pis — that's
  what Longhorn already does, properly, at the k8s layer.

## Capacity planning

| Tier | Today | After 2 more 26 TB drives | After clean-up |
|---|---|---|---|
| Bulk (tank) | 24 TB usable | 72 TB usable | same |
| SSD (Longhorn) | ~1 TB usable | same | ~2 TB usable (if rpi-control SSD joins) |
| SD (local-path) | ~500 GB scratch | same | same |

Plenty of room for years of growth without buying more hardware.

## Related

- [`bulk-storage.md`](./bulk-storage.md) — tank tier design + ops
- [`manifests/nfs-storage.yaml`](../manifests/nfs-storage.yaml) — `nfs-1` PVs
- [`manifests/tank-storage.yaml`](../manifests/tank-storage.yaml) — `nfs-tank` PVs
- [`ansible/playbooks/storage.yml`](../ansible/playbooks/storage.yml) — initial SSD setup
- [`ansible/playbooks/tank.yml`](../ansible/playbooks/tank.yml) — bulk tier setup
