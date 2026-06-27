# Drive failure & recovery — how parity actually saves you

A plain-English explainer for the tank tier on rpi-node4. If you want the
commands and ops side, see [`bulk-storage.md`](./bulk-storage.md); this doc
is about the *why*: what happens when a drive dies, how the surviving drive
can rebuild the lost one, and the scenarios where parity won't save you.

## TL;DR

- You have **2 drives** in the DAS: one holds your **data**, one holds
  **parity** (math derived from the data).
- If **either drive dies**, you replace it and rebuild from the survivor.
  Zero file loss.
- That's the *only* thing parity protects against. Two drives dying at
  once, ransomware, accidental `rm -rf`, and house fires are all separate
  problems with separate answers (mostly: off-site backup).
- Future you adds more data drives. Parity stays at one drive. Overhead
  drops from 50% today (1 of 2 drives) → 20% at 4 data drives (1 of 5).

## The setup, in one picture

```
TerraMaster DAS over USB 3.2 Gen 2
├── /dev/sdb → /dev/sdb1 → /mnt/d1       24 TiB   DATA
└── /dev/sdc → /dev/sdc1 → /mnt/parity1  24 TiB   PARITY
                                ↓
                          /mnt/tank      24 TiB usable
                          (mergerfs union view —
                           today equals /mnt/d1)
```

Each 26 TB drive is **one single partition** that spans the whole disk.
Not split into slices. The `sdb` / `sdb1` you see in `lsblk` is just the
physical-drive / partition naming convention — one of each.

### Why "26 TB" shows as "24 TB"

Two unrelated things stacked, neither is wrong:

1. **Marketing TB vs real TiB.** Drive vendors sell in decimal (1 TB =
   10¹² bytes). Linux's `df` reports in binary (1 TiB ≈ 1.1 decimal TB).
   A "26 TB" drive is really ~23.6 TiB. Same drive, different yardstick.
2. **Filesystem overhead.** ext4 reserves a tiny bit for metadata + a
   small root-only reserve. Negligible at this scale.

Nothing was lost.

## How parity saves you

### The intuition (with one data drive — your setup today)

With one data drive, parity is literally a mirror. Byte-for-byte the same
as the data drive. If `sdb1` melts, `sdc1` has every file. If `sdc1`
melts, `sdb1` has every file. Whichever survives, you copy from it to a
replacement drive.

(This is why "1 data + 1 parity" feels like 50% overhead: you're paying for
a full second copy. It pays off later — see below.)

### The intuition (with 2+ data drives — once the pool grows)

Once you add a second data drive, parity stops being a mirror and becomes
a **XOR sum** of the corresponding blocks across all data drives:

```
parity_block_N = data1_block_N XOR data2_block_N XOR data3_block_N ...
```

XOR has a useful property: if you know all-but-one of the inputs and the
output, you can derive the missing one:

```
data2_block_N = data1_block_N XOR parity_block_N XOR data3_block_N ...
```

So when *any one* data drive dies, SnapRAID reads every surviving data
drive plus the parity drive, XORs them block-by-block, and writes the
result to the replacement drive. The file system that comes out is
bit-for-bit identical to the one that died.

The *parity drive* dying is even simpler — there's nothing to reconstruct,
just recompute parity from the surviving data drives.

### Walkthrough: data drive (`/mnt/d1`) dies

1. You notice — kernel log full of I/O errors, `df` shows `/mnt/d1`
   gone, app pods that mount tank start failing, or (if you set up SMART
   alerts) you get a warning before it fully dies.
2. **Don't panic.** Files on the live drive(s) keep serving over Samba/NFS;
   only data on the dead drive is unavailable until rebuild.
3. Buy a replacement 26 TB drive. Doesn't have to be the same brand /
   model — only the *size* matters (must be ≥ the dead drive).
4. Pull the dead drive from the DAS bay, slot the replacement.
5. Partition + format ext4 with the same label (`data1`), mount at the
   same path (`/mnt/d1`). The exact commands are in
   [`bulk-storage.md` § Recovering a failed drive](./bulk-storage.md#recovering-a-failed-drive).
6. Run `sudo snapraid -d d1 fix` — it streams data from parity back onto
   the new disk. **Expect ~24 hours** for a full rebuild over USB 3.2
   (≈250 MB/s sustained, bottlenecked by the DAS, not the drives).
7. Run `sudo snapraid sync` to mark the array clean again.
8. Files come back identical, bit-for-bit. Done.

### Walkthrough: parity drive (`/mnt/parity1`) dies

Even simpler — no files were ever on this drive.

1. Replace the dead drive, partition + format with label `parity1`, mount
   at `/mnt/parity1`.
2. Run `sudo snapraid sync` — parity is recomputed from live data.
3. ~24 hours later, you're back to single-drive-failure protection.

Files were never at risk during the parity-drive failure. You were just
**unprotected** for the window between the parity drive dying and the
rebuild completing — if a data drive *also* died in that window, you'd
lose files. So fix parity failures with the same urgency as data failures.

## What parity does NOT save you from

This is the honest part. Single-drive-failure protection is one specific
guarantee, not a magic shield. Here's the full failure matrix:

| Scenario | Parity helps? | Mitigation |
|---|---|---|
| One drive dies (data OR parity) | ✅ Full recovery | This whole doc |
| Bitrot / silent corruption on one drive | ✅ Detected by weekly `snapraid scrub`, fixable from parity | Already runs Sundays 03:00 |
| **Two drives die before rebuild finishes** | ❌ Data on dead drives is gone | More parity drives (raid6-ish) or off-site backup |
| **Whole DAS fries** (PSU, controller, drop, theft, fire, flood) | ❌ All drives gone at once | **Off-site backup** is the only answer |
| Accidental `rm -rf`, mom drags Photos to Trash by mistake | ⚠️ Caught by nightly sync — see below | Snapshots + SMB recycle bin |
| Ransomware encrypts files via SMB | ❌ SnapRAID will dutifully parity-protect the encrypted versions | Snapshots, off-site backup, restricting SMB write access |
| You overwrote a file with a worse version | ❌ Same file path, no version history | Snapshots, Git for code |

### The "accidental deletion" footnote

`snapraid sync` runs **nightly at 02:00** and bakes the current state into
parity. So:

- **If you delete a file at 1pm and notice at 3pm**, the file is still in
  parity (last sync was last night, deletion hasn't been parity'd yet).
  `sudo snapraid fix -f path/to/file` brings it back. ✅
- **If you delete a file at 1pm and notice tomorrow afternoon**, last
  night's sync already wrote "this file is gone" into parity. Recovery
  not possible from parity alone. ❌

The SMB share has a recycle bin (`vfs_recycle`) enabled — deletes via
Finder go to `.recycle/<username>/` inside the share, not actually
deleted. That covers the common case (mom drags something to the trash).
It does *not* cover deletes done over NFS or via SSH on the node.

## How parity scales as you add drives

The big payoff of SnapRAID over just buying two drives and rsync'ing
between them: parity doesn't double when you double data. One parity
drive protects every data drive in the pool.

| Drives in DAS | Data drives | Parity drives | Usable | Overhead |
|---|---|---|---|---|
| 2 (today) | 1 × 26 TB | 1 × 26 TB | 24 TiB | 50% |
| 3 | 2 × 26 TB | 1 × 26 TB | 48 TiB | 33% |
| 4 (DAS max) | 3 × 26 TB | 1 × 26 TB | 72 TiB | 25% |

A second parity drive (raid6-equivalent, survives 2 failures at once) is
also possible. SnapRAID supports up to 6 parity drives. Not configured
today — the tradeoff is "lose one DAS bay's worth of data capacity in
exchange for surviving *two* simultaneous failures." Worth it once you
have lots of data drives (4+) where rebuild windows get long and
second-failure probability climbs.

## What to actually do when a drive fails

The hard rule: **act on the failure within a week.** SnapRAID survives
one drive dying. It does not survive two drives dying when you've been
ignoring the first one for a month.

Right now there's **no automated alerting** — you'd find out by noticing
something broke, or by running `snapraid status` manually. Two cheap
improvements worth doing before you need them:

1. **SMART monitoring with email/ntfy alerts.** `smartd` reads SMART
   attributes from each drive every few hours and emails on
   pre-failure indicators (reallocated sectors climbing, read-error
   rate spiking, etc.). Catches most drives ~weeks before they fully
   die. Not yet set up.
2. **A simple health check cron** that emails if `snapraid status` reports
   anything other than "no error detected". Cheap insurance. Not yet
   set up.

If you want either of those wired up, ask — they're each a small ansible
addition.

In the meantime, a quick manual check any time you're poking around:

```sh
ssh victord@192.168.4.32 'sudo snapraid status'
```

Should report "No error detected" and a recent sync time. Anything else
deserves a closer look.

## The next layer: off-site backup

Parity protects against drives. Off-site backup protects against
everything else — theft, fire, flood, ransomware, "I rm-rf'd the wrong
thing two weeks ago." It's a different shape of problem and needs a
different tool.

The current plan (not yet implemented, tracked in
[`bulk-storage.md` § Open follow-ups](./bulk-storage.md#open-follow-ups)):

- **restic → Backblaze B2** for `/mnt/tank/photos` (irreplaceable family
  data) at a minimum.
- ~$6/TB/year. Encrypted client-side so B2 only sees opaque blobs.
- Incremental, deduped, can restore individual files or whole tree.
- Nightly cron job after `snapraid sync` finishes.

When you're ready to set that up, this is the doc to extend.

## Related

- [`bulk-storage.md`](./bulk-storage.md) — operational guide:
  commands, fstab entries, file layout, troubleshooting
- [`storage-allocation.md`](./storage-allocation.md) — what's currently
  using which subdir of the tank pool
- [`storage-tiers.md`](./storage-tiers.md) — when to put data on the
  tank tier vs Longhorn vs local-path
- [`ansible/playbooks/tank.yml`](../ansible/playbooks/tank.yml) —
  the source of truth for snapraid + samba + nfs config
