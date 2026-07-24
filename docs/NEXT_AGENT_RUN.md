# Next Cloud Agent Run — Handoff

Secrets are injected **only at environment start**. This run had `GEMINI_API_KEY` only. After you add `GCP_SA_KEY_B64`, **start a new agent** — do not expect this session to see the new secret.

## Prerequisites (human, before new run)

1. On an admin machine with `gcloud`, create deployer SA + state bucket (safe script: no giant IAM dumps / no base64 printed to terminal). Prefer [`infra/scripts/create-deployer-sa.sh`](../infra/scripts/create-deployer-sa.sh) from a clone, **or** paste the crash-safe block from the PR / chat.
2. Add Cursor Cloud Agent / environment secret:
   - **Name:** `GCP_SA_KEY_B64`
   - **Value:** single-line base64 of `opencost-deployer@demogcp-terra2021.iam.gserviceaccount.com` JSON key (copy from file, do not `cat` huge lines into a flaky terminal)
3. Ensure GCP **resource/detailed** BigQuery billing export exists in `demogcp-terra2021`. Note `dataset` + `table` names.
4. Start a **new** Cloud Agent on branch `cursor/agents-gcp-cloudcost-9250` (or `develop` after merge) with that secret attached.

## First message to give the new agent

```text
Continue OpenCost Cloud Run deploy for demogcp-terra2021.

1. Verify secret: test -n "$GCP_SA_KEY_B64" && echo ok
2. ./infra/scripts/auth-from-secret.sh
3. Edit infra/examples/cloud-integration.demogcp-terra2021.json with real BQ dataset/table (REPLACE_* placeholders). I will provide: dataset=___ table=___
4. cp infra/terraform.tfvars.example infra/terraform.tfvars  (set invoker_members to my user email if I give one)
5. cp infra/backend.hcl.example infra/backend.hcl
6. Install gcloud if missing; then: cd infra && tofu init -backend-config=backend.hcl && tofu apply
7. Create ADMIN_TOKEN file and: ./infra/scripts/deploy.sh all
8. Smoke test /cloudCost/status with identity token or document invoker grant needed

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
