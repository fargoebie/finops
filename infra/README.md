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
| Dataset | `opencost_billing` (location `US`) |
| Table | `gcp_billing_export_resource_v1_016618_1D5A80_CF4367` |
| Billing account | `016618-1D5A80-CF4367` |

Enable **Detailed usage cost** export in the Cloud Billing console into that dataset (no public API). Config file: `examples/cloud-integration.demogcp-terra2021.json`.

OpenTofu remote state prefix must be **`tofu/opencost`** (see `backend.hcl.example`) — do not share `tofu/state` with other stacks.

## One-time on an admin machine

```bash
# 1) Create deployer SA + print base64 for Cursor secret GCP_SA_KEY_B64
./scripts/create-deployer-sa.sh

# 2) Create tofu state bucket
./scripts/bootstrap-state-bucket.sh

# 3) Enable billing export (resource/detailed) into opencost_billing (console)
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
| `deploy.sh` | push AR image, sync secrets, update Cloud Run |

## Intentionally omitted (v1)

`cloud_sql.tf`, `redis_vm.tf`, `cloud_scheduler.tf`, `gcs.tf` (app data) — not required for cloud-cost-only.
