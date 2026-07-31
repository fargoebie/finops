#!/usr/bin/env python3
"""Build Terralogiq BOD Metabase dashboards (idempotent) via the REST API.

Reads the admin API key from ~/.config/finops-mb-api-key.
Step 1: Deletes the 5 legacy "FinOps — *" dashboards and their cards.
Step 2: Creates (or updates) a "Terralogiq BOD" collection with 4 dashboards.

All money cards support a currency toggle (IDR default, USD optional)
via a {{currency}} template tag. Run the script; it prints every action and a
final verification table.
"""
import json, os, ssl, sys, urllib.request, urllib.error

MB = "https://34.101.217.143"
DB = 2  # BigQuery database id in Metabase
KEY = open(os.path.expanduser("~/.config/finops-mb-api-key")).read().strip()
CTX = ssl.create_default_context()
CTX.check_hostname = False
CTX.verify_mode = ssl.CERT_NONE

GRID = 24  # Metabase 24-column grid

# ---------------------------------------------------------------------------
# API helper
# ---------------------------------------------------------------------------

def api(method, path, body=None, raise_on_error=True):
    url = MB + path
    data = json.dumps(body).encode() if body is not None else None
    req = urllib.request.Request(url, data=data, method=method)
    req.add_header("x-api-key", KEY)
    if data:
        req.add_header("Content-Type", "application/json")
    try:
        with urllib.request.urlopen(req, context=CTX, timeout=60) as r:
            raw = r.read()
            return json.loads(raw) if raw else None
    except urllib.error.HTTPError as e:
        body_text = e.read().decode()[:800]
        print("  HTTP %s on %s %s\n  %s" % (e.code, method, path, body_text))
        if raise_on_error:
            raise
        return None

# ---------------------------------------------------------------------------
# Viz helpers
# ---------------------------------------------------------------------------

def idr_col(col):
    return {'["name","%s"]' % col: {
        "number_style": "currency",
        "currency": "IDR",
        "currency_style": "code",
        "currency_in_header": False,
        "decimals": 0,
    }}

def pct_col(col):
    return {'["name","%s"]' % col: {
        "number_style": "percent",
        "decimals": 1,
    }}

def disc_pct_col(col):
    """SQL already outputs value*100 (e.g. 20.9); render as decimal + % suffix, no second ×100."""
    _titles = {
        "discount_pct": "Discount %",
        "disc_plus_credits_pct": "Disc + Credits %",
    }
    entry = {
        "number_style": "decimal",
        "decimals": 1,
        "suffix": "%",
    }
    if col in _titles:
        entry["column_title"] = _titles[col]
    return {'["name","%s"]' % col: entry}

def scalar_idr_vs(col):
    return {"column_settings": idr_col(col)}

def scalar_pct_vs(col):
    return {"column_settings": pct_col(col)}

def bar_vs(dim, metric, currency=True, stacked=False):
    vs = {"graph.dimensions": [dim], "graph.metrics": [metric]}
    if currency:
        vs["column_settings"] = idr_col(metric)
    if stacked:
        vs["stackable.stack_type"] = "stacked"
    return vs

def table_vs(money_cols=None, pct_cols=None, disc_pct_cols=None):
    cs = {}
    for c in (money_cols or []):
        cs.update(idr_col(c))
    for c in (pct_cols or []):
        cs.update(pct_col(c))
    for c in (disc_pct_cols or []):
        cs.update(disc_pct_col(c))
    return {"column_settings": cs}

# ---------------------------------------------------------------------------
# Currency CASE helper
# ---------------------------------------------------------------------------

def currency_case(idr_expr, usd_expr, alias):
    """CASE WHEN {{currency}}='USD' THEN <usd_expr> ELSE <idr_expr> END AS alias"""
    return "CASE WHEN {{currency}} = 'USD' THEN %s ELSE %s END AS %s" % (
        usd_expr, idr_expr, alias)

# Template-tag definition (shared by all money cards)
CURRENCY_TAG = {
    "currency": {
        "id": "currency-tag",
        "name": "currency",
        "display-name": "Currency",
        "type": "text",
        "default": "IDR",
        "required": True,
    }
}

# Dashboard currency parameter
CURRENCY_PARAM = {
    "id": "cur_param",
    "name": "Currency",
    "slug": "currency",
    "type": "category",
    "default": ["IDR"],
}

def currency_mapping(card_id):
    return [{
        "parameter_id": "cur_param",
        "card_id": card_id,
        "target": ["variable", ["template-tag", "currency"]],
    }]

# ---------------------------------------------------------------------------
# Collection helpers
# ---------------------------------------------------------------------------

def find_or_create_collection(name, parent_id=None):
    for c in api("GET", "/api/collection"):
        if c.get("name") == name and not c.get("archived"):
            return c["id"]
    return api("POST", "/api/collection", {"name": name, "parent_id": parent_id})["id"]

def coll_items(coll_id, model):
    items = api("GET", "/api/collection/%s/items?models=%s" % (coll_id, model)) or {}
    return {i["name"]: i["id"] for i in items.get("data", [])}

# ---------------------------------------------------------------------------
# Step 1 — Delete legacy FinOps dashboards + their cards
# ---------------------------------------------------------------------------

OLD_DASH_NAMES = [
    "FinOps — Spend Overview",
    "FinOps — Discounts & Savings",
    "FinOps — Credits",
    "FinOps — CUD / Commitments",
    "FinOps — Showback",
]
OLD_COLL_ID = 5  # "FinOps" collection id

print("=" * 60)
print("STEP 1: Delete legacy FinOps dashboards")
print("=" * 60)

legacy_dashes = coll_items(OLD_COLL_ID, "dashboard")
for dash_name in OLD_DASH_NAMES:
    if dash_name not in legacy_dashes:
        print("  [skip] dashboard not found: %s" % dash_name)
        continue
    dash_id = legacy_dashes[dash_name]
    # Collect card ids from dashcards before deleting
    dash_detail = api("GET", "/api/dashboard/%s" % dash_id)
    card_ids = []
    if dash_detail:
        for dc in dash_detail.get("dashcards", []):
            cid = dc.get("card_id")
            if cid:
                card_ids.append(cid)
    # Delete dashboard
    api("DELETE", "/api/dashboard/%s" % dash_id, raise_on_error=False)
    print("  [deleted] dashboard %r (id=%s)" % (dash_name, dash_id))
    # Delete orphaned cards
    for cid in card_ids:
        api("DELETE", "/api/card/%s" % cid, raise_on_error=False)
        print("    [deleted] card id=%s" % cid)

print()

# ---------------------------------------------------------------------------
# Step 2 — Create "Terralogiq BOD" collection and 4 dashboards
# ---------------------------------------------------------------------------

print("=" * 60)
print("STEP 2: Build Terralogiq BOD dashboards")
print("=" * 60)

BOD_COLL = find_or_create_collection("Terralogiq BOD")
print("collection 'Terralogiq BOD' id=%s" % BOD_COLL)

existing_cards  = coll_items(BOD_COLL, "card")
existing_dashes = coll_items(BOD_COLL, "dashboard")

def upsert_card(name, query, tags, display, vs):
    """Create or update a native-SQL card; return its id."""
    payload = {
        "name": name,
        "dataset_query": {
            "database": DB,
            "type": "native",
            "native": {"query": query, "template-tags": tags},
        },
        "display": display,
        "visualization_settings": vs,
        "collection_id": BOD_COLL,
    }
    if name in existing_cards:
        cid = existing_cards[name]
        api("PUT", "/api/card/%s" % cid, payload)
        print("  [updated] card %r id=%s" % (name, cid))
        return cid
    cid = api("POST", "/api/card", payload)["id"]
    existing_cards[name] = cid
    print("  [created] card %r id=%s" % (name, cid))
    return cid

def upsert_dashboard(name):
    if name in existing_dashes:
        return existing_dashes[name]
    did = api("POST", "/api/dashboard", {
        "name": name,
        "collection_id": BOD_COLL,
        "parameters": [CURRENCY_PARAM],
    })["id"]
    existing_dashes[name] = did
    return did

def layout_dashcards(specs):
    """
    specs: list of dicts with keys:
      name, sql, tags, display, vs, w, h
      OR virtual=True, text, w, h  (markdown text panel)
      with optional is_money=True to wire currency_mapping
    Returns (dashcards_list, card_id_map)  — card_id_map: name→id for money cards
    """
    dashcards = []
    col, row, row_h = 0, 0, 0
    tmp_id = -1
    card_id_map = {}

    for spec in specs:
        w, h = spec["w"], spec["h"]
        if col + w > GRID:
            row += row_h
            col = 0
            row_h = 0

        if spec.get("virtual"):
            # Markdown text panel
            dc = {
                "id": tmp_id,
                "card_id": None,
                "row": row, "col": col,
                "size_x": w, "size_y": h,
                "series": [],
                "parameter_mappings": [],
                "visualization_settings": {
                    "text": spec["text"],
                    "virtual_card": {"display": "text"},
                },
            }
        else:
            cid = upsert_card(
                spec["name"], spec["sql"],
                spec.get("tags", {}), spec["display"], spec["vs"]
            )
            card_id_map[spec["name"]] = cid
            pm = currency_mapping(cid) if spec.get("is_money") else []
            dc = {
                "id": tmp_id,
                "card_id": cid,
                "row": row, "col": col,
                "size_x": w, "size_y": h,
                "series": [],
                "parameter_mappings": pm,
                "visualization_settings": {},
            }

        dashcards.append(dc)
        tmp_id -= 1
        col += w
        row_h = max(row_h, h)

    return dashcards, card_id_map

def put_dashboard(dash_id, dashcards):
    api("PUT", "/api/dashboard/%s" % dash_id, {
        "parameters": [CURRENCY_PARAM],
        "dashcards": dashcards,
    })

# ── Mart table references ──
FCM  = "`finops_dbt.fct_customer_monthly`"
FCSM = "`finops_dbt.fct_customer_service_month`"

RESOLD = "billing_account_type = 'Resold'"

# ===========================================================================
# Dashboard 1 — BOD — Executive Summary
# ===========================================================================

dash1_name = "BOD — Executive Summary"
print("\n--- %s ---" % dash1_name)

d1_specs = [
    {
        "name": "Total Spend (IDR)",
        "sql": "SELECT SUM(net_cost_idr) AS total_spend_idr\n"
               "FROM %s\nWHERE %s" % (FCM, RESOLD),
        "tags": {},
        "display": "scalar",
        "vs": scalar_idr_vs("total_spend_idr"),
        "w": 6, "h": 3,
        "is_money": False,
    },
    {
        "name": "Total Spend (USD)",
        "sql": "SELECT SUM(net_cost_usd) AS total_spend_usd\n"
               "FROM %s\nWHERE %s" % (FCM, RESOLD),
        "tags": {},
        "display": "scalar",
        "vs": {"column_settings": {'["name","total_spend_usd"]': {
            "number_style": "currency", "currency": "USD",
            "currency_style": "symbol", "decimals": 0}}},
        "w": 6, "h": 3,
        "is_money": False,
    },
    {
        "name": "GCP vs GMP Spend",
        "sql": ("SELECT platform,\n"
                "  %s\n"
                "FROM %s\n"
                "WHERE %s\n"
                "GROUP BY platform") % (
                    currency_case("SUM(net_cost_idr)", "SUM(net_cost_usd)", "amount"),
                    FCM, RESOLD),
        "tags": CURRENCY_TAG,
        "display": "row",
        "vs": bar_vs("platform", "amount"),
        "w": 12, "h": 6,
        "is_money": True,
    },
    {
        "name": "Monthly Spend Trend",
        "sql": ("SELECT charge_month,\n"
                "  %s\n"
                "FROM %s\n"
                "WHERE %s\n"
                "GROUP BY charge_month\n"
                "ORDER BY charge_month") % (
                    currency_case("SUM(net_cost_idr)", "SUM(net_cost_usd)", "amount"),
                    FCM, RESOLD),
        "tags": CURRENCY_TAG,
        "display": "bar",
        "vs": bar_vs("charge_month", "amount"),
        "w": 24, "h": 6,
        "is_money": True,
    },
    {
        "name": "Top 10 Customers by Spend",
        "sql": ("SELECT customer_name,\n"
                "  %s\n"
                "FROM %s\n"
                "WHERE %s\n"
                "GROUP BY customer_name\n"
                "ORDER BY amount DESC\n"
                "LIMIT 10") % (
                    currency_case("SUM(net_cost_idr)", "SUM(net_cost_usd)", "amount"),
                    FCM, RESOLD),
        "tags": CURRENCY_TAG,
        "display": "table",
        "vs": table_vs(money_cols=["amount"]),
        "w": 24, "h": 8,
        "is_money": True,
    },
]

d1_id = upsert_dashboard(dash1_name)
d1_dashcards, _ = layout_dashcards(d1_specs)
put_dashboard(d1_id, d1_dashcards)
print("  dashboard id=%s  cards=%s" % (d1_id, len([s for s in d1_specs if not s.get("virtual")])))

# ===========================================================================
# Dashboard 2 — BOD — Customer Leaderboard
# ===========================================================================

dash2_name = "BOD — Customer Leaderboard"
print("\n--- %s ---" % dash2_name)

d2_specs = [
    {
        "name": "Customer Leaderboard Table",
        "sql": ("SELECT customer_name, platform,\n"
                "  %s,\n"
                "  ROUND((1 - SAFE_DIVIDE(SUM(contracted_cost_idr), NULLIF(SUM(gross_cost_idr), 0))) * 100, 1) AS discount_pct,\n"
                "  ROUND((1 - SAFE_DIVIDE(SUM(net_cost_idr), NULLIF(SUM(gross_cost_idr), 0))) * 100, 1) AS disc_plus_credits_pct,\n"
                "  SUM(mom_delta_idr) AS mom_delta_idr\n"
                "FROM %s\n"
                "WHERE %s\n"
                "GROUP BY customer_name, platform\n"
                "ORDER BY amount DESC") % (
                    currency_case("SUM(net_cost_idr)", "SUM(net_cost_usd)", "amount"),
                    FCM, RESOLD),
        "tags": CURRENCY_TAG,
        "display": "table",
        "vs": table_vs(money_cols=["amount", "mom_delta_idr"], disc_pct_cols=["discount_pct", "disc_plus_credits_pct"]),
        "w": 24, "h": 10,
        "is_money": True,
    },
    {
        "name": "MoM Delta by Customer",
        "sql": ("SELECT customer_name, SUM(mom_delta_idr) AS mom_delta_idr\n"
                "FROM %s\n"
                "WHERE %s\n"
                "GROUP BY customer_name\n"
                "ORDER BY mom_delta_idr DESC") % (FCM, RESOLD),
        "tags": {},
        "display": "bar",
        "vs": bar_vs("customer_name", "mom_delta_idr"),
        "w": 16, "h": 6,
        "is_money": False,
    },
    {
        "name": "Unmapped Accounts Count",
        "sql": ("SELECT COUNT(DISTINCT billing_account_id) AS unmapped_count\n"
                "FROM %s\n"
                "WHERE customer_name = '(unmapped)'\n"
                "  AND %s") % (FCM, RESOLD),
        "tags": {},
        "display": "scalar",
        "vs": {},
        "w": 8, "h": 3,
        "is_money": False,
    },
    {
        "virtual": True,
        "text": ("**Note on MoM deltas**\n\n"
                 "Month-over-month delta columns (`mom_delta_idr`, `mom_delta_usd`, `mom_delta_pct`) "
                 "will show NULL until a second month of data has accrued in the billing export. "
                 "This is expected behaviour — the figures will populate automatically starting in August 2026."),
        "w": 8, "h": 3,
    },
]

d2_id = upsert_dashboard(dash2_name)
d2_dashcards, _ = layout_dashcards(d2_specs)
put_dashboard(d2_id, d2_dashcards)
real_cards_2 = len([s for s in d2_specs if not s.get("virtual")])
print("  dashboard id=%s  cards=%s  (+1 text panel)" % (d2_id, real_cards_2))

# ===========================================================================
# Dashboard 3 — BOD — Platform & Service
# ===========================================================================

dash3_name = "BOD — Platform & Service"
print("\n--- %s ---" % dash3_name)

d3_specs = [
    {
        "name": "GCP Top 10 Services",
        "sql": ("SELECT service_name, SUM(effective_cost_idr) AS amount\n"
                "FROM %s\n"
                "WHERE platform = 'GCP'\n"
                "GROUP BY 1\n"
                "ORDER BY 2 DESC\n"
                "LIMIT 10") % FCSM,
        "tags": {},
        "display": "row",
        "vs": bar_vs("service_name", "amount"),
        "w": 12, "h": 8,
        "is_money": False,
    },
    {
        "name": "GMP Top 10 Services",
        "sql": ("SELECT service_name, SUM(effective_cost_idr) AS amount\n"
                "FROM %s\n"
                "WHERE platform = 'GMP'\n"
                "GROUP BY 1\n"
                "ORDER BY 2 DESC\n"
                "LIMIT 10") % FCSM,
        "tags": {},
        "display": "row",
        "vs": bar_vs("service_name", "amount"),
        "w": 12, "h": 8,
        "is_money": False,
    },
    {
        "name": "Customer x Service Table",
        "sql": ("SELECT customer_name, service_name, SUM(effective_cost_idr) AS amount\n"
                "FROM %s\n"
                "GROUP BY 1, 2\n"
                "ORDER BY 3 DESC\n"
                "LIMIT 100") % FCSM,
        "tags": {},
        "display": "table",
        "vs": table_vs(money_cols=["amount"]),
        "w": 24, "h": 10,
        "is_money": False,
    },
    {
        "name": "Service Trend by Month",
        "sql": ("WITH top5 AS (\n"
                "  SELECT service_name\n"
                "  FROM %s\n"
                "  GROUP BY 1\n"
                "  ORDER BY SUM(effective_cost_idr) DESC\n"
                "  LIMIT 5\n"
                ")\n"
                "SELECT t.charge_month, t.service_name, SUM(t.effective_cost_idr) AS amount\n"
                "FROM %s t\n"
                "JOIN top5 USING (service_name)\n"
                "GROUP BY 1, 2\n"
                "ORDER BY 1, 2") % (FCSM, FCSM),
        "tags": {},
        "display": "line",
        "vs": {"graph.dimensions": ["charge_month", "service_name"],
               "graph.metrics": ["amount"],
               "column_settings": idr_col("amount")},
        "w": 24, "h": 8,
        "is_money": False,
    },
]

d3_id = upsert_dashboard(dash3_name)
d3_dashcards, _ = layout_dashcards(d3_specs)
put_dashboard(d3_id, d3_dashcards)
print("  dashboard id=%s  cards=%s" % (d3_id, len(d3_specs)))

# ===========================================================================
# Dashboard 4 — BOD — Discounts & Credits
# ===========================================================================

dash4_name = "BOD — Discounts & Credits"
print("\n--- %s ---" % dash4_name)

d4_specs = [
    {
        "name": "Discount % by Customer — rate vs all-in",
        "sql": ("SELECT customer_name,\n"
                "  ROUND((1 - SAFE_DIVIDE(SUM(contracted_cost_idr), NULLIF(SUM(gross_cost_idr), 0))) * 100, 1) AS discount_pct,\n"
                "  ROUND((1 - SAFE_DIVIDE(SUM(net_cost_idr), NULLIF(SUM(gross_cost_idr), 0))) * 100, 1) AS disc_plus_credits_pct\n"
                "FROM %s\n"
                "WHERE %s\n"
                "GROUP BY customer_name\n"
                "ORDER BY disc_plus_credits_pct DESC") % (FCM, RESOLD),
        "tags": {},
        "display": "table",
        "vs": table_vs(disc_pct_cols=["discount_pct", "disc_plus_credits_pct"]),
        "w": 24, "h": 8,
        "is_money": False,
    },
    {
        "name": "CUD Credits by Customer",
        "sql": ("SELECT customer_name, SUM(cud_credits_idr) AS cud_credits_idr\n"
                "FROM %s\n"
                "WHERE %s\n"
                "GROUP BY customer_name\n"
                "ORDER BY cud_credits_idr") % (FCM, RESOLD),
        "tags": {},
        "display": "bar",
        "vs": bar_vs("customer_name", "cud_credits_idr"),
        "w": 12, "h": 8,
        "is_money": False,
    },
    {
        "name": "Credit Type Mix by Customer",
        "sql": ("SELECT customer_name,\n"
                "  SUM(cud_credits_idr)        AS cud_credits_idr,\n"
                "  SUM(sud_credits_idr)        AS sud_credits_idr,\n"
                "  SUM(promo_credits_idr)      AS promo_credits_idr,\n"
                "  SUM(free_tier_credits_idr)  AS free_tier_credits_idr,\n"
                "  SUM(other_credits_idr)      AS other_credits_idr\n"
                "FROM %s\n"
                "WHERE %s\n"
                "GROUP BY customer_name\n"
                "ORDER BY (cud_credits_idr + sud_credits_idr + promo_credits_idr\n"
                "         + free_tier_credits_idr + other_credits_idr)") % (FCM, RESOLD),
        "tags": {},
        "display": "bar",
        "vs": {
            "graph.dimensions": ["customer_name"],
            "graph.metrics": [
                "cud_credits_idr", "sud_credits_idr", "promo_credits_idr",
                "free_tier_credits_idr", "other_credits_idr",
            ],
            "stackable.stack_type": "stacked",
            "column_settings": {
                **idr_col("cud_credits_idr"), **idr_col("sud_credits_idr"),
                **idr_col("promo_credits_idr"), **idr_col("free_tier_credits_idr"),
                **idr_col("other_credits_idr"),
            },
        },
        "w": 12, "h": 8,
        "is_money": False,
    },
    {
        "name": "CUD Coverage Rate",
        "sql": ("SELECT ROUND(\n"
                "  SAFE_DIVIDE(ABS(SUM(cud_credits_idr)), NULLIF(SUM(gross_cost_idr), 0)),\n"
                "  4\n"
                ") AS cud_coverage_rate\n"
                "FROM %s\n"
                "WHERE %s") % (FCM, RESOLD),
        "tags": {},
        "display": "scalar",
        "vs": scalar_pct_vs("cud_coverage_rate"),
        "w": 6, "h": 3,
        "is_money": False,
    },
]

d4_id = upsert_dashboard(dash4_name)
d4_dashcards, _ = layout_dashcards(d4_specs)
put_dashboard(d4_id, d4_dashcards)
print("  dashboard id=%s  cards=%s" % (d4_id, len(d4_specs)))

# ===========================================================================
# Step 3 — Verification
# ===========================================================================

print("\n" + "=" * 60)
print("STEP 3: Verify — run all card queries")
print("=" * 60)

# Collect all real card ids created across all dashboards
all_card_ids = {}
for spec in d1_specs + d2_specs + d3_specs + d4_specs:
    if not spec.get("virtual") and spec["name"] in existing_cards:
        all_card_ids[spec["name"]] = existing_cards[spec["name"]]

ok, errored = [], []
for name, cid in all_card_ids.items():
    try:
        result = api("POST", "/api/card/%s/query" % cid, {})
        status = (result or {}).get("status", "unknown")
        if status == "completed":
            ok.append((name, cid))
        else:
            errored.append((name, cid, status))
            print("  [FAIL] %r  status=%s" % (name, status))
    except Exception as ex:
        errored.append((name, cid, str(ex)))
        print("  [ERROR] %r  %s" % (name, ex))

print("\nCard execution: %s ok, %s errored" % (len(ok), len(errored)))
if errored:
    print("Failed cards:")
    for name, cid, status in errored:
        print("  - %r (id=%s): %s" % (name, cid, status))

# ===========================================================================
# Step 4 — Currency toggle verification
# ===========================================================================

print("\n" + "=" * 60)
print("STEP 4: Currency toggle — IDR vs USD")
print("=" * 60)

# GET the dashboard to find server-assigned dashcard IDs (PUT only returns the
# dashcard list with real IDs assigned by Metabase, not our temporary negatives)
toggle_card_name = "Monthly Spend Trend"
toggle_card_id = existing_cards.get(toggle_card_name)
toggle_dashcard_id = None
d1_live = api("GET", "/api/dashboard/%s" % d1_id)
if d1_live:
    for dc in d1_live.get("dashcards", []):
        if dc.get("card_id") == toggle_card_id:
            toggle_dashcard_id = dc["id"]
            break

if toggle_card_id and toggle_dashcard_id is not None:
    def run_with_currency(currency_val):
        body = {
            "parameters": [{
                "id": "cur_param",
                "target": ["variable", ["template-tag", "currency"]],
                "value": currency_val,
            }]
        }
        path = "/api/dashboard/%s/dashcard/%s/card/%s/query" % (
            d1_id, toggle_dashcard_id, toggle_card_id)
        return api("POST", path, body)

    idr_result = run_with_currency("IDR")
    usd_result = run_with_currency("USD")

    def extract_total(result):
        try:
            rows = result["data"]["rows"]
            # Sum all amount values across months
            return sum(r[-1] for r in rows if r[-1] is not None)
        except Exception:
            return None

    idr_total = extract_total(idr_result)
    usd_total = extract_total(usd_result)

    if idr_total and usd_total and usd_total != 0:
        ratio = idr_total / usd_total
        print("  IDR total: {:,.0f}".format(idr_total))
        print("  USD total: {:,.2f}".format(usd_total))
        print("  IDR/USD ratio: {:,.0f}x".format(ratio))
        if 16000 <= ratio <= 18000:
            print("  [PASS] Ratio in expected range 16,000–18,000x")
        else:
            print("  [WARN] Ratio outside expected range — check conversion rate")
    else:
        print("  [WARN] Could not compute ratio. IDR=%s  USD=%s" % (idr_total, usd_total))
else:
    print("  [SKIP] Could not locate dashcard for toggle test")

# ===========================================================================
# Step 5 — Confirm old dashboards deleted, print new URLs
# ===========================================================================

print("\n" + "=" * 60)
print("STEP 5: Confirm old dashboards gone + new dashboard URLs")
print("=" * 60)

current_finops_items = coll_items(OLD_COLL_ID, "dashboard")
found_old = [n for n in OLD_DASH_NAMES if n in current_finops_items]
if found_old:
    print("  [WARN] Still present in collection 5: %s" % found_old)
else:
    print("  [OK] All 5 legacy dashboards confirmed absent from collection 5")

print("\nNew dashboards:")
for name, did in [
    (dash1_name, d1_id),
    (dash2_name, d2_id),
    (dash3_name, d3_id),
    (dash4_name, d4_id),
]:
    print("  %-40s %s/dashboard/%s" % (name, MB, did))
