# rpi-cluster progress

Living checklist from "boxes on a desk" → first workload running.

## Environment

- 4× Raspberry Pi 5 (8 GB), Ubuntu Server 24.04 arm64
- LAN: `192.168.4.0/24` (eero, DHCP reservations)
  - `rpi-control` → `192.168.4.27`
  - `rpi-node1`   → `192.168.4.95`
  - `rpi-node2`   → `192.168.4.91`
  - `rpi-node3`   → `192.168.4.94`
- Cluster: k3s `v1.35.5+k3s1`, single control plane, 3 workers
- Laptop: Arch, `victord` user, SSH key auto-deployed via cloud-init

## Done

- [x] Flash script (`scripts/01-flash-pi.sh`) writes Ubuntu image + cloud-init `user-data` for hostname, SSH key, swap-off, memory cgroups
- [x] Flash script supports optional Wi-Fi via `WIFI_SSID` / `WIFI_PASSWORD` env vars (writes netplan `network-config` + `iw reg set` in runcmd)
- [x] Flashed and booted all 4 Pis
- [x] Ansible inventory (`ansible/inventory.ini`) populated with reserved IPs
- [x] `ansible.cfg` callbacks fixed (`stdout_callback = default` + `result_format = yaml`; the `community.general.yaml` callback was removed in v12)
- [x] Reserved `all` tag removed from plays (Ansible warns; `all` is implicit)
- [x] Prep play hardened: `cloud-init status --wait` + dpkg-lock wait + `lock_timeout: 600` so first-boot unattended-upgrades doesn't race the playbook
- [x] OS prep ran cleanly: apt upgrade, avahi/iscsi/nfs installed, `/etc/hosts` block written, swap disabled, memory cgroups asserted
- [x] k3s server installed on `rpi-control`
- [x] k3s agents joined from all 3 workers
- [x] `kubectl get nodes` shows 4× Ready
- [x] kubeconfig fetched to `~/.kube/config-homelab`
- [x] `kubectl` installed locally (Arch pacman)
- [x] `KUBECONFIG` exported (one-shot; persist via `~/.zshrc` if not already)
- [x] ingress-nginx installed (LoadBalancer, klipper-lb pins it to all 4 node IPs)
- [x] cert-manager installed (3 pods Running)

## In progress

- [x] Helm install of Rancher chart triggered (a prior attempt was still pending in helm's state, which is why a re-run errored with "another operation in progress" — but the original install was actually running)
- [ ] Rancher pod becomes `Running 1/1` (image pull on arm64, typically 3–8 min)
- [ ] Rancher Ingress reachable
  - Ingress exists with host `rancher.192.168.4.27.nip.io`, bound to all 4 node IPs via klipper-lb
  - Will return 503 → then the welcome page once the pod is Ready

## Next — to first pod

1. [ ] **Verify Rancher UI**
   - Browse to `https://rancher.192.168.4.27.nip.io/`
   - Accept the self-signed cert
   - Log in with bootstrap password (one-time, from `-e rancher_bootstrap_password=...`)
   - Set a strong admin password on the welcome screen — Rancher forces this on first login
   - Sanity-check: the "local" cluster shows 4 nodes Active

2. [ ] **First "pod that feels like a Linux VM" — sandbox.**
   Long-running Ubuntu 24.04 pod with a 5 GB PVC mounted at `/root` so your files survive pod restarts. Manifest committed at [`manifests/sandbox.yaml`](./manifests/sandbox.yaml).

   ```bash
   kubectl apply -f manifests/sandbox.yaml
   kubectl -n sandbox get pods -w     # wait for Running 1/1
   ```

   Open a shell into it:
   ```bash
   kubectl -n sandbox exec -it deploy/sandbox -- bash
   ```

   Inside the pod (first time only), install whatever tools you want:
   ```bash
   apt-get update && apt-get install -y curl vim git iputils-ping htop
   cd /root && echo hello > note.txt   # this WILL persist
   ```

   **What persists, what doesn't:**
   - Files under `/root` (the PVC mount) — survive pod restarts, node reboots, even pod deletes (until you `kubectl delete pvc`).
   - Files anywhere else (incl. `apt`-installed binaries in `/usr/bin`) — gone the next time the pod restarts, because they live on the container's ephemeral overlay.
   - To make tooling persist, either bake a custom image with your tools pre-installed, or stop trying to make a pod be a VM and use **KubeVirt** instead (real VMs as Kubernetes resources — heavier but the legit "I want a VM" answer).

   **Smoke-test it survives a restart:**
   ```bash
   kubectl -n sandbox delete pod -l app=sandbox     # pod gets recreated by the Deployment
   kubectl -n sandbox exec -it deploy/sandbox -- cat /root/note.txt   # still says "hello"
   ```

3. [ ] **(Optional) Expose the sandbox over SSH** — only if you'd rather `ssh` in than `kubectl exec`. Two ways:
   - **kubectl port-forward** (zero setup, only works while the command is running):
     ```bash
     kubectl -n sandbox port-forward deploy/sandbox 2222:22
     # in another terminal:
     ssh -p 2222 root@127.0.0.1
     ```
     Requires `openssh-server` installed + a password set inside the pod first.
   - **NodePort Service** (persistent, reachable from any LAN device): add a `Service` of type NodePort to the manifest. Skip this for now unless you actually need it.

4. [ ] **(Optional) nginx hello-world Ingress smoke test** — separate exercise to confirm ingress-nginx routes correctly:
   ```bash
   kubectl create deployment hello --image=nginx:alpine
   kubectl expose deployment hello --port=80
   cat <<'EOF' | kubectl apply -f -
   apiVersion: networking.k8s.io/v1
   kind: Ingress
   metadata:
     name: hello
   spec:
     ingressClassName: nginx
     rules:
       - host: hello.192.168.4.27.nip.io
         http:
           paths:
             - path: /
               pathType: Prefix
               backend:
                 service:
                   name: hello
                   port:
                     number: 80
   EOF
   curl http://hello.192.168.4.27.nip.io/   # expect nginx welcome page
   ```

## Family chat / LLM (Open WebUI + Tailscale)

Goal: a ChatGPT-style UI the family can hit from anywhere. Pis run the frontend and the Tailscale exit; the model itself comes from a cloud API (Claude / GPT / etc. via OpenRouter) with a small local Ollama as an offline fallback.

Manifests:
- [`manifests/chat-webui.yaml`](./manifests/chat-webui.yaml) — Open WebUI + PVC + Service + LAN Ingress
- [`manifests/ollama.yaml`](./manifests/ollama.yaml) — optional local model runner (slow on Pi, but offline-capable)
- [`manifests/chat-webui-tailscale.yaml`](./manifests/chat-webui-tailscale.yaml) — Tailscale Ingress (needs the operator first)

### 1. Open WebUI on the LAN

```bash
kubectl apply -f manifests/chat-webui.yaml

# Put your OpenRouter key in the secret (get one at openrouter.ai/keys):
kubectl -n chat create secret generic webui-llm-keys \
  --from-literal=openai-api-key='sk-or-...' \
  --dry-run=client -o yaml | kubectl apply -f -

kubectl -n chat rollout restart deploy/open-webui
kubectl -n chat get pods -w           # wait for Running 1/1
```

Browse to `http://chat.192.168.4.27.nip.io/`. First account you create becomes admin; later signups land in `pending` until you approve them in Settings → Admin → Users. In Settings → Models pick something like `anthropic/claude-3.5-sonnet` or `openai/gpt-4o-mini` as the default.

### 2. (Optional) Local model fallback

```bash
kubectl apply -f manifests/ollama.yaml
kubectl -n ollama get pods -w

# Pull a Pi-sized model (~2 GB):
kubectl -n ollama exec -it deploy/ollama -- ollama pull qwen2.5:3b
```

It'll show up in Open WebUI's model picker automatically. Expect ~3-5 tok/s on a Pi 5 — fine for short answers, slow for anything long.

### 3. Tailscale operator (so family can use it from anywhere)

One-time per cluster:

```bash
# (a) Create an OAuth client at https://login.tailscale.com/admin/settings/oauth
#     - Scopes: Devices: Core (read+write), Auth Keys (write)
#     - Tag the operator's devices, e.g. tag:k8s
#     - In tailnet ACLs, add: "tagOwners": { "tag:k8s": ["autogroup:admin"] }
#     - Save the client ID and secret.

# (b) Install the operator
helm repo add tailscale https://pkgs.tailscale.com/helmcharts
helm repo update

helm install tailscale-operator tailscale/tailscale-operator \
  --namespace tailscale --create-namespace \
  --set-string oauth.clientId=tskey-client-... \
  --set-string oauth.clientSecret=tskey-... \
  --set-string operatorConfig.defaultTags='{tag:k8s}'

kubectl -n tailscale get pods -w      # wait for operator Running 1/1

# (c) Expose Open WebUI on the tailnet
kubectl apply -f manifests/chat-webui-tailscale.yaml

# Find the assigned hostname (something like chat.bluebuck-micro.ts.net):
kubectl -n chat get ingress open-webui-ts -w
```

On each family member's phone/laptop:
1. Install Tailscale, sign in, accept the invite to your tailnet.
2. Open `https://chat.bluebuck-micro.ts.net/` in any browser.
3. Sign up; you approve them once from the admin panel.

That's it — encrypted, no public exposure, no auth proxy of your own to maintain.

## Deployed apps + URLs

Single source of truth. LAN URLs only work on home Wi-Fi; Tailscale URLs work anywhere on the tailnet (TLS by Let's Encrypt, no port-forward).

| App | LAN | Tailscale | Auth model |
|---|---|---|---|
| Rancher (k8s admin) | https://rancher.192.168.4.27.nip.io | https://rancher.bluebuck-micro.ts.net | Local admin |
| Chat (Open WebUI) | http://chat.192.168.4.27.nip.io | https://chat.bluebuck-micro.ts.net | First user wins admin, new signups pending |
| Vaultwarden (passwords) | http://vault.192.168.4.27.nip.io | https://vault.bluebuck-micro.ts.net | `/admin` token + per-user signup |
| Uptime Kuma (monitoring) | http://uptime.192.168.4.27.nip.io | https://uptime.bluebuck-micro.ts.net | First user wins admin |
| AdGuard (DNS + adblock) | http://adguard.192.168.4.27.nip.io | https://adguard.bluebuck-micro.ts.net | Wizard sets admin user |
| Home Assistant | http://homeassistant.192.168.4.27.nip.io | https://homeassistant.bluebuck-micro.ts.net | First user wins admin |
| Jellyfin (media) | http://jellyfin.192.168.4.27.nip.io | https://jellyfin.bluebuck-micro.ts.net | First user wins admin |
| **Mealie (recipes)** | http://recipes.192.168.4.27.nip.io | https://recipes.bluebuck-micro.ts.net | Default `changeme@example.com / MyPassword` — change immediately |
| **Nextcloud (files/photos/CalDAV)** | http://cloud.192.168.4.27.nip.io | https://cloud.bluebuck-micro.ts.net | `admin` + password in `nextcloud-admin` Secret |
| **Audiobookshelf (audiobooks/podcasts)** | http://audiobooks.192.168.4.27.nip.io | https://audiobooks.bluebuck-micro.ts.net | First user wins admin |
| **Homepage (dashboard)** | http://home.192.168.4.27.nip.io | https://home.bluebuck-micro.ts.net | No auth — bookmark this on every device, jumps to every other app |
| **Longhorn (storage admin)** | http://longhorn.192.168.4.27.nip.io | https://longhorn.bluebuck-micro.ts.net | ⚠️ No auth by default — anyone on tailnet/LAN can delete volumes. Add htpasswd if exposed. |
| **Registry** (internal) | http://192.168.4.27:5000 | https://registry.bluebuck-micro.ts.net | No auth, HTTP on LAN. Each Pi trusts it via `/etc/rancher/k3s/registries.yaml` (set up by `ansible/playbooks/registries.yml`). |
| **TrialDay** (Next.js, in progress) | http://trialday.192.168.4.27.nip.io | https://trialday.bluebuck-micro.ts.net | Clerk (cloud) |
| **HTTP file server** | http://files.192.168.4.27.nip.io | https://files.bluebuck-micro.ts.net | Open — anything you drop in `/mnt/nfs/shared` is publicly listable. |
| **PXE boot (proxyDHCP + TFTP)** | host-network only on rpi-control | — | Boots netboot.xyz menu for any x86 PC on the LAN. |
| Glances API (per-Pi sensors) | http://192.168.4.{27,91,94,95}:61208 | — | Open (LAN-only by hostNetwork) |
| Ollama API (LLM backend) | (in-cluster `ollama.ollama.svc.cluster.local:11434`) | — | Open within cluster |

Not deployed yet (manifests written): Immich (`photos.*`), Sandbox (`kubectl exec` only).

## Building + deploying your own apps (TrialDay example)

The cluster has a self-hosted container registry at `192.168.4.27:5000` (Tailscale-exposed, Let's Encrypt TLS, backed by a Longhorn PVC). Build images on the laptop with `docker buildx`, tag for the registry, push — all 4 Pis can then pull from a single source.

### One-time laptop setup

```bash
# Start docker daemon (Arch — not auto-started)
sudo systemctl start docker

# Install docker-buildx as a user plugin (no sudo)
mkdir -p ~/.docker/cli-plugins
curl -sSL https://github.com/docker/buildx/releases/download/v0.20.1/buildx-v0.20.1.linux-amd64 \
  -o ~/.docker/cli-plugins/docker-buildx
chmod +x ~/.docker/cli-plugins/docker-buildx

# Register QEMU for arm64 emulation
sudo docker run --privileged --rm tonistiigi/binfmt --install arm64

# Create a multi-arch builder
sudo HOME=$HOME docker buildx create --name multiarch --driver docker-container --use
sudo HOME=$HOME docker buildx inspect --bootstrap
```

(If you'd rather not type `sudo` every time, add your user to the `docker` group: `sudo usermod -aG docker $USER` then `newgrp docker`.)

### Build + push a Next.js app (TrialDay)

Source: `~/git/worksim` (GitHub: ByVictorrr/worksim). Dockerfile + .dockerignore committed at repo root.

```bash
cd ~/git/worksim

# Source public env vars so NEXT_PUBLIC_* bake in at build time
set -a && source .env.local && set +a

sudo -E HOME=$HOME docker buildx build \
  --platform linux/arm64 \
  --build-arg NEXT_PUBLIC_APP_URL=https://trialday.bluebuck-micro.ts.net \
  --build-arg NEXT_PUBLIC_CLERK_PUBLISHABLE_KEY="$NEXT_PUBLIC_CLERK_PUBLISHABLE_KEY" \
  --build-arg NEXT_PUBLIC_CLERK_SIGN_IN_URL="$NEXT_PUBLIC_CLERK_SIGN_IN_URL" \
  --build-arg NEXT_PUBLIC_CLERK_SIGN_UP_URL="$NEXT_PUBLIC_CLERK_SIGN_UP_URL" \
  --build-arg NEXT_PUBLIC_CLERK_AFTER_SIGN_IN_URL="$NEXT_PUBLIC_CLERK_AFTER_SIGN_IN_URL" \
  --build-arg NEXT_PUBLIC_CLERK_AFTER_SIGN_UP_URL="$NEXT_PUBLIC_CLERK_AFTER_SIGN_UP_URL" \
  --build-arg NEXT_PUBLIC_POSTHOG_KEY="$NEXT_PUBLIC_POSTHOG_KEY" \
  --build-arg NEXT_PUBLIC_POSTHOG_HOST="$NEXT_PUBLIC_POSTHOG_HOST" \
  -t 192.168.4.27:5000/trialday:latest \
  --push .
```

QEMU emulation is slow — expect 15-25 min for a first build, 3-5 min for incremental ones (buildx cache stays in the builder container).

### Deploy / update

```bash
# First time only:
kubectl apply -f manifests/trialday.yaml -f manifests/trialday-tailscale.yaml

# Drop the runtime secrets straight from .env.local (cluster URL gets overridden in the Deployment spec):
kubectl -n trialday create secret generic trialday-env \
  --from-env-file=~/git/worksim/.env.local \
  --dry-run=client -o yaml | kubectl apply -f -

# Roll the pod so it picks up the new image + secret:
kubectl -n trialday rollout restart deploy/trialday
kubectl -n trialday rollout status deploy/trialday
```

After this, **https://trialday.bluebuck-micro.ts.net** should serve the app. Webhooks (Clerk, Stripe) still point at the Vercel deployment unless you reconfigure them — this cluster instance is for browser traffic + API only.

### Gotchas

- **Clerk allowed origins** must include `https://trialday.bluebuck-micro.ts.net` (Clerk Dashboard → Domains). Otherwise auth flows fail with a CORS-ish error.
- **Public env vars** (`NEXT_PUBLIC_*`) are baked in at build time — changing them in `.env.local` requires a rebuild. Server-side vars (in `trialday-env` Secret) hot-reload after pod restart.
- **Same Supabase + Stripe + Clerk as Vercel**: this cluster instance shares the production backends. Be careful about double-handling webhooks or test transactions.
- **Build context size**: `.dockerignore` excludes `node_modules`, `.next`, `.git`, `playwright-report`, etc. Build context should be ~5MB. If you see "transferring context: 500MB+", something slipped past `.dockerignore`.

## Later (not blocking first pod)

- [ ] **Persistent storage** — Longhorn. Prep is done (`open-iscsi` + `iscsid` are already installed by the prep play). Install via Rancher's app catalog or `helm install longhorn longhorn/longhorn -n longhorn-system --create-namespace`. Needed before any stateful workload.
- [ ] **Backups** — once Longhorn is up, point it at NFS or S3 for volume snapshots.
- [ ] **5th Pi (rpi-node4)** — full walkthrough below.
- [ ] **Real DNS** — Pi-hole / AdGuard inside the cluster, point eero's custom DNS at the CP's IP. Replaces nip.io with real internal hostnames.
- [ ] **Amazon Echo → Home Assistant** — voice control of HA entities. Two paths:
  - Easy: Nabu Casa Alexa integration ($7.50/mo, official, also gives HA Cloud remote access).
  - Free: Emulated Hue — HA pretends to be a Hue bridge, Echo discovers it via SSDP. Needs `hostNetwork: true` on the HA pod so SSDP works, which pins HA to a specific node. Limited to switch-like entities.
- [ ] **Immich (photos)** — manifest in `manifests/immich.yaml` is namespace + secret only. The official Helm chart dropped its bundled postgres, so to install: deploy a postgres-with-pgvector first (e.g. `tensorchord/pgvecto-rs`), then helm install immich pointing at it. See chart docs for the env wiring.
- [ ] **Vaultwarden WebAuthn / passkeys** — currently `DOMAIN` env points at the LAN HTTP URL; passkeys require HTTPS. After confirming `https://vault.bluebuck-micro.ts.net` works, patch the deployment env: `DOMAIN=https://vault.bluebuck-micro.ts.net`.
- [ ] **AdGuard as LAN DNS** — in eero app, Settings → Network Settings → DNS → Custom → Primary = `192.168.4.27`, Secondary = `1.1.1.1`. Then in AdGuard → Filters → DNS rewrites, add A records (e.g. `chat.home.lan` → `192.168.4.27`) to replace the nip.io URLs.
- [ ] **HA shutdown SSH key** — `manifests/glances.yaml` + thermal-shutdown automations are deployed, but the SSH key from the HA pod still needs to be installed on each Pi. One-time, run the loop documented in the conversation (adds `~/.ssh/authorized_keys` + `/etc/sudoers.d/ha-shutdown` on each Pi).

## Adding the 5th Pi (rpi-node4)

The playbook is idempotent and supports `--limit` for single-host runs, so adding a node is mostly mechanical.

### 1. Reserve an IP on eero

In the eero app → Settings → Network Settings → DHCP & NAT → Reservations. Pick a free IP in `192.168.4.0/24` (e.g. `192.168.4.67`) for the new Pi's MAC. Skip if you're fine with DHCP-assigned IPs — but reserved IPs make the rest of the cluster more reliable.

### 2. Flash the SD card

```bash
# From your laptop, with the SD card in /dev/mmcblk0
cd ~/git/rpi-cluster
sudo ./scripts/01-flash-pi.sh rpi-node4 /dev/mmcblk0

# If you want Wi-Fi instead of Ethernet:
sudo WIFI_SSID=Marilyn ./scripts/01-flash-pi.sh rpi-node4 /dev/mmcblk0
# (it'll prompt securely for the password)
```

Eject, put the card in the new Pi, plug in Ethernet (or rely on Wi-Fi), power on.

### 3. Wait for first boot (~90s), then smoke-test SSH

```bash
ssh victord@rpi-node4.local   # via mDNS — should work on this LAN
# or, if mDNS is flaky:
ssh victord@192.168.4.67      # if you reserved an IP
```

If SSH hangs more than a couple minutes, cloud-init didn't finish — give it longer, then check the boot partition's `user-data` is what you expect.

### 4. Add the host to the Ansible inventory

Edit `ansible/inventory.ini`, uncomment or add the `rpi-node4` line in the `[k3s_agent]` group, and pin it to the reserved IP:

```ini
[k3s_agent]
rpi-node1    ansible_host=192.168.4.95
rpi-node2    ansible_host=192.168.4.91
rpi-node3    ansible_host=192.168.4.94
rpi-node4    ansible_host=192.168.4.67   # <-- new line
```

### 5. Provision it

```bash
cd ~/git/rpi-cluster/ansible

# Smoke test SSH from Ansible's perspective
ansible rpi-node4 -m ping

# Full provisioning — limited to the new host.
# Skip rancher because that play targets localhost / the existing cluster.
ansible-playbook site.yml --skip-tags rancher --limit rpi-node4
```

This runs prep (apt, avahi, /etc/hosts, swap, cgroup check) and k3s-agent install + join on rpi-node4 only. Existing nodes are untouched.

> Note: the k3s-agent play depends on the `k3s_node_token` fact set by the `k3s_server` play. With `--limit rpi-node4` the server play doesn't run, so the fact would be missing. If you hit `'dict object' has no attribute 'k3s_node_token'`, widen the limit to include the server too:
> ```bash
> ansible-playbook site.yml --skip-tags rancher --limit 'rpi-node4:rpi-control'
> ```
> The server play is idempotent (k3s already installed → it's a no-op), it just gathers the token for the agent play to consume.

### 6. Verify

```bash
export KUBECONFIG=$HOME/.kube/config-homelab
kubectl get nodes -o wide
# expect 5 nodes Ready
```

### 7. (Optional) Update `/etc/hosts` on every node

The prep play writes a managed `/etc/hosts` block on every Pi listing all cluster nodes. With `--limit rpi-node4`, only the new Pi got the updated block. To refresh the others so they all know about rpi-node4:

```bash
ansible-playbook site.yml --tags prep
```

Idempotent; ~30s.

### 8. (Optional) Format and attach rpi-node4's SSD to the storage pool

The new Pi has a **500 GB SSD** (vs. the others' 1 TB). The `playbooks/storage.yml` playbook already includes `rpi-node4 → longhorn` by default, so it'll join the Longhorn pool, taking total raw capacity from ~1 TB → ~1.5 TB (replica=2 gives ~750 GB usable).

```bash
cd ~/git/rpi-cluster/ansible
ansible-playbook playbooks/storage.yml --ask-become-pass --limit rpi-node4
```

If you want a different role (e.g. third NFS server, dedicated app store), edit the `storage_role` dict at the top of `playbooks/storage.yml` before running.

After the playbook finishes, refresh Longhorn so it picks up the new disk:

```bash
kubectl -n longhorn-system get nodes.longhorn.io rpi-node4 -o yaml
# Disk path /var/lib/longhorn should appear; if not, edit the Node CR and add it.
```

### 9. (Optional) Let Kubernetes rebalance

New nodes don't pull existing pods toward them automatically. If you want some workloads to migrate, either delete the pods (let the Deployment recreate them, scheduler may place them on rpi-node4) or use a descheduler. For a homelab this is usually overkill — let new workloads land naturally.

## Storage layout (1 TB SSD × 3 + 500 GB SSD × 1)

| Pi | SSD | Role | Mount | Purpose |
|---|---|---|---|---|
| rpi-control | 1 TB | NFS server (sole) | `/mnt/nfs` | Single shared filesystem for media, family files, Mac/PC mount, PXE TFTP root, backups |
| rpi-node1 | 1 TB | Nextcloud-only | `/mnt/nextcloud` | hostPath PVC, bound to Nextcloud's data dir |
| rpi-node2 | 1 TB | Longhorn | `/var/lib/longhorn` | Distributed block storage (replica 1 of 2) |
| rpi-node3 | 1 TB | Longhorn | `/var/lib/longhorn` | Distributed block storage (replica 2 of 2) |
| rpi-node4 | 500 GB | Longhorn (when added) | `/var/lib/longhorn` | Extends Longhorn pool |

**Why one NFS instead of two:** earlier the layout split nfs-1 and nfs-2 across rpi-control and rpi-node3, ostensibly so a single-Pi outage only took down half the shared space. In practice that just meant two icons in Finder and confusing per-app PV choices. Consolidating to one share gave Longhorn a second physical disk — now replica=2 actually has somewhere to replicate to. From a client, mount `nfs://192.168.4.27/mnt/nfs` (or `nfs://rpi-control.local/mnt/nfs`) and you see every shared subdir at once.

**To set it up the first time:**

```bash
cd ~/git/rpi-cluster/ansible
ansible-playbook playbooks/storage.yml
```

Idempotent — re-running is a no-op once disks are formatted + mounted. The playbook installs `nfs-kernel-server` on rpi-control and writes `/etc/exports` to grant LAN + pod-CIDR + tailnet access. Passwordless sudo on the Pis means `--ask-become-pass` isn't needed.

### Kubernetes StorageClasses available after rollout

| StorageClass | Backing | Capacity | Access | Use for |
|---|---|---|---|---|
| `local-path` (default) | Per-node SD card | ~80 GB / node | RWO | Small, non-critical app data (configs, sqlite DBs). The k3s default. |
| `nextcloud-local` | rpi-node1 hostPath `/mnt/nextcloud` | 1 TB | RWO | Single-app dedicated drive (Nextcloud data). Bound to a single host. |
| `longhorn` | rpi-node2 + rpi-node3 SSDs (`/var/lib/longhorn`) | ~2 TB raw → ~1 TB usable at replica=2 | RWO, replicated | Important stateful workloads. Survives a single-node failure. |
| `nfs-1` | NFS from rpi-control `/mnt/nfs` | ~900 GB shared pool | RWX | Anything multi-pod RWX. Subpath PVs scope each app to its own dir. Mountable from Mac/PC at `nfs://192.168.4.27/mnt/nfs`. |

Static PVs that bind these classes live in `manifests/nfs-storage.yaml` and `manifests/nextcloud-storage.yaml`. To use a new RWX volume from any namespace, just reference the matching storageClassName in a PVC of size ≤ the backing PV.

**Pre-created NFS PVs (all on `rpi-control:/mnt/nfs/<subdir>`, all 900 Gi capacity over the same ~900 GB pool):**

| PV | Subpath | Used by |
|---|---|---|
| `nfs-media` | `/mnt/nfs/media` | Jellyfin |
| `nfs-audiobooks` | `/mnt/nfs/audiobooks` | Audiobookshelf |
| `nfs-shared` | `/mnt/nfs/shared` | HTTP fileserver + family drop-zone |
| `nfs-backups` | `/mnt/nfs/backups` | Longhorn backup target, DB dumps |
| `nfs-pxe` | `/mnt/nfs/pxe-tftp` | PXE/TFTP root (10 Gi) |

Capacities are deliberately overcommitted — Kubernetes doesn't enforce per-PV quotas on NFS, so the first app to fill the disk wins. Watch `df -h /mnt/nfs` on rpi-control.

### What was migrated

| App | Before | After | Why |
|---|---|---|---|
| Nextcloud `data` PVC | local-path (SD, 100 GB) | hostPath `/mnt/nextcloud` on rpi-node1 (1 TB) | Photos / family files need real capacity. Migration required full reinstall — postgres schema was reset because old NC tables blocked the install on a fresh data dir. |
| Jellyfin `media` PVC | local-path (SD, 50 GB) | NFS-1 (800 GB RWX) | Media doesn't need to be node-local; also shareable with Mac Finder. |
| Audiobookshelf `media` PVC | local-path (SD, 50 GB) | NFS-2 (800 GB RWX) | Same reason. |
| Audiobookshelf `config`, `metadata` | local-path (unchanged) | local-path | Small — fine on SD. |
| Nextcloud `postgres` PVC | local-path (10 GB) | local-path (10 GB, reset) | Was reset during the data migration to clear the old NC schema. |

Everything else's PVC stayed on local-path — small, no need to move.

### Adding NFS storage to a new app

```yaml
apiVersion: v1
kind: PersistentVolumeClaim
metadata: { name: myapp-shared, namespace: myapp }
spec:
  accessModes: [ReadWriteMany]
  storageClassName: nfs-1            # or nfs-2
  volumeName: nfs-1-media            # claim the static PV by name
  resources: { requests: { storage: 100Gi } }
```

Or to mount the NFS share on macOS Finder:

```
Cmd+K → nfs://192.168.4.27/mnt/nfs    (nfs-1 — same as Jellyfin sees)
Cmd+K → nfs://192.168.4.94/mnt/nfs    (nfs-2 — same as Audiobookshelf sees)
```

On Linux:
```
sudo mount -t nfs 192.168.4.27:/mnt/nfs /mnt/family
```

### Common shared NFS volumes

Two general-purpose RWX volumes carved out of the existing exports, split across both NFS servers so a single-Pi outage only takes down half of your shared space. Both are pre-created in `manifests/nfs-storage.yaml` and `Available` — just claim them.

| PV | Backing | Capacity | StorageClass | What it's for |
|---|---|---|---|---|
| `nfs-backups` | `rpi-control:/mnt/nfs/backups` | 400 GB | nfs-1 | Longhorn backup target, postgres `pg_dump` archives, etcd snapshots, restic/borg repos — anything that should survive a node wipe. |
| `nfs-shared` | `rpi-node3:/mnt/nfs/shared` | 400 GB | nfs-2 | Family drop-zone, multi-app working dirs, photo overflow, manual uploads from Finder via `nfs://192.168.4.94/mnt/nfs/shared`. |

**Wire Longhorn's backup target to `nfs-backups`:** Longhorn UI → Settings → General → Backup Target = `nfs://192.168.4.27/mnt/nfs/backups`. From then on, schedule snapshots via Longhorn UI → Recurring Job.

**Claim one from a pod:** copy the PVC template from "Adding NFS storage to a new app" above and set `volumeName: nfs-backups` (or `nfs-shared`). Each PV binds 1:1 with a PVC — for many-apps-write-to-the-same-share, use an inline `nfs:` volume in the pod spec instead.

### Mounting the NFS shares from clients

The two NFS exports (`nfs-1` on rpi-control, `nfs-2` on rpi-node3) are reachable from anything on the LAN, the cluster pod network, or the tailnet.

**macOS Finder** — `⌘K` → Connect to Server →
```
nfs://192.168.4.27/mnt/nfs        (or nfs://rpi-control/mnt/nfs when on tailnet)
nfs://192.168.4.94/mnt/nfs        (or nfs://rpi-node3/mnt/nfs)
```

**Linux** (one-time):
```bash
sudo pacman -S nfs-utils         # or apt install nfs-common on Debian/Ubuntu
sudo mkdir -p /mnt/nfs1 /mnt/nfs2
sudo mount -t nfs 192.168.4.27:/mnt/nfs /mnt/nfs1
sudo mount -t nfs 192.168.4.94:/mnt/nfs /mnt/nfs2
```

**Linux persistent** (`/etc/fstab`):
```
192.168.4.27:/mnt/nfs   /mnt/nfs1   nfs   defaults,_netdev,noauto,x-systemd.automount,x-systemd.idle-timeout=600   0 0
192.168.4.94:/mnt/nfs   /mnt/nfs2   nfs   defaults,_netdev,noauto,x-systemd.automount,x-systemd.idle-timeout=600   0 0
```

(`x-systemd.automount` = mounts on first access, unmounts after 10 min idle.)

**Windows** — Enable "Services for NFS" (Pro/Enterprise only), then `mount -o anon \\192.168.4.27\mnt\nfs Z:`. On Home edition use Nextcloud WebDAV instead.

### Putting all 4 Pis on the tailnet

Lets you SSH from anywhere, makes the cluster registry pullable from each node by hostname, and gives you `<pi>.bluebuck-micro.ts.net` MagicDNS names.

```bash
# 1. Generate a REUSABLE auth key at https://login.tailscale.com/admin/settings/keys
#    Settings: Reusable ✓  Pre-approved ✓  Tags: tag:k8s

# 2. Run the playbook (installs Tailscale + joins via the key)
cd ~/git/rpi-cluster/ansible
ansible-playbook playbooks/tailscale.yml --ask-become-pass \
  -e tailscale_authkey=tskey-auth-...
```

The playbook is idempotent — re-running it won't re-join already-on-tailnet Pis. After it finishes, `tailscale status | grep rpi` from the laptop should list all 4. You can then `ssh victord@rpi-control` from anywhere.

When adding a 5th Pi later, the same playbook + `--limit rpi-node4` handles it.

### HTTP file server — drop files, share by URL

`manifests/http-fileserver.yaml` runs nginx with directory autoindex against the `nfs-2-shared` subpath PV. Anything in `/mnt/nfs/shared` is served at:

- http://files.192.168.4.27.nip.io/  (LAN)
- https://files.bluebuck-micro.ts.net/   (anywhere on tailnet)

```bash
# One-time: mkdir the subpath on rpi-node3 with the right ownership
ssh victord@192.168.4.94 'sudo mkdir -p /mnt/nfs/shared && sudo chown nobody:nogroup /mnt/nfs/shared'

# Apply
kubectl apply -f manifests/http-fileserver.yaml

# Drop a file in
echo "hello" > ~/hello.txt
scp ~/hello.txt victord@192.168.4.94:/tmp/
ssh victord@192.168.4.94 'sudo mv /tmp/hello.txt /mnt/nfs/shared/'

# Or mount the NFS on your Mac and drag-drop into Volumes/nfs/shared/
```

Visit the URL — you'll see the file listing with `hello.txt`. Click it to download.

### PXE network boot (for x86 PCs, not Pis)

`manifests/pxe-boot.yaml` runs `dnsmasq` in **proxyDHCP mode** on rpi-control. eero still hands out IPs; dnsmasq only adds PXE options (next-server + filename). The TFTP root holds the netboot.xyz iPXE binaries (one for UEFI, one for legacy BIOS), bootstrapped automatically from boot.netboot.xyz on first apply.

```bash
kubectl apply -f manifests/pxe-boot.yaml
kubectl -n pxe get pods -w     # wait for dnsmasq Running + tftp-bootstrap Completed
kubectl -n pxe logs deploy/dnsmasq    # confirm it's listening on host network
```

To network-boot a target machine:

1. Power on, press the firmware boot-menu key (F12 / F11 / F8 depending on vendor)
2. Pick **PXE Boot** / **Network Boot** / **LAN**
3. After ~10s you'll see the netboot.xyz menu — Ubuntu, Debian, Arch, Memtest86, Windows installers, rescue images, etc., all served from netboot.xyz's CDN

Does **not** PXE-boot Pis (Pi firmware needs a different TFTP path + boot files — use the SD-card flash script instead).

Conflict check: if you ever see "DHCP from unknown server" errors on the LAN, eero is responding to a request meant for proxyDHCP. The fix is in the dnsmasq.conf inside the manifest — pull `dhcp-no-override` and tighten the tag matches.

### Longhorn UI

Browse to https://longhorn.bluebuck-micro.ts.net or http://longhorn.192.168.4.27.nip.io — volumes, replicas, snapshots, recurring backup jobs. **No auth by default**; add htpasswd Ingress annotations if you'd rather lock it down. Set Backup Target to `nfs://192.168.4.27/mnt/nfs/backups` to auto-snapshot Longhorn volumes off-disk.

## Using hostnames instead of IPs

You don't have to memorize `192.168.4.27` / `.94` to mount NFS shares or hit app URLs. Two layers — use mDNS today, set up AdGuard for full coverage later.

### Quick path: mDNS (already working on Mac/Linux)

The prep play installs `avahi-daemon` on every Pi, so each broadcasts `<hostname>.local` on the LAN. From any Mac (built-in) or Linux box with `nss-mdns` (Arch: `pacman -S nss-mdns`):

```bash
# Mac Finder: Cmd+K then paste any of:
nfs://rpi-control.local/mnt/nfs/backups
nfs://rpi-node3.local/mnt/nfs/shared

# Linux mount:
sudo mount -t nfs rpi-control.local:/mnt/nfs/backups /mnt/backups

# Sanity check resolution from anywhere on the LAN:
ping rpi-control.local
```

**Limits:** Windows needs Bonjour Print Services installed for `.local` to resolve. Android is hit-or-miss. iOS works. mDNS is link-local — only same LAN segment, not over Tailscale.

### Permanent path: AdGuard as LAN DNS (works on every device)

Once set up, every device that gets DHCP from your eero gets `rpi-control.home.lan` (and your app URLs like `chat.home.lan`) for free — phones, smart TVs, Windows boxes, everything.

**1. Add DNS rewrites in AdGuard** (http://adguard.192.168.4.27.nip.io → Filters → DNS rewrites):

Cluster nodes:
```
rpi-control.home.lan  → 192.168.4.27
rpi-node1.home.lan    → 192.168.4.95
rpi-node2.home.lan    → 192.168.4.91
rpi-node3.home.lan    → 192.168.4.94
```

App URLs (every Ingress routes through ingress-nginx, which klipper-lb binds to all 4 node IPs — so any node IP works as the target):
```
chat.home.lan          → 192.168.4.27
jellyfin.home.lan      → 192.168.4.27
audiobooks.home.lan    → 192.168.4.27
cloud.home.lan         → 192.168.4.27
recipes.home.lan       → 192.168.4.27
vault.home.lan         → 192.168.4.27
uptime.home.lan        → 192.168.4.27
homeassistant.home.lan → 192.168.4.27
home.home.lan          → 192.168.4.27
longhorn.home.lan      → 192.168.4.27
rancher.home.lan       → 192.168.4.27
adguard.home.lan       → 192.168.4.27
```

**2. Point eero at AdGuard.** eero app → Settings → Network Settings → DNS → Custom:
- Primary: `192.168.4.27`
- Secondary: `1.1.1.1` *(fallback when AdGuard is down — keep this set or DNS dies for the whole house if the AdGuard pod restarts)*

**3. Refresh DHCP leases** so clients pick up the new resolver. Toggle Wi-Fi on phones; on Linux: `sudo systemctl restart NetworkManager`; on Mac: System Settings → Network → Wi-Fi → Details → Renew DHCP Lease.

**4. Update Ingress hosts** in each `manifests/*.yaml` to add `<app>.home.lan` next to the existing nip.io host (don't remove nip.io — useful fallback when DNS is broken). Example for `manifests/chat-webui.yaml`:

```yaml
spec:
  rules:
    - host: chat.192.168.4.27.nip.io   # existing fallback
      http: { ... }
    - host: chat.home.lan              # new clean URL
      http: { ... }                    # same backend block
```

Re-apply with `kubectl apply -f manifests/<app>.yaml`.

**Sanity check:**
```bash
nslookup chat.home.lan
# → 192.168.4.27 (via AdGuard)

curl -H 'Host: chat.home.lan' http://192.168.4.27
# → Open WebUI welcome page
```

### Tailscale (anywhere, not just LAN)

The Tailscale operator already gives every app a MagicDNS hostname like `chat.bluebuck-micro.ts.net` — same "hostname instead of IP" idea but for the tailnet, working from your phone on cellular, your laptop at a coffee shop, etc. mDNS and AdGuard are LAN-only; Tailscale fills in everywhere else.

## Recovering when a Pi's IP changes

The whole stack is wired around the control plane's IP (`rpi-control` = `192.168.4.27` currently). If that IP changes — eero reassigns it, you swap the Pi, etc. — several things break at once: kubectl can't reach the API server, agents stay `NotReady` because their k3s join URL is stale, and Ingress hosts (`*.<cp-ip>.nip.io`) stop matching. Recipe to recover:

1. **Set the new IP everywhere in the repo** and re-run prep so `/etc/hosts` and `cluster_endpoint` agree:
   ```bash
   # Update inventory.ini if needed (k3s_server line)
   cd ansible
   ansible-playbook site.yml --tags prep
   ```

2. **Fix the laptop kubeconfig** so kubectl works again:
   ```bash
   sed -i 's|server: https://OLD_IP:6443|server: https://NEW_IP:6443|' ~/.kube/config-homelab
   kubectl get nodes        # control plane should be Ready
   ```

3. **Re-point each k3s agent at the new server** (workers stay `NotReady` until you do this). For each worker:
   ```bash
   ssh victord@<worker-ip> "sudo sed -i 's|OLD_IP|NEW_IP|g' /etc/systemd/system/k3s-agent.service.env && sudo systemctl daemon-reload && sudo systemctl restart k3s-agent"
   ```
   Or just re-run `ansible-playbook site.yml --skip-tags rancher` — it regenerates the agent env file from `cluster_endpoint`.

4. **Update Ingress hosts** that bake in the IP (chat, rancher, etc.):
   ```bash
   # chat — just re-apply the manifest after editing host in chat-webui.yaml
   kubectl apply -f manifests/chat-webui.yaml
   # rancher — patch in place
   kubectl -n cattle-system patch ingress rancher --type=json -p='[
     {"op":"replace","path":"/spec/rules/0/host","value":"rancher.NEW_IP.nip.io"},
     {"op":"replace","path":"/spec/tls/0/hosts/0","value":"rancher.NEW_IP.nip.io"}
   ]'
   ```
   ⚠️ Re-applying `chat-webui.yaml` resets the `webui-llm-keys` Secret to the `REPLACE_ME` placeholder. Put the real OpenRouter key back:
   ```bash
   kubectl -n chat create secret generic webui-llm-keys \
     --from-literal=openai-api-key='sk-or-...' \
     --dry-run=client -o yaml | kubectl apply -f -
   kubectl -n chat rollout restart deploy/open-webui
   ```

5. **Force-delete stuck Tailscale proxy pods** if they were on a now-offline node — the operator will respawn them on a healthy node:
   ```bash
   kubectl -n tailscale delete pod -l 'tailscale.com/parent-resource-type=ingress' --force --grace-period=0
   ```

6. **Avoid all of this**: pin every Pi to a DHCP reservation in eero (Settings → Network Settings → DHCP & NAT → Reservations) so the IPs don't drift.

## Useful commands

```bash
# Always
export KUBECONFIG=$HOME/.kube/config-homelab

# Cluster status
kubectl get nodes -o wide
kubectl get pods -A

# Ansible
cd ~/git/rpi-cluster/ansible
ansible all -m ping                          # SSH smoke test
ansible-playbook site.yml --skip-tags rancher
ansible-playbook site.yml --tags rancher \
  -e rancher_bootstrap_password='...' \
  -e rancher_hostname=rancher.192.168.4.27.nip.io

# Watch the Rancher rollout
kubectl -n cattle-system get pods -w
kubectl -n cattle-system get ingress
```
