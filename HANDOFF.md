# HANDOFF.md — Session-to-session gotchas

Architecture and instructions live in [AGENTS.md](AGENTS.md). Deferred/future work lives in [ROADMAP.md](ROADMAP.md). This file holds non-obvious operational knowledge learned the hard way.

---

## Auth (gcloud / ADC)

- gcloud + ADC tokens expire frequently. Re-auth with **both**:
  ```bash
  gcloud auth login
  gcloud auth application-default login
  ```
  dbt and direct `bq` calls both use ADC — one without the other will fail.
- `gcloud auth login` resets the active project to `demogcp-terra2021`. Reset immediately:
  ```bash
  gcloud config set project gcp-coe-492507
  ```
  Always pass `--project=gcp-coe-492507` to `bq` commands explicitly rather than relying on the active project config.

---

## BigQuery query gotchas

- `bq query` defaults to `--max_rows=100`. Pass `--max_rows=10000` (or higher) when counting or listing rows — silent truncation has hidden discrepancies before (e.g. a 108-vs-100 account count that looked correct at the default limit).
- `rows` is a reserved word in BigQuery SQL. Alias row-count aggregates as `n_rows` or similar.

---

## FOCUS data semantics

- Multi-customer **reseller** export: `BillingAccountType` = `Resold` (107 customer accounts) or `Reseller` (1 — Terralogiq itself, a GCP + GMP partner).
- **Credits are embedded in usage rows** (`x_Credits`, UNNEST in `int_credits`), NOT as separate charge rows. `BilledCost` and `EffectiveCost` are already net of credits (`billed = contracted + credits`; `effective = billed` in this data). Never subtract credits from billed a second time (see "Cost & discount semantics" in AGENTS.md).
- Everything is **IDR**; USD is derived row-level (`cost / x_CurrencyConversionRate ≈ 17,922`).
- Only **one month** of data so far (export enabled ~2026-07-25; data = 2026-07). MoM/QoQ comparisons return NULL until August arrives. FOCUS exports do not backfill months prior to enablement.

---

## Customer mapping pitfalls

- **Org-ancestry is unreliable as a customer identifier.** Terralogiq hosts ~65 customers' projects under its own org (`terralogiq.com`), so ancestry lookups produce false-positives (collapsing distinct customers), not just nulls. `int_customer_map` nulls out the reseller's own org; `dbt/seeds/customer_accounts.csv` is the authoritative override.
- Keep `customer_name` identical for every row sharing a `customer_id` — the leaderboard groups by name, so mixed spellings (e.g. "Bank BRI" vs "bbri.id") split the same customer across rows.
- ~37 accounts are currently `(unmapped)`. See ROADMAP.md for mapping instructions.

---

## Correctness / verification discipline

Lessons from a 6-bug audit — don't repeat these:

- **Reconcile mart absolute totals against source**, not just internal consistency. "GCP + GMP = total" passed while everything was ~2× inflated. Known-good targets (Resold accounts, July 2026): net ≈ Rp 2.95B, credits ≈ −Rp 395M.
- **Watch for fan-out.** `SELECT DISTINCT` over NULL-varying columns, and joins at mismatched grain, both silently multiplied rows (~2× and ~4×). Enforce one-row-per-key and check row counts after each model.
- Discount aggregation: always **ratio-of-sums** (`SUM(billed) / SUM(list)`), never `AVG` of per-row percentages.

---

## Metabase build

- Dashboards are code: `metabase/build_dashboards.py` — idempotent, auth via `x-api-key` read from `~/.config/finops-mb-api-key`, self-signed TLS (cert verification disabled in the script).
- Metabase v0.63, 24-col grid. Dashcards are placed/sized via `PUT /api/dashboard/:id`.
- **Currency toggle:** implemented via a `{{currency}}` template tag (IDR default). Percent columns: SQL already outputs the value ×100 — format as **decimal + "%" suffix**, NOT `percent` number_style (which multiplies by 100 again, producing "2100%").
- Live dashboards are in the **"Terralogiq BOD"** collection (dashboards 7–10). They query the marts live — a `dbt run` refreshes them without rebuilding the dashboards.

---

## Local dbt quickstart

Use the repo `.venv` (dbt-bigquery 1.12):

```bash
python3 -m venv .venv && .venv/bin/pip install dbt-bigquery
source .venv/bin/activate
```

Export the five `DBT_*` env vars (see AGENTS.md "Local development"), then:

```bash
cd dbt
dbt seed && dbt run && dbt test
```

Profile method is `oauth` (ADC). Ensure `gcloud auth application-default login` is current before running.
