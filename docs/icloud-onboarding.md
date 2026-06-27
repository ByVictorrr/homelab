# iCloud account onboarding (one-command flow)

Quick reference for adding an iCloud Photo Library to the nightly backup —
yours, your parents', your kids', anyone whose Apple ID you have access to.
For the full design + ops, see [`icloud-backup.md`](./icloud-backup.md).

## What's a "slug"?

A short, lowercase, no-spaces name you pick for each iCloud account. It
becomes both the directory name on tank and the k8s namespace suffix.

Examples:
- `victor`, `mom`, `dad`, `wife`, `kid1`

Once you pick it, **every command and path uses that string in place of
`<slug>`**:

| If your slug is `mom`… | …then `<slug>` becomes |
|---|---|
| `/data/icloud/<slug>` (Immich) | `/data/icloud/mom` |
| `/mnt/tank/photos/icloud/<slug>/` (on rpi-node4) | `/mnt/tank/photos/icloud/mom/` |
| `icloudpd-<slug>` (k8s namespace) | `icloudpd-mom` |

Keep slugs short and stable — Immich's External Library config references
them and renaming later means re-indexing.

## Step 1 — run the script

```sh
scripts/add-icloud-account.sh
```

Prompts for slug + Apple ID + password (hidden). Then handles:

1. `mkdir` the destination on rpi-node4
2. `kubectl apply` namespace + cookie PVC + CronJob (per-account namespace `icloudpd-<slug>`)
3. Create credentials Secret
4. Launch interactive pod for Apple's 2FA prompt — you type the SMS code
5. Print the next steps

Examples:

```sh
# Your account:
scripts/add-icloud-account.sh victor you@icloud.com

# Your parents:
scripts/add-icloud-account.sh mom mom@icloud.com
scripts/add-icloud-account.sh dad dad@icloud.com
```

Each account gets isolated in its own namespace and writes to its own subfolder
under `/mnt/tank/photos/icloud/<slug>/`. Run the script once per account.

Custom schedule (env override):

```sh
SCHEDULE='0 5 * * *' scripts/add-icloud-account.sh dad dad@icloud.com
```

Remove an account (downloads on tank are preserved):

```sh
scripts/add-icloud-account.sh --remove mom
```

## Step 2 — the 2FA bootstrap prompt

The script will pause at:

```
Press Enter to launch the bootstrap pod...
```

Press Enter. Then watch for these stages.

### Stage 1 — pod starts (5–30 sec)
The icloudpd image is already cached on rpi-node4 so this should be fast.

### Stage 2 — icloudpd authenticates with Apple
Output:
```
INFO     Authenticating...
INFO     Two-step authentication is required...
```
**Apple texts a 6-digit code** to your trusted device (the iPhone/iPad/Mac
registered with that Apple ID). Takes 10–30 seconds to arrive.

### Stage 3 — the prompt
```
Please enter two-factor authentication code:
```
Type the 6 digits, hit Enter.

### Stage 4 — success
```
INFO     Authenticated.
pod "icloudpd-bootstrap" deleted
```
Cookie is now saved on the Longhorn PVC. The script continues to print
the Immich UI instructions.

### Things that can go wrong

- **No code arrives** → Apple may have rate-limited. Wait 60 seconds, re-run.
- **"Failed: Wrong verification code"** → re-run the script. Codes expire fast.
- **Prompt never appears, pod exits cleanly** → cookie from a previous bootstrap
  is still valid. You're done, move to Step 3.
- **Pod hangs with no prompt at all** → terminal isn't passing the TTY. Use a
  real terminal (iTerm, Terminal.app), not tmux-detached / VS Code Run Task /
  CI runner.

## Step 3 — register the External Library in Immich

The Immich UI's "Add Library" dialog is unreliable across versions (it often
shows "invalid path" even for paths that demonstrably exist). Skip the UI
fight — the same script does it for you over Immich's REST API if you set
one env var first:

```sh
# 1. Get an API key (one time, reusable for all accounts):
#    Immich UI → Account Settings → API Keys → "New API Key" → copy

export IMMICH_API_KEY=<paste the key>

# 2. Re-run the script — it skips re-bootstrap if the cookie is valid and
#    will just register the Immich library.
SKIP_BOOTSTRAP=1 scripts/add-icloud-account.sh victor you@icloud.com
```

If you set `IMMICH_API_KEY` **before** running the script the first time,
adding an account becomes truly one command (k8s + 2FA + Immich all in one):

```sh
export IMMICH_API_KEY=<key>
scripts/add-icloud-account.sh mom mom@icloud.com
```

### One API key, multiple Immich users

The same `IMMICH_API_KEY` (yours) works for setting up any iCloud account. By
default, the library Immich creates is owned by **you** (the key holder).

To assign the library to a different Immich user — e.g. mom has her own
Immich account and you want her photos under her user — pass her Immich
email as the **3rd argument**:

```sh
# Library will be owned by mom@yourdomain.com in Immich,
# even though your API key did the create.
scripts/add-icloud-account.sh mom mom@icloud.com mom@yourdomain.com
```

(`IMMICH_OWNER_EMAIL=<email>` env var works too if you prefer.)

The Immich user must already exist — create them via Administration → Users
in the Immich UI first.

### Library management subcommands

```sh
scripts/add-icloud-account.sh --list-libraries          # show all Immich libraries
scripts/add-icloud-account.sh --remove-library <id>     # delete an Immich library
```

### Doing it by hand in the UI (if you must)

Where to look depends on Immich version:

| Where to look | Notes |
|---|---|
| **Administration → External Libraries** | Most common in v1.106+ |
| **Account Settings → External Libraries** | Recent v2.x moved these per-user |
| **Administration → Settings → External Library** | **NOT the right page** — only Watching / Periodic Scanning toggles |

When you find the right page: **Create Library** → Owner = your Immich user →
**Import Path** = `/data/icloud/<slug>` (e.g. `/data/icloud/victor`) → Save →
**Scan All Libraries**.

## Step 4 — kick off the first sync (don't wait for 04:00)

```sh
SLUG=victor   # whatever slug you used
kubectl -n icloudpd-$SLUG create job test-$(date +%s) --from=cronjob/icloudpd-sync
kubectl -n icloudpd-$SLUG logs -f -l job-name
```

First sync downloads your entire iCloud library — could be hours-to-days
depending on size. Subsequent nightly runs are incremental and fast.

## What the script creates (per account)

For slug `mom`:

| Resource | Location |
|---|---|
| Directory | `rpi-node4:/mnt/tank/photos/icloud/mom/` |
| Namespace | `icloudpd-mom` |
| Secret | `icloudpd-mom/icloudpd-creds` (apple-id + password + slug) |
| Cookie PVC | `icloudpd-mom/icloudpd-cookies` (1 Gi, Longhorn — persists session) |
| CronJob | `icloudpd-mom/icloudpd-sync` (default `0 4 * * *`) |

Per-account namespaces give clean isolation: deleting one user's setup doesn't
touch any other's, and credentials never overlap.

## When cookies expire (~every 30 days)

Re-run the script for that account — it's idempotent and re-triggers the 2FA
bootstrap:

```sh
scripts/add-icloud-account.sh mom mom@icloud.com
```

Detect expired sessions:

```sh
kubectl get jobs -A | grep icloudpd | awk '$3==0'
```

## List all configured accounts

```sh
kubectl get namespaces -l icloudpd.account
```

## Related

- [`scripts/add-icloud-account.sh`](../scripts/add-icloud-account.sh) — the only script (k8s + 2FA + Immich registration)
- [`docs/icloud-backup.md`](./icloud-backup.md) — full design + operations
- [`docs/bulk-storage.md`](./bulk-storage.md) — the tank tier this depends on
