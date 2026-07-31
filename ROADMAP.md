# FinOps Partner BOD Dashboard — Roadmap

Deferred features beyond the v1 partner/reseller BOD dashboard. v1 delivered: a
customer- and platform-aware dbt model (`fct_customer_monthly`,
`fct_customer_service_month`) with hybrid customer mapping (`int_customer_map` +
`seeds/customer_accounts.csv`), IDR/USD dual currency, and four Metabase BOD
dashboards (Executive Summary, Customer Leaderboard, Platform & Service,
Discounts & Credits).

## Deferred (post-v1)

- **Anomaly detection** — flag customers/accounts whose spend exceeds ~2σ over their
  trailing mean. Needs ≥3 months of history to be meaningful.
- **CUD wastage / coverage visualization** (Ternary-style) — committed-usage purchased
  vs. applied, with unutilized-commitment highlighting. Requires commitment-purchase
  data joined against credit coverage.
- **Commitment recommendations** — model optimal CUD size/term per customer. Depends on
  ≥3 months of stable usage and a cost-modeling layer.
- **Margin / markup layer** — reseller markup (resold price vs. Terralogiq's cost) per
  customer for P&L reporting. Requires contractual markup rates per customer; out of
  scope for a read-only v1.
- **Scheduled BOD email** — auto-deliver a monthly PDF/HTML snapshot. Metabase
  subscriptions are the mechanism; needs SMTP config and a template.
- **Customer-facing portal** — per-customer read-only views with row-level security so
  each customer sees only their own spend. Requires Metabase multi-tenant sandboxing and
  an auth handoff — significant infrastructure work.

## Audit later — ~37 unmapped billing accounts

`Resold` accounts that resolve to `(unmapped)` because they can't be identified from
the billing data alone. Map them via internal records / billing-account contacts, then
add/complete rows in `dbt/seeds/customer_accounts.csv` and run `dbt seed && dbt run`.

Two groups:
1. **No org ancestry, generic project names** (the original ~10): `"Google Maps - ASSET"`
   (a Terralogiq provisioning template, appears on several accounts — a product, not a
   customer), `"Singapore"`, `"My First Project"`, `"My Maps Project"`, plus tentative
   guesses like VMF (a multifinance), Eureka/Masterdiskon, Combi-Portal.
2. **Reseller-org false-positives** (27 accounts): their projects are hosted under
   Terralogiq's own `terralogiq.com` GCP org, so org-ancestry named them "terralogiq.com"
   even though they are distinct customers. `int_customer_map` now nulls out the
   reseller's own org (see its header), so these correctly fall to `(unmapped)`. 38 of the
   65 were mapped from clear project-name evidence (BRI, Telkomsel, Pemprov DKI, Kemenkeu,
   PLN, PELNI, BPJS-TK, Alfamidi, SCTV, Ajinomoto, …); the rest need records.

Regenerate the current unmapped list any time with:
```sql
SELECT billing_account_id FROM `gcp-coe-492507.dbt_intermediate.int_customer_map`
WHERE customer_name = '(unmapped)' AND billing_account_type = 'Resold';
```

**Seed hygiene:** keep `customer_name` identical for every row sharing a `customer_id`
(the leaderboard groups by name); mixing e.g. "Bank BRI" and "bbri.id" under one
`customer_id` splits the customer into two rows.

## Operational notes

- **Seed upkeep:** new customer → add a row to `dbt/seeds/customer_accounts.csv` →
  `dbt seed && dbt run`. The `assert_no_unmapped_resold_accounts` test (currently
  `severity: warn`) surfaces gaps; flip it to `error` once the 17 currently-unmapped
  accounts are mapped.
- **Growth views:** MoM/QoQ columns stay NULL until a second month of billing data
  accrues (first export month is 2026-07); they populate automatically thereafter.
