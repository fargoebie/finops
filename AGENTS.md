# AGENTS.md - OpenCost AI Agent Guide

This document provides guidance for AI assistants working with this OpenCost-based repository.

## AI Assistant Behaviour

- Never include AI assistant session links or URLs (e.g. claude.ai) in commit messages or pull request bodies.
- Prefer graphify (`graphify query` / `path` / `explain`) when `graphify-out/` exists before broad Grep/Read exploration.
- For this fork, default to **cloud-cost-first** work (GCP BigQuery billing + Cloud Run). Do not expand into Kubernetes allocation/Prometheus unless the user asks.

## Fork Objective (Primary)

This fork’s primary goal is to run OpenCost as a **GCP Cloud Cost API**:

1. Ingest **actual GCP invoice data** from BigQuery billing export
2. Expose it via `/cloudCost*` (and optional UI/MCP later)
3. Deploy the service on **Cloud Run** (no Kubernetes required)

Kubernetes cost allocation (`/allocation`, `/assets`, Prometheus) is **out of primary scope**. Keep upstream OpenCost conventions, but treat allocation paths as optional.

### Agent priorities

When implementing or debugging, prefer these code areas first:

1. `pkg/cloud/gcp/` — BigQuery integration, authorizers
2. `pkg/cloudcost/` — ingestion pipeline, querier, status
3. `pkg/cloud/config/` — `cloud-integration.json` watchers
4. `pkg/cmd/costmodel/` — cloud-cost-only startup path
5. `pkg/env/cloudcost.go` — cloud cost env vars

## Project Overview

OpenCost is a CNCF Kubernetes cost monitoring tool. Upstream supports:

- Real-time cost allocation by namespace, pod, controller, service, etc.
- Multi-cloud cost monitoring (AWS, Azure, GCP, …)
- Dynamic on-demand pricing via cloud provider APIs
- MCP server and Prometheus metrics export

**This fork focuses on:** GCP Cloud Costs via BigQuery export, deployed on Cloud Run.

## Repository Structure

```
opencost/
├── cmd/costmodel/          # Main entry point (main.go)
├── core/                   # Core module (shared libraries)
├── modules/
│   ├── collector-source/   # Metrics collector (allocation; secondary here)
│   └── prometheus-source/  # Prometheus source (allocation; secondary here)
├── pkg/
│   ├── cloud/
│   │   └── gcp/            # PRIMARY: BigQuery billing + authorizers
│   ├── cloudcost/          # PRIMARY: cloud cost pipeline
│   ├── cloud/config/       # cloud-integration.json loading
│   ├── cmd/costmodel/      # Process wiring (k8s optional, cloud cost optional)
│   ├── costmodel/          # API handlers / InitializeCloudCost
│   ├── env/                # Environment variable definitions
│   └── mcp/                # MCP server (optional; currently needs k8s path)
├── configs/                # Default pricing configurations
├── docs/                   # Project docs (includes architecture-compliance.md)
├── infra/                  # OpenTofu IaC for GCP Cloud Run (cloud-cost-only)
├── graphify-out/           # Local knowledge graph (gitignored)
└── ui/                     # UI components (main UI in opencost/opencost-ui)
```

**Compliance baseline:** [`docs/architecture-compliance.md`](docs/architecture-compliance.md) — project-agnostic GCP architecture principles. All deploy work must satisfy those principles (see **Architecture Compliance Review** below).

## Architecture (Cloud-Cost Path)

```
GCP Billing Account
        │
        ▼
BigQuery resource/detailed export table
        │
        ▼
OpenCost cloudcost pipeline  (CLOUD_COST_ENABLED=true)
  pkg/cloud/gcp/bigquery*.go
  pkg/cloudcost/*
        │
        ▼
In-memory CloudCost repository
        │
        ▼
HTTP API :9003  →  GET /cloudCost, /cloudCost/status, …
        │
        ▼
Cloud Run service (this fork’s deploy target)
```

**Important:** Kubernetes is enabled only when `KUBERNETES_PORT` is set (injected automatically in pods). On Cloud Run / local Docker without that env, OpenCost stays Kubernetes-off and can run cloud-cost-only.

Allocation pricing (`CLOUD_PROVIDER_API_KEY` / Billing Catalog) is a **separate** system from Cloud Costs. An API key alone does **not** populate `/cloudCost`.

---

## Plan A — Connect GCP BigQuery billing

Use this checklist when wiring billing accounts.

### A1. Enable billing export

1. Choose a GCP project to host the export dataset (billing must be enabled).
2. Create a BigQuery dataset (note location: `US`, `EU`, `us-central1`, …).
3. In **Billing → Billing export**, enable **detailed / resource-level** export into that dataset.
4. Confirm the table exists and has rows, e.g.  
   `gcp_billing_export_resource_v1_<BILLING_ACCOUNT_ID>`  
   Export lag is normal; empty tables look like OpenCost failures.

### A2. Create a reader service account

On the project that owns the dataset:

```bash
export PROJECT_ID="$(gcloud config get-value project)"
export SA_NAME="opencost-bq-reader"
export SA_EMAIL="${SA_NAME}@${PROJECT_ID}.iam.gserviceaccount.com"

gcloud iam service-accounts create "${SA_NAME}" \
  --display-name="OpenCost BigQuery reader"

for ROLE in roles/bigquery.dataViewer roles/bigquery.jobUser roles/bigquery.user; do
  gcloud projects add-iam-policy-binding "${PROJECT_ID}" \
    --member="serviceAccount:${SA_EMAIL}" \
    --role="${ROLE}"
done
```

**Cloud Run preferred auth:** run the Cloud Run service as this SA and use `"authorizerType": "GCPWorkloadIdentity"` (Application Default Credentials). Avoid shipping JSON keys when possible.

**Local/dev fallback:** create a key and embed it as `GCPServiceAccountKey` (never commit the key).

### A3. Author `cloud-integration.json`

Path resolution (code): `$CONFIG_PATH/cloud-integration.json`  
(`CONFIG_PATH` defaults to `/var/configs`). Fallbacks also check:

- `/var/cloud-integration/cloud-integration.json`
- `/var/configs/cloud-integration/cloud-integration.json`

Example (Cloud Run / ADC):

```json
{
  "gcp": {
    "bigQuery": [
      {
        "projectID": "<PROJECT_WITH_DATASET>",
        "dataset": "<DATASET>",
        "table": "gcp_billing_export_resource_v1_XXXXXX_XXXXXX_XXXXXX",
        "location": "US",
        "queryProjectID": "",
        "excludePartitionTime": false,
        "authorizer": {
          "authorizerType": "GCPWorkloadIdentity"
        }
      }
    ]
  }
}
```

Key-based local example (do not commit secrets):

```json
{
  "gcp": {
    "bigQuery": [
      {
        "projectID": "<PROJECT_WITH_DATASET>",
        "dataset": "<DATASET>",
        "table": "gcp_billing_export_resource_v1_XXXXXX_XXXXXX_XXXXXX",
        "location": "US",
        "authorizer": {
          "authorizerType": "GCPServiceAccountKey",
          "key": {
            "type": "service_account",
            "project_id": "<PROJECT_ID>",
            "private_key_id": "...",
            "private_key": "-----BEGIN PRIVATE KEY-----\n...\n-----END PRIVATE KEY-----\n",
            "client_email": "opencost-bq-reader@<PROJECT_ID>.iam.gserviceaccount.com",
            "client_id": "...",
            "auth_uri": "https://accounts.google.com/o/oauth2/auth",
            "token_uri": "https://oauth2.googleapis.com/token"
          }
        }
      }
    ]
  }
}
```

Optional fields:

| Field | Purpose |
|-------|---------|
| `location` | BigQuery job location |
| `queryProjectID` | Project used for BQ jobs (defaults to `projectID`) |
| `excludePartitionTime` | Set `true` if `_PARTITIONTIME` filters fail |

### A4. Required runtime env (cloud-cost-only)

| Variable | Value | Notes |
|----------|-------|-------|
| `CLOUD_COST_ENABLED` | `true` | Master switch (default `false`) |
| `CONFIG_PATH` | e.g. `/var/configs` | Directory containing `cloud-integration.json` |
| `API_PORT` | `9003` | HTTP API |
| `ADMIN_TOKEN` | secret string | Needed for rebuild/config admin endpoints |

Useful tuning:

| Variable | Default | Role |
|----------|---------|------|
| `CLOUD_COST_REFRESH_RATE_HOURS` | `6` | Ingest cadence |
| `CLOUD_COST_RUN_WINDOW_DAYS` | `3` | Standard lookback |
| `CLOUD_COST_QUERY_WINDOW_DAYS` | `7` | Max days per BQ query chunk |
| `CLOUD_COST_MONTH_TO_DATE_INTERVAL` | `6` | MTD rebuild frequency |

### A5. Verify connectivity

```bash
# Status / coverage
curl -sS "$OPENCOST_URL/cloudCost/status" | jq .

# Sample query
curl -sS -G "$OPENCOST_URL/cloudCost" \
  -d window=7d -d aggregate=provider,service | jq .

# Admin rebuild (requires ADMIN_TOKEN)
curl -sS -H "Authorization: Bearer $ADMIN_TOKEN" \
  "$OPENCOST_URL/cloudCost/rebuild?commit=true" | jq .
```

### A6. Common pitfalls

1. Using standard usage export instead of **resource/detailed** export
2. Forgetting `CLOUD_COST_ENABLED=true`
3. Missing `bigquery.jobUser` (can read metadata but cannot run queries)
4. Wrong `location` vs dataset region
5. Expecting allocation pricing API key to populate Cloud Costs
6. Assuming Cloud Costs persist across restarts (in-memory repo; rebuild from BQ after redeploy)

---

## Plan B — Deploy to a GCP project (Cloud Run first, compliance-aligned)

Target: cloud-cost-only OpenCost on **Cloud Run**, implemented with **OpenTofu** under `infra/` per [`docs/architecture-compliance.md`](docs/architecture-compliance.md).

**Active project (deploy + BQ same):** `demogcp-terra2021`  
Scripts default there via [`infra/scripts/env.sh`](infra/scripts/env.sh). Cloud Agent deploy auth: secret `GCP_SA_KEY_B64` (base64 of `opencost-deployer` JSON) → [`infra/scripts/auth-from-secret.sh`](infra/scripts/auth-from-secret.sh).

**New Cloud Agent runs:** secrets do **not** reload mid-session. After adding `GCP_SA_KEY_B64`, start a new run and follow [`docs/NEXT_AGENT_RUN.md`](docs/NEXT_AGENT_RUN.md).

> **Do not treat ad-hoc `gcloud` as the production path.** Use the commands below only for bootstrap / emergency debugging. Steady-state deploy is `infra/scripts/deploy.sh` after `tofu apply`.

### B0. Compliance constraints (non-negotiable)

| Principle | Required for this fork |
|-----------|------------------------|
| **A** Dedicated least-privilege SA | Runtime SA `opencost-cloudcost@…` only; never default Compute SA |
| **B** Secrets by reference | `cloud-integration.json` + `ADMIN_TOKEN` in Secret Manager; mount/inject by ref |
| **C** Network isolation | Custom VPC + subnet; Cloud Run Direct VPC egress (or connector); Private Google Access for BQ APIs |
| **D** IAP admin | N/A unless VMs are introduced; no public SSH |
| **E** App-layer auth on public surface | Cloud Run `--no-allow-unauthenticated`; grant `roles/run.invoker` per caller; `ADMIN_TOKEN` for admin APIs |
| **F** Durability | BQ export is system of record; define BQ dataset retention; OpenCost memory cache is ephemeral |
| **G** IaC + private registry | OpenTofu remote state; images only from project Artifact Registry |
| **H** Observability | Runtime SA gets `roles/cloudtrace.agent` + `roles/monitoring.metricWriter` |
| **I** Layout | Flat `infra/*.tf` as specified in the baseline |

### B1. Bootstrap (out-of-band, once)

```bash
export PROJECT_ID="<your-gcp-project>"
export REGION="us-central1"
export STATE_BUCKET="${PROJECT_ID}-tofu-state"

gcloud config set project "${PROJECT_ID}"

# Remote OpenTofu state bucket (versioned) — create before first tofu init
gcloud storage buckets create "gs://${STATE_BUCKET}" --location="${REGION}" --uniform-bucket-level-access
gcloud storage buckets update "gs://${STATE_BUCKET}" --versioning
```

Complete **Plan A** (resource/detailed billing export + BQ reader roles for the runtime SA). Prefer **ADC / Workload Identity authorizer** in `cloud-integration.json` (no JSON keys).

### B2. `infra/` layout (scaffolded)

Implemented under [`infra/`](infra/) (see [`infra/README.md`](infra/README.md)):

```
infra/
├── provider.tf / variables.tf / outputs.tf / locals.tf / apis.tf
├── iam.tf / secret_manager.tf / vpc.tf
├── artifact_registry.tf / cloud_run.tf / monitoring_dashboard.tf
├── scripts/deploy.sh
├── terraform.tfvars.example / backend.hcl.example
├── .terraform.lock.hcl / .gitignore / README.md
```

Omitted on purpose for v1 (N/A): `cloud_sql.tf`, `redis_vm.tf`, `cloud_scheduler.tf`, `gcs.tf`.

Pin tooling as in the baseline (`tofu` ≥ 1.11.5, `hashicorp/google` ≥ 7.26.0).

### B3. Identity & secrets (principle A/B)

- **One SA per workload:** `opencost-cloudcost@${PROJECT_ID}.iam.gserviceaccount.com`
- **Grants (minimum):**
  - Project (or dataset-scoped where possible): `roles/bigquery.dataViewer`, `roles/bigquery.jobUser`, `roles/bigquery.user` for billing export access
  - Per-secret: `roles/secretmanager.secretAccessor` on `opencost-cloud-integration` and `opencost-admin-token` only
  - Observability: `roles/cloudtrace.agent`, `roles/monitoring.metricWriter`
- **Never** attach `roles/owner`, `roles/editor`, or the default Compute Engine SA to Cloud Run
- **Human access:** grant `roles/run.invoker` / `roles/run.developer` to individual user emails, not shared keys
- **Secrets:** write values with deploy script / `gcloud secrets versions add`; never commit keys; never put secret literals in Cloud Run env YAML or `.tfvars`

`cloud-integration.json` for Cloud Run should use:

```json
"authorizer": { "authorizerType": "GCPWorkloadIdentity" }
```

so the runtime SA identity is used (no private key in the secret).

### B4. Network (principle C)

Even though OpenCost talks to managed BigQuery (not a self-hosted DB):

1. Create a **custom VPC + subnet** (no default network).
2. Enable **Private Google Access** on the subnet.
3. Attach Cloud Run with **Direct VPC egress** (preferred) or a Serverless VPC Access connector.
4. Egress mode: private ranges + Google APIs via PGA/NAT as required; avoid giving the revision a needless public data-plane.
5. Firewall: default deny; only open what is required (typically none inbound to VPC for this API-only service).

Data-store public-IP rules in the baseline are **N/A** (no Cloud SQL/Redis in v1). If those are added later, they must be private-IP + PSA.

### B5. Image & deploy (principle G)

1. Build for a pinned platform (`linux/amd64`) and tag immutably (`git sha` / semver) — avoid floating `latest` in prod.
2. Push **only** to project Artifact Registry:  
   `${REGION}-docker.pkg.dev/${PROJECT_ID}/opencost/opencost:<tag>`
3. Cloud Run pulls from that private repo (AR reader on the runtime or Cloud Run agent SA as required).
4. Orchestrate via `infra/scripts/deploy.sh`: build → push → update Cloud Run revision (or `tofu apply` for infra-owned service template).

### B6. Cloud Run service shape (principle E/H)

Declarative equivalent of:

- Image from private AR (pinned tag)
- Service account = `opencost-cloudcost@…`
- Port `9003`
- Env (non-secret): `CLOUD_COST_ENABLED=true`, `CONFIG_PATH=/var/configs`, `API_PORT=9003`
- **No** `KUBERNETES_PORT`
- Secrets by reference:
  - volume/file: `/var/configs/cloud-integration.json` ← `opencost-cloud-integration`
  - env: `ADMIN_TOKEN` ← `opencost-admin-token`
- Ingress: internal + load balancer **or** all with **IAM auth required** (`invoker` IAM). Prefer not publicly invokable without identity.
- VPC egress attached (B4)
- CPU/memory sized for BQ ingest; min instances as needed for cold-start tolerance

### B7. Auth model for callers (principle E)

OpenCost OSS does not ship OAuth/session cookies. For this API-only deploy:

1. **Transport / identity:** Cloud Run IAM (`roles/run.invoker`) for every caller (user or SA).
2. **Admin APIs:** `ADMIN_TOKEN` bearer (secret-injected).
3. If a public UI is added later: put it behind IAP or OAuth with explicit domain allowlists; do not expose `/cloudCost` anonymously.

```bash
# Example authenticated probe (after IAM invoker grant)
export OPENCOST_URL="https://opencost-cloudcost-....a.run.app"
curl -sS -H "Authorization: Bearer $(gcloud auth print-identity-token)" \
  "${OPENCOST_URL}/cloudCost/status" | jq .
```

### B8. Data lifecycle (principle F)

| Store | Policy |
|-------|--------|
| BigQuery billing export | System of record; set dataset/table retention to match finance policy |
| OpenCost in-memory repo | Ephemeral cache (~`CLOUD_COST_*` retention envs); rebuild after redeploy |
| Secret versions | Enable secret versioning; disable old versions after rotation |
| Tofu state bucket | Versioning on; uniform bucket-level access; no force-destroy |

### B9. Smoke test checklist

- [ ] `tofu plan` clean; state in versioned GCS bucket
- [ ] Cloud Run revision healthy; image digest from **private AR**
- [ ] Runtime SA is dedicated (not default compute); IAM bindings match B3
- [ ] Secrets mounted by reference; no secret literals in service YAML / tfvars
- [ ] Unauthenticated `curl` to service URL fails; identity-token call succeeds
- [ ] `/cloudCost/status` connected; `/cloudCost?window=7d&aggregate=service` returns rows
- [ ] Trace/metric roles present; basic dashboard or log-based alert exists
- [ ] No JSON service-account key in `cloud-integration` secret (WI/ADC authorizer)

### B10. Optional later: GKE Helm

Not the primary path. If added, reuse the same dedicated SA via Workload Identity, same secrets pattern, and same VPC principles. Prefer Cloud Run until Kubernetes allocation is in scope.

---

## Architecture Compliance Review

Reviewed against [`docs/architecture-compliance.md`](docs/architecture-compliance.md) for the **cloud-cost-only Cloud Run** design (Plans A/B).

### Non-negotiables

| ID | Principle | Status for documented target | Notes / required action |
|----|-----------|------------------------------|-------------------------|
| **A** | Dedicated least-privilege SAs | **Required / designed** | One runtime SA; no default Compute SA; BQ + per-secret + observability roles only |
| **B** | Managed secrets by reference | **Required / designed** | Secret Manager for integration JSON + `ADMIN_TOKEN`; WI authorizer (no key material) |
| **C** | No public IP on data stores | **N/A (v1)** | No Cloud SQL/Redis; BQ is Google-managed. Still require custom VPC + PGA + restricted Cloud Run egress |
| **D** | IAP-only admin access | **N/A (v1)** | No VMs. If a bastion/UI VM appears later, IAP + OS Login become mandatory |
| **E** | App-layer auth on public services | **Required / designed** | Cloud Run IAM invoker + `ADMIN_TOKEN` for admin routes; no anonymous `/cloudCost` |

### Other principles

| ID | Principle | Status | Gap vs previous click-ops Plan B |
|----|-----------|--------|----------------------------------|
| **F** | Data durability & lifecycle | **Partial → defined** | BQ export retention must be set in GCP; OpenCost cache is ephemeral by design |
| **G** | Declarative deploy + private registry | **Gap → required** | Previous plan allowed `gcloud`/`ghcr.io`; target is OpenTofu + project Artifact Registry only |
| **H** | Traces & metrics on runtime SA | **Gap → required** | Add `cloudtrace.agent` + `monitoring.metricWriter`; add dashboard tf |
| **I** | `infra/` OpenTofu layout | **Gap → required** | `infra/` does not exist yet; create per baseline before production deploy |

### Verdict

- **Current repo state:** `infra/` OpenTofu scaffold **exists** (APIs, IAM, secrets, VPC, AR, Cloud Run, dashboard, `scripts/deploy.sh`). Still **not production-complete** until applied to a real GCP project with seeded secrets, a pushed AR image, billing export, and invoker grants.
- **Documented target:** Cloud Run + OpenTofu + Secret Manager + private AR + dedicated SA + IAM invoker **satisfies** A/B/E/G/H/I in design; C via custom VPC + PGA + Direct VPC egress; D N/A for v1.
- **Agent rule:** Extend `infra/` rather than inventing click-ops. Do not regress to public unauthenticated Cloud Run, shared/default Compute SAs, secret literals, or GHCR-only production pulls.

### Applicable vs not applicable (this SKU)

| Baseline item | Applies? |
|---------------|----------|
| Cloud SQL / Redis private IP, backups, deletion protection | No (not in v1 architecture) |
| Schema migration job before deploy | No (no app DB) |
| Cloud Scheduler dedicated invoker SA | Optional (only if scheduled rebuild jobs are added) |
| Custom VPC, AR, Secret Manager, Cloud Run IAM, tofu state | **Yes** |

---

## Local development (cloud-cost-only)

### Prerequisites

- Go (see `go.mod`)
- Docker (optional)
- `gcloud` authenticated to a project with BQ export access
- `cloud-integration.json` (local path; never commit secrets)

### Run API locally without Kubernetes

```bash
# Ensure KUBERNETES_PORT is unset
unset KUBERNETES_PORT

export CLOUD_COST_ENABLED=true
export CONFIG_PATH="$(pwd)/.local-config"   # place cloud-integration.json here
mkdir -p "${CONFIG_PATH}"
# cp /secure/path/cloud-integration.json "${CONFIG_PATH}/"

go run ./cmd/costmodel/main.go
# API: http://127.0.0.1:9003
```

Docker equivalent:

```bash
docker run --rm -p 9003:9003 \
  -e CLOUD_COST_ENABLED=true \
  -e CONFIG_PATH=/var/configs \
  -v "$(pwd)/.local-config:/var/configs:ro" \
  ghcr.io/opencost/opencost:latest
```

### Quick commands

```bash
just test
just test-opencost
just build-local
```

## Key Environment Variables

### Cloud Cost (primary)

| Variable | Default | Description |
|----------|---------|-------------|
| `CLOUD_COST_ENABLED` | `false` | Enable cloud cost ingestion |
| `CONFIG_PATH` | `/var/configs` | Dir for `cloud-integration.json` |
| `API_PORT` | `9003` | OpenCost API port |
| `ADMIN_TOKEN` | (unset) | Bearer token for admin endpoints; unset → those endpoints return 503 |
| `CLOUD_COST_REFRESH_RATE_HOURS` | `6` | Ingest cadence |
| `CLOUD_COST_RUN_WINDOW_DAYS` | `3` | Standard lookback |
| `CLOUD_COST_QUERY_WINDOW_DAYS` | `7` | Max days per BQ query chunk |

Admin-protected endpoints:

- `GET /cloudCost/rebuild`, `GET /cloudCost/repair`
- `GET /cloud/config/export`, `GET /cloud/config/enable`, `GET /cloud/config/disable`, `GET /cloud/config/delete`
- `POST /serviceKey`, `GET /helmValues`

### Kubernetes / allocation (secondary — usually off here)

Kubernetes path activates when `KUBERNETES_PORT` is set. Allocation also typically needs `PROMETHEUS_SERVER_ENDPOINT` and optionally `CLOUD_PROVIDER_API_KEY` for GCP SKU pricing. Not required for Cloud Run cloud-cost-only.

## API Endpoints (cloud-cost focus)

| Endpoint | Description |
|----------|-------------|
| `GET /cloudCost` | Cloud cost data (`window`, `aggregate`, filters) |
| `GET /cloudCost/status` | Integration / ingest status |
| `GET /cloudCost/view` | View helper |
| `GET /metrics` | Prometheus metrics |
| `GET /allocation` | K8s allocation (only if Kubernetes path enabled) |
| `GET /assets` | K8s assets (only if Kubernetes path enabled) |

## Code Conventions

### Go Style

- Use structured logging via `github.com/opencost/opencost/core/pkg/log`
- Environment variables via `pkg/env` or `core/pkg/env`
- Wrap errors with context

**Before committing, always run:**

```bash
go fmt ./...
go vet ./...
```

### Module Structure

- `github.com/opencost/opencost` — Main module
- `github.com/opencost/opencost/core` — Core shared library
- `github.com/opencost/opencost/modules/prometheus-source` — Prometheus integration
- `github.com/opencost/opencost/modules/collector-source` — Metrics collector

### Testing

- Unit tests: `*_test.go`
- Integration tests: `INTEGRATION=true`
- Prefer mocks for BigQuery / GCP SDK in unit tests

### Logging

```go
import "github.com/opencost/opencost/core/pkg/log"

log.Infof("Processing cloud cost window: %s", window)
log.Errorf("Failed to query BigQuery: %v", err)
log.Warnf("Missing billing export rows for window")
log.Debugf("Detailed debug information")
```

## Pull Request Guidelines

1. Link related issues: `Fixes #123`, `Closes #456`
2. Describe user-facing / breaking changes
3. Include tests for new functionality
4. Run `just test` before submitting
5. Use signed commits (`Signed-off-by` required)

## Key Types

- `CloudCost` — Cloud service costs from billing export
- `Window` — Time range for queries
- `Allocation` / `Asset` — Kubernetes cost types (secondary in this fork)

## Useful Links

- [Architecture compliance baseline](docs/architecture-compliance.md) (this fork)
- [OpenCost GCP configuration](https://www.opencost.io/docs/configuration/gcp/)
- [OpenCost Docker / Kubernetesless cloud costs](https://www.opencost.io/docs/installation/docker/)
- [OpenCost Cloud Cost API](https://www.opencost.io/docs/integrations/api/)
- [Helm Chart](https://github.com/opencost/opencost-helm-chart) (optional GKE path)
- [OpenCost Specification](spec/opencost-specv01.md)
- [CNCF Slack #opencost](https://cloud-native.slack.com/archives/C03D56FPD4G)
