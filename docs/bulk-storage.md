# Bulk-storage tier (SnapRAID on rpi-node4)

Big-disk storage for family files, photos, media, backups, and any k8s app
that needs more than the original 900 GB `nfs-1` tier can hold.

## TL;DR

- **Host:** rpi-node4 (192.168.4.32)
- **Hardware:** TerraMaster D4-320U DAS over USB 3.2 Gen 2
- **Drives today:** 2× 26 TB (1 data + 1 parity), can grow to 4× 26 TB
- **Usable today:** ~24 TB (mergerfs pool at `/mnt/tank`)
- **Usable when full:** ~72 TB (3 data + 1 parity)
- **Redundancy:** survives any 1 drive failure (SnapRAID parity)
- **Mac/iPhone access:** `smb://192.168.4.32/family`
- **Linux/k8s access:** `nfs://192.168.4.32/mnt/tank` (see PVs in [`manifests/tank-storage.yaml`](../manifests/tank-storage.yaml))

## Why this design?

The first storage tier (`/mnt/nfs` on rpi-control) is ~900 GB on a single SSD —
plenty for configs and small libraries but not for family photos and media. The
bulk tier sits next to it; nothing migrates automatically, apps move when ready.

### Layout chosen: SnapRAID + mergerfs, not traditional RAID

For 26 TB drives, traditional RAID 5/6 has long, risky rebuild windows (days of
pegged I/O during which a second failure means total loss). SnapRAID + mergerfs:

| Property | Why it matters here |
|---|---|
| Each disk stays a normal ext4 filesystem | Pull a drive, plug into anything, read your files |
| Parity is computed nightly, not real-time | Cheaper, but writes done today aren't protected until tonight's sync |
| Multi-drive failure only loses dead drives' contents | RAID would lose the whole array |
| Grows in place by adding more disks | Add 2 more drives → 72 TB usable, no migration |
| Mismatched drive sizes welcome | Future-proof, no rebuild on add |
| Tiny RAM/CPU cost | Runs fine on a Pi |

Tradeoff: not real-time parity, no read striping. Both irrelevant for media/photo
workloads on a 1 Gbps LAN.

## Drives and roles

| Mount | Device by-id | Serial | Role | Size |
|---|---|---|---|---|
| `/mnt/d1` | `usb-ST26000N_M000C-3WE103_ZXA18HVG-0:0` | ZXA18HVG | data | 24 TiB |
| `/mnt/parity1` | `usb-ST26000N_M000C-3WE103_ZXA07GWP-0:0` | ZXA07GWP | parity | 24 TiB |
| `/mnt/tank` | mergerfs union | — | pool | 24 TiB usable |

`/etc/fstab` mounts both data + parity by UUID (with `nofail` and
`x-systemd.device-timeout=30s` so a missing DAS doesn't block boot), then
mergerfs unions data drives into `/mnt/tank`.

## Subdirectory layout

```
/mnt/tank/
├── family/       (family:family, 2775)   — Samba share, shared family files
├── photos/       (victord:victord, 0775) — Immich destination
├── media/        (victord:victord, 0775) — future Jellyfin migration
├── backups/      (root:root, 0755)        — DB dumps, Longhorn target, restic
└── k8s/          (root:root, 0755)        — catch-all for new app PVs
```

The `family` subdir is owned by a shared `family` Unix user/group; the Samba
share uses `force user/group = family` so every SMB user writes as `family`
regardless of who connected. Combined with the setgid bit (`2775`), new files
inherit the `family` group, so everyone in the share can read/edit each
other's files — but who is *allowed* to connect is still controlled
per-person by the `samba_users` list, which means individual passwords and
revocability.

Each subdir is exposed both as an NFS PV (`tank-family`, `tank-photos`, …) and,
where useful, as a Samba share.

## Access

### From a Mac (Finder)

`Cmd-K` → `smb://192.168.4.32/family` → log in as `victord` with the SMB password
(see *Setting passwords* below). Drag-and-drop works; macOS metadata
(`.DS_Store`, resource forks) is handled correctly by `vfs_fruit`.

### From an iPhone (Files app)

Files → ⋯ → Connect to Server → `smb://192.168.4.32` → user `victord`.

### From Linux

```sh
mount -t nfs 192.168.4.32:/mnt/tank /mnt/somewhere
# or a subdir:
mount -t nfs 192.168.4.32:/mnt/tank/photos /mnt/photos
```

### From k3s pods

Use one of the PVs in `manifests/tank-storage.yaml`. Example PVC:

```yaml
apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: my-app-data
spec:
  accessModes: [ReadWriteMany]
  storageClassName: nfs-tank
  resources: { requests: { storage: 100Gi } }
  volumeName: tank-k8s   # bind to the tank-k8s PV
```

(All PVs are 24 Ti so any PVC fits — they share the pool, NFS doesn't enforce
per-PV quotas. First app to fill the pool wins.)

## SnapRAID schedule

Cron at `/etc/cron.d/snapraid` on rpi-node4:

- **Daily 02:00** — `snapraid sync` recomputes parity for new/changed files
- **Sundays 03:00** — `snapraid scrub -p 8 -o 14` reads 8% of blocks aged ≥14 days
  to detect bitrot. Covers the whole array every ~12 weeks.

Logs go to syslog tagged `snapraid-sync` and `snapraid-scrub`:

```sh
journalctl -t snapraid-sync -n 50
```

## What it protects against — and what it doesn't

For the long-form explainer with the *why* (XOR intuition, full failure
matrix, scaling math, when to act), see
[`drive-failure-recovery.md`](./drive-failure-recovery.md). Quick version:

✅ **Protected:** single-drive failure (data OR parity) → recoverable.
✅ **Protected:** bitrot / silent corruption → detected by `snapraid scrub`, fixable from parity.
✅ **Partial:** multi-drive failure → you lose only the dead drives' contents (each disk is independent ext4), not the whole pool.

❌ **NOT protected:** accidental `rm -rf` — parity will dutifully sync the deletion. *(Mitigation: snapshots — not yet set up; SMB recycle bin — not yet enabled.)*
❌ **NOT protected:** ransomware via SMB write access — *(Mitigation: snapshots, restic offsite backup.)*
❌ **NOT protected:** house fire / flood / theft / DAS PSU frying both drives — *(Mitigation: offsite backup of irreplaceables.)*

**RAID is not backup.** For irreplaceable data (family photos especially), the
plan is restic → Backblaze B2 (~$6/TB/yr) for the `photos/` subtree at minimum.
Not yet implemented.

## Operations

### Health check

```sh
ssh victord@192.168.4.32 'sudo snapraid status'
```

Shows files counted per drive, fragmentation, and time-since-last-sync.

### Manual sync (before unplugging or after big writes)

```sh
ssh victord@192.168.4.32 'sudo snapraid sync'
```

### Recovering a failed drive

1. Replace the dead drive in the bay
2. Partition + format ext4 with the same label (`data1`, `parity1`)
3. Mount at the same path (`/mnt/d1` etc.)
4. `sudo snapraid -d dN fix` to restore data from parity
5. `sudo snapraid sync`

### Adding a 3rd or 4th data drive

```sh
# On rpi-node4:
sudo sgdisk -Z /dev/sdX
sudo sgdisk -n 1:0:0 -t 1:8300 -c 1:data2 /dev/sdX
sudo mkfs.ext4 -L data2 -m 0 -E lazy_itable_init=1,lazy_journal_init=1 /dev/sdX1
sudo mkdir /mnt/d2
echo "UUID=<new-uuid> /mnt/d2 ext4 defaults,nofail,x-systemd.device-timeout=30s 0 2" | sudo tee -a /etc/fstab
sudo mount /mnt/d2

# Add to mergerfs in /etc/fstab — change branches:
#   /mnt/d1  /mnt/tank  fuse.mergerfs  ...
# to:
#   /mnt/d1:/mnt/d2  /mnt/tank  fuse.mergerfs  ...
sudo umount /mnt/tank && sudo mount /mnt/tank

# Add to /etc/snapraid.conf:
#   data d2 /mnt/d2
sudo snapraid sync
```

Better: update `tank_data_drives` in `ansible/playbooks/tank.yml` and run the playbook.

### Adding a family member to the SMB share

The list of SMB users lives in [`ansible/host_vars/rpi-node4.yml`](../ansible/host_vars/rpi-node4.yml)
under `samba_users`. Adding someone is two files + one ssh command:

```sh
# 1. Edit ansible/host_vars/rpi-node4.yml — add their name to samba_users:
#    samba_users:
#      - victord
#      - mom
#      - wife
#      - kid          # ← new line
#
# 2. Re-run the playbook (creates the Linux user, updates smb.conf valid_users):
cd ansible
ansible-playbook playbooks/tank.yml --ask-become-pass

# 3. Set their SMB password (interactive — only step that can't be automated):
ssh victord@192.168.4.32
sudo smbpasswd -a kid
```

Then they mount `smb://192.168.4.32/family` from Finder (`⌘K`) with their own
password. To revoke access later, remove them from `samba_users` and re-run —
the playbook will drop them from `valid users` in smb.conf. (Their Linux user
and SMB password DB entry stay around as orphans; clean those up by hand if
you care: `sudo userdel kid && sudo smbpasswd -x kid`.)

### Changing an existing user's SMB password

```sh
ssh victord@192.168.4.32
sudo smbpasswd <username>      # no -a flag for an existing user
```

### Reproducible setup

The initial format was done by hand (too dangerous to automate). Everything
after that is captured in `ansible/playbooks/tank.yml` and can be re-run
idempotently to recreate the NFS export, Samba config, snapraid config, cron,
and the subdir layout:

```sh
cd ansible
ansible-playbook playbooks/tank.yml --ask-become-pass
```

> **Don't hand-edit `/etc/samba/smb.conf`, `/etc/exports.d/tank.exports`, or
> `/etc/snapraid.conf` on the node.** The playbook rewrites them on every run,
> so hand-edits silently disappear next time someone re-runs it. Make changes
> in `ansible/playbooks/tank.yml` (or `ansible/host_vars/rpi-node4.yml` for the
> user list) and re-run. Always `--check --diff` first if you're unsure — it
> shows exactly what will change on disk.

## Troubleshooting

### Finder: "the operation can't be completed because original item for 'family' can't be found"

Almost always a stale Finder alias or cached mount, not a real Samba problem.
Fix:

1. In Finder sidebar, click the eject icon next to `192.168.4.32` (or whatever
   the share is mounted as) — kills any stuck connection.
2. Finder → `⌘K` → type **exactly** `smb://192.168.4.32` (no trailing path) →
   Connect → enter your SMB username + password → pick `family` from the list.

If the error reproduces after a clean reconnect, then it's real — check
`sudo journalctl -u smbd -n 100` on rpi-node4 and `sudo testparm -s` to
validate smb.conf.

### "I can't edit files in the share"

Files in `/mnt/tank/family` should always be `family:family`. If something
created files with a different owner (e.g. an old NFS write before
`force user = family` was in place), they may not be writable by the SMB
user. Fix:

```sh
ssh victord@192.168.4.32
sudo chown -R family:family /mnt/tank/family
sudo chmod -R g+w /mnt/tank/family
```

The directory's setgid bit (`drwxrwsr-x`) ensures *new* files inherit the
`family` group automatically, so this should only ever be a one-time cleanup.

### `smbpasswd -a <user>` fails with "Failed to add entry for user"

The Linux user doesn't exist yet. Add them to `samba_users` in
`ansible/host_vars/rpi-node4.yml` and re-run the playbook — that creates the
Linux user as a side effect. Then `smbpasswd -a` will succeed.

### k8s pods can't mount `nfs-tank` PVs

Check that `/etc/exports.d/tank.exports` still has `fsid=20` on every entry
— it's required because `/mnt/tank` is mergerfs (FUSE), which the kernel NFS
server can't auto-ID. The playbook sets this; if it goes missing, something
hand-edited the file.

## Manifests touched

- [`manifests/tank-storage.yaml`](../manifests/tank-storage.yaml) — new `nfs-tank` StorageClass + PVs
- [`ansible/playbooks/tank.yml`](../ansible/playbooks/tank.yml) — NFS + Samba + snapraid config
- [`ansible/host_vars/rpi-node4.yml`](../ansible/host_vars/rpi-node4.yml) — `samba_users` list (the one file you edit to add a family member)

## Open follow-ups

- [ ] Set Samba passwords for `mom` and `wife` (`sudo smbpasswd -a mom`, `sudo smbpasswd -a wife` on rpi-node4)
- [ ] Migrate Immich photo library from Longhorn/local-path → `tank-photos`
- [ ] Snapshots (snapper on the data drives, or rsnapshot wrapper)
- [ ] Offsite backup for `photos/` → Backblaze B2 via restic
- [ ] Add `nfs-tank` to Longhorn backup targets (use `tank-backups`)
- [ ] When 2 more drives arrive: expand pool to 3 data + 1 parity (~72 TB usable)
