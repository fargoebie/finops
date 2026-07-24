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
cp backend.hcl.example backend.hcl
tofu init -backend-config=backend.hcl
tofu apply

# Edit examples/cloud-integration.demogcp-terra2021.json (dataset/table)
export ADMIN_TOKEN_FILE=/secure/admin_token.txt   # optional
./scripts/deploy.sh all
```

## Scripts

| Script | Purpose |
|--------|---------|
| `env.sh` | Shared defaults (`PROJECT_ID=demogcp-terra2021`) |
| `create-deployer-sa.sh` | Create deployer SA + roles + base64 for agent secret |
| `auth-from-secret.sh` | Decode `GCP_SA_KEY_B64` → `GOOGLE_APPLICATION_CREDENTIALS` |
| `bootstrap-state-bucket.sh` | `gs://demogcp-terra2021-tofu-state` + versioning |
| `deploy.sh` | push API+UI AR images, sync secrets, update Cloud Run |

## UI (Option B — sidecar)

Cloud Run runs **two containers** in one service:

| Container | Port | Role |
|-----------|------|------|
| `opencost-ui` | **9090** (ingress) | SPA + nginx proxy `/model` → API |
| `opencost` | 9003 (localhost only) | Cloud Cost API → BigQuery |

UI env: `API_SERVER=127.0.0.1`, `API_PORT=9003`, `LEGACY_MODE=true` (required for `/cloud`).  
Public Cloud Costs page: `${cloud_run_service_uri}/cloud`  
Note: the default (non-legacy) UI has no `/cloud` route and will show a client-side 404.

## Intentionally omitted (v1)

`cloud_sql.tf`, `redis_vm.tf`, `cloud_scheduler.tf`, `gcs.tf` (app data) — not required for cloud-cost-only.
