#!/usr/bin/env python3
"""Build a self-contained "Cost by project" page for one billing account.

Runs one BigQuery query via the `bq` CLI against dbt_staging.stg_focus_billing,
asserts the cost identity, and writes a single HTML file (template.html) with
the data embedded as JSON. The page has a monthly period picker, a summary, a
stacked daily chart with forecast, and a sortable per-project table.

The output defaults to OUTSIDE the repo so customer billing data cannot be
committed by accident. Python 3 stdlib only; needs `bq` and fresh gcloud auth.

    python3 tools/project_billing_page/build_page.py
    python3 tools/project_billing_page/build_page.py --billing-account XXXXXX-XXXXXX-XXXXXX --account-name "Acme"
"""
import argparse, json, os, subprocess, sys
from datetime import datetime, timezone

HERE = os.path.dirname(os.path.abspath(__file__))
PROJECT = "gcp-coe-492507"
LOCATION = "asia-southeast2"
DEFAULT_OUT = os.path.join(HERE, "..", "..", "..", "trlq-credit-projects.html")

# One row per (day, project, charge category). Credits come from the x_credits
# array; they are ALREADY inside billed_cost, so subtotal is never reduced again.
SQL = """
select
  cast(charge_date as string) as d,
  project_id as pid,
  coalesce(project_name, project_id, '(no project)') as pname,
  charge_category as cat,
  sum(if(charge_category = 'Usage', list_cost, 0)) as usage_cost,
  sum(if(charge_category = 'Usage', contracted_cost - list_cost, 0)) as negotiated_savings,
  sum((select coalesce(sum(c.amount), 0) from unnest(x_credits) c
       where starts_with(c.type, 'COMMITTED_USAGE_DISCOUNT'))) as savings_programs,
  sum((select coalesce(sum(c.amount), 0) from unnest(x_credits) c
       where not starts_with(c.type, 'COMMITTED_USAGE_DISCOUNT'))) as other_savings,
  sum(if(charge_category = 'Tax', billed_cost, 0)) as tax,
  sum(billed_cost) as subtotal
from `gcp-coe-492507.dbt_staging.stg_focus_billing`
where billing_account_id = @acct
group by 1, 2, 3, 4
order by 1, 2, 4
"""
NUM = ["usage_cost", "negotiated_savings", "savings_programs", "other_savings", "tax", "subtotal"]


def query(acct):
    cmd = ["bq", f"--project_id={PROJECT}", f"--location={LOCATION}", "query",
           "--use_legacy_sql=false", "--format=json", "--max_rows=1000000",
           f"--parameter=acct::{acct}", SQL]
    res = subprocess.run(cmd, capture_output=True, text=True)
    if res.returncode:
        sys.exit(f"bq failed:\n{res.stderr}")
    rows = json.loads(res.stdout)
    for r in rows:
        for k in NUM:
            r[k] = round(float(r[k]), 4)
    return rows


def check_identity(rows):
    """Usage rows: usage + negotiated + programs + other must equal billed (subtotal)."""
    usage = [r for r in rows if r["cat"] == "Usage"]
    err = sum(abs(r["usage_cost"] + r["negotiated_savings"] + r["savings_programs"]
                  + r["other_savings"] - r["subtotal"]) for r in usage)
    print(f"identity check: {len(usage)} usage rows, total abs error {err:.6f} (limit {0.01 * len(usage):.2f})")
    assert err <= 0.01 * len(usage), "cost identity broken: usage+negotiated+programs+other != billed"


def main():
    ap = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    ap.add_argument("--billing-account", default="01E5F4-66804E-8286B7")
    ap.add_argument("--account-name", default="TRLQ Credit")
    ap.add_argument("--out", default=DEFAULT_OUT)
    a = ap.parse_args()

    rows = query(a.billing_account)
    if not rows:
        sys.exit(f"no rows for billing account {a.billing_account}")
    check_identity(rows)

    data = {"account": a.billing_account, "name": a.account_name,
            "generated": datetime.now(timezone.utc).strftime("%Y-%m-%d %H:%M UTC"), "rows": rows}
    # "</" would end the script tag early inside inline JSON.
    blob = json.dumps(data, separators=(",", ":")).replace("</", "<\\/")
    html = open(os.path.join(HERE, "template.html")).read()
    html = (html.replace("__TITLE__", f"{a.account_name} - cost by project")
                .replace("__DATA__", blob))
    out = os.path.abspath(a.out)
    with open(out, "w") as f:
        f.write(html)
    print(f"{len(rows)} rows, {rows[0]['d']}..{rows[-1]['d']} -> {out} ({os.path.getsize(out):,} bytes)")


if __name__ == "__main__":
    main()
