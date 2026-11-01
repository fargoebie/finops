# Plan: connect grokbot to the FinOps marts, with guardrails

Status: **deployed and in use** (2026-11-01).
- Phase 1 applied with a targeted apply: 3 added, 0 changed.
- The key is in the Grok Bot FinOps bot. The tool is installed at `/workspace/finops`.
- First live session: 32 jobs, 404 MB billed (≈ $0.0025), no access outside `finops_dbt`.
- `referenced_tables` lists the mart tables on real jobs.
- Follow-ups:
  - The prompt was fixed for `charge_month` being a TIMESTAMP, "last full month", customer grouping, and billed = `net_cost_*`.
  - Rotate the key by 2027-01-30. Approach: a service-account key for an SA in `gcp-coe-492507`. No Beads in this repo; this file is the tracker.

## Goal (done means)

- grokbot answers FinOps questions by querying the **marts in `gcp-coe-492507.finops_dbt`** only.
- grokbot **cannot** read the costly tables: the raw FOCUS export (`terra-coe-finops…`), `finops_history`, `dbt_staging.stg_focus_billing` (~900 GB) or `dbt_intermediate`. This is enforced by IAM.
- The SA has exactly two grants: `roles/bigquery.jobUser` on `gcp-coe-492507` and `roles/bigquery.dataViewer` on dataset `gcp-coe-492507:finops_dbt`.
- The negative tests in Phase 4 fail closed, and the output is pasted into this file.

## Context (self-reported by grokbot on 2026-11-01, not verified)

- **Runtime:** a hosted "Grok Bot" platform, plus a persistent Linux box (`/workspace`, general internet access) **shared with the user's other bots**. Not on GCP.
- **Secrets:** supplied as masked env vars on that box. The bot has a shell, so it, and any bot on the box, can use them.
- **Audience:** personal; only Farry.
- **Data handling:** the platform keeps transcripts; retention and xAI training settings are UNKNOWN.
- **Rejected:** the catalog BigQuery connector. It uses OAuth as farry@terralogiq.com, so it has full access and no byte cap.
- **Decided against** (by Farry): a separate project with a hard quota, and a self-hosted MCP server.
- **Key creation:** allowed (confirmed by Farry).

## Trust model

The key sits on a shared box with a shell, so anything on the box can bypass `bq_tool.py`. Only IAM is a guarantee.

| # | Layer | Enforced by | Stops |
|---|---|---|---|
| 1 | **IAM boundary.** `dataViewer` on `finops_dbt` only (7 marts + 3 seeds, MB-scale) | GCP | Reading raw FOCUS / stg / int / history ($0, access denied) |
| 2 | **Key hygiene.** No key in tofu state; 90-day rotation; local copy deleted after upload | Process | Long-lived leaked credentials |
| 3 | **Guarded tool:** dry run, table allowlist from `referencedTables`, SELECT-only, 1 GB per-query cap, row limit, label `app=grokbot` | `bq_tool.py` (advisory) | A well-behaved bot picking wrong tables or wasting bytes |

**Accepted residual risk (no hard cost cap):**
- `jobUser` lets anything holding the key run jobs billed to `gcp-coe-492507`, including scans of `bigquery-public-data`.
- The project's per-user daily quota can't contain this: it is one value for all principals and would also cap dbt.
- Spend through `finops_dbt` itself is negligible.
- Detection, if wanted: Phase 5.

## Phases

### Phase 1 — IaC (`infra/grokbot.tf`)

- `google_service_account.grokbot` (`${var.name_prefix}-grokbot`) in `var.project_id`.
- `google_project_iam_member`: `roles/bigquery.jobUser` on `var.project_id`. Nothing else at project level.
- `google_bigquery_dataset_iam_member`: `roles/bigquery.dataViewer` on `finops_dbt` (member resource; dbt owns the dataset).
- **No `google_service_account_key`:** it would write the private key into tofu state.
- `infra/outputs.tf`: output `grokbot_service_account_email`.

### Phase 2 — Key (out-of-band, Farry)

```bash
gcloud iam service-accounts keys create ~/grokbot.json \
  --iam-account=finops-grokbot@gcp-coe-492507.iam.gserviceaccount.com
# paste the contents into the Grok Bot masked secret GROKBOT_SA_KEY, then:
rm -P ~/grokbot.json
```

Rotate every 90 days: create a new key, update the secret, delete the old one. Revoke with `keys delete <id>`, or disable the SA.

### Phase 3 — Guarded tool + bot context (`tools/grokbot/`)

- `bq_tool.py` (CLI + importable function) reads credentials from `GROKBOT_SA_KEY` (JSON in an env var; no key file on disk). Jobs run with `project=gcp-coe-492507`, `location=asia-southeast2`.
- Flow: dry run → `statement_type == SELECT` → `referenced_tables` non-empty and all on the allowlist → dry-run bytes ≤ cap → run with `maximum_bytes_billed`, label `app=grokbot`, timeout, row cap. Output JSON with rows, bytes_billed and job_id; errors as actionable text.
- Read via `result()` iteration. No `google-cloud-bigquery-storage`, no `to_dataframe()`: the Storage Read API needs `readsessions.create`, which isn't granted.
- `allowlist.txt`: the 7 `fct_*` marts and 3 seeds, fully qualified.
- `test_bq_tool.py`: mocked-client unit tests, one per check.
- `system_prompt.md`: derived from `finops-data-access.md`; no raw FOCUS table or column names; rules in mart-column terms; mart columns from `dbt/models/marts/schema.yml`. It also says: always use `bq_tool.py`, never raw `bq`, curl or the client library.
- Install on grokbot's box: copy `tools/grokbot/` to `/workspace/finops/`, `pip install -r requirements.txt`, and add `system_prompt.md` to grokbot's instructions or memory.

### Phase 4 — Verify (as the grokbot SA, after `tofu apply` + key)

| Test | Expected | Layer |
|---|---|---|
| `bq query` against `terra-coe-finops.…focus…` | Access denied, $0 | 1 |
| `bq query` against `dbt_staging.stg_focus_billing` | Access denied | 1 |
| `bq query` against `finops_history.focus_billing_history` | Access denied | 1 |
| `bq_tool.py` against `bigquery-public-data.…` | Rejected by the allowlist, not run | 3 |
| `bq_tool.py` DELETE / DDL | Rejected (SELECT-only) | 3 |
| "Top 10 customers by billed USD, last full month" via grokbot | Correct; KB-scale bytes; label visible | — |

Audit (run as Farry): `SELECT SUM(total_bytes_billed) FROM \`gcp-coe-492507\`.\`region-asia-southeast2\`.INFORMATION_SCHEMA.JOBS_BY_PROJECT WHERE user_email LIKE 'finops-grokbot@%' AND DATE(creation_time)=CURRENT_DATE() AND statement_type!='SCRIPT'`.

### Phase 5 — Optional

- **Detection:** a log-based metric on BigQuery audit logs (`principalEmail` = grokbot SA, `totalBilledBytes`), alerting at more than 20 GB a day.
- **Move to a hard cap** (separate project with a quota, or a self-hosted MCP server) if the key is misused or the bot gains other users.

## File ownership

| File | Phase | Owner |
|---|---|---|
| `infra/grokbot.tf` (new), `infra/outputs.tf` (append one output) | 1 | worker A (tier 2) |
| `tools/grokbot/*` (new) | 3 | worker B (tier 2) |
| `tofu apply`, key, Grok Bot secret, install on the box | 2, 3 | Farry |
| `docs/plans/grokbot-bq-integration.md` | all | orchestrator |

## Risks

- **The key is reachable by every bot on the shared box.** Impact: read access to the `finops_dbt` marts, plus uncapped query billing in `gcp-coe-492507` if misused.
- **Data egress to the bot platform and xAI** for customer billing data that was already breached once (CVE-2026-72898). The platform's retention settings are unchecked.
- **A future large table in `finops_dbt`** would be readable and billable. Keep large models out of `finops_dbt`.
- **A mart turned back into a view over stg** would fail with access denied. That fails closed, but the bot breaks.
- **An authoritative dataset access resource** on `finops_dbt` would strip the member grant. Use members only.
