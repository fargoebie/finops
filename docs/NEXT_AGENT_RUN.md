# Next Cloud Agent Run — Handoff

Secrets are injected **only at environment start**. This run had `GEMINI_API_KEY` only. After you add `GCP_SA_KEY_B64`, **start a new agent** — do not expect this session to see the new secret.

## Status (2026-07-24 deploy run)

Deployed Cloud Run cloud-cost API on `demogcp-terra2021`:

| Item | Value |
|------|--------|
| Service URL | `https://opencost-cloudcost-lhcstnm7cq-uc.a.run.app` |
| Image | `us-central1-docker.pkg.dev/demogcp-terra2021/opencost/opencost:97bc460a` |
| Runtime SA | `opencost-cloudcost@demogcp-terra2021.iam.gserviceaccount.com` |
| BQ dataset | `opencost_billing` (US) — **created** |
| Expected table | `gcp_billing_export_resource_v1_016618_1D5A80_CF4367` |
| Billing account | `016618-1D5A80-CF4367` |
| Tofu state | `gs://demogcp-terra2021-tofu-state` prefix **`tofu/opencost`** (isolated; do **not** use `tofu/state`) |
| Invokers | `user:farry@terralogiq.com`, deployer SA |

`/cloudCost/status` returns `connectionStatus: "Data Missing"` until the console export creates the table.

### Remaining human step (console-only — no public API)

1. Open **Billing → Billing export → BigQuery export**.
2. Enable **Detailed usage cost** for billing account `016618-1D5A80-CF4367`.
3. Project + dataset: `demogcp-terra2021` / `opencost_billing`.
4. Wait for table `gcp_billing_export_resource_v1_016618_1D5A80_CF4367` (export lag is normal).
5. Probe again:

```bash
export OPENCOST_URL="https://opencost-cloudcost-lhcstnm7cq-uc.a.run.app"
curl -sS -H "Authorization: Bearer $(gcloud auth print-identity-token)" \
  "${OPENCOST_URL}/cloudCost/status" | jq .
```

### Note on shared state

An earlier apply briefly used prefix `tofu/state` (maps-agent stack). Foreign resources were removed from OpenCost state; `maps-agent-runtime` SA + bindings were restored. Always use prefix `tofu/opencost`.

## Prerequisites (human, before new run)

1. On an admin machine with `gcloud`, create deployer SA + state bucket (safe script: no giant IAM dumps / no base64 printed to terminal). Prefer [`infra/scripts/create-deployer-sa.sh`](../infra/scripts/create-deployer-sa.sh) from a clone, **or** paste the crash-safe block from the PR / chat. *(Done for demogcp-terra2021.)*
2. Add Cursor Cloud Agent / environment secret:
   - **Name:** `GCP_SA_KEY_B64`
   - **Value:** single-line base64 of `opencost-deployer@demogcp-terra2021.iam.gserviceaccount.com` JSON key (copy from file, do not `cat` huge lines into a flaky terminal)
3. Ensure GCP **resource/detailed** BigQuery billing export exists in `demogcp-terra2021` dataset `opencost_billing` (see remaining human step above).
4. Start a **new** Cloud Agent on branch `cursor/agents-gcp-cloudcost-9250` (or `develop` after merge) with that secret attached.

## First message to give the new agent

```text
Continue OpenCost Cloud Run deploy for demogcp-terra2021.

1. Verify secret: test -n "$GCP_SA_KEY_B64" && echo ok
2. ./infra/scripts/auth-from-secret.sh
3. cloud-integration already set: dataset=opencost_billing table=gcp_billing_export_resource_v1_016618_1D5A80_CF4367
4. cp infra/terraform.tfvars.example infra/terraform.tfvars  (invokers include farry@terralogiq.com)
5. cp infra/backend.hcl.example infra/backend.hcl  (prefix must be tofu/opencost)
6. Install gcloud/tofu/docker if missing; then: cd infra && tofu init -backend-config=backend.hcl && tofu apply
7. Create ADMIN_TOKEN file and: ./infra/scripts/deploy.sh all
8. Smoke test /cloudCost/status with identity token; if Data Missing, enable detailed BQ export in console

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
