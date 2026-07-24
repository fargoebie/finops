# OpenCost Cloud Cost — GCP infrastructure (OpenTofu)

Compliance-aligned IaC for **cloud-cost-only** OpenCost on **Cloud Run**.

Baseline: [`../docs/architecture-compliance.md`](../docs/architecture-compliance.md)  
Agent plan: [`../AGENTS.md`](../AGENTS.md) (Plan B)

## Intentionally omitted (v1)

Per compliance review, these baseline files are **not** present until needed:

- `cloud_sql.tf` / `redis_vm.tf` — no app database/cache
- `cloud_scheduler.tf` — add when scheduled `/cloudCost/rebuild` jobs are required
- `gcs.tf` — add if durable exports are introduced (tofu state bucket is out-of-band)

## Bootstrap

1. Create versioned state bucket: `gs://${PROJECT_ID}-tofu-state`
2. Edit `provider.tf` `backend "gcs" { bucket = "..." }` (or use partial backend config)
3. `cp terraform.tfvars.example terraform.tfvars` and fill non-secret values
4. Ensure BigQuery **resource/detailed** billing export exists (Plan A)
5. Prepare `cloud-integration.json` with `"authorizerType": "GCPWorkloadIdentity"` (no private key)
6. `tofu init && tofu apply`
7. Seed secrets + image:

```bash
export PROJECT_ID=...
export CLOUD_INTEGRATION_FILE=/secure/path/cloud-integration.json
export ADMIN_TOKEN_FILE=/secure/path/admin_token.txt
./scripts/deploy.sh all
```

## Auth model

- Cloud Run requires IAM invoker (`invoker_members` in tfvars)
- Admin routes require `ADMIN_TOKEN` from Secret Manager
- Runtime SA uses ADC for BigQuery (WI authorizer in integration JSON)
