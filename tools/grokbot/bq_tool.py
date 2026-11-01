#!/usr/bin/env python3
"""Guarded BigQuery query tool for grokbot.

Usage:  python bq_tool.py "SELECT ..."      (or pipe SQL on stdin)
Prints one JSON object. On any failed check prints {"error": "..."} and exits 1.

Checks run in order and none of them runs the real query: dry run, SELECT only,
table allowlist, byte cap. Advisory only -- IAM on the service account is the
real boundary (see docs/plans/grokbot-bq-integration.md).
"""
import base64
import datetime
import decimal
import json
import os
import sys

from google.cloud import bigquery
from google.oauth2 import service_account

ALLOWLIST_PATH = os.path.join(os.path.dirname(os.path.abspath(__file__)), "allowlist.txt")
SUGGESTED_MARTS = "fct_customer_monthly, fct_customer_service_month, fct_spend_waterfall"


def _env_int(name, default):
    return int(os.environ.get(name, default))


def load_allowlist(path=ALLOWLIST_PATH):
    with open(path) as fh:
        lines = (line.split("#", 1)[0].strip() for line in fh)
        return {line for line in lines if line}


def make_client():
    info = json.loads(os.environ["GROKBOT_SA_KEY"])
    creds = service_account.Credentials.from_service_account_info(
        info, scopes=["https://www.googleapis.com/auth/bigquery"]
    )
    return bigquery.Client(
        project=os.environ.get("GROKBOT_PROJECT", "gcp-coe-492507"),
        location=os.environ.get("GROKBOT_LOCATION", "asia-southeast2"),
        credentials=creds,
    )


def _json_safe(value):
    if isinstance(value, decimal.Decimal):
        return str(value)
    if isinstance(value, (datetime.datetime, datetime.date, datetime.time)):
        return value.isoformat()
    if isinstance(value, bytes):
        return base64.b64encode(value).decode("ascii")
    if isinstance(value, float) and (value != value or value in (float("inf"), float("-inf"))):
        return str(value)
    if isinstance(value, dict):
        return {k: _json_safe(v) for k, v in value.items()}
    if isinstance(value, (list, tuple)):
        return [_json_safe(v) for v in value]
    return value


def run_finops_query(sql, *, client=None):
    """Validate and run `sql`. Returns a result dict, or {"error": "..."} on rejection/failure."""
    try:
        max_bytes = _env_int("GROKBOT_MAX_BYTES", 1_000_000_000)
        row_cap = _env_int("GROKBOT_MAX_ROWS", 500)
        timeout_s = _env_int("GROKBOT_TIMEOUT_SECONDS", 60)
        allowlist = load_allowlist()
        if client is None:
            client = make_client()
    except KeyError:
        return {"error": "GROKBOT_SA_KEY is not set. Add the service-account JSON key as that env var."}
    except (ValueError, OSError) as exc:
        return {"error": "Tool configuration problem: %s" % exc}

    if not sql or not sql.strip():
        return {"error": "Empty query. Pass a single SELECT statement."}

    # 1. Dry run
    try:
        dry = client.query(sql, job_config=bigquery.QueryJobConfig(dry_run=True, use_query_cache=False))
    except Exception as exc:  # syntax error, access denied, missing table, ...
        return {"error": "Dry run failed (query was not run): %s" % exc}

    # 2. SELECT only
    if dry.statement_type != "SELECT":
        return {
            "error": "Only a single SELECT statement is allowed (got statement type %r). "
            "Rewrite as one read-only SELECT, with no DDL, DML or multi-statement scripts."
            % dry.statement_type
        }

    # 3. Table allowlist
    refs = ["%s.%s.%s" % (t.project, t.dataset_id, t.table_id) for t in (dry.referenced_tables or [])]
    if not refs:
        return {
            "error": "Query references no allowlisted table. Select FROM a mart in "
            "gcp-coe-492507.finops_dbt, e.g. %s." % SUGGESTED_MARTS
        }
    denied = sorted(set(r for r in refs if r not in allowlist))
    if denied:
        return {
            "error": "Table(s) not allowed: %s. Query only the allowlisted marts in "
            "gcp-coe-492507.finops_dbt, e.g. %s. Full list: %s"
            % (", ".join(denied), SUGGESTED_MARTS, ", ".join(sorted(allowlist)))
        }

    # 4. Byte cap
    processed = dry.total_bytes_processed or 0
    if processed > max_bytes:
        return {
            "error": "Query would process %d bytes, over the cap of %d. Select only the columns "
            "you need and filter on charge_month (or another narrow predicate)."
            % (processed, max_bytes)
        }

    # Real run
    config = bigquery.QueryJobConfig(
        maximum_bytes_billed=max_bytes,
        labels={"app": "grokbot"},
        job_timeout_ms=timeout_s * 1000,
    )
    try:
        job = client.query(sql, job_config=config)
        iterator = job.result(max_results=row_cap + 1, timeout=timeout_s)
        columns = [f.name for f in iterator.schema]
        rows = [dict(zip(columns, _json_safe(list(row.values())))) for row in iterator]
    except Exception as exc:
        return {"error": "Query failed: %s" % exc}

    truncated = len(rows) > row_cap
    rows = rows[:row_cap]
    return {
        "columns": columns,
        "rows": rows,
        "row_count": len(rows),
        "truncated": truncated,
        "bytes_billed": job.total_bytes_billed,
        "bytes_processed": job.total_bytes_processed,
        "job_id": job.job_id,
    }


def main(argv=None):
    argv = sys.argv[1:] if argv is None else argv
    sql = " ".join(argv) if argv else sys.stdin.read()
    result = run_finops_query(sql)
    print(json.dumps(result, indent=2))
    return 1 if "error" in result else 0


if __name__ == "__main__":
    sys.exit(main())
