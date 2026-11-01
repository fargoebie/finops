"""Unit tests for bq_tool with a mocked BigQuery client (no network)."""
import datetime
import decimal
from types import SimpleNamespace
from unittest import mock

import pytest

import bq_tool

MART = ("gcp-coe-492507", "finops_dbt", "fct_customer_monthly")


def ref(project, dataset, table):
    return SimpleNamespace(project=project, dataset_id=dataset, table_id=table)


def dry_job(statement_type="SELECT", tables=(MART,), bytes_processed=1000):
    return SimpleNamespace(
        statement_type=statement_type,
        referenced_tables=[ref(*t) for t in tables],
        total_bytes_processed=bytes_processed,
    )


def real_job(rows, columns=("customer_name", "net_cost_usd")):
    iterator = mock.MagicMock()
    iterator.schema = [SimpleNamespace(name=c) for c in columns]
    iterator.__iter__.side_effect = lambda: iter(
        [SimpleNamespace(values=lambda r=r: list(r)) for r in rows]
    )
    job = mock.MagicMock()
    job.result.return_value = iterator
    job.total_bytes_billed = 10485760
    job.total_bytes_processed = 1000
    job.job_id = "job_123"
    return job


def make_client(dry, real=None):
    """query() returns `dry` for dry-run configs and `real` otherwise."""
    client = mock.MagicMock()

    def query(sql, job_config=None):
        return dry if job_config.dry_run else real

    client.query.side_effect = query
    return client


def real_calls(client):
    return [c for c in client.query.call_args_list if not c.kwargs["job_config"].dry_run]


def test_dry_run_uses_no_cache():
    client = make_client(dry_job(), real_job([]))
    bq_tool.run_finops_query("SELECT 1", client=client)
    cfg = client.query.call_args_list[0].kwargs["job_config"]
    assert cfg.dry_run is True and cfg.use_query_cache is False


def test_dry_run_failure_is_reported_without_running():
    client = mock.MagicMock()
    client.query.side_effect = RuntimeError("Syntax error at [1:1]")
    out = bq_tool.run_finops_query("SELEC 1", client=client)
    assert "Dry run failed" in out["error"] and "Syntax error" in out["error"]
    assert client.query.call_count == 1


@pytest.mark.parametrize("stmt", ["DELETE", "CREATE_TABLE", "SCRIPT", "INSERT"])
def test_non_select_rejected(stmt):
    client = make_client(dry_job(statement_type=stmt))
    out = bq_tool.run_finops_query("DELETE FROM x WHERE true", client=client)
    assert "Only a single SELECT" in out["error"]
    assert real_calls(client) == []


def test_empty_referenced_tables_rejected():
    client = make_client(dry_job(tables=()))
    out = bq_tool.run_finops_query("SELECT 1", client=client)
    assert "references no allowlisted table" in out["error"]
    assert "fct_customer_monthly" in out["error"]
    assert real_calls(client) == []


def test_public_dataset_rejected():
    client = make_client(dry_job(tables=[("bigquery-public-data", "samples", "shakespeare")]))
    out = bq_tool.run_finops_query("SELECT * FROM `bigquery-public-data.samples.shakespeare`", client=client)
    assert "bigquery-public-data.samples.shakespeare" in out["error"]
    assert "fct_customer_monthly" in out["error"]  # suggests allowed marts
    assert real_calls(client) == []


def test_staging_table_rejected():
    client = make_client(dry_job(tables=[("gcp-coe-492507", "dbt_staging", "stg_focus_billing")]))
    out = bq_tool.run_finops_query("SELECT 1 FROM x", client=client)
    assert "stg_focus_billing" in out["error"]
    assert real_calls(client) == []


def test_one_bad_table_among_good_rejected():
    client = make_client(dry_job(tables=[MART, ("gcp-coe-492507", "dbt_staging", "stg_focus_billing")]))
    out = bq_tool.run_finops_query("SELECT 1 FROM x", client=client)
    assert "not allowed" in out["error"]
    assert real_calls(client) == []


def test_over_byte_cap_rejected():
    client = make_client(dry_job(bytes_processed=1_000_000_001))
    out = bq_tool.run_finops_query("SELECT 1 FROM x", client=client)
    assert "over the cap" in out["error"]
    assert real_calls(client) == []


def test_byte_cap_env_override(monkeypatch):
    monkeypatch.setenv("GROKBOT_MAX_BYTES", "500")
    client = make_client(dry_job(bytes_processed=1000))
    out = bq_tool.run_finops_query("SELECT 1 FROM x", client=client)
    assert "over the cap of 500" in out["error"]


def test_happy_path_returns_rows_and_sets_job_config():
    rows = [
        ("Acme", decimal.Decimal("12.50")),
        ("Beta", datetime.date(2026, 9, 1)),
    ]
    client = make_client(dry_job(), real_job(rows))
    out = bq_tool.run_finops_query("SELECT customer_name, net_cost_usd FROM x", client=client)
    assert out == {
        "columns": ["customer_name", "net_cost_usd"],
        "rows": [
            {"customer_name": "Acme", "net_cost_usd": "12.50"},
            {"customer_name": "Beta", "net_cost_usd": "2026-09-01"},
        ],
        "row_count": 2,
        "truncated": False,
        "bytes_billed": 10485760,
        "bytes_processed": 1000,
        "job_id": "job_123",
    }
    (call,) = real_calls(client)
    cfg = call.kwargs["job_config"]
    assert cfg.labels == {"app": "grokbot"}
    assert cfg.maximum_bytes_billed == 1_000_000_000
    assert int(cfg.job_timeout_ms) == 60_000  # library returns it as a string


def test_truncation(monkeypatch):
    monkeypatch.setenv("GROKBOT_MAX_ROWS", "3")
    rows = [("c%d" % i, i) for i in range(4)]  # row_cap + 1 rows fetched
    job = real_job(rows)
    client = make_client(dry_job(), job)
    out = bq_tool.run_finops_query("SELECT 1 FROM x", client=client)
    assert out["truncated"] is True
    assert out["row_count"] == 3 and len(out["rows"]) == 3
    assert job.result.call_args.kwargs["max_results"] == 4


def test_real_run_failure_returns_error():
    job = real_job([])
    job.result.side_effect = RuntimeError("Query exceeded limit for bytes billed")
    client = make_client(dry_job(), job)
    out = bq_tool.run_finops_query("SELECT 1 FROM x", client=client)
    assert "Query failed" in out["error"]


def test_missing_key_is_clear_error(monkeypatch):
    monkeypatch.delenv("GROKBOT_SA_KEY", raising=False)
    out = bq_tool.run_finops_query("SELECT 1")
    assert "GROKBOT_SA_KEY" in out["error"]


def test_allowlist_covers_marts_and_seeds():
    allowed = bq_tool.load_allowlist()
    assert len(allowed) == 10
    assert all(t.startswith("gcp-coe-492507.finops_dbt.") for t in allowed)
    assert "gcp-coe-492507.finops_dbt.fct_credit_runway" in allowed
