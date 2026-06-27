# Family Time Machine setup — message template

Reusable draft to send to family members (wife, kids, parents, anyone whose
Mac you want backing up to the home tank). Edit the SMB username, password
delivery line, and tailnet hostname before sending.

## Before sending (prep on your end)

1. Add the user to `samba_users` in `ansible/host_vars/rpi-node4.yml` if they
   are not already there, then run `cd ansible && ansible-playbook
   playbooks/tank.yml`.
2. Set their Samba password on rpi-node4:
   ```sh
   ssh victord@192.168.4.32
   sudo smbpasswd -a <theirusername>
   ```
   Deliver the password to them through a secure channel (Signal, in-person,
   1Password share — not email or SMS in plaintext).
3. Get their Mac on the tailnet — either invite their email at
   login.tailscale.com → Users → Invite, or share just the rpi-node4 node
   from login.tailscale.com → Machines → rpi-node4 → Share.

## Message body (copy-paste into Gmail / Mail / iMessage / etc.)

**Subject:** Setting up Time Machine backup for your laptop

---

Hey love — setting you up to auto-back-up your laptop to our home server.
After this it runs hourly forever in the background, and if your Mac ever
dies we can restore everything. ~10 min, two steps.

### 1. Install Tailscale

This is the secure tunnel that lets your laptop talk to the home server
from anywhere (coffee shop, your parents' house, work).

- Go to https://tailscale.com/download and click **Download for macOS**
- Install it, open it, click **Log in**
- Sign in with the email I sent the invite to (check your inbox for a
  "Tailscale invitation")
- Done — it lives in your menu bar (look for the little Tailscale icon up top)

### 2. Add the Time Machine destination

- Open **System Settings → General → Time Machine**
- Click **Add Backup Disk…**
- If you see **rpi-node4** in the list with a Time Capsule icon, click it.
- If you don't, hold **⌥ Option** and click *Add Backup Disk* again — a text
  box appears. Paste:

  ```
  smb://wife@rpi-node4.bluebuck-micro.ts.net/timemachine
  ```

- It'll ask for a password — I'll text you that separately.
- It'll then offer to **Encrypt backups** — say YES and pick a passphrase
  you'll remember (or stash in your password manager). You only need it if
  you ever restore from the backup, but losing it = losing the backup, so
  don't lose it.
- Click **Done**.

That's it. First backup pulls everything (could run for a day or two — leave
the laptop awake and plugged in overnight). After that it's hourly and
invisible.

### Heads up

- If you ever see the menu bar icon stop spinning weirdly or pop a "backup
  failed" notification, screenshot it and send it to me.
- You can pause backups any time from the TM menu bar icon (top right).
- It backs up over WiFi wherever you are — as long as Tailscale is on, it
  will find the server.

Love you 💛

---

## Related

- [`storage-allocation.md`](./storage-allocation.md) §6 — per-Mac sparsebundle
  paths, isolation guarantees, and the case for enabling Mac-side encryption
- [`ansible/playbooks/tank.yml`](../ansible/playbooks/tank.yml) — server-side
  Samba + avahi setup that makes the destination discoverable
- [`ansible/host_vars/rpi-node4.yml`](../ansible/host_vars/rpi-node4.yml) —
  add new users to `samba_users` here
