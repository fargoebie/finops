# grokbot FinOps query tool

Guarded BigQuery access for grokbot. `bq_tool.py` runs one `SELECT` against the allowlisted marts and seeds in `gcp-coe-492507.finops_dbt`. It dry-runs first and rejects non-SELECT statements, non-allowlisted tables (from the dry run's `referenced_tables`), and queries over the byte cap. Real runs set `maximum_bytes_billed`, label `app=grokbot`, a job timeout and a row cap. Output is JSON.

These checks are advisory. The real boundary is IAM on the grokbot service account (see `docs/plans/grokbot-bq-integration.md`).

## Install (grokbot box)

```bash
cp -r tools/grokbot/. /workspace/finops/
cd /workspace/finops && pip install -r requirements.txt
# set the masked secret GROKBOT_SA_KEY = full service-account JSON key
```

Then add `system_prompt.md` to grokbot's instructions or memory.

```bash
python /workspace/finops/bq_tool.py "SELECT ... FROM \`gcp-coe-492507.finops_dbt.fct_customer_monthly\` ..."
echo "SELECT ..." | python /workspace/finops/bq_tool.py
```

Exit code is nonzero and stdout is `{"error": "..."}` when a check fails. Python API: `from bq_tool import run_finops_query`.

## Environment

| Variable | Default | Meaning |
|---|---|---|
| `GROKBOT_SA_KEY` | required | Service-account key JSON (never written to disk) |
| `GROKBOT_PROJECT` | `gcp-coe-492507` | Billing project for jobs |
| `GROKBOT_LOCATION` | `asia-southeast2` | Job location |
| `GROKBOT_MAX_BYTES` | `1000000000` | Per-query cap (dry-run and `maximum_bytes_billed`) |
| `GROKBOT_MAX_ROWS` | `500` | Rows returned; `truncated` is set beyond this |
| `GROKBOT_TIMEOUT_SECONDS` | `60` | Job timeout |

Keep `allowlist.txt` in sync with `dbt/models/marts/*.sql` and `dbt/seeds/*.csv`.

## Tests

```bash
pip install -r requirements.txt
python -m pytest -v   # mocked client, no network
```
