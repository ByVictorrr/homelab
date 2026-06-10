# rpi-cluster progress

Living checklist from "boxes on a desk" → first workload running.

## Environment

- 4× Raspberry Pi 5 (8 GB), Ubuntu Server 24.04 arm64
- LAN: `192.168.4.0/24` (eero, DHCP reservations)
  - `rpi-control` → `192.168.4.92`
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
  - Ingress exists with host `rancher.192.168.4.92.nip.io`, bound to all 4 node IPs via klipper-lb
  - Will return 503 → then the welcome page once the pod is Ready

## Next — to first pod

1. [ ] **Verify Rancher UI**
   - Browse to `https://rancher.192.168.4.92.nip.io/`
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
       - host: hello.192.168.4.92.nip.io
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
   curl http://hello.192.168.4.92.nip.io/   # expect nginx welcome page
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

Browse to `http://chat.192.168.4.92.nip.io/`. First account you create becomes admin; later signups land in `pending` until you approve them in Settings → Admin → Users. In Settings → Models pick something like `anthropic/claude-3.5-sonnet` or `openai/gpt-4o-mini` as the default.

### 2. (Optional) Local model fallback

```bash
kubectl apply -f manifests/ollama.yaml
kubectl -n ollama get pods -w

# Pull a Pi-sized model (~2 GB):
kubectl -n ollama exec -it deploy/ollama -- ollama pull llama3.2:3b
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

# Find the assigned hostname (something like chat.<tailnet>.ts.net):
kubectl -n chat get ingress open-webui-ts -w
```

On each family member's phone/laptop:
1. Install Tailscale, sign in, accept the invite to your tailnet.
2. Open `https://chat.<your-tailnet>.ts.net/` in any browser.
3. Sign up; you approve them once from the admin panel.

That's it — encrypted, no public exposure, no auth proxy of your own to maintain.

## Later (not blocking first pod)

- [ ] **Persistent storage** — Longhorn. Prep is done (`open-iscsi` + `iscsid` are already installed by the prep play). Install via Rancher's app catalog or `helm install longhorn longhorn/longhorn -n longhorn-system --create-namespace`. Needed before any stateful workload.
- [ ] **Backups** — once Longhorn is up, point it at NFS or S3 for volume snapshots.
- [ ] **5th Pi (rpi-node4)** — full walkthrough below.
- [ ] **Real DNS** — Pi-hole / AdGuard inside the cluster, point eero's custom DNS at the CP's IP. Replaces nip.io with real internal hostnames.

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

### 8. (Optional) Let Kubernetes rebalance

New nodes don't pull existing pods toward them automatically. If you want some workloads to migrate, either delete the pods (let the Deployment recreate them, scheduler may place them on rpi-node4) or use a descheduler. For a homelab this is usually overkill — let new workloads land naturally.

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
  -e rancher_hostname=rancher.192.168.4.92.nip.io

# Watch the Rancher rollout
kubectl -n cattle-system get pods -w
kubectl -n cattle-system get ingress
```
