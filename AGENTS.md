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
├── docs/                   # Project docs
├── graphify-out/           # Local knowledge graph (gitignored)
└── ui/                     # UI components (main UI in opencost/opencost-ui)
```

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

## Plan B — Deploy to a GCP project (Cloud Run first)

Target: cloud-cost-only OpenCost on **Cloud Run**.

### B1. Project bootstrap

```bash
export PROJECT_ID="<your-gcp-project>"
export REGION="us-central1"
export REPO="opencost"
export SERVICE="opencost-cloudcost"
export SA_EMAIL="opencost-bq-reader@${PROJECT_ID}.iam.gserviceaccount.com"

gcloud config set project "${PROJECT_ID}"
gcloud services enable \
  run.googleapis.com \
  artifactregistry.googleapis.com \
  secretmanager.googleapis.com \
  bigquery.googleapis.com \
  iam.googleapis.com
```

Complete **Plan A** (export + SA IAM) in this project (or grant the SA access to the export project).

### B2. Store integration config in Secret Manager

```bash
# Create secret from local file (contains no private key if using Workload Identity authorizer)
gcloud secrets create opencost-cloud-integration \
  --data-file=./cloud-integration.json \
  --replication-policy=automatic

# Allow the Cloud Run runtime SA to read it
gcloud secrets add-iam-policy-binding opencost-cloud-integration \
  --member="serviceAccount:${SA_EMAIL}" \
  --role="roles/secretmanager.secretAccessor"
```

### B3. Container image

Option 1 — upstream image:

```bash
# Pull/retag into Artifact Registry if desired
gcloud artifacts repositories create "${REPO}" \
  --repository-format=docker --location="${REGION}" || true

docker pull ghcr.io/opencost/opencost:latest
docker tag ghcr.io/opencost/opencost:latest \
  "${REGION}-docker.pkg.dev/${PROJECT_ID}/${REPO}/opencost:latest"
docker push "${REGION}-docker.pkg.dev/${PROJECT_ID}/${REPO}/opencost:latest"
```

Option 2 — build from this repo (when you need fork changes):

```bash
just build-local   # or docker build via project Dockerfiles
# push resulting image to Artifact Registry
```

### B4. Deploy Cloud Run

Mount the secret as a file at `/var/configs/cloud-integration.json` and do **not** set `KUBERNETES_PORT`.

```bash
gcloud run deploy "${SERVICE}" \
  --image="${REGION}-docker.pkg.dev/${PROJECT_ID}/${REPO}/opencost:latest" \
  --region="${REGION}" \
  --service-account="${SA_EMAIL}" \
  --port=9003 \
  --cpu=1 --memory=1Gi \
  --min-instances=0 --max-instances=2 \
  --no-allow-unauthenticated \
  --set-env-vars="CLOUD_COST_ENABLED=true,CONFIG_PATH=/var/configs,API_PORT=9003" \
  --set-secrets="/var/configs/cloud-integration.json=opencost-cloud-integration:latest"
```

Set `ADMIN_TOKEN` via Secret Manager / env when you need rebuild endpoints:

```bash
gcloud run services update "${SERVICE}" --region="${REGION}" \
  --set-secrets="ADMIN_TOKEN=opencost-admin-token:latest"
```

### B5. Invoke securely

```bash
export OPENCOST_URL="$(gcloud run services describe "${SERVICE}" \
  --region="${REGION}" --format='value(status.url)')"

# Caller identity needs roles/run.invoker on the service
curl -sS -H "Authorization: Bearer $(gcloud auth print-identity-token)" \
  "${OPENCOST_URL}/cloudCost/status" | jq .
```

### B6. Smoke test checklist

- [ ] Cloud Run revision healthy
- [ ] `/cloudCost/status` shows GCP integration connected
- [ ] `/cloudCost?window=7d&aggregate=service` returns rows
- [ ] Logs show BigQuery queries succeeding (no 403/404 on table)
- [ ] Secret is not baked into the image; SA has least privilege

### B7. Optional later: GKE Helm

Not the primary path. If needed later: Helm chart + `opencost.cloudCost.enabled=true` + `cloudIntegrationSecret`, with Workload Identity bound to the same BQ reader SA. Prefer Cloud Run until Kubernetes allocation is in scope.

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

- [OpenCost GCP configuration](https://www.opencost.io/docs/configuration/gcp/)
- [OpenCost Docker / Kubernetesless cloud costs](https://www.opencost.io/docs/installation/docker/)
- [OpenCost Cloud Cost API](https://www.opencost.io/docs/integrations/api/)
- [Helm Chart](https://github.com/opencost/opencost-helm-chart) (optional GKE path)
- [OpenCost Specification](spec/opencost-specv01.md)
- [CNCF Slack #opencost](https://cloud-native.slack.com/archives/C03D56FPD4G)
