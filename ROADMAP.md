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

## Audit later — 10 unmapped billing accounts

These `Resold` accounts have no GCP org ancestry and generic project names, so they
can't be identified from the billing data alone. They roll up under `(unmapped)` until
someone maps them via internal records / billing-account contacts, then adds a row to
`dbt/seeds/customer_accounts.csv`. (7 of the original 17 were mapped from clear project
names; these 10 remain.)

| Billing account | Project-name clue | Tentative guess | Billed (IDR) |
|---|---|---|---|
| `01024A-DA4AC6-521FE3` | Google Maps - ASSET | — (generic Terralogiq template) | 4.5M |
| `016372-82F82A-433751` | Google Maps - ASSET | — | 2.8M |
| `01E694-82D7A8-8D1B54` | Google Maps - ASSET | — | 0 |
| `019DF5-F95405-3773A9` | Development, GIS-Production, Google Maps - ASSET | — | 1.6M |
| `019A1C-D1998E-36F507` | Singapore | — | 4.2M |
| `012371-B03D2A-4E7036` | My First Project | — | 2.4M |
| `018509-728291-1E9D08` | My Maps Project | — | 0 |
| `0196E4-9FB915-0858AD` | Mobile Collections/Order Survey VMF | a "VMF" multifinance? | 0 |
| `01D242-BD6EC9-40FFE4` | Eureka Online, Masterdiskon, RajaCepat | one PPOB/fintech group? | 990k |
| `010862-0E26CE-CE7B57` | Combi-Portal | Combiphar? | 0 |

Note: `"Google Maps - ASSET"` appears across several accounts and looks like a standard
Terralogiq project-provisioning name (a product, not a customer) — resolve via records.

## Operational notes

- **Seed upkeep:** new customer → add a row to `dbt/seeds/customer_accounts.csv` →
  `dbt seed && dbt run`. The `assert_no_unmapped_resold_accounts` test (currently
  `severity: warn`) surfaces gaps; flip it to `error` once the 17 currently-unmapped
  accounts are mapped.
- **Growth views:** MoM/QoQ columns stay NULL until a second month of billing data
  accrues (first export month is 2026-07); they populate automatically thereafter.
