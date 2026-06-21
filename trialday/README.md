# Raspberry Pi k3s deploy

Manifests + scripts to run Trialday on a k3s cluster of arm64 Raspberry Pis,
pulling images from GHCR built by GitHub Actions.

```
deploy/
├── k8s/
│   ├── namespace.yaml
│   ├── kustomization.yaml         # bundles app + postgres + cron
│   ├── postgres/                  # StatefulSet + headless Service + PVC
│   ├── app/                       # Deployment + Service + Ingress + migrate Job
│   ├── cron/                      # CronJobs that hit /api/cron/* + push metrics
│   └── observability/             # Prometheus + Pushgateway + Grafana (own bundle)
└── scripts/
    ├── create-secrets.sh          # trialday-env + postgres-credentials
    ├── ghcr-login.sh              # imagePullSecret for GHCR
    ├── deploy.sh                  # migrate then roll the Deployment
    └── observability-bootstrap.sh # one-shot Prometheus+Grafana install
```

The kustomize bundle intentionally **omits** the Secrets and the migrate Job:
secrets are applied separately to avoid committing values, and the migrate
Job is created per-release by `deploy.sh` so the image tag matches.

The observability stack lives in its **own namespace** (`observability`) with
its own kustomize bundle, so it can be installed, updated, or removed
independently of the app.

## One-time cluster bootstrap

1. **Install k3s** on every Pi (one server, rest as agents). On the server
   node:
   ```sh
   curl -sfL https://get.k3s.io | sh -
   sudo cat /etc/rancher/k3s/k3s.yaml   # use as ~/.kube/config from your laptop
   ```
   Workers join with the token from `/var/lib/rancher/k3s/server/node-token`.

2. **Pick the Postgres node.** The Postgres StatefulSet uses `local-path`
   storage, so the PVC is bound to whichever node first schedules the pod.
   Label that node so it stays pinned there across restarts:
   ```sh
   kubectl label node <pi-with-ssd> trialday.app/postgres=true
   ```

3. **Push the namespace and pull secret:**
   ```sh
   kubectl apply -f deploy/k8s/namespace.yaml
   GHCR_USERNAME=byvictorrr GHCR_TOKEN=ghp_... ./deploy/scripts/ghcr-login.sh
   ```

4. **Create the env Secrets.** Put a real `.env.production` together (copy
   `deploy/k8s/app/secret.example.yaml` for the shape) and a `.env.postgres`
   with `POSTGRES_USER` / `POSTGRES_PASSWORD` / `POSTGRES_DB`. Make the
   `DATABASE_URL` in `.env.production` point at
   `postgres.trialday.svc.cluster.local:5432` and reuse the same password
   as `.env.postgres`. Then:
   ```sh
   ./deploy/scripts/create-secrets.sh .env.production .env.postgres
   ```

5. **DNS + TLS.** Point `trialday.app` at the public IP that fronts your
   cluster (router port-forward, Cloudflare Tunnel, Tailscale Funnel, …).
   For TLS, install cert-manager and uncomment the annotations + `tls:`
   block in `deploy/k8s/app/ingress.yaml`.

## Configure GitHub Actions

In the repo's **Settings → Secrets and variables → Actions**, add the
build-time `NEXT_PUBLIC_*` values under **Variables** (they end up in the
client bundle, no point hiding them):

- `NEXT_PUBLIC_APP_URL`
- `NEXT_PUBLIC_CLERK_PUBLISHABLE_KEY`
- `NEXT_PUBLIC_POSTHOG_KEY`
- `NEXT_PUBLIC_POSTHOG_HOST`

`.github/workflows/deploy-image.yml` builds `linux/arm64` on every push to
`main` and tags the image as both `sha-<short>` and `latest`. The workflow
needs no extra secrets — `GITHUB_TOKEN` is auto-injected for GHCR push.

> Sentry source-map upload is **off** in this Pi build because the
> Dockerfile clears `SENTRY_AUTH_TOKEN` in the builder stage. If you want
> symbolicated traces from Pi deploys, change that ENV line to read the
> token from a `--mount=type=secret` and pass it via the workflow's
> `secrets:` block.

## Day-to-day deploys

Wait for the GHA build to finish, grab the short SHA, then:

```sh
./deploy/scripts/deploy.sh sha-1a2b3c4
```

This deletes any prior migrate Job, runs `prisma migrate deploy` at the
new image, waits for completion, then applies the kustomize bundle with the
tag patched in and watches the rollout.

> **First deploy / no migrations checked in?** Open
> `deploy/k8s/app/migrate-job.yaml` and switch the command to
> `npx prisma db push --accept-data-loss` for the first run, then add a
> baseline migration with `prisma migrate dev --name init` locally and
> commit it.

## Scheduled jobs (cron) + visualization

The in-cluster CronJobs in `deploy/k8s/cron/` mirror the existing
`.github/workflows/cron.yml` schedule but run on the Pi cluster — they hit
the **internal** Service URL instead of `trialday.app`, so no public
traffic and no GitHub-Actions minutes per run.

| Job                 | Schedule (UTC)      | Endpoint                          |
| ------------------- | ------------------- | --------------------------------- |
| `abandoned-sims`    | `0 13 * * *` daily  | `/api/cron/abandoned-sims`        |
| `recruiter-digest`  | `0 14 * * 1` weekly | `/api/cron/recruiter-digest`      |
| `trial-reminders`   | `0 15 * * *` daily  | `/api/cron/trial-reminders`       |

Every run pushes four gauges to the in-cluster **Pushgateway**:

- `trialday_cron_last_success` — 1 if HTTP 2xx, else 0
- `trialday_cron_last_duration_seconds` — wall-clock run time
- `trialday_cron_last_http_status` — raw HTTP code (helps distinguish 5xx vs auth failures)
- `trialday_cron_last_run_timestamp_seconds` — UNIX time of the run

Prometheus scrapes Pushgateway (`honor_labels: true`, so the `instance`
label on each metric stays as the cron name) and Grafana auto-provisions
the **Trialday Cron** dashboard from `deploy/k8s/observability/dashboards/`:

- per-job status tiles (green/red on last run)
- time since last run (auto-yellow > 25h, red > 48h)
- last duration, with sparkline
- duration history (stepped line)
- HTTP status history
- 7-day success rate gauge with thresholds

### Install the observability stack

Do this **once**, after the app is up:

```sh
GRAFANA_ADMIN_PASSWORD=$(openssl rand -hex 24) \
  ./deploy/scripts/observability-bootstrap.sh
# Save the password somewhere safe — you'll log in with admin/<it>.
```

The script creates the `grafana-admin` Secret, applies the kustomize
bundle, and waits for all three Deployments to be ready.

Then point `grafana.trialday.app` at the cluster's public IP (same as
`trialday.app`) and add a TLS block to `deploy/k8s/observability/grafana.yaml`
if you've installed cert-manager.

### Manually trigger a cron

```sh
# Create a one-shot Job from the CronJob template (k8s built-in shortcut)
kubectl -n trialday create job manual-abandoned-sims-$(date +%s) \
  --from=cronjob/cron-abandoned-sims
```

The runner pushes metrics under the same `instance` label, so manual
triggers show up on the dashboard alongside scheduled runs.

### Retiring the GitHub Actions cron

Once you've verified the k8s CronJobs run cleanly (give it a couple of
days), delete `.github/workflows/cron.yml` so you're not running both
schedules at once. Until then, the in-cluster version is harmless overlap:
the endpoints are idempotent and `Forbid` concurrencyPolicy prevents
overlap inside the cluster.

## Common operations

```sh
# Tail logs
kubectl -n trialday logs -l app=trialday -f --max-log-requests=10

# psql shell
kubectl -n trialday exec -it postgres-0 -- psql -U trialday -d trialday

# Scale replicas (e.g. while one Pi is being rebooted)
kubectl -n trialday scale deploy/trialday --replicas=1

# Rotate the GHCR pull secret after the PAT changes
GHCR_USERNAME=byvictorrr GHCR_TOKEN=ghp_... ./deploy/scripts/ghcr-login.sh
```

## Resource sizing notes

Defaults assume Pi 5 (4 GB+) nodes. Tighten if you're on Pi 4 / 2 GB models
— in particular drop the app container's memory limit to `512Mi` and run a
single replica.
