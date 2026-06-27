# Connecting to the home server

A short guide for accessing the family server at home — for shared files and
for backing up your Mac. **No iCloud subscription needed.**

You'll need two things from Victor before starting:

- **Your username** (something like `mom` or `wife`)
- **Your password** (a 1-time setup, only used for the server)

The server is on the home Wi-Fi only. You can't reach it from outside the
house unless Victor has set up Tailscale on your device.

---

## 1. Open the family folder on your Mac

This is the shared folder for family photos, documents, scans — anything
everyone might want to look at.

1. Open **Finder**.
2. Press **⌘ K** (hold the Command key and tap K).
   _Or:_ from the Finder menu bar, choose **Go → Connect to Server…**
3. In the box, type exactly:

   ```
   smb://192.168.4.32
   ```

4. Click **Connect**.
5. When asked, choose **Registered User**, then enter:
   - **Name:** your username
   - **Password:** your password
   - ✅ tick **Remember this password in my keychain** (so you don't have to
     type it every time).
6. From the list of shares that pops up, double-click **family**.

A Finder window opens showing the shared family files. You can drag files in
and out like any normal folder.

**To put it in your Finder sidebar permanently:** drag the **family** icon
from the title bar of that Finder window into the sidebar on the left, under
"Locations". Next time, one click connects you.

---

## 2. Back up your Mac to the server (replaces iCloud / Time Machine to a drive)

This sets up automatic hourly backups of your entire Mac to the server. If
your Mac is ever lost or broken, you can restore everything — files, apps,
settings — from these backups.

1. Open **System Settings** (the gear icon).
2. In the left sidebar, click **General**, then **Time Machine**.
3. Click **+ Add Backup Disk…**
4. **rpi-node4** should appear in the list. Click it, then click **Set Up Disk**.
5. When prompted, enter your **username** and **password** (same as above).
6. Accept the defaults and click **Done**.

The first backup runs in the background and can take a few hours (or
overnight) depending on how much data you have. After that, Time Machine
backs up new and changed files automatically about once an hour, as long
as you're on home Wi-Fi.

**You can keep using your Mac normally while it backs up.** It's designed
to run quietly in the background.

---

## 3. Browse the family folder on your iPhone (optional)

You can also view (and add to) the family folder from your iPhone.

1. Open the **Files** app (the blue folder icon).
2. Tap the **⋯** menu in the top-right corner.
3. Tap **Connect to Server**.
4. Enter exactly: `smb://192.168.4.32` → tap **Connect**.
5. Choose **Registered User** → enter your username and password → **Next**.
6. Pick **family** from the list.

Now in the Files app, under **Locations**, you'll see **192.168.4.32**.
Tap it any time you're on home Wi-Fi to browse, upload, or download files.

> **iPhone photo backup note:** the Files-app SMB connection is for
> browsing, not for auto-backing-up your camera roll. Your phone photos
> back up automatically via a separate app (Immich) — Victor will set that
> up on your phone separately.

---

## Troubleshooting

**"The operation can't be completed because original item for 'family' can't be found"**
This is a stuck shortcut, not a real problem. In Finder, click the eject ⏏︎
icon next to `192.168.4.32` in the sidebar, then reconnect with **⌘ K**
fresh, typing `smb://192.168.4.32` again.

**"There was a problem connecting to the server"**
You're probably not on home Wi-Fi. Check the Wi-Fi name at the top-right of
your screen — it should say the home network name. If it does and the error
persists, the server may be off — ask Victor.

**Wrong password**
Macs cache the old password. Open **Keychain Access** (search Spotlight),
search for `192.168.4.32`, delete the entry, and try connecting again — it
will prompt you for the password.

**Time Machine says backup failed**
Usually a temporary network blip. Time Machine retries on its own; check
again in an hour. If it keeps failing for more than a day, tell Victor.

---

## Quick reference

| Thing | How |
|---|---|
| Server address | `smb://192.168.4.32` |
| Connect on Mac | Finder → ⌘ K → paste address |
| Connect on iPhone | Files → ⋯ → Connect to Server |
| Set up Mac backup | System Settings → General → Time Machine → Add Backup Disk |
| Where backups live | On the server, in your own private folder |
| Where shared files live | The `family` share — everyone can see them |

That's it. Once it's set up, you don't have to think about it — files sync
when you drag them in, backups happen automatically.
