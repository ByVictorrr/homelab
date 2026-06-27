# iCloud Photo Library backup via icloudpd → Immich External Library

Pulls everything from one (or more) iCloud Photo Libraries into the bulk tier
nightly, surfacing it in Immich alongside native uploads. Belt-and-suspenders
alongside the Immich mobile app — the app covers anything taken on-device
after install; icloudpd covers history, shared content, and family members on
their own iCloud accounts.

## How it fits together

```
Apple iCloud
     │
     │  icloudpd (k8s CronJob, one per account, nightly)
     │  authenticated via cached session cookie
     ▼
/mnt/tank/photos/icloud/<slug>/YYYY/MM/IMG_xxxx.HEIC
     │
     │  Immich's library mount IS /mnt/tank/photos,
     │  so it sees icloud/<slug>/ automatically
     ▼
Immich UI: External Library /data/icloud/<slug>
           — faces, dates, search, just like native uploads
```

No copy step. icloudpd writes the file; Immich reads it. The two cohabit the
same NFS path.

## Add an account (one command)

```sh
scripts/add-icloud-account.sh
```

Prompts for:
- **Slug** — short directory name (e.g. `victor`, `mom`, `dad`)
- **Apple ID email**
- **Apple ID password** (hidden input)

Then:
1. Creates `/mnt/tank/photos/icloud/<slug>/` on rpi-node4
2. Applies a per-account namespace `icloudpd-<slug>` with a CronJob + cookie PVC
3. Stores credentials in a k8s Secret
4. Launches an interactive pod for **Apple's 2FA prompt** — type the SMS code
5. Prints next steps for the Immich UI

Run it once per iCloud account.

Non-interactive form, with custom schedule:

```sh
SCHEDULE='0 5 * * *' scripts/add-icloud-account.sh dad dad@example.com
# (still prompts for password — never accepts it via argv or env for safety)
```

Remove an account (downloads on tank are preserved):

```sh
scripts/add-icloud-account.sh --remove mom
```

## Wire it into Immich (one-time UI step per account)

Immich's API doesn't expose External Library creation reliably across versions,
so this stays manual:

1. Open the Immich UI (`https://photos.<tailnet>.ts.net` or
   `http://photos.192.168.4.27.nip.io`)
2. Log in as admin
3. **Administration → External Libraries → Add Library**
4. **Owner**: the Immich user that should own these photos
5. **Import Path**: `/data/icloud/<slug>`
6. **Watch**: on
7. Save → **Scan All Libraries**

Immich now indexes the iCloud downloads. New files (from the nightly CronJob)
get picked up automatically thanks to Watch.

## What the script creates

For slug `mom`:

| Resource | Location |
|---|---|
| Directory | `rpi-node4:/mnt/tank/photos/icloud/mom/` |
| Namespace | `icloudpd-mom` |
| Secret | `icloudpd-mom/icloudpd-creds` (apple-id + password + account-slug) |
| Cookie PVC | `icloudpd-mom/icloudpd-cookies` (1 Gi, Longhorn — persists session) |
| CronJob | `icloudpd-mom/icloudpd-sync` (default `0 4 * * *`) |

Per-account namespaces give clean isolation: deleting one user's setup doesn't
touch any other's, and credentials never overlap.

## Cookie expiry / re-auth

Apple session cookies expire every ~30 days. When that happens the CronJob
starts failing with auth errors. Detect it:

```sh
kubectl get jobs -A | grep icloudpd | awk '$3==0'   # any jobs with 0 completions
```

When that happens, re-run the script for that account — it's idempotent and
will trigger a fresh 2FA bootstrap:

```sh
scripts/add-icloud-account.sh mom mom@example.com
```

To get alerted automatically: Prometheus already scrapes `kube-state-metrics`.
A PrometheusRule on `kube_job_failed{namespace=~"icloudpd-.*"} > 0` will fire
in Alertmanager / Grafana.

## What gets pulled (and what doesn't)

✅ **Pulled:**
- Photo + video originals from iCloud Photo Library
- Live Photos (both still + video portion)
- Shared albums you own
- Edits preserved (Apple stores edits as adjustments; both originals + edits download)

❌ **NOT pulled** by icloudpd:
- iCloud Drive files — use `rclone` with the iCloud Drive backend, or copy via Finder
- Messages history — only via Mac with Messages-in-iCloud → Time Machine
- App data backed up via iCloud Backup of the device — only via plug-in-to-Mac → Finder backup → Time Machine
- Notes / Reminders / Calendar / Contacts — different scope

## Why it's safe alongside the Immich mobile app

Both can run together. If a photo arrives via both routes, Immich detects the
duplicate via checksum and you can either:

- Leave both visible (they're identical, costs almost nothing)
- Use Immich's **Duplicate Detection** to surface them
- Use Immich's **Stacks** to group them

The Immich mobile app uploads to `/data/upload/` (native library).
icloudpd writes to `/data/icloud/<slug>/`. They never collide at the
filesystem level.

## Operations

### Trigger a manual sync for one account

```sh
kubectl -n icloudpd-mom create job test-$(date +%s) --from=cronjob/icloudpd-sync
kubectl -n icloudpd-mom logs -f -l job-name
```

### List all configured accounts

```sh
kubectl get namespaces -l icloudpd.account
```

### Disable an account temporarily (e.g. while traveling)

```sh
kubectl -n icloudpd-mom patch cronjob icloudpd-sync -p '{"spec":{"suspend":true}}'
# Re-enable:
kubectl -n icloudpd-mom patch cronjob icloudpd-sync -p '{"spec":{"suspend":false}}'
```

### Disk usage by account

```sh
ssh victord@192.168.4.32 'sudo du -sh /mnt/tank/photos/icloud/*'
```

### View recent run logs across all accounts

```sh
for ns in $(kubectl get ns -l icloudpd.account -o name); do
  echo "=== $ns ==="
  kubectl -n "${ns#namespace/}" logs --tail=20 -l job-name 2>/dev/null
done
```

## File layout on tank

```
/mnt/tank/photos/icloud/
├── victor/
│   ├── 2024/01/IMG_0001.HEIC
│   ├── 2024/01/IMG_0001_HEVC.MOV       # Live Photo video portion
│   ├── 2024/02/...
│   └── ...
├── mom/
│   └── 2024/...
└── dad/
    └── ...
```

`{:%Y/%m}` folder structure means easy browsing from a Mac via SMB if Immich
is ever unavailable.

## Related

- [`scripts/add-icloud-account.sh`](../scripts/add-icloud-account.sh) — the script
- [`manifests/tank-storage.yaml`](../manifests/tank-storage.yaml) — bulk tier PVs
- [`manifests/immich.yaml`](../manifests/immich.yaml) — Immich (External Libraries set up via UI)
- [`docs/bulk-storage.md`](./bulk-storage.md) — the tank tier this depends on
