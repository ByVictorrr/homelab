# Family iPhone / iPad photo backup setup — message template

Pairs with `family-timemachine-setup.md`. Same idea: a message you can send to
a family member to set up auto-backup of their phone/iPad photos to the home
tank via the Immich app, with zero ongoing maintenance for either of you.

## Before sending (prep on your end)

1. **Create an Immich user for them** (only if they don't already have one):
   - Open Immich UI: `http://photos.192.168.4.27.nip.io` or `https://photos.<tailnet>.ts.net`
   - **Administration → Users → New User**
   - Email: `<theirname>@yourdomain.com` (any email — only used for login)
   - Name: their name
   - Set an initial password — Immich will force them to change it on first login
   - Optional: set a per-user storage quota under their user details

2. **Get their phone on the tailnet** (only needed if they'll back up over LTE):
   - login.tailscale.com → Users → Invite to email
   - Or share just the `photos` ingress: login.tailscale.com → Machines → photos-ingress → Share

3. **Give them their login info** through a secure channel (Signal, in-person,
   1Password share — never plaintext email/SMS).

## Message body (copy-paste into iMessage / Signal / Mail)

**Subject:** Setting up auto-backup for your iPhone photos

---

Hey — putting your iPhone on auto-backup to my home server. Once this is done
it runs forever in the background. Photos and videos you take show up on the
server within a minute or so. Frees up your iCloud (you can downgrade plans),
and if your phone is ever lost/stolen everything is recoverable. ~5 min, two
steps.

### 1. Install Tailscale (so it works when you're not at home)

This is the secure tunnel that connects your phone to the home server from
anywhere — coffee shop, your office, your in-laws' house.

- Open the App Store, search for **Tailscale**, install
- Open it, tap **Get Started**
- Sign in with the email I sent the invite to (look for a "Tailscale
  invitation" email in your inbox)
- Tap **Allow** when it asks to add a VPN profile (this is normal — it's
  Tailscale's tunnel, not data going through anyone else)
- Done — leave it running. There's a little Tailscale icon next to the
  battery indicator when it's connected.

### 2. Install Immich and turn on auto-backup

- App Store → search **Immich** → install (it's free, open-source)
- Open Immich. Tap **Server URL** and paste:

  ```
  http://photos.192.168.4.27.nip.io
  ```

  *(Or on Tailscale: `https://photos.<my-tailnet>.ts.net` — I'll send the
  exact one.)*

- Tap **Next**
- Log in with the credentials I sent you. You'll be forced to change the
  password on first login — pick something memorable.
- Tap your profile picture (top right) → **Account Settings** → **Backup**
- Toggle **Backup** ON
- Optional but recommended: also toggle **Foreground Backup** and
  **Background Backup** ON
- Pick which albums to back up — usually **Recents** (= camera roll) is all
  you need. You can pick more later.
- Tap **Start Backup**

You'll see a progress bar — first run uploads your whole library and can take
hours on a big phone. Subsequent backups happen automatically every time the
app opens or you charge the phone overnight.

### 3. (Optional) Stop paying Apple for iCloud Photos

Once you confirm your photos are showing up in Immich and you're happy with
the workflow, you can:

- **Apple Settings → Apple ID → iCloud → Photos → toggle "Sync this iPhone" OFF**
  (Apple will warn you; it'll keep originals on the device but stop uploading
  new ones to iCloud)
- **Apple Settings → Apple ID → iCloud → Manage Storage → Photos →
  Disable & Delete** if you want to free the iCloud space (gives you 30 days
  to change your mind — Recently Deleted recovery window)
- Then **Apple Settings → Apple ID → iCloud → Storage** → downgrade your
  storage plan if you don't need 200 GB / 2 TB anymore.

This is optional. Some people keep iCloud as a second backup just in case.
It's belt + suspenders.

### Questions / troubleshooting

If photos don't seem to be uploading:

- Open the Immich app → tap **Backup** at the top → check the status
- Make sure Tailscale is connected (icon by battery)
- Background backup only happens when Immich is open OR phone is charging
  AND on WiFi. If you want **always-on** backup, leave the app open
  periodically.

If you can't reach the server:

- Wifi: should work at home (LAN URL) and away (Tailscale URL)
- Cellular: only the Tailscale URL works, and only with Tailscale connected
- Pick one URL and stick with it for consistency

---

## What this gives the family vs the iCloud-only approach

| | iCloud Photos only | Immich app auto-backup |
|---|---|---|
| Storage cost | $0.99–$9.99/mo per Apple ID | $0 (lives on your home tank) |
| Storage limit | 5 GB / 50 GB / 200 GB / 2 TB | ~24 TB (effectively unlimited) |
| Multiple family members share pool | ❌ each pays for own iCloud | ✅ one server holds everyone's |
| Survives Apple account ban / loss of access | ❌ | ✅ |
| Searchable by face / object / date | ✅ | ✅ (Immich does ML on tank) |
| Available outside your home | ✅ Apple's CDN | ✅ Tailscale tunnel |
| Photo-sharing albums with non-family | ✅ Apple's UI | ✅ Immich's UI (link sharing) |
| Off-cluster backup of irreplaceables | Apple keeps it | Set up restic → Backblaze B2 separately (~$6/TB/yr) |

## Notes for you (the admin)

### Where the photos actually land

For each family member with their own Immich user, photos upload via the app
to **Immich's native library**, which lives at `/data/upload/<user-id>/` inside
the Immich pod — which is `/mnt/tank/photos/upload/<user-id>/` on rpi-node4.

This is a different path from `icloud/<slug>/` (which is where icloudpd-pulled
photos land). Each Immich user only sees their own uploads + any libraries
explicitly shared with them.

### Do you still need icloudpd?

Two cases where yes:
- **Backfilling old photos**: photos taken years ago are already in iCloud
  but not on the phone. The Immich app only uploads what's *on the device*.
  icloudpd pulls iCloud → tank for the historical archive, then you can
  disable the CronJob.
- **Family member who refuses to install Immich**: keep their iCloud sync
  running, point icloudpd at it, and let them keep using Apple's app.

If neither applies, you can **suspend the icloudpd CronJob** for that user:

```sh
kubectl -n icloudpd-<slug> patch cronjob icloudpd-sync \
  -p '{"spec":{"suspend":true}}'
```

Re-enable by setting `suspend:false`. The Apple ID secret + cookie PVC stay
intact — re-enabling later doesn't require re-bootstrap as long as the cookie
is still within its 30-day window.

### One-time historical pull pattern

For a clean "back up the entire iCloud history, then stop":

```sh
# 1. Set up the account (one full sync starts running):
scripts/add-icloud-account.sh victor vickol1234@aol.com

# 2. Watch first sync finish (can be hours-to-days; safe to leave overnight)
ssh victord@192.168.4.32 'sudo du -sh /mnt/tank/photos/icloud/victor/'

# 3. Once complete, suspend the nightly job:
kubectl -n icloudpd-victor patch cronjob icloudpd-sync -p '{"spec":{"suspend":true}}'

# 4. Disable iCloud Photos on the iPhone, install Immich app for future photos
```

You now have the entire iCloud library archived on tank, all future photos
land on tank directly via the Immich app, and no more 30-day re-auth.

## Related

- [`docs/icloud-backup.md`](./icloud-backup.md) — icloudpd design + ops
- [`docs/icloud-onboarding.md`](./icloud-onboarding.md) — adding icloudpd accounts
- [`docs/family-timemachine-setup.md`](./family-timemachine-setup.md) — Mac Time Machine setup (same pattern, different app)
- [`docs/bulk-storage.md`](./bulk-storage.md) — the tank tier all of this lands on
