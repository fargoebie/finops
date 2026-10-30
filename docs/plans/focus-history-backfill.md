# Plan: FOCUS history backfill (Jan 2026 → today)

Status: **executed 2026-10-30**; steps 2-7 done, step 8 docs done. Open items listed in the handoff (Nanda READER grant, `int_customer_map` nondeterminism, `fct_credit_runway` windows, 2028 partition expiry). No Beads DB in this repo, so this file is the tracker and the handoff.

## Goal

Every dbt mart, Metabase dashboard and ad-hoc query covers **2026-01-01 → today with no gaps** (user priority is 2026 only, decided 2026-10-30). Today they start at 2026-07-26.

Done means:
- `stg_focus_billing` reads one gap-free, FOCUS-shaped source.
- The `dbt build` reconciliation test passes at **zero difference** (|Δ| < Rp 0.01) for each account × month × charge type × service in the overlap window.
- The marts show monthly totals from Jan 2026 onward.

## Why

The FOCUS export (`terra-coe-finops.gcp_billing_immutable_01A09A_A37EA6_F0AC6C_asia_southeast2.gcp_billing_export_focus_01A09A_A37EA6_F0AC6C`) was enabled around 2026-07-25 and does not backfill:

| FOCUS date range | Content |
|---|---|
| 2026-07-01 | Month-start Tax/Adjustment rows only |
| 07-02 → 07-19 | **No rows** |
| 07-20 → 07-24 | Near-zero ramp-up |
| 07-25 | Partial (~75% of a normal day) |
| **07-26 →** | Complete |

The history lives in the detailed (resource-level) export:
- Table: `terralogiq-billing-export-new.tes_billing_export.gcp_billing_export_resource_v1_01A09A_A37EA6_F0AC6C`
- Region: **asia-southeast1**
- Coverage: gap-free from **2025-08-28** (Aug 2025 otherwise holds only 08-01 tax/rounding rows), so Sept 2025 is the first full month.
- Size: 709M rows, 915 GB.
- Also in that dataset: a standard export (from 2025-10-01) and `cloud_pricing_export`.

## Source survey of `terralogiq-billing-export-new` (2026-10-30)

All billing tables are in asia-southeast1 and in IDR.

| Table | Live? | Usage range | Verdict |
|---|---|---|---|
| `tes_billing_export.gcp_billing_export_resource_v1_01A09A_A37EA6_F0AC6C` | **Yes**: created 2025-10-01, last modified today, `export_time` up to 10-29 23:58 | gap-free from 2025-08-28 | **Use** for 2025-09-01 → cutover |
| `tes_billing_export.gcp_billing_export_v1_01A09A_A37EA6_F0AC6C` | Yes | from 2025-10-01 | Redundant with the detailed export |
| `tes_billing_export_try.gcp_billing_export_v1_01A09A_A37EA6_F0AC6C_copy` | **No**: frozen snapshot from 2025-10-07 | 2020-03-27 → 2025-10-06, no gaps after that start | Optional pre-Sept-2025 extension. Sept 2025 cost, credits and list match `gcp_billing_export_resource_v1_01A09A_A37EA6_F0AC6C` **exactly** |
| `tes_billing_export_try.gcp_billing_export_v1_01E5F4_66804E_8286B7` | No | same | Byte-identical duplicate of `_copy` (same row count and range) |
| `tes_billing_export_details_try.gcp_billing_export_resource_v1_01E5F4_66804E_8286B7` | No | 2025-07-01 → 10-06 | **Don't use.** Sept 2025 is 2× the other sources and July is partial |

Schemas (flattened field paths, types compared): the three `gcp_billing_export_v1_*` tables are identical (76 paths). `gcp_billing_export_resource_v1_*` adds `resource.{global_name,name}` and `subscription.instance_id`. The live one also has `consumption_model.applied_subscription_instance_id` (82 paths vs 81). No type conflicts.

Caveats on `gcp_billing_export_v1_01A09A_A37EA6_F0AC6C_copy`:
- `cost_at_list` is NULL for all rows before 2023-07, so Discount % is undefined before 2023-08.
- It has no resource columns.
- It never gets late corrections.
- It lives in someone's `_try` scratch dataset. Copy it soon if it's wanted.

Also: the FOCUS export table has **730-day partition expiration** (ingestion-time). FOCUS rows start aging out on 2028-07-25, so the marts will need a similar frozen snapshot eventually.

## Evidence the sources agree (verified 2026-10-30)

Overlap window 2026-07-26 → 10-28, grouped by `(billing account, month, charge type, service)`:
- **3,553 groups in each source**, and every group exists in both.
- Charge types map 1:1: `USAGE`↔`regular`, `TAX`↔`tax`, `ADJUSTMENT`↔`adjustment`, `ROUNDING`↔`rounding_error`.
- **List, contracted, billed and credits match to < Rp 0.0001** for July 26–31, August, September and Oct 1–27. The leftover is NUMERIC summation noise.
- Only **10-28** differed (Rp 26K list out of Rp 79.8B). That day was still being revised; FOCUS refreshed 26 minutes after the detailed export. **Exclude the most recent 3 days from any reconciliation.**
- Row counts differ (FOCUS 390M vs 257M), because FOCUS splits rows more finely. Compare sums, never row counts.

Money mapping, proven exact:

| FOCUS | Detailed export |
|---|---|
| `ListCost` | `cost_at_list` |
| `ContractedCost` | `cost` |
| `BilledCost` (= `EffectiveCost`) | `cost + SUM(credits.amount)` |
| `x_Credits` (Name, Amount, FullName, Id, Type) | `credits` (name, amount, full_name, id, type) |
| `BillingAccountId` | `billing_account_id` (the sub-account) |
| `ChargePeriodStart` | `usage_start_time` |

## Design

```
gcp-coe-492507 (asia-southeast2)
  finops_history.resource_export_raw      TABLE  cross-region `bq cp` of the detailed export (708.9M rows)
  finops_history.focus_billing_history    TABLE  frozen; [2026-01-01, 2026-10-01); FOCUS schema; partitioned DATE(ChargePeriodStart), clustered BillingAccountId, ServiceName
          |
  stg_focus_billing:  history (< cutover)  UNION ALL  focus_export (>= cutover)
```

- Dataset `finops_history` uses PHYSICAL storage billing. One history table; its post-cutover rows double as the reconciliation fixture.

- **Cutover = `2026-07-26`.** It goes in a dbt var `focus_cutover_date`. Each day comes from exactly one source.
  - July's month-start Tax rows (dated 07-01) come from history.
  - FOCUS rows dated before 07-26 are dropped, so nothing is counted twice.
- **Identical schema:** create with `CREATE TABLE … LIKE <focus_export>`, then `INSERT … SELECT <mapped columns>`. That makes `UNION ALL` type-safe, nested `x_Credits`/`x_Project`/`x_Tags` included, and `stg_focus_billing` keeps its column list unchanged.
- **The history table is frozen.** New months arrive through the live FOCUS side. If Google posts late corrections to pre-cutover months, rebuild once; no schedule is needed.
- **Datasets are created by script, not OpenTofu.** This matches `finops_dbt`; no BigQuery datasets are under `infra/` today.

## Steps

1. **Pre-flight (needs the user).**
   - Confirm who owns `terralogiq-billing-export-new`, and that `tes_billing_export` is the export actually configured under Billing → Billing export for `01A09A-A37EA6-F0AC6C`, not a one-off copy.
   - Confirm the user accepts a one-time cross-region copy cost.
2. **Copy raw across regions** (`tools/history_backfill/01_copy.sh`): `bq cp` the detailed export into `finops_history.resource_export_raw` (asia-southeast2). No se1 staging dataset. Row count (708,864,848) and SUM(cost) match the source. Gotchas: no `--location` (gives "Not found: Dataset"); the copy prompts interactively, so the script passes `-n`.
3. **Convert** (`02_convert.sql`): build `focus_billing_history` from the raw copy for `[2026-01-01, 2026-10-01)`: 479,594,030 rows, partitioned by `DATE(ChargePeriodStart)`, clustered on `BillingAccountId`, `ServiceName`, schema identical to the FOCUS export. Rows from the cutover on serve as the test fixture; there is no overlap table.
4. **Map columns and check schema.** Mapping and the NULL list for FOCUS-only fields (`CommitmentDiscount*`, `ContractedUnitPrice`, `x_ConsumptionModel*`, `x_ExportTime`) are in the README; `check_schema.py` confirms the schema matches. Only inexact mart-path column: `PricingQuantity` (up to 2.2% high for `hour` units); no mart reads it.
5. **dbt.**
   - Source `finops_history` (table `focus_billing_history`); var `focus_cutover_date: '2026-07-26'`.
   - `stg_focus_billing` = history (< cutover) UNION ALL live FOCUS (>= cutover).
   - Test `assert_history_matches_focus_overlap.sql`: cost grain (account, sub-account, month, category, service; list/contracted/billed/credits within 0.01 IDR, billed USD within 0.001) and credit grain (account, month, credit type, id), with a compile guard on the cutover.
6. **Seeds.** 17 churned Resold accounts added to `customer_accounts.csv`, 21 promotion credits to `credit_programs.csv`, clearing the warnings the longer history introduced.

## File ownership

| File | Change | Step |
|---|---|---|
| `tools/history_backfill/01_copy.sh` | new: cross-region `bq cp` | 2 |
| `tools/history_backfill/02_convert.sql` | new: build `focus_billing_history` | 3-4 |
| `tools/history_backfill/check_schema.py` | new: history schema == FOCUS schema | 4 |
| `tools/history_backfill/README.md` | new: runbook, column mapping, NULL list | 4 |
| `dbt/models/staging/sources.yml` | add `finops_history` source | 5 |
| `dbt/models/staging/stg_focus_billing.sql` | `from` -> cutover union | 5 |
| `dbt/models/staging/schema.yml` | doc update | 5 |
| `dbt/dbt_project.yml` | add `vars: focus_cutover_date` | 5 |
| `dbt/tests/assert_history_matches_focus_overlap.sql` | new | 5 |
| `dbt/seeds/customer_accounts.csv` | +17 churned Resold accounts | 6 |
| `dbt/seeds/credit_programs.csv` | +21 promotion credits | 6 |
| `.gitignore` | modified | 6 |
| `AGENTS.md`, `HANDOFF.md` | coverage and source docs | 8 |

## Reference numbers (for verification)

BRI GCP 5 (`01319C-C0F533-768FB2`) monthly billed, usage only, from the detailed export (Rp M):

| Feb* | Mar | Apr | May | Jun | Jul | Aug | Sep | Oct 1–29 |
|---:|---:|---:|---:|---:|---:|---:|---:|---:|
| 261.2 | 3,625.1 | 3,970.5 | 4,947.8 | 6,359.3 | 8,158.9 | 9,951.7 | 10,389.3 | 11,490.1 |

\* BRI5 starts 2026-02-26, when `app-brimo-prd-01` moved over.

## Risks

- **Mart query cost and latency:** staging and marts are views, so the union roughly quadruples the rows scanned per Metabase query. If dashboards slow down, materialize `stg_focus_billing` (or `int_charges`) as a partitioned table.
- **`terralogiq-billing-export-new` belongs to someone else and feeds their dashboards** (PLN, Pegadaian, BRI, SPE). Treat it as read-only. If it ever disappears, nothing breaks after step 4, because the history is already copied.
- **Stale assumptions:** any mart logic that assumes data starts in July (MoM NULLs, `fct_credit_runway` windows) needs re-checking with the longer history.

## Handoff: resume here

- **Executed 2026-10-30** (see Status). Source accepted as the live export on circumstantial evidence (rows through 10-29, still being revised); cost approved (source 29.5 GB physical, 915 GB logical).
- **Scope:** history starts **2026-01-01**; source is `tes_billing_export.gcp_billing_export_resource_v1_01A09A_A37EA6_F0AC6C` only. The `_try` tables are out of scope.
- **July 1-25 pre-cutover check:** Tax identical in both sources (Rp 2,176.872M, 450 rows). Usage is Rp 19,913M in the detailed export vs 413M in FOCUS, which confirms the FOCUS gap. The detailed export's -Rp 155,933 adjustment on `01A09A` is supplied by history.
- **Step 7 evidence:**
  - `dbt build`: PASS=50, WARN=0, ERROR=0.
  - Fan-out: `fct_customer_monthly` and `fct_spend_waterfall` monthly billed equal `int_charges`, delta 0, every month Jan-Oct 2026.
  - BRI5 usage billed matches the reference table exactly for Feb-Sep.
  - July 2026 is Rp 22.049B; genuine, the raw detailed export agrees exactly.
  - No NULL `ChargePeriodStart` in either source.
  - Metabase spot-check not possible: `finops-vm` is stopped after the CVE-2026-72898 breach, pending rebuild.
- **Seeds:** 17 churned Resold accounts added to `customer_accounts.csv`, 21 promotion credits to `credit_programs.csv` (clears the two warnings from the longer history).
- **Deployment order:** don't deploy the dbt changes to the VM before `focus_billing_history` exists; `stg_focus_billing` fails without it.
- **Open items:**
  - `int_customer_map.observed` uses `any_value(billing_account_type)`; `01A09A` has NULL and `'Reseller'` rows, so it can resolve nondeterministically (existing bug).
  - `fct_credit_runway.applied_to_date_idr` now sums observed history back to 2026-01; check the runway/burn windows still behave as intended.
  - FOCUS export partitions expire after 730 days; rows start aging out 2028-07-25, so the history table will need to absorb them.
- **Auth:** gcloud and ADC expire about hourly. The user runs `! gcloud auth login` (and `! gcloud auth application-default login` for dbt). Always pass `--project_id=gcp-coe-492507` to `bq`.
- **Cross-region:** a single query can't join `terralogiq-billing-export-new` (asia-southeast1) with anything in asia-southeast2, including `finops_dbt.billing_accounts`. Join results in Python.
- **Session deliverables (untracked, not committed):**
  - `finops-data-access.md`: Nanda's access guide, with the coverage line fixed to 26 July.
  - `project-renames-2026-10-29.md`: 13 display-name renames to `PGD-*`, with revert commands.
  - `bri-gcp5-sku-waterfall-2026-09.csv`, `bri-gcp5-product-discounts-2026-09.csv`.
- **Open questions from the session:**
  - Should Nanda get `roles/billing.viewer` on `01A09A-A37EA6-F0AC6C`? Not granted; it would expose every customer's invoices.
  - Should `01E5F4-66804E-8286B7` (Pegadaian Credit) be added to `dbt/seeds/billing_accounts.csv`? The seed is generated by `scripts/refresh_billing_accounts.sh`, so re-run that rather than hand-editing.
  - Should the PLN/GG/CoE projects be re-linked off the Pegadaian Credit account?
- **Nanda's access (verified):** `roles/bigquery.jobUser` and `roles/serviceusage.serviceUsageConsumer` on `gcp-coe-492507`; READER on `finops_dbt`, `dbt_staging`, `dbt_intermediate` and the linked FOCUS dataset (table-level grants aren't possible there), and `finops_history` (granted 2026-10-30).
