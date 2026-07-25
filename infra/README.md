# OpenCost Cloud Cost — GCP infra (`demogcp-terra2021`)

**Project:** `demogcp-terra2021` (deploy **and** BigQuery billing export)  
**Tooling:** OpenTofu + scripts under `scripts/`  
**Baseline:** [`../docs/architecture-compliance.md`](../docs/architecture-compliance.md)

## Identities

| SA | Key? | Role |
|----|------|------|
| `opencost-deployer@demogcp-terra2021.iam.gserviceaccount.com` | Yes — base64 in Cloud Agent secret `GCP_SA_KEY_B64` | tofu / deploy.sh |
| `opencost-cloudcost@demogcp-terra2021.iam.gserviceaccount.com` | **No** (WI/ADC on Cloud Run) | Read BQ billing export |

## BigQuery billing export (Plan A)

| Field | Value |
|-------|--------|
| Dataset | `export_billing_demogcp_detailed` (location `US`) |
| Table | `gcp_billing_export_resource_v1_01E5F4_66804E_8286B7` |
| Fully qualified | `demogcp-terra2021.export_billing_demogcp_detailed.gcp_billing_export_resource_v1_01E5F4_66804E_8286B7` |

Config file: `examples/cloud-integration.demogcp-terra2021.json`.

OpenTofu remote state prefix must be **`tofu/opencost`** (see `backend.hcl.example`) — do not share `tofu/state` with other stacks.

## One-time on an admin machine

```bash
# 1) Create deployer SA + print base64 for Cursor secret GCP_SA_KEY_B64
./scripts/create-deployer-sa.sh

# 2) Create tofu state bucket
./scripts/bootstrap-state-bucket.sh

# 3) Confirm billing export table export_billing_demogcp_detailed.gcp_billing_export_resource_v1_01E5F4_66804E_8286B7
```

Add Cloud Agent secret:

- **Name:** `GCP_SA_KEY_B64`
- **Value:** single-line base64 from `create-deployer-sa.sh` output

## On the Cloud Agent (no interactive ADC)

```bash
cp terraform.tfvars.example terraform.tfvars
# set invoker_members, then:

./scripts/auth-from-secret.sh          # decodes GCP_SA_KEY_B64 → ADC file
cp backend.hcl.example backend.hcl     # prefix must be tofu/opencost
tofu init -backend-config=backend.hcl

# Apply creates secret shells and seed-if-empty versions (example JSON +
# bootstrap admin placeholder) so Cloud Run can mount version=latest.
tofu apply

# Day-2 / real credentials + images (git sha tags). Tofu ignores image drift.
export ADMIN_TOKEN_FILE=/secure/admin_token.txt   # recommended
./scripts/deploy.sh all
```

`examples/cloud-integration.demogcp-terra2021.json` already points at the demogcp detailed export table (Workload Identity). Re-run `sync-secrets` after edits.

## Scripts

| Script | Purpose |
|--------|---------|
| `env.sh` | Shared defaults (`PROJECT_ID=demogcp-terra2021`) |
| `create-deployer-sa.sh` | Create deployer SA + roles + base64 for agent secret |
| `auth-from-secret.sh` | Decode `GCP_SA_KEY_B64` → `GOOGLE_APPLICATION_CREDENTIALS` |
| `bootstrap-state-bucket.sh` | `gs://demogcp-terra2021-tofu-state` + versioning |
| `deploy.sh` | push API/`ui-finops` images, sync secrets, update Cloud Run; `rebuild-cloudcost` after API restarts |

## FinOps SPA (Option B — sidecar)

Cloud Run runs **two containers** in one service:

| Container | Port | Role |
|-----------|------|------|
| `opencost-ui` | **9090** (ingress) | FinOps SPA + nginx proxy `/model` → API |
| `opencost` | 9003 (localhost only) | Cloud Cost API → BigQuery |

The ingress image is built from [`../ui-finops`](../ui-finops) by `./scripts/deploy.sh push-image` and needs no Cloud Run UI env. Its nginx config serves the SPA at `/`, exposes `/healthz`, and proxies `/model/*` to the OpenCost API sidecar.

| Route | Purpose |
|-------|---------|
| `/` | GCP FinOps Inform home |
| `/model/cloudCost/status` | Smoke status endpoint via UI proxy |
| `/model/cloudCost*` | Cloud Cost API proxied to the sidecar |

Smoke after `deploy.sh deploy-revision`:

```bash
BASE=https://opencost-cloudcost-lhcstnm7cq-uc.a.run.app
curl -sS -o /dev/null -w '%{http_code}\n' "$BASE/"
curl -sS "$BASE/model/cloudCost/status" | jq '.data[0].connectionStatus'
curl -sS -G "$BASE/model/cloudCost" -d window=7d -d aggregate=category | jq '.data.sets | length'
```

### Avoid empty dashboards after deploy

The OpenCost cloud-cost store is **in-memory**. Any new Cloud Run revision
restarts **both** containers (even `DEPLOY_TARGET=ui`), so spend disappears
until the next refresh (~6h) or an admin rebuild.

```bash
# Prefer SPA-only image builds (faster); revision still restarts the API.
DEPLOY_TARGET=ui ./scripts/deploy.sh push-image
DEPLOY_TARGET=ui ./scripts/deploy.sh deploy-revision
# deploy-revision rebuilds cloud-cost automatically (REBUILD_AFTER_API_DEPLOY=true).

# Manual recovery if the dashboard is empty:
./scripts/deploy.sh rebuild-cloudcost
```

## Intentionally omitted (v1)

`cloud_sql.tf`, `redis_vm.tf`, `cloud_scheduler.tf`, `gcs.tf` (app data) — not required for cloud-cost-only.
