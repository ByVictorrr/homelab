#!/usr/bin/env bash
# Add (or update) an iCloud Photo Library backup account end-to-end:
#   1. mkdir destination on rpi-node4
#   2. k8s namespace + cookie PVC + CronJob + Secret
#   3. interactive Apple 2FA bootstrap (cookie cached for ~30 days of unattended runs)
#   4. register the path as an External Library in Immich (if IMMICH_API_KEY is set)
#
# Run from a host with:
#   - kubectl configured for the cluster (KUBECONFIG=~/.kube/config-homelab)
#   - SSH access to rpi-node4
#   - A real TTY (Apple's 2FA prompt needs interactive stdin)
#   - curl + jq (only if registering in Immich)
#
# Usage:
#   scripts/add-icloud-account.sh                                      # interactive
#   scripts/add-icloud-account.sh victor you@example.com               # half-interactive
#   scripts/add-icloud-account.sh mom mom@icloud.com mom@yourdom.com   # library owned by mom's Immich user
#   scripts/add-icloud-account.sh --remove mom                         # tear down an account
#   scripts/add-icloud-account.sh --list-libraries                     # list Immich libraries (needs IMMICH_API_KEY)
#   scripts/add-icloud-account.sh --remove-library <id>                # delete an Immich library
#
# Args:
#   $1 slug          — short directory name (e.g. victor, mom). Becomes the namespace suffix.
#   $2 apple-id      — Apple ID email for this iCloud account
#   $3 immich-owner  — (optional) Immich user email that should own the library.
#                      Defaults to the IMMICH_API_KEY owner. Use this to assign
#                      mom's iCloud library to her Immich user, not yours.
#
# Env overrides:
#   IMMICH_API_KEY      If set, auto-register the External Library after bootstrap.
#                       Generate in Immich UI → Account Settings → API Keys.
#                       One admin key works for setting up libraries owned by any user.
#   IMMICH_OWNER_EMAIL  Alternative to passing 3rd arg.
#   IMMICH_URL          (default: http://photos.192.168.4.27.nip.io)
#   SCHEDULE          (default: "0 4 * * *") — cron expr for nightly sync
#   IMAGE             (default: icloudpd/icloudpd:latest)
#   RPI_NODE4_IP      (default: 192.168.4.32)
#   RPI_NODE4_USER    (default: victord)
#   SKIP_BOOTSTRAP=1  Skip the Apple 2FA bootstrap (e.g. when re-registering in Immich only)
#   SKIP_IMMICH=1     Skip Immich library registration even if IMMICH_API_KEY is set
#   SKIP_SCAN=1       Don't trigger an initial Immich scan after registration

set -euo pipefail

RPI_NODE4_IP="${RPI_NODE4_IP:-192.168.4.32}"
RPI_NODE4_USER="${RPI_NODE4_USER:-victord}"
ICLOUD_BASE="/mnt/tank/photos/icloud"
SCHEDULE="${SCHEDULE:-0 4 * * *}"
IMAGE="${IMAGE:-icloudpd/icloudpd:latest}"
IMMICH_URL="${IMMICH_URL:-http://photos.192.168.4.27.nip.io}"

die() { printf 'ERROR: %s\n' "$*" >&2; exit 1; }
need() { command -v "$1" >/dev/null || die "$1 not in PATH"; }

# --- Immich API helpers (only used if IMMICH_API_KEY set) ---------------------

immich_api() {
  local method="$1" path="$2" body="${3:-}"
  local args=(-fsS -X "$method" -H "x-api-key: $IMMICH_API_KEY")
  [ -n "$body" ] && args+=(-H 'Content-Type: application/json' -d "$body")
  curl "${args[@]}" "$IMMICH_URL$path"
}
immich_api_verbose() {
  local method="$1" path="$2" body="${3:-}"
  if ! immich_api "$method" "$path" "$body"; then
    echo "  API call failed, full response:" >&2
    local args=(-sS -X "$method" -H "x-api-key: $IMMICH_API_KEY")
    [ -n "$body" ] && args+=(-H 'Content-Type: application/json' -d "$body")
    curl "${args[@]}" "$IMMICH_URL$path" >&2
    return 1
  fi
}

# --- subcommands --------------------------------------------------------------

case "${1:-}" in
  -h|--help|help)
    sed -n '2,/^$/p' "$0" | sed 's/^# \?//'
    exit 0
    ;;
  --remove)
    SLUG="${2:-}"; [ -n "$SLUG" ] || die "--remove needs a slug"
    NS="icloudpd-$SLUG"
    need kubectl
    echo "Removing namespace $NS (downloads on tank are preserved)..."
    kubectl delete namespace "$NS" --ignore-not-found
    echo "Done. /mnt/tank/photos/icloud/$SLUG is untouched on rpi-node4."
    exit 0
    ;;
  --list-libraries)
    need curl; need jq
    [ -n "${IMMICH_API_KEY:-}" ] || die "IMMICH_API_KEY env var required"
    echo "Immich libraries:"
    immich_api GET /api/libraries | jq -r '.[] | "  \(.id)  owner=\(.ownerId)  name=\(.name)  paths=\(.importPaths | join(","))"'
    exit 0
    ;;
  --remove-library)
    need curl
    [ -n "${IMMICH_API_KEY:-}" ] || die "IMMICH_API_KEY env var required"
    LIB_ID="${2:-}"; [ -n "$LIB_ID" ] || die "--remove-library needs a library id (see --list-libraries)"
    echo "Deleting Immich library $LIB_ID..."
    immich_api DELETE "/api/libraries/$LIB_ID"
    echo "Done."
    exit 0
    ;;
esac

# --- main: add/update an account ---------------------------------------------

need kubectl
kubectl get nodes >/dev/null 2>&1 || die "kubectl can't reach the cluster (check KUBECONFIG)"

SLUG="${1:-}"
APPLE_ID="${2:-}"
# Optional 3rd arg: Immich user email to own the library. Defaults to the
# IMMICH_API_KEY owner (you). Use this when adding an account for someone
# else who has their own Immich user — e.g. you set up mom's iCloud but want
# her photos owned by her Immich account, not yours.
IMMICH_OWNER_EMAIL="${3:-${IMMICH_OWNER_EMAIL:-}}"

[ -z "$SLUG" ]     && read -rp "Account slug (lowercase, no spaces — e.g. victor, mom): " SLUG
[[ "$SLUG" =~ ^[a-z0-9][a-z0-9-]*$ ]] || die "Slug must match ^[a-z0-9][a-z0-9-]*\$"
case "$SLUG" in default|kube-*|longhorn-*) die "Reserved slug: $SLUG" ;; esac

[ -z "$APPLE_ID" ] && read -rp "Apple ID email: " APPLE_ID
[[ "$APPLE_ID" == *@*.* ]] || die "Apple ID must be an email"

read -rsp "Apple ID password: " APPLE_PASSWORD; echo
[ -n "$APPLE_PASSWORD" ] || die "password cannot be empty"

NS="icloudpd-$SLUG"
DIR="$ICLOUD_BASE/$SLUG"

cat <<INFO

Adding/updating iCloud account:
  Slug      : $SLUG
  Apple ID  : $APPLE_ID
  Namespace : $NS
  Directory : $RPI_NODE4_IP:$DIR
  Schedule  : $SCHEDULE
  Image     : $IMAGE
  Immich    : $([ -n "${IMMICH_API_KEY:-}" ] && echo "auto-register at $IMMICH_URL" || echo "skipped (IMMICH_API_KEY not set)")

INFO

# --- 1. ensure destination dir exists on rpi-node4 ---------------------------

echo "→ Ensuring $DIR exists on rpi-node4..."
ssh -o BatchMode=yes "$RPI_NODE4_USER@$RPI_NODE4_IP" \
  "sudo mkdir -p '$DIR' && sudo chown root:root '$DIR'" \
  || die "Failed to ssh+mkdir on rpi-node4 (check ssh + sudo NOPASSWD?)"

# --- 2. apply k8s resources (idempotent) -------------------------------------

echo "→ Applying k8s resources..."
kubectl apply -f - <<YAML
apiVersion: v1
kind: Namespace
metadata:
  name: $NS
  labels:
    icloudpd.account: "$SLUG"
---
apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: icloudpd-cookies
  namespace: $NS
spec:
  accessModes: [ReadWriteOnce]
  storageClassName: longhorn
  resources:
    requests:
      storage: 1Gi
---
apiVersion: batch/v1
kind: CronJob
metadata:
  name: icloudpd-sync
  namespace: $NS
spec:
  schedule: "$SCHEDULE"
  concurrencyPolicy: Forbid
  successfulJobsHistoryLimit: 3
  failedJobsHistoryLimit: 7
  jobTemplate:
    spec:
      backoffLimit: 1
      activeDeadlineSeconds: 21600
      template:
        spec:
          restartPolicy: OnFailure
          nodeSelector:
            kubernetes.io/hostname: rpi-node4
          containers:
            - name: icloudpd
              image: $IMAGE
              env:
                - { name: TZ, value: America/New_York }
                - name: APPLE_ID
                  valueFrom: { secretKeyRef: { name: icloudpd-creds, key: apple-id } }
                - name: APPLE_PASSWORD
                  valueFrom: { secretKeyRef: { name: icloudpd-creds, key: password } }
              command: ["/bin/sh", "-c"]
              args:
                - |
                  set -eu
                  # ARCHIVE mode: NO --auto-delete. Deleting in iCloud does NOT
                  # delete from tank — your home server is the permanent record,
                  # iCloud is just the funnel that gets photos there. To enable
                  # MIRROR mode (sync iCloud deletions to tank), add --auto-delete.
                  #
                  # --skip-videos / --skip-live-photos are bare flags (toggles).
                  # Omitting them = include everything. Adding them = skip.
                  /app/icloudpd \\
                    --username "\$APPLE_ID" \\
                    --password "\$APPLE_PASSWORD" \\
                    --cookie-directory /cookies \\
                    --directory /downloads \\
                    --folder-structure "{:%Y/%m}" \\
                    --no-progress-bar \\
                    --log-level info
              volumeMounts:
                - { name: cookies,   mountPath: /cookies }
                - { name: downloads, mountPath: /downloads }
              resources:
                requests: { cpu: "100m", memory: "256Mi" }
                limits:   { cpu: "1500m", memory: "1Gi" }
          volumes:
            - name: cookies
              persistentVolumeClaim: { claimName: icloudpd-cookies }
            - name: downloads
              nfs:
                server: $RPI_NODE4_IP
                path: $DIR
YAML

# --- 3. apply Secret separately (so password isn't in apply args) ------------

echo "→ Applying credentials Secret..."
kubectl -n "$NS" create secret generic icloudpd-creds \
  --from-literal=apple-id="$APPLE_ID" \
  --from-literal=password="$APPLE_PASSWORD" \
  --from-literal=account-slug="$SLUG" \
  --dry-run=client -o yaml | kubectl apply -f -

echo "→ Waiting for cookie PVC to bind..."
kubectl -n "$NS" wait --for=jsonpath='{.status.phase}'=Bound \
  pvc/icloudpd-cookies --timeout=60s

# --- 4. interactive bootstrap (Apple 2FA) ------------------------------------

if [ "${SKIP_BOOTSTRAP:-0}" = "1" ]; then
  echo "→ Skipping 2FA bootstrap (SKIP_BOOTSTRAP=1)"
else
  cat <<NOTE

============================================================
Bootstrap: Apple 2FA login
------------------------------------------------------------
A short-lived pod will run on rpi-node4 and prompt for the
six-digit code Apple texts to your trusted device.

If a previous bootstrap left a cookie that is still valid you
won't be prompted; the pod will exit with "Authenticated."

If the pod hangs at "Please enter two-factor authentication
code:" your terminal isn't passing through the TTY. Re-run
this script from an interactive terminal (not via tmux
detached / CI / nohup).
============================================================

NOTE
  read -rp "Press Enter to launch the bootstrap pod... " _

  kubectl -n "$NS" delete pod icloudpd-bootstrap --ignore-not-found >/dev/null 2>&1 || true

  OVERRIDES=$(cat <<JSON
{
  "spec": {
    "nodeSelector": {"kubernetes.io/hostname": "rpi-node4"},
    "containers": [{
      "name": "icloudpd",
      "image": "$IMAGE",
      "stdin": true,
      "tty": true,
      "env": [
        {"name": "APPLE_ID", "valueFrom": {"secretKeyRef": {"name": "icloudpd-creds", "key": "apple-id"}}},
        {"name": "APPLE_PASSWORD", "valueFrom": {"secretKeyRef": {"name": "icloudpd-creds", "key": "password"}}}
      ],
      "command": ["/bin/sh", "-c"],
      "args": ["/app/icloudpd --username \"\$APPLE_ID\" --password \"\$APPLE_PASSWORD\" --cookie-directory /cookies --directory /downloads --auth-only"],
      "volumeMounts": [
        {"name": "cookies", "mountPath": "/cookies"},
        {"name": "downloads", "mountPath": "/downloads"}
      ]
    }],
    "volumes": [
      {"name": "cookies", "persistentVolumeClaim": {"claimName": "icloudpd-cookies"}},
      {"name": "downloads", "nfs": {"server": "$RPI_NODE4_IP", "path": "$DIR"}}
    ]
  }
}
JSON
)

  kubectl -n "$NS" run icloudpd-bootstrap \
    --rm -it --restart=Never \
    --image="$IMAGE" \
    --overrides="$OVERRIDES" \
    --command -- true   # command is overridden via JSON above
fi

# --- 5. (optional) register Immich External Library --------------------------

if [ -n "${IMMICH_API_KEY:-}" ] && [ "${SKIP_IMMICH:-0}" != "1" ]; then
  need curl; need jq

  IMPORT_PATH="/data/icloud/$SLUG"
  LIBRARY_NAME="iCloud — $SLUG"

  echo
  echo "→ Registering External Library in Immich..."
  echo "  URL  : $IMMICH_URL"
  echo "  Path : $IMPORT_PATH"
  echo "  Name : $LIBRARY_NAME"

  # Resolve owner: explicit email (3rd arg / IMMICH_OWNER_EMAIL), or default to
  # whoever owns the API key (/api/users/me).
  if [ -n "$IMMICH_OWNER_EMAIL" ]; then
    USERS_JSON="$(immich_api GET /api/users)"
    OWNER_ID=$(echo "$USERS_JSON" | jq -r --arg e "$IMMICH_OWNER_EMAIL" \
      '.[] | select(.email==$e) | .id' | head -1)
    OWNER_EMAIL="$IMMICH_OWNER_EMAIL"
    if [ -z "$OWNER_ID" ]; then
      echo "WARN: no Immich user with email $IMMICH_OWNER_EMAIL — Immich registration skipped"
      OWNER_ID=""
    fi
  else
    ME_JSON="$(immich_api GET /api/users/me)"
    OWNER_ID=$(echo "$ME_JSON" | jq -r '.id')
    OWNER_EMAIL=$(echo "$ME_JSON" | jq -r '.email')
  fi
  if [ -z "$OWNER_ID" ] || [ "$OWNER_ID" = null ]; then
    [ -z "$OWNER_ID" ] || echo "WARN: couldn't resolve owner — Immich registration skipped"
  else
    echo "  Owner: $OWNER_EMAIL ($OWNER_ID)"

    # Check for existing library on the same path (idempotent)
    EXISTING=$(immich_api GET /api/libraries | jq -r --arg p "$IMPORT_PATH" \
      '.[] | select(.importPaths | index($p)) | .id' | head -1)

    if [ -n "$EXISTING" ]; then
      echo "  Library already exists for $IMPORT_PATH (id=$EXISTING) — triggering re-scan"
      LIB_ID="$EXISTING"
    else
      REQ=$(jq -n \
        --arg owner "$OWNER_ID" \
        --arg name  "$LIBRARY_NAME" \
        --arg path  "$IMPORT_PATH" \
        '{ownerId:$owner, name:$name, importPaths:[$path], exclusionPatterns:[]}')
      RESP=$(immich_api_verbose POST /api/libraries "$REQ") || RESP=""
      LIB_ID=$(echo "$RESP" | jq -r .id 2>/dev/null || echo "")
      if [ -z "$LIB_ID" ] || [ "$LIB_ID" = null ]; then
        echo "WARN: library creation failed; you can re-run this script after the 2FA cookie is saved"
        LIB_ID=""
      else
        echo "  Created library id $LIB_ID"
      fi
    fi

    if [ -n "$LIB_ID" ] && [ "${SKIP_SCAN:-0}" != "1" ]; then
      echo "→ Triggering scan..."
      immich_api POST "/api/libraries/$LIB_ID/scan" >/dev/null || \
        echo "WARN: scan trigger failed (you can scan from the Immich UI)"
    fi
  fi
fi

# --- 6. next steps -----------------------------------------------------------

cat <<DONE

============================================================
✓ Account "$SLUG" is set up.

What it does now:
  - Nightly $SCHEDULE: pulls new iCloud photos to
    /mnt/tank/photos/icloud/$SLUG/  on rpi-node4
  - Immich indexes the same path automatically (if registered)

Trigger a sync immediately:
  kubectl -n $NS create job test-\$(date +%s) --from=cronjob/icloudpd-sync
  kubectl -n $NS logs -f -l job-name

Check download size:
  ssh $RPI_NODE4_USER@$RPI_NODE4_IP 'sudo du -sh $DIR'

Remove this account later:
  $0 --remove $SLUG
DONE

if [ -z "${IMMICH_API_KEY:-}" ]; then
  cat <<MANUAL

To register in Immich UI:
  1. Account Settings → API Keys → "New API Key" → copy
  2. Re-run: IMMICH_API_KEY=<key> $0 $SLUG $APPLE_ID
     (SKIP_BOOTSTRAP=1 if your cookie is still valid)
MANUAL
fi

echo "============================================================"
