"""Generate k8s-pi-cluster-plan.pdf — recommended k3s cluster config for 4-now/5-soon Pi 5 (8GB) homelab."""

from reportlab.lib.pagesizes import LETTER
from reportlab.lib.styles import getSampleStyleSheet, ParagraphStyle
from reportlab.lib.units import inch
from reportlab.lib import colors
from reportlab.platypus import (
    SimpleDocTemplate, Paragraph, Spacer, Table, TableStyle,
    PageBreak, KeepTogether, Preformatted,
)
from reportlab.lib.enums import TA_LEFT

OUT = "/home/victord/git/rpi-cluster/plan.pdf"

styles = getSampleStyleSheet()
H1 = ParagraphStyle("H1", parent=styles["Heading1"], fontSize=18, spaceAfter=10,
                    textColor=colors.HexColor("#0b3d91"))
H2 = ParagraphStyle("H2", parent=styles["Heading2"], fontSize=13, spaceBefore=12,
                    spaceAfter=6, textColor=colors.HexColor("#0b3d91"))
H3 = ParagraphStyle("H3", parent=styles["Heading3"], fontSize=11, spaceBefore=8,
                    spaceAfter=4, textColor=colors.HexColor("#333333"))
BODY = ParagraphStyle("Body", parent=styles["BodyText"], fontSize=10, leading=14,
                      alignment=TA_LEFT, spaceAfter=6)
SMALL = ParagraphStyle("Small", parent=styles["BodyText"], fontSize=9, leading=12,
                       textColor=colors.HexColor("#555555"))
CODE = ParagraphStyle("Code", parent=styles["Code"], fontSize=8.5, leading=11,
                      leftIndent=10, backColor=colors.HexColor("#f3f3f3"),
                      borderPadding=6, spaceBefore=4, spaceAfter=8)
SCRIPT = ParagraphStyle("Script", parent=styles["Code"], fontSize=7.2, leading=9,
                        leftIndent=6, backColor=colors.HexColor("#f7f7f7"),
                        borderPadding=4, spaceBefore=2, spaceAfter=6)

def code(text):
    return Preformatted(text.strip("\n"), CODE)

def script_block(path):
    with open(path) as f:
        body = f.read().rstrip("\n")
    return Preformatted(body, SCRIPT)

def hr(width=6.5*inch):
    t = Table([[""]], colWidths=[width], rowHeights=[1])
    t.setStyle(TableStyle([("LINEABOVE", (0,0), (-1,-1), 0.5, colors.HexColor("#cccccc"))]))
    return t

story = []

# ---------- Title ----------
story += [
    Paragraph("Raspberry Pi Kubernetes Cluster Plan", H1),
    Paragraph("k3s on 4× Pi 5 (8GB), growing to 5 — single control plane, homelab + learning",
              SMALL),
    Spacer(1, 6), hr(), Spacer(1, 10),
]

# ---------- TL;DR ----------
story += [
    Paragraph("TL;DR", H2),
    Paragraph(
        "Run a <b>single k3s server + k3s agents</b> on every other node. Phase 1 is "
        "<b>1 server + 3 agents</b> (4 Pis you have today). When the 5th Pi arrives, "
        "just join it as a 4th agent — <b>1 server + 4 agents</b>. No HA, no rebuild. "
        "Run Ubuntu Server 24.04 arm64 on every node. Put the control-plane role on "
        "whichever Pi has the best storage (NVMe HAT &gt; USB SSD &gt; SD card) — "
        "etcd writes will hammer it.",
        BODY),
    Paragraph(
        "<b>Tradeoff you&rsquo;re accepting:</b> if the control-plane Pi dies, the API "
        "is unreachable until you restore it. Workloads on workers keep running, but "
        "you can&rsquo;t deploy, scale, or schedule until the CP is back. Mitigate with "
        "regular etcd snapshots (covered at the end).",
        BODY),
]

# ---------- Topology table ----------
story += [Paragraph("Topology", H2)]

TABLE_STYLE = TableStyle([
    ("BACKGROUND", (0,0), (-1,0), colors.HexColor("#0b3d91")),
    ("TEXTCOLOR", (0,0), (-1,0), colors.white),
    ("FONTNAME", (0,0), (-1,0), "Helvetica-Bold"),
    ("FONTSIZE", (0,0), (-1,-1), 9),
    ("GRID", (0,0), (-1,-1), 0.25, colors.HexColor("#999999")),
    ("VALIGN", (0,0), (-1,-1), "TOP"),
    ("ROWBACKGROUNDS", (0,1), (-1,-1), [colors.white, colors.HexColor("#f7f7f7")]),
])

topo_now = [
    ["Role", "Count", "Hostname", "k3s role", "Notes"],
    ["Control plane", "1", "rpi-control", "server", "Best storage; runs API, scheduler, etcd"],
    ["Worker", "3", "rpi-node{1..3}", "agent", "Run workloads; SD OK, SSD better"],
]
t = Table(topo_now, colWidths=[1.0*inch, 0.5*inch, 1.2*inch, 0.8*inch, 3.0*inch])
t.setStyle(TABLE_STYLE)
story += [Paragraph("<b>Phase 1 — 4 nodes (today)</b>", H3), t, Spacer(1, 6)]

topo_later = [
    ["Role", "Count", "Hostname", "k3s role", "Notes"],
    ["Control plane", "1", "rpi-control", "server", "Unchanged from Phase 1"],
    ["Worker", "4", "rpi-node{1..4}", "agent", "Just add the 5th Pi as a new agent"],
]
t2 = Table(topo_later, colWidths=[1.0*inch, 0.5*inch, 1.2*inch, 0.8*inch, 3.0*inch])
t2.setStyle(TABLE_STYLE)
story += [Paragraph("<b>Phase 2 — 5 nodes (when Pi #5 arrives)</b>", H3), t2, Spacer(1, 10)]

# ---------- Why this shape ----------
story += [
    Paragraph("Why this shape", H2),
    Paragraph(
        "• <b>Single CP, by choice.</b> One server + many workers is the simplest "
        "possible cluster: minimal moving parts, no quorum to reason about, no etcd "
        "leader elections to debug. Ideal for learning kubectl, manifests, helm, "
        "ingress, and storage without HA noise on top.", BODY),
    Paragraph(
        "• <b>Failure mode is well-defined.</b> Worker death = pods reschedule onto "
        "surviving workers. CP death = API down until you fix the CP Pi; running "
        "workloads on workers keep serving. Acceptable for homelab use.", BODY),
    Paragraph(
        "• <b>Pi 5 8GB is comfortable.</b> A k3s server idles around 600–900 MB. "
        "Plenty of headroom for the control plane plus a few light workloads on the "
        "same node if you want to taint it as schedulable.", BODY),
    Paragraph(
        "• <b>k3s vs kubeadm.</b> For a Pi homelab, k3s wins: single binary, embedded "
        "etcd, Traefik + ServiceLB + local-path-provisioner preinstalled. You still get "
        "vanilla kubectl, Helm, manifests — it&rsquo;s real Kubernetes.", BODY),
    Paragraph(
        "• <b>Growth path stays trivial.</b> Adding the 5th Pi (or a 6th, 7th…) is just "
        "one curl command on that node. No cluster reshape needed.", BODY),
]

# ---------- Hardware role assignment ----------
story += [
    Paragraph("Hardware role assignment", H2),
    Paragraph(
        "Match the storage to the role. etcd is write-heavy and SD cards die fast under "
        "that load — months, not years.", BODY),
]
hw = [
    ["Storage on Pi", "Best role", "Why"],
    ["NVMe HAT", "Control plane", "Best write endurance + latency for etcd; pick this one as CP"],
    ["USB SSD", "Worker w/ persistent volumes", "Good for stateful pods, DBs, Longhorn replicas"],
    ["SD card only", "Pure worker", "Fine for stateless pods; avoid PV writes"],
]
t3 = Table(hw, colWidths=[1.6*inch, 2.2*inch, 2.7*inch])
t3.setStyle(TABLE_STYLE)
story += [t3, Spacer(1, 6)]

story += [PageBreak()]

# ---------- Network plan ----------
story += [
    Paragraph("Network plan", H2),
    Paragraph("• Wired Gigabit on every node. WiFi is fine for one-off experiments but "
              "wreaks havoc on etcd heartbeats and pod-to-pod latency.", BODY),
    Paragraph("• All nodes on the same /24 subnet. Pin each node to a stable IP via "
              "DHCP reservation on your router (easier than static configs per node).", BODY),
    Paragraph("• Reserve a small block of IPs on your LAN for LoadBalancer services "
              "(e.g., 10 IPs). k3s&rsquo;s built-in <b>ServiceLB</b> works on day 1; "
              "swap in <b>MetalLB</b> when you want real LB semantics.", BODY),
    Paragraph("<b>Example IP plan</b>", H3),
    code("""
192.168.1.10   rpi-control       (control plane / NVMe Pi)
192.168.1.11   rpi-node1     (worker)
192.168.1.12   rpi-node2     (worker)
192.168.1.13   rpi-node3     (worker)
192.168.1.14   rpi-node4     (worker — the Pi #5 once it arrives)
192.168.1.200-210   reserved for LoadBalancer service IPs
"""),
]

# ---------- Runbook with Ansible ----------
story += [
    Paragraph("Build runbook (Ansible)", H2),
    Paragraph(
        "Two-phase flow. Flashing has to happen per SD card (can&rsquo;t SSH to a Pi "
        "that hasn&rsquo;t booted yet), so <code>01-flash-pi.sh</code> stays. Everything "
        "after first boot is one Ansible playbook that hits all 4 Pis in parallel and is "
        "idempotent — rerun it freely.", BODY),
    Paragraph(
        "Ansible files live in <code>~/git/rpi-cluster/ansible/</code>:", BODY),
]
files = [
    ["File", "Purpose"],
    ["ansible.cfg", "Defaults — uses inventory.ini, 10 forks, SSH ControlMaster for speed."],
    ["inventory.ini", "Maps hostnames to .local addresses and groups them as k3s_server "
                      "and k3s_agent."],
    ["group_vars/all.yml", "Variables: k3s install args, kubeconfig path, Rancher hostname "
                            "+ bootstrap password (override on the CLI with -e KEY=VAL)."],
    ["site.yml", "One playbook with 5 plays: OS prep, k3s server, k3s agents, fetch "
                  "kubeconfig, install Rancher. Use --tags to run pieces in isolation."],
]
tf = Table(files, colWidths=[1.6*inch, 4.9*inch])
tf.setStyle(TABLE_STYLE)
story += [tf, Spacer(1, 8)]

story += [
    Paragraph("Step 0 — One-time setup on your laptop", H3),
    code("""
sudo apt -y install ansible
ansible-galaxy collection install kubernetes.core community.general

# helm is needed by the Rancher play:
curl -fsSL https://raw.githubusercontent.com/helm/helm/main/scripts/get-helm-3 | bash
"""),

    Paragraph("Step 1 — Flash + boot each Pi", H3),
    Paragraph("Per SD card (still scripted, not Ansible):", BODY),
    code("""
# rpi-control first, then each worker:
sudo ~/git/rpi-cluster/scripts/01-flash-pi.sh rpi-control /dev/mmcblk0
sudo ~/git/rpi-cluster/scripts/01-flash-pi.sh rpi-node1   /dev/mmcblk0
sudo ~/git/rpi-cluster/scripts/01-flash-pi.sh rpi-node2   /dev/mmcblk0
sudo ~/git/rpi-cluster/scripts/01-flash-pi.sh rpi-node3   /dev/mmcblk0
"""),
    Paragraph("Boot each Pi, wait ~90 s for cloud-init. Verify SSH works to all:", BODY),
    code("""
cd ~/git/rpi-cluster/ansible
ansible all -m ping
# Expect 'pong' from rpi-control + rpi-node{1..3}.
"""),

    Paragraph("Step 2 — Run the full playbook", H3),
    code("""
cd ~/git/rpi-cluster/ansible

# Everything except Rancher (OS prep, k3s server, k3s agents, kubeconfig):
ansible-playbook site.yml --skip-tags rancher

# Then Rancher (override the default bootstrap password first):
ansible-playbook site.yml --tags rancher \\
  -e rancher_bootstrap_password='something-long-and-yours'
"""),
    Paragraph(
        "<b>What happens:</b> Ansible SSHes to all 4 Pis in parallel, runs apt upgrade + "
        "swap off + iscsid, asserts memory cgroups are enabled (and stops if not). Then "
        "it installs k3s server on rpi-control, grabs the join token off the filesystem, "
        "and installs k3s agent on every worker — joining them automatically with the "
        "right URL + token. No copy/paste of tokens between steps. Then it pulls the "
        "kubeconfig to <code>~/.kube/config-homelab</code> on your laptop.", BODY),

    Paragraph("Useful tag combinations", H3),
    code("""
# Smoke-test SSH only:
ansible all -m ping

# Just the OS prep on every node (e.g., after kernel update):
ansible-playbook site.yml --tags prep

# Just a single host (e.g., re-provision rpi-node2):
ansible-playbook site.yml --limit rpi-node2

# Just refetch kubeconfig:
ansible-playbook site.yml --tags kubeconfig

# Dry-run everything (show what would change, don't apply):
ansible-playbook site.yml --check --diff
"""),

    Paragraph("Step 3 — Adding the 5th Pi later", H3),
    Paragraph("Uncomment the <code>rpi-node4</code> line in <code>inventory.ini</code>, "
              "flash its card, boot, then:", BODY),
    code("ansible-playbook site.yml --skip-tags rancher --limit rpi-node4"),
    Paragraph("Done. Ansible re-runs the prep + agent install on just that host. "
              "Existing nodes are skipped because the playbook is idempotent.", BODY),
]

story += [PageBreak()]

# ---------- Rancher (now via Ansible) ----------
story += [
    Paragraph("Installing Rancher Manager", H2),
    Paragraph(
        "<b>What it is.</b> Rancher Manager is a web UI for managing one or more "
        "Kubernetes clusters — workload browser, kubectl-in-browser, RBAC, monitoring, "
        "Fleet (GitOps), and one-click app installs. It runs <i>inside</i> the cluster "
        "as a Deployment in the <code>cattle-system</code> namespace.", BODY),
    Paragraph(
        "<b>What the playbook does.</b> The <code>rancher</code> tag runs locally on your "
        "laptop (uses the kubeconfig already fetched to <code>~/.kube/config-homelab</code>) "
        "and Helm-installs three things in order: <b>ingress-nginx</b> (since Traefik was "
        "disabled), <b>cert-manager</b> (Rancher needs it for TLS), then <b>Rancher</b> itself.", BODY),
    Paragraph(
        "<b>Hostname trick.</b> Rancher needs a hostname to serve from. To avoid editing "
        "<code>/etc/hosts</code> on every device, the playbook defaults to <code>rancher."
        "&lt;rpi-control-ip&gt;.nip.io</code> — <i>nip.io</i> is a wildcard DNS service "
        "that resolves any <code>x.y.z.w.nip.io</code> back to its embedded IP. Override "
        "with <code>-e rancher_hostname=rancher.example.lan</code> if you prefer a real "
        "DNS name.", BODY),
    Paragraph(
        "<b>Resource cost.</b> Rancher + nginx + cert-manager together use about "
        "1.5–2 GB RAM. Pi 5 8GB handles it comfortably.", BODY),
    Paragraph("<b>Run it</b> (after the rest of the playbook has succeeded):", H3),
    code("""
cd ~/git/rpi-cluster/ansible
ansible-playbook site.yml --tags rancher \\
  -e rancher_bootstrap_password='something-long-and-yours'

# When the play finishes, the final debug task prints the URL to open.
"""),
    Paragraph(
        "First page load shows a self-signed cert warning — accept it, then set a real "
        "admin password on the welcome screen.", BODY),
    Paragraph("<b>If something gets stuck</b>", H3),
    code("""
# Watch the Rancher pods come up:
kubectl -n cattle-system get pods -w

# Most common slow step: pulling arm64 images on first install (5-10 min).

# If the URL won't load, check the nginx LoadBalancer got an IP:
kubectl -n ingress-nginx get svc ingress-nginx-controller
# EXTERNAL-IP should be one of the rpi-control / rpi-node{1..3} IPs.

# Logs:
kubectl -n cattle-system logs deploy/rancher --tail=200
"""),
    Paragraph(
        "<b>Importing the cluster into Rancher.</b> Rancher auto-imports the cluster it "
        "runs on (it shows up as &lsquo;local&rsquo;). To add additional clusters later, "
        "use the &lsquo;Import Existing&rsquo; flow in the UI and run the import command "
        "it gives you on the new cluster.", BODY),
]

# ---------- Backups / etcd snapshots ----------
story += [
    Paragraph("Backups: etcd snapshots", H2),
    Paragraph(
        "Single-CP means the cluster API depends on rpi-control. Take regular etcd "
        "snapshots and store them off-Pi so you can rebuild fast if the SD/SSD dies:", BODY),
    code("""
# One-shot snapshot (run on rpi-control):
sudo k3s etcd-snapshot save --name manual-$(date +%F)

# Or enable automatic snapshots — every 6 hours, keep last 10.
# Edit /etc/systemd/system/k3s.service and append to ExecStart:
#   --etcd-snapshot-schedule-cron '0 */6 * * *' \\
#   --etcd-snapshot-retention 10
# then: sudo systemctl daemon-reload && sudo systemctl restart k3s

# Snapshots land in /var/lib/rancher/k3s/server/db/snapshots/
# Rsync them to off-Pi storage on a cron from your laptop:
rsync -av victord@rpi-control:/var/lib/rancher/k3s/server/db/snapshots/ ~/backups/k3s/
"""),
]

# ---------- Suggested add-ons ----------
story += [
    Paragraph("Suggested add-ons for a homelab", H2),
    Paragraph("Install these once the cluster is healthy. All run fine on Pi 5 8GB.", BODY),
]
addons = [
    ["Add-on", "Purpose", "Notes"],
    ["MetalLB", "LoadBalancer IPs on bare metal", "Or use k3s built-in ServiceLB to start"],
    ["cert-manager", "Auto TLS certs (Let's Encrypt)", "Pairs with Traefik or nginx-ingress"],
    ["Longhorn", "Distributed block storage / PVs", "Wants SSDs; replicate across 3 nodes"],
    ["ArgoCD or Flux", "GitOps — declare cluster state in git", "Great learning vehicle"],
    ["kube-prometheus-stack", "Metrics + Grafana", "Heavier; watch RAM on CPs"],
    ["Pi-hole / AdGuard", "Network DNS sinkhole", "Classic first homelab workload"],
    ["Home Assistant", "Home automation", "Use a StatefulSet with PV on Longhorn"],
]
t4 = Table(addons, colWidths=[1.7*inch, 2.1*inch, 2.7*inch])
t4.setStyle(TABLE_STYLE)
story += [t4, Spacer(1, 8)]

# ---------- Gotchas ----------
story += [
    Paragraph("Gotchas worth knowing up front", H2),
    Paragraph("• <b>SD card death.</b> etcd + container logs murder SD cards. If your CP "
              "is on SD, plan to migrate to SSD within weeks, not months.", BODY),
    Paragraph("• <b>Power.</b> Pi 5 wants the official 27 W USB-C PD supply. Undervoltage "
              "throttling on a CP looks like random API timeouts.", BODY),
    Paragraph("• <b>Cooling.</b> Active cooling (the official fan or a case with one) "
              "is basically required for sustained K8s workloads on Pi 5.", BODY),
    Paragraph("• <b>iptables-nft vs legacy.</b> Ubuntu 24.04 uses nft by default and k3s "
              "handles it correctly; only a problem if you mix in custom iptables rules.", BODY),
    Paragraph("• <b>Mixed-arch images.</b> Always pull arm64 image variants. Most popular "
              "images are multi-arch now, but some niche ones aren&rsquo;t.", BODY),
    Paragraph("• <b>Backups matter more with single CP.</b> Set up etcd snapshots from "
              "day 1 (see Phase 2 section). With no HA, a snapshot is the difference "
              "between a 10-minute restore and rebuilding everything from scratch.", BODY),
    Paragraph("• <b>Don&rsquo;t taint the CP unschedulable</b> unless you start running "
              "out of capacity. With 1 CP + 3 workers, letting light system pods land on "
              "the CP keeps cluster utilization sensible.", BODY),
]

# ---------- Appendix A: flash script source ----------
SCRIPTS_DIR = "/home/victord/git/rpi-cluster/scripts"
ANSIBLE_DIR = "/home/victord/git/rpi-cluster/ansible"

story += [
    PageBreak(),
    Paragraph("Appendix A: SD card flash script", H2),
    Paragraph(
        f"Lives in <code>{SCRIPTS_DIR}/</code>. Used once per Pi before Ansible can "
        f"reach it.", BODY),
    Paragraph("<b>01-flash-pi.sh</b>", H3),
    Paragraph("Flashes Ubuntu 24.04 to the SD card and writes cloud-init user-data "
              "(hostname + your SSH key) + cgroup params to cmdline.txt. Run locally "
              "with sudo.", BODY),
    script_block(f"{SCRIPTS_DIR}/01-flash-pi.sh"),
]

# ---------- Appendix B: Ansible files ----------
ANSIBLE_FILES = [
    ("ansible.cfg", "Defaults: uses inventory.ini, 10 forks, SSH ControlMaster."),
    ("inventory.ini", "Hosts + groups (k3s_server, k3s_agent)."),
    ("group_vars/all.yml", "Cluster-wide variables — k3s args, kubeconfig path, "
                            "Rancher defaults. Override on the CLI with -e KEY=VAL."),
    ("site.yml", "Five plays: prep, k3s server, k3s agents, fetch kubeconfig, Rancher."),
]
story += [
    PageBreak(),
    Paragraph("Appendix B: Ansible files", H2),
    Paragraph(f"All Ansible files live in <code>{ANSIBLE_DIR}/</code>.", BODY),
]
for name, desc in ANSIBLE_FILES:
    path = f"{ANSIBLE_DIR}/{name}"
    story += [
        Paragraph(f"<b>{name}</b>", H3),
        Paragraph(desc, BODY),
        script_block(path),
    ]

# ---------- Footer ----------
story += [
    Spacer(1, 12), hr(),
    Paragraph("Generated for vdelaplainess@gmail.com — 2026-06-06", SMALL),
]

doc = SimpleDocTemplate(
    OUT, pagesize=LETTER,
    leftMargin=0.75*inch, rightMargin=0.75*inch,
    topMargin=0.7*inch, bottomMargin=0.7*inch,
    title="Raspberry Pi Kubernetes Cluster Plan",
    author="Claude Code",
)
doc.build(story)
print(f"wrote {OUT}")
