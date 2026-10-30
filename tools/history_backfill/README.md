# FOCUS history backfill

Gives the marts a gap-free history from **2025-01-01** by converting Terralogiq's billing exports into the exact
schema of the *FOCUS* export, which only has complete data from 2026-07-26: the *detailed* (resource-level)
export for 2025-09-01 onward and a frozen *standard* export for 2025-01-01 to 2025-08-31.
Plan and rationale: `docs/plans/focus-history-backfill.md`.

**Status:** copy and convert executed 2026-10-30; extended back to 2025-01-01 the same day.
`resource_export_raw` has 708,864,848 rows and matched the source on SUM(cost). `standard_export_raw` has
110,599,166 rows and matched the source on rows and SUM(cost) over the whole table.
`focus_billing_history` has 630,472,288 rows (2026 part unchanged: 479,594,030 rows, same sums).
`dbt build` after the extension: PASS=48, WARN=2, ERROR=0 (50 nodes). The overlap test passes. The two WARNs are
`assert_no_unmapped_resold_accounts` (27 accounts) and `assert_all_promo_credits_seeded` (25 credits); every one of
them exists only in 2025 (no row from 2026-01-01), none is seeded yet. `dbt build` scanned ~7.1 TB: the marts are
views, so each of the ~40 data tests rescans the whole history table (150-260 GB each).

```
terralogiq-billing-export-new.tes_billing_export.gcp_billing_export_resource_v1_01A09A_A37EA6_F0AC6C  (asia-southeast1, live, 915 GB logical)
terralogiq-billing-export-new.tes_billing_export_try.gcp_billing_export_v1_01A09A_A37EA6_F0AC6C_copy  (asia-southeast1, frozen 2025-10-07, 65 GB logical)
        │  01_copy.sh  (bq cp, cross-region, kept; the standard copy runs with VERIFY_FULL=1)
        ▼
gcp-coe-492507:finops_history  (asia-southeast2, PHYSICAL storage billing)
  resource_export_raw           detailed export, used for usage >= 2025-09-01   ({{SRC_DETAIL}})
  standard_export_raw           standard export, used for 2025-01-01 <= usage < 2025-09-01   ({{SRC_STANDARD}})
        │  02_convert.sql  (one CREATE, one mapping body; `src` CTE unions the two at 2025-09-01)
        ▼
  focus_billing_history   2025-01-01 <= usage_start_time < 2026-10-01   frozen
                          rows < cutover (2026-07-26): read by stg_focus_billing
                          rows >= cutover: overlap the live FOCUS export, TEST FIXTURE ONLY
        │
stg_focus_billing = history (ChargePeriodStart < cutover)  UNION ALL  FOCUS export (>= cutover)
```

`bq cp` must not pass `--location`: pinning the job to the destination region makes bq report the source dataset
"Not found". `01_copy.sh` calls `bq cp -n` (no_clobber; `-f` was dropped).

The cutover `2026-07-26` is **UTC midnight** and lives in `dbt/dbt_project.yml` (`focus_cutover_date`).
`stg_focus_billing` filters the history table to `ChargePeriodStart < cutover`, so the rows from the cutover to
2026-10-01 never reach the marts; `assert_history_matches_focus_overlap` reads exactly those rows and compares
them with the live FOCUS export. `check_schema.py` fails if the cutover is not inside the table's window.

## Runbook

Order matters; each step is safe to stop after.

| # | Step | Command | Cost / effect |
|---|------|---------|---------------|
| 0 | **Pre-flight (needs the user)**: confirm `tes_billing_export` is the export configured in Billing, not a one-off copy (plan step 1). | | |
| 1 | Schema check (dry-run only). Must print `OK` and exit 0. | `python3 tools/history_backfill/check_schema.py` | free |
| 2 | Create dataset, copy both raw tables, verify | `tools/history_backfill/01_copy.sh`, then the same with `SRC_DATASET=tes_billing_export_try SRC_TABLE=gcp_billing_export_v1_01A09A_A37EA6_F0AC6C_copy RAW_TABLE=standard_export_raw VERIFY_FULL=1` | cross-region transfer for ~30 GB + ~4 GB physical; verify scans ~6 GB per side (detailed), the cost column of 65 GB (standard) |
| 3 | Build the history table | see below | one statement, scans ~0.94 TB (dry-run: 944.7 GB) |
| 3b | One-off seam check of 2025-09-01 (must print `pass = true` on both rows; result recorded below) | `bq --project_id=gcp-coe-492507 --location=asia-southeast2 query --nouse_legacy_sql < tools/history_backfill/03_seam_check_2025.sql` | scans ~12 GB |
| 4 | dbt | `cd dbt && dbt build` | `assert_history_matches_focus_overlap` must pass; the overlap test itself scans most of the FOCUS export (~22 GB), but the whole build scanned ~7.1 TB on 2026-10-30 (the marts are views and ~40 data tests each rescan the history table) |
| 5 | Grant READER on `finops_history` to human analysts (e.g. Nanda). The VM SA should already read it through its project-level `bigquery.dataViewer` (AGENTS.md B3); confirm. | | |

**Deployment order.** The dbt changes (`stg_focus_billing`, `sources.yml`) reference the history table. Merge or
deploy them only after step 3 has created `focus_billing_history`; before that, `dbt run`
fails at `stg_focus_billing` and takes the downstream DAG (and the VM's daily cron) with it.

Step 3:

```bash
sed -e 's|{{SRC_DETAIL}}|`gcp-coe-492507.finops_history.resource_export_raw`|g' \
    -e 's|{{SRC_STANDARD}}|`gcp-coe-492507.finops_history.standard_export_raw`|g' \
    tools/history_backfill/02_convert.sql \
  | bq --project_id=gcp-coe-492507 --location=asia-southeast2 query --nouse_legacy_sql
```

`CREATE OR REPLACE` makes step 3 re-runnable; it is also the way to rebuild after Google posts late
corrections to pre-cutover months (re-run `01_copy.sh` against a fresh copy first, after `bq rm -t` of the old one;
the standard export is frozen, so only the detailed copy has late corrections to pick up).
The raw tables' `usage_start_time` cannot prune (partitions are by ingestion time), so the statement scans
both whole copies: 944.7 GB in the dry-run (882 GB detailed + 65 GB standard).

`01_copy.sh` runs `bq cp` through a cross-region confirmation prompt (`Proceed with cross-region copy? [y/N]`),
which reads stdin: pipe `echo y |` into it when it runs unattended. `VERIFY_FULL=1` drops the
`_PARTITIONTIME < cutoff` filter and compares the whole table; use it for the frozen standard copy.

**Auth.** `gcloud auth login` (for `bq`) and `gcloud auth application-default login` (for dbt) expire about
hourly. Every `bq` call passes `--project_id=gcp-coe-492507`. Required: Data Viewer on the source dataset; on
`gcp-coe-492507`, rights to create a dataset plus Data Editor and Job User.

**One-way door.** `bq mk --storage_billing_model=PHYSICAL` cannot be switched back for 14 days.

**If cross-region `bq cp` is refused** (partitioned source, org policy): stage then copy. In asia-southeast1,
`CREATE TABLE <se1_stage_dataset>.resource_export_raw AS SELECT * FROM <source>` into a throwaway dataset (a
plain table copies cross-region without the partitioning question), then `bq cp` that table to
`finops_history.resource_export_raw` and drop the stage. Alternative: `bq extract` to a GCS bucket and `bq load`
in asia-southeast2. Not scripted; the checks in `01_copy.sh` still apply (the stage should keep
`_PARTITIONTIME` or the script's cutoff query must be changed to `usage_start_time`).

## How the mapping was established

For every FOCUS column the detailed-export source was found and then **compared against the real FOCUS rows**
(read-only queries; both sides aggregated by the value of each converted column, then diffed in Python).
Because FOCUS splits rows more finely than the detailed export, only sums are comparable, never row counts.

* **2026-09-15 usage day** (rows ingested 09-15..09-17, ~3.5M FOCUS rows): 55 dimension columns compared
  (every low/medium cardinality converted column, credits by type/name/id, label keys, `x_Project.Ancestors`,
  `ResourceId`). Per-value `BilledCost` difference was **0.0** for every column except `PricingCategory`.
  List, contracted, effective and pricing-currency cost, `ConsumedQuantity` and the `x_CostAt*` columns also match
  per account / category / unit; `PricingQuantity` does not.
* **2026-09-01 and 2026-08-01** (month-start tax/adjustment/rounding rows, `BillingPeriod*` boundaries,
  reseller account): same result, again only `PricingCategory` differs.
* **ChargeClass `correction`** on usage rows (price corrections landing 7 days late): 19 rows / -4,989 on both sides.
* **Price columns** (`SkuPriceId`, `ListUnitPrice`, `ContractedUnitPrice`, `x_PriceEffectivePriceDefault`,
  `x_PriceListPriceConsumptionModel`, 3,579 distinct account/SKU/price tuples on 2026-09-15): identical sets.
* **USD** (derived row-level in staging from `x_CurrencyConversionRate`): billed and list USD identical per
  rate for 2026-07-26..10-19, four rates.
* Money (list, contracted, billed, credits) matches the plan's reconciliation to < Rp 0.0001.

## Column mapping

All 55 FOCUS export columns, in output order. `s` is the detailed-export row; `bq show --schema` of the FOCUS
table is the reference (`check_schema.py` enforces name, type, mode, order and nested field names).

| FOCUS column | Source / rule | Exact? |
|---|---|---|
| `AvailabilityZone` | `location.zone` (`''` vs NULL preserved) | yes |
| `BilledCost` | `CAST(cost) + COALESCE(SUM(CAST(credits.amount)), 0)`, NUMERIC arithmetic. Credits are already inside billed, see AGENTS.md | yes |
| `BillingAccountId` | `billing_account_id` | yes |
| `BillingCurrency` | `currency` (always IDR) | yes |
| `BillingPeriodStart` | `TIMESTAMP(PARSE_DATE('%Y%m', invoice.month), 'America/Los_Angeles')`. Follows the *invoice* month, not the usage month: late-July usage can carry 2026-08-01 | yes for Jul-Oct (PDT, 07:00Z). **Unverifiable for PST months**, see caveats |
| `BillingPeriodEnd` | same zone, `LAST_DAY` of the invoice month (FOCUS uses the last day's midnight, 2026-09-30 07:00Z, not Oct 1) | as above |
| `ChargeCategory` | `cost_type`: regular→Usage, tax→Tax, adjustment→Adjustment, rounding_error→Adjustment; anything else → NULL (trips the dbt `not_null`/`accepted_values` tests) | yes |
| `ChargeClass` | `'correction'` (lower case) iff `adjustment_info.type IS NOT NULL`, else NULL. Covers `PRICE_CORRECTION`, `INVOICE_CORRECTION`, `GENERAL_ADJUSTMENT` (seen in the overlap window) and `GOODWILL`, `USAGE_CORRECTION` (seen only before July, so untestable against FOCUS) | yes |
| `ChargeDescription` | `sku.description` | yes |
| `ChargePeriodStart` | `usage_start_time` | yes |
| `ChargePeriodEnd` | `usage_end_time` | yes |
| `ConsumedQuantity` | `CAST(usage.amount AS NUMERIC)` | yes |
| `ConsumedUnit` | `usage.unit` | yes |
| `ContractedCost` | `CAST(cost AS NUMERIC)` | yes |
| `ContractedUnitPrice` | `price.effective_price` (the plan said NULL; the source exists and matches) | yes |
| `ListCost` | `CAST(cost_at_list AS NUMERIC)` (NULL on tax/adjustment/rounding rows, as in FOCUS) | yes |
| `ListUnitPrice` | `price.list_price` | yes |
| `PricingCategory` | NULL unless `cost_type='regular'`; `'committed'` if `sku.description` starts with `Commitment v1` **or** a credit of type `COMMITTED_USAGE_DISCOUNT` exists; else `'standard'` | **no, heuristic**, see caveats |
| `PricingQuantity` | `CAST(usage.amount_in_pricing_units AS NUMERIC)` | **no**, sums differ from FOCUS, see caveats |
| `PricingUnit` | `usage.pricing_unit` | yes |
| `ProviderName` | constant `'Google Cloud'` (the only value FOCUS has) | yes |
| `PublisherName` | `seller_name`, with `'Google'`→`'Google Cloud'`; NULL stays NULL | yes |
| `RegionId` | `location.region` (`''` vs NULL preserved) | yes |
| `RegionName` | lookup on `location.region` built from the 40 named pairs FOCUS emitted 2026-07-26..10-29; unnamed or `''` regions → NULL, as FOCUS | yes for those regions; **stale for regions FOCUS names later** |
| `ResourceId` | `resource.global_name`. **NULL for 2025-01..08** (standard export has no resource grain) | yes |
| `ResourceName` | `resource.name`. **NULL for 2025-01..08**, as above | yes |
| `ServiceName` | `service.description` | yes |
| `SkuId` | `sku.id` only when `cost_type='regular'`; NULL on tax/adjustment/rounding rows (FOCUS leaves it NULL; the detailed export has an id) | yes |
| `SkuPriceId` | `CONCAT('SKU ID: ', sku.id, ', Price Tier Start Amount: ', CAST(price.tier_start_amount AS STRING))` | yes |
| `SubAccountId` | `project.id` (identical to `x_Project.Id` on every FOCUS row) | yes |
| `SubAccountName` | `project.name` | yes |
| `x_Credits` | `ARRAY(SELECT AS STRUCT name AS Name, CAST(amount AS NUMERIC) AS Amount, full_name AS FullName, id AS Id, type AS Type FROM UNNEST(credits))` | yes |
| `x_CostType` | regular→USAGE, tax→TAX, adjustment→ADJUSTMENT, rounding_error→ROUNDING | yes |
| `x_CurrencyConversionRate` | `currency_conversion_rate` (FLOAT) | yes |
| `x_ExportTime` | `export_time`. **Same meaning, different value**: it is the detailed export's own load time, not FOCUS's (FOCUS lands ~26 min later) | semantic only |
| `x_Location` | `location.location` | yes |
| `x_Project` | `STRUCT(project.id AS Id, project.number AS Number, project.name AS Name, project.ancestry_numbers AS AncestryNumbers, ancestors AS Ancestors(ResourceName, DisplayName))` | yes |
| `x_ServiceId` | `service.id` | yes |
| `x_SystemLabels` | 7 keys renamed to FOCUS's `goog-*` form (`compute.googleapis.com/cores`→`goog-compute-cores`, `…/cores_milliscale_multiplier`, `…/is_unused_reservation`, `…/machine_spec`, `…/memory`, `cloud-invoice.googleapis.com/sku_id`→`goog-cloud-invoice-sku-id`, `storage.googleapis.com/object_state`→`goog-storage-object-state`). All other keys (`compute.googleapis.com/reservation_*`, `backupdr.googleapis.com/*`) are dropped because FOCUS drops them; the raw copy keeps them | yes |
| `x_Labels` | `labels` (key, value) | yes |
| `x_ProjectLabels` | `project.labels` (key, value) | yes |
| `x_Tags` | `tags` (key→Key, value→Value, inherited→x_Inherited, namespace→x_Namespace) | yes |
| `EffectiveCost` | same expression as `BilledCost` (effective = billed in this data) | yes |
| `PricingCurrency` | `currency` | yes |
| `PricingCurrencyContractedUnitPrice` | `price.effective_price` (pricing currency = billing currency = IDR) | yes |
| `PricingCurrencyEffectiveCost` | same as `BilledCost` | yes |
| `PricingCurrencyListUnitPrice` | `price.list_price` | yes |
| `BillingAccountType` | not in the detailed export. Account `01A09A-A37EA6-F0AC6C` (the reseller itself): `'Reseller'` on usage rows, NULL on tax/adjustment/rounding rows; every other account: `'Resold'`. Data wins over Google's doc, which says "Resold or blank" | yes |
| `x_SubscriptionInstanceId` | `subscription.instance_id`. **NULL for 2025-01..08**, as above | yes |
| `x_PriceEffectivePriceDefault` | `price.effective_price_default` | yes |
| `x_PriceListPriceConsumptionModel` | `price.list_price_consumption_model` | yes |
| `x_CostAtEffectivePriceDefault` | `CAST(cost_at_effective_price_default AS NUMERIC)` | yes |
| `x_CostAtListConsumptionModel` | `CAST(cost_at_list_consumption_model AS NUMERIC)` | yes |
| `x_ConsumptionModelId` | `consumption_model.id` | yes |
| `x_ConsumptionModelDescription` | `consumption_model.description` | yes |

Detailed-export columns not carried over: `consumption_model.applied_subscription_instance_id`,
`invoice.publisher_type`, `transaction_type` (FOCUS has no counterpart).

## 2025-01 to 2025-08: the standard export, and the seam

`src` in `02_convert.sql` unions two sources at **2025-09-01 00:00 UTC** and the one mapping body above runs on the
result. The standard export (`tes_billing_export_try.gcp_billing_export_v1_..._copy`, snapshot 2025-10-07, usage
2020-03-27 to 2025-10-06, no gaps) has 76 field paths; the detailed export's 82 minus `resource.{name,global_name}`,
`subscription.instance_id` and `consumption_model.applied_subscription_instance_id`. The standard branch pads
those with typed NULLs (`resource` as `STRUCT<name STRING, global_name STRING>`, **name first**, the detailed table's
order). The other 26 top-level columns are identical to the detailed table in name, type, mode and nested field
order, apart from the padded `consumption_model` field (checked in both directions; the UNION ALL dry-run alone does not catch a swap of two STRING fields).
Nothing here has a FOCUS counterpart to compare against: the live FOCUS export starts 2026-07-25, so 2025 rows
are validated only against the detailed export, at the seam.

Findings on the standard export's 2025-01..08 rows (checked in asia-southeast1 before the build):

* `cost_at_list IS NULL` only on `tax` (5,674 rows) and `rounding_error` (16 rows), both service `Invoice`. No usage
  row has a NULL list cost, so Discount % has a denominator for all 2025 usage.
* **No price detail before mid-June 2025.** `price.*`, `cost_at_effective_price_default`,
  `cost_at_list_consumption_model` and `consumption_model.id` are NULL on 100% of usage rows for 2025-01..05, 78.2%
  of 2025-06 and 0% from 2025-07 (35.3% of all Jan-Aug usage rows). In the converted table that is
  `ContractedUnitPrice`, `ListUnitPrice`, `PricingCurrency*UnitPrice`, `x_PriceEffectivePriceDefault`,
  `x_PriceListPriceConsumptionModel`, `x_CostAtEffectivePriceDefault`, `x_CostAtListConsumptionModel`,
  `x_ConsumptionModelId`, `x_ConsumptionModelDescription`, and `SkuPriceId` (its CONCAT needs
  `price.tier_start_amount`). Cost columns (`ListCost`, `ContractedCost`, `BilledCost`, credits) are complete.
* Month-start `tax` (291 rows on 2025-08-01 07:00Z, 523 on 2025-09-01 07:00Z) and `rounding_error` rows exist in the
  standard export for both 2025-08-01 and 2025-09-01. The 2025-08-01 rows enter the table from the standard side,
  the 2025-09-01 rows from the detailed side.
* Maps services absent from the GMP list in `stg_focus_billing` (so counted as platform `GCP`): `Navigation API`,
  `Google Maps Platform - Mobility Billing`, `Places Insights API`, `Google Maps Platform Rides and Deliveries
  Service`, `Google Maps Platform Air Quality Service`, `Google Maps Platform Solar Service`. All have cost 0 in
  2025-01..08. Other services matching `API` (Cloud Vision, Gemini, Document AI, BigQuery Storage/Reservation,
  Dialogflow, Text-to-Speech, Mailgun, SendGrid) are not Maps.

**Seam check (2026-10-30, `03_seam_check_2025.sql`).** September 2025 mapped from `standard_export_raw` against the
table's September 2025 rows (detailed side), at (billing account, ChargeCategory, ServiceName) on ListCost,
ContractedCost, BilledCost and total credits, and at (billing account, credit Type) on credit Amount:

| Check | Groups | Missing in standard / table | Groups over 0.01 | Max abs delta |
|---|---|---|---|---|
| cost grain | 692 | 0 / 0 | 0 | 0 (list, contracted, billed, credits) |
| credit grain | 90 | 0 / 0 | 0 | 0 |

Totals are equal on both sides: list 6,373,768,511.44, contracted 6,316,119,458.41, billed 4,254,256,686.69,
credits -2,061,862,771.72. The query repeats only the seven expressions it needs from `02_convert.sql`; it is a
one-off, not part of the nightly build.

**Monthly check (2026-10-30).** Row count and `SUM(BilledCost)` of the table equal row count and `SUM(cost + credits)`
of the source raw table, exactly, for every month 2025-01..2025-12 (standard raw for 01..08, detailed raw for 09..12):

| Month | Rows | SUM(BilledCost) |
|---|---|---|
| 2025-01 | 1,712,077 | 3,214,422,496.84 |
| 2025-02 | 1,575,153 | 3,193,297,601.53 |
| 2025-03 | 1,801,859 | 3,756,224,900.99 |
| 2025-04 | 1,881,185 | 3,305,826,710.36 |
| 2025-05 | 2,248,134 | 3,368,764,161.54 |
| 2025-06 | 2,219,589 | 3,377,865,119.99 |
| 2025-07 | 8,898,082 | 4,061,331,145.05 |
| 2025-08 | 10,667,924 | 4,128,467,495.94 |
| 2025-09 | 25,728,475 | 4,254,256,686.69 |
| 2025-10 | 29,290,536 | 5,072,968,255.96 |
| 2025-11 | 31,535,279 | 4,835,779,806.72 |
| 2025-12 | 33,319,965 | 5,621,040,342.66 |

## NULL list

**No FOCUS column is NULL for every row of the table.** Every FOCUS field has a detailed-export source or a
derivation, except that for 2025-01..08 (standard export) `ResourceId`, `ResourceName` and `x_SubscriptionInstanceId`
are NULL on every row, and the price / consumption-model columns are NULL up to mid-June 2025 (see above).
Rows where a column is NULL by design, matching FOCUS:

| Column | NULL when | Why |
|---|---|---|
| `ListCost`, `ListUnitPrice`, price columns | tax / adjustment / rounding rows | the detailed export has no list cost or price on them |
| `SkuId`, `SkuPriceId` | tax / adjustment / rounding rows | FOCUS blanks them (the detailed export carries an invoice-line SKU id; not copied) |
| `PricingCategory` | non-usage rows | FOCUS leaves it NULL |
| `BillingAccountType` | non-usage rows of the reseller account | FOCUS does |
| `RegionName` | `''` (multi-region/global) and regions FOCUS has not named (e.g. `us-east7`, `asia-southeast3`) | no name exists; `RegionId` still set |
| `PublisherName` | rows with no `seller_name` (14 accounts' third-party resold lines, tax, rounding) | FOCUS does |

Fields the plan assumed but the FOCUS table does not have, so nothing to map: `CommitmentDiscount*`,
`BillingAccountName` (names come from `seeds/billing_accounts.csv`), `InvoiceIssuerName`.

## Caveats and inexact columns

Only `PricingQuantity` is on a mart-feeding path at all: `stg_focus_billing` selects it and `int_charges` passes it
on, but no mart or dashboard reads it past `int_charges`. The rest are not read by `dbt/models/intermediate` or
`dbt/models/marts`.

* **`PricingQuantity` does not reproduce FOCUS.** Compared to FOCUS on 2026-09-15 the history sum is higher by
  1e-7 (`tebibyte`) to 2.2% (`hour`) per pricing unit (0.09% for `count`), concentrated in some SKUs such as the
  Gemini token SKUs, where FOCUS reports less pricing quantity than the detailed export's
  `amount_in_pricing_units` although cost, credits and `ConsumedQuantity` match exactly. Cause not identified.
  `pricing_quantity` is selected by `int_charges` but no mart or dashboard reads it.
* **`PricingCategory` is a heuristic.** FOCUS splits a usage row that is only partly covered by a
  resource-based CUD into a `committed` and a `standard` row; the detailed export has one row, which this
  maps wholly to `committed`. On 2026-09-15 the per-category billed totals differ by ~1.6% (Rp 4.6M of 564M).
  Totals across categories are exact. Do not use history `PricingCategory` for committed-share analysis.
* **`BillingPeriodStart/End` for PST months.** Every FOCUS value observable (Jul-Oct 2026) is PDT (07:00Z).
  Jan-Mar history uses PST (08:00Z) if Google uses the real LA zone, which is what this maps. Unverifiable.
* **`x_ExportTime`** differs in value from what FOCUS would have carried (see table).
* **`RegionName`** lookup is a snapshot of FOCUS's own pairs; a region renamed or newly named later stays as mapped.
* **Late corrections** to pre-cutover months are not picked up (the history table is frozen) until the
  tables are rebuilt from a refreshed raw copy.
* **Overlap test drift.** FOCUS keeps receiving corrections to recent usage (rows arrive up to ~7+ days late),
  while the rows from the cutover to 2026-10-01 in `focus_billing_history` are a snapshot.
  `assert_history_matches_focus_overlap` can turn red later without the conversion being wrong; re-baseline by
  rebuilding `focus_billing_history`. The test is severity error, but the VM cron runs `dbt run` only, so it does not
  gate the nightly build.
* **FOCUS expiry.** The FOCUS export partitions expire after 730 days; rows start aging out on 2028-07-25.
