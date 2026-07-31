# Metabase Dashboard Builder

`build_dashboards.py` is an idempotent script that builds the Terralogiq BOD dashboards
in the self-hosted Metabase instance via its REST API.

## Prerequisites

- Python 3.9+
- API key at `~/.config/finops-mb-api-key`
- Metabase running at `https://34.101.217.143` (self-signed cert; TLS verification is
  disabled in the script)
- BigQuery mart tables populated:
  - `finops_dbt.fct_customer_monthly`
  - `finops_dbt.fct_customer_service_month`

## Usage

```bash
python metabase/build_dashboards.py
```

The script is safe to re-run: it upserts cards and dashboards by name.

## What it does

1. **Deletes** the 5 legacy "FinOps — *" dashboards and their orphaned cards.
2. **Creates** (or updates) a "Terralogiq BOD" collection with 4 dashboards:
   - BOD — Executive Summary
   - BOD — Customer Leaderboard
   - BOD — Platform & Service
   - BOD — Discounts & Credits
3. **Verifies** every card by running `POST /api/card/:id/query` and reports a pass/fail
   count.
4. **Verifies the currency toggle** by querying the "Monthly Spend Trend" dashcard twice
   (IDR and USD) and asserting the IDR/USD ratio is in the 16,000–18,000x range.

## Currency toggle

Every money card has a `{{currency}}` template tag (default `IDR`). Each dashboard has a
"Currency" filter parameter wired to all money dashcards. Switch between IDR and USD in
the Metabase UI or via the API.

IDR cost columns are formatted as compact currency (Rp X.XB). USD columns use the dollar
symbol.

## Data scope

All customer dashboards filter `billing_account_type = 'Resold'`, which excludes the
Terralogiq reseller account from customer metrics.

## Adding cards or dashboards

Define a new entry in the `d1_specs` / `d2_specs` / `d3_specs` / `d4_specs` list using
the same dict schema, then re-run the script. To add a new dashboard, call
`upsert_dashboard()`, build specs, call `layout_dashcards()`, and `put_dashboard()`.
