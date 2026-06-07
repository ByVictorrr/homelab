# SSH recovery — rpi-node3 (192.168.4.54)

## Symptom

```
$ ssh pi@192.168.4.54
pi@192.168.4.54: Permission denied (publickey).
```

Both `pi` and `victord` rejected. SSH offered `~/.ssh/id_rsa` and
`~/.ssh/id_ed25519` — server rejected both. Server reply was
`Authentications that can continue: publickey`, so **password auth is
disabled** on the Pi. The only way in is a key it already trusts.

## Diagnosis

This Pi was flashed with **Raspberry Pi Imager (custom settings)**,
intended user `pi`. The public key Imager wrote into
`/home/pi/.ssh/authorized_keys` is not either of the keys currently in
`~/.ssh/` on this laptop. Either a different key was pasted into Imager,
or the local key has since been regenerated.

## Recovery options (easiest first)

### Option 1 — Mount the SD card on this laptop and add the key

1. Power down rpi-node3, pull the SD card, insert into this laptop.
2. Find the rootfs partition (the larger one, ext4):
   ```bash
   lsblk
   # likely /dev/mmcblk0p2 (boot is p1)
   ```
3. Mount it and append your pubkey:
   ```bash
   sudo mkdir -p /mnt/pi
   sudo mount /dev/mmcblk0p2 /mnt/pi
   sudo mkdir -p /mnt/pi/home/pi/.ssh
   sudo chmod 700 /mnt/pi/home/pi/.ssh
   cat ~/.ssh/id_ed25519.pub | sudo tee -a /mnt/pi/home/pi/.ssh/authorized_keys
   sudo chmod 600 /mnt/pi/home/pi/.ssh/authorized_keys
   # fix ownership — on the Pi, pi is uid/gid 1000
   sudo chown -R 1000:1000 /mnt/pi/home/pi/.ssh
   sudo umount /mnt/pi
   ```
4. Put the card back, boot, then:
   ```bash
   ssh pi@192.168.4.54
   ```

### Option 2 — Console in with HDMI + keyboard

1. Plug HDMI + USB keyboard into rpi-node3, boot.
2. Log in as `pi` with the password set in Imager.
3. Add the key:
   ```bash
   mkdir -p ~/.ssh && chmod 700 ~/.ssh
   echo 'PASTE_CONTENTS_OF_id_ed25519.pub_HERE' >> ~/.ssh/authorized_keys
   chmod 600 ~/.ssh/authorized_keys
   ```
   Your pubkey is in `~/.ssh/id_ed25519.pub` on this laptop — `cat` it
   and copy it across by hand.

### Option 3 — Re-flash with this repo's script

The script bakes in your current `~/.ssh/id_ed25519.pub` automatically,
but its default user is the *invoking* user (`victord`). To match
`ansible_user=pi` in `ansible/inventory.ini`:

```bash
cd ~/git/rpi-cluster
sudo USERNAME=pi ./scripts/01-flash-pi.sh rpi-node3 /dev/mmcblk0
```

Then boot the Pi and `ssh pi@192.168.4.54` should just work.

## After recovery — smoke test

```bash
cd ~/git/rpi-cluster/ansible
ansible rpi-node3 -m ping
```

Expect `pong`. Then the full cluster:

```bash
ansible all -m ping
```

## Reference: keys on this laptop

```
~/.ssh/id_rsa        SHA256:CrDemBamHnTV9ooW3qDh8+f83T5jAnSFYVTjkQ8mTLo
~/.ssh/id_ed25519    SHA256:aDQieOrcaUePP7Ku5rPl45NsQdVPrf1AGu2oc8zvJyw
```

Pi host key (already in `~/.ssh/known_hosts`):
`ssh-ed25519 SHA256:ixi7qusG3Am65DZQyA8bkLbEznJwZkTmXbJsWjKkwlY`
