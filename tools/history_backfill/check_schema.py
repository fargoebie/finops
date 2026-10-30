#!/usr/bin/env python3
"""Dry-run the SELECT in 02_convert.sql and diff its result schema against the FOCUS export's.

Substitutes {{SRC_DETAIL}} (default: the live se1 detailed export) and {{SRC_STANDARD}} (default: the
frozen se1 standard export), dry-runs the CREATE's SELECT with `bq query --dry_run` in their region
(both must be in --location), and compares name / type / mode / order recursively against
`bq show --schema` of the FOCUS table. The dry-run also fails if the standard branch's padding does not
match the detailed schema (UNION ALL type error). Also asserts that dbt var focus_cutover_date lies
inside the SQL's usage_start_time window.

No table is created and nothing is billed beyond the dry-run. Exit 0 = schemas identical.
Needs: bq authenticated (gcloud auth login).
"""
import argparse
import json
import pathlib
import re
import subprocess
import sys

HERE = pathlib.Path(__file__).resolve().parent
REPO = HERE.parent.parent

DEFAULT_SRC_DETAIL = ("terralogiq-billing-export-new.tes_billing_export."
                      "gcp_billing_export_resource_v1_01A09A_A37EA6_F0AC6C")
DEFAULT_SRC_STANDARD = ("terralogiq-billing-export-new.tes_billing_export_try."
                        "gcp_billing_export_v1_01A09A_A37EA6_F0AC6C_copy")
DEFAULT_FOCUS = ("terra-coe-finops:gcp_billing_immutable_01A09A_A37EA6_F0AC6C_asia_southeast2."
                 "gcp_billing_export_focus_01A09A_A37EA6_F0AC6C")

# bq reports legacy names in `show` and GoogleSQL names in some query schemas.
TYPE_ALIAS = {"FLOAT64": "FLOAT", "INT64": "INTEGER", "BOOL": "BOOLEAN", "STRUCT": "RECORD"}


def bq(args, stdin=None):
    p = subprocess.run(["bq", *args], input=stdin, capture_output=True, text=True)
    if p.returncode != 0:
        sys.exit(f"bq {' '.join(args[:3])} failed (auth expired?):\n{p.stderr.strip() or p.stdout.strip()}")
    return p.stdout


def norm(fields):
    """Keep only what must match: name, type, mode, nested fields. Order is preserved."""
    out = []
    for f in fields or []:
        t = f["type"].upper()
        out.append({
            "name": f["name"],
            "type": TYPE_ALIAS.get(t, t),
            "mode": (f.get("mode") or "NULLABLE").upper(),
            "fields": norm(f.get("fields")),
        })
    return out


def diff(a, b, path=""):
    """a = FOCUS (expected), b = converted SELECT (actual). Yields human-readable differences."""
    for i in range(max(len(a), len(b))):
        if i >= len(a):
            yield f"{path}[{i}] extra in SELECT: {b[i]['name']} {b[i]['type']} {b[i]['mode']}"
            continue
        if i >= len(b):
            yield f"{path}[{i}] missing from SELECT: {a[i]['name']} {a[i]['type']} {a[i]['mode']}"
            continue
        x, y = a[i], b[i]
        here = f"{path}{x['name']}"
        if x["name"] != y["name"]:
            yield f"{path}[{i}] name: FOCUS {x['name']!r} vs SELECT {y['name']!r}"
        for k in ("type", "mode"):
            if x[k] != y[k]:
                yield f"{here} {k}: FOCUS {x[k]} vs SELECT {y[k]}"
        if x["name"] == y["name"]:
            yield from diff(x["fields"], y["fields"], here + ".")


def split_creates(sql):
    """-> [(target_table, select_body, where_clause)] for each CREATE ... AS SELECT ... ;"""
    sql = re.sub(r"--.*$", "", sql, flags=re.M)  # comments may contain ';' and the {{SRC_*}} placeholders
    stmts = [s.strip() for s in re.split(r";\s*$", sql, flags=re.M) if s.strip()]
    out = []
    for s in stmts:
        m = re.match(r"CREATE OR REPLACE TABLE\s+`([^`]+)`.*?^AS\s*$\n(.*)$", s, flags=re.S | re.M)
        if not m:
            sys.exit(f"unrecognised statement (expected CREATE OR REPLACE TABLE ... AS SELECT):\n{s[:200]}")
        select_all = m.group(2).strip()
        body, where = re.split(r"^WHERE\b", select_all, maxsplit=1, flags=re.M)
        out.append((m.group(1), body.strip(), "WHERE" + where))
    return out


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--src-detail", default=DEFAULT_SRC_DETAIL,
                    help="detailed export, project.dataset.table (default: live se1 export)")
    ap.add_argument("--src-standard", default=DEFAULT_SRC_STANDARD,
                    help="standard export, project.dataset.table (default: frozen se1 copy)")
    ap.add_argument("--location", default="asia-southeast1", help="region of --src-detail and --src-standard")
    ap.add_argument("--focus", default=DEFAULT_FOCUS, help="FOCUS table, project:dataset.table")
    ap.add_argument("--project", default="gcp-coe-492507", help="billing project for bq")
    ap.add_argument("--sql", default=str(HERE / "02_convert.sql"))
    args = ap.parse_args()

    focus = norm(json.loads(bq([f"--project_id={args.project}", "show", "--schema", "--format=json", args.focus])))
    sql = (pathlib.Path(args.sql).read_text()
           .replace("{{SRC_DETAIL}}", f"`{args.src_detail}`")
           .replace("{{SRC_STANDARD}}", f"`{args.src_standard}`"))
    creates = split_creates(sql)
    failures = []

    # 1. exactly one CREATE
    if len(creates) != 1:
        print(f"DIFF expected exactly one CREATE statement, found {len(creates)}")
        failures.append("statements")

    # 2. the dbt cutover must lie inside the table's usage_start_time window [lo, hi)
    proj = (REPO / "dbt" / "dbt_project.yml").read_text()
    m = re.search(r"focus_cutover_date:\s*['\"]?(\d{4}-\d{2}-\d{2})", proj)
    if not m:
        print("DIFF dbt/dbt_project.yml has no focus_cutover_date var")
        failures.append("cutover")
    elif creates:
        cutover, where = m.group(1), creates[0][2]
        lo = re.search(r">=\s+TIMESTAMP '(\d{4}-\d{2}-\d{2})'", where)
        hi = re.search(r"<\s+TIMESTAMP '(\d{4}-\d{2}-\d{2})'", where)
        if not (lo and hi and lo.group(1) <= cutover < hi.group(1)):
            print(f"DIFF dbt cutover {cutover} is not inside the SQL window "
                  f"[{lo and lo.group(1)}, {hi and hi.group(1)})")
            failures.append("cutover")

    # 3. schema of the SELECT vs FOCUS
    for target, body, _ in creates:
        out = bq([f"--project_id={args.project}", f"--location={args.location}", "query",
                  "--dry_run", "--nouse_legacy_sql", "--format=json"], stdin=body)
        job = json.loads(out)
        stats = job["statistics"]["query"]
        actual = norm(stats["schema"]["fields"])
        d = list(diff(focus, actual))
        n_cols = len(actual)
        print(f"{target}: {n_cols} columns (FOCUS has {len(focus)}); "
              f"dry-run scans {int(job['statistics']['totalBytesProcessed']) / 1e9:.1f} GB over the whole source")
        for line in d:
            print(f"  DIFF {line}")
        failures += d

    if failures:
        print(f"\nFAIL: {len(failures)} problem(s)")
        return 1
    print("\nOK: SELECT schema is identical to the FOCUS export (name, type, mode, order, nested fields); "
          "dbt cutover is inside the table window.")
    return 0


if __name__ == "__main__":
    sys.exit(main())
