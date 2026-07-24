# Next Cloud Agent Run — Handoff

Secrets are injected **only at environment start**. This run had `GEMINI_API_KEY` only. After you add `GCP_SA_KEY_B64`, **start a new agent** — do not expect this session to see the new secret.

## Status (2026-07-24 deploy run)

Deployed Cloud Run cloud-cost API on `demogcp-terra2021`:

| Item | Value |
|------|--------|
| Service URL | `https://opencost-cloudcost-lhcstnm7cq-uc.a.run.app` |
| UI | `https://opencost-cloudcost-lhcstnm7cq-uc.a.run.app/cloud` |
| Images | `…/opencost:<sha>` + `…/opencost-ui:<sha>` (multi-container) |
| Runtime SA | `opencost-cloudcost@demogcp-terra2021.iam.gserviceaccount.com` |
| BQ dataset | `export_billing_demogcp_detailed` (US) |
| Table | `gcp_billing_export_resource_v1_01E5F4_66804E_8286B7` |
| Billing account (invoice) | `01E5F4-66804E-8286B7` |
| Tofu state | `gs://demogcp-terra2021-tofu-state` prefix **`tofu/opencost`** (isolated; do **not** use `tofu/state`) |
| Invokers | **`allUsers` (public URL)**, `user:farry@terralogiq.com`, deployer SA |

`/cloudCost/status` → `Connection Successful` with coverage over the billing export table.

### Note on shared state

An earlier apply briefly used prefix `tofu/state` (maps-agent stack). Foreign resources were removed from OpenCost state; `maps-agent-runtime` SA + bindings were restored. Always use prefix `tofu/opencost`.

## Prerequisites (human, before new run)

1. On an admin machine with `gcloud`, create deployer SA + state bucket (safe script: no giant IAM dumps / no base64 printed to terminal). Prefer [`infra/scripts/create-deployer-sa.sh`](../infra/scripts/create-deployer-sa.sh) from a clone, **or** paste the crash-safe block from the PR / chat. *(Done for demogcp-terra2021.)*
2. Add Cursor Cloud Agent / environment secret:
   - **Name:** `GCP_SA_KEY_B64`
   - **Value:** single-line base64 of `opencost-deployer@demogcp-terra2021.iam.gserviceaccount.com` JSON key (copy from file, do not `cat` huge lines into a flaky terminal)
3. BQ export path (confirmed): `demogcp-terra2021.export_billing_demogcp_detailed.gcp_billing_export_resource_v1_01E5F4_66804E_8286B7`
4. Start a **new** Cloud Agent on branch `cursor/agents-gcp-cloudcost-9250` (or `develop` after merge) with that secret attached.

## First message to give the new agent

```text
Continue OpenCost Cloud Run deploy for demogcp-terra2021.

1. Verify secret: test -n "$GCP_SA_KEY_B64" && echo ok
2. ./infra/scripts/auth-from-secret.sh
3. cloud-integration: dataset=export_billing_demogcp_detailed table=gcp_billing_export_resource_v1_01E5F4_66804E_8286B7
4. cp infra/terraform.tfvars.example infra/terraform.tfvars  (invokers include farry@terralogiq.com)
5. cp infra/backend.hcl.example infra/backend.hcl  (prefix must be tofu/opencost)
6. Install gcloud/tofu/docker if missing; then: cd infra && tofu init -backend-config=backend.hcl && tofu apply
7. Create ADMIN_TOKEN file and: ./infra/scripts/deploy.sh all
8. Smoke test /cloudCost/status — expect Connection Successful

Project is same for deploy + BQ: demogcp-terra2021.
Follow AGENTS.md Plan A/B and docs/architecture-compliance.md. Do not commit secrets or terraform.tfvars.
```

## Verify secrets on new run

```bash
echo "ALL=$CLOUD_AGENT_ALL_SECRET_NAMES"
echo "INJECTED=$CLOUD_AGENT_INJECTED_SECRET_NAMES"
test -n "${GCP_SA_KEY_B64:-}" && echo "GCP_SA_KEY_B64 ok len=${#GCP_SA_KEY_B64}" || echo "GCP_SA_KEY_B64 MISSING — restart agent after adding secret"
./infra/scripts/auth-from-secret.sh
./infra/scripts/deploy.sh print-env
```

## Expected identities

| SA | Secret/key | Purpose |
|----|------------|---------|
| `opencost-deployer@demogcp-terra2021.iam.gserviceaccount.com` | `GCP_SA_KEY_B64` on agent | tofu + deploy.sh |
| `opencost-cloudcost@demogcp-terra2021.iam.gserviceaccount.com` | none (WI) | Cloud Run → BigQuery |

## Branch / PR

- Branch: `cursor/agents-gcp-cloudcost-9250`
- PR: https://github.com/fargoebie/finops/pull/3
- Key paths: `infra/`, `AGENTS.md`, `docs/architecture-compliance.md`
