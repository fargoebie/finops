# FOCUS history backfill

Gives the marts a gap-free history from **2026-01-01** by converting Terralogiq's *detailed*
(resource-level) billing export into the exact schema of the *FOCUS* export, which only has complete
data from 2026-07-26. Plan and rationale: `docs/plans/focus-history-backfill.md`.

**Status:** copy and convert executed 2026-10-30. `resource_export_raw` has 708,864,848 rows and matched the
source on SUM(cost). `focus_billing_history` has 479,594,030 rows. `dbt build` gave PASS=48, WARN=2, ERROR=0.

```
terralogiq-billing-export-new.tes_billing_export.gcp_billing_export_resource_v1_01A09A_A37EA6_F0AC6C  (asia-southeast1, live, 915 GB logical)
        │  01_copy.sh  (bq cp, cross-region, kept)
        ▼
gcp-coe-492507:finops_history  (asia-southeast2, PHYSICAL storage billing)
  resource_export_raw           raw copy, kept so a rebuild needs no second copy
        │  02_convert.sql
        ▼
  focus_billing_history   2026-01-01 <= usage_start_time < 2026-10-01   frozen
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
| 2 | Create dataset, copy raw table, verify | `tools/history_backfill/01_copy.sh` | cross-region transfer for ~30 GB physical; verify scans ~6 GB per side |
| 3 | Build the history table | see below | one statement, scans ~0.88 TB (dry-run) |
| 4 | dbt | `cd dbt && dbt build` | `assert_history_matches_focus_overlap` must pass; it scans most of the FOCUS export (~22 GB) |
| 5 | Grant READER on `finops_history` to human analysts (e.g. Nanda). The VM SA should already read it through its project-level `bigquery.dataViewer` (AGENTS.md B3); confirm. | | |

**Deployment order.** The dbt changes (`stg_focus_billing`, `sources.yml`) reference the history table. Merge or
deploy them only after step 3 has created `focus_billing_history`; before that, `dbt run`
fails at `stg_focus_billing` and takes the downstream DAG (and the VM's daily cron) with it.

Step 3:

```bash
sed 's|{{SRC}}|`gcp-coe-492507.finops_history.resource_export_raw`|g' tools/history_backfill/02_convert.sql \
  | bq --project_id=gcp-coe-492507 --location=asia-southeast2 query --nouse_legacy_sql
```

`CREATE OR REPLACE` makes step 3 re-runnable; it is also the way to rebuild after Google posts late
corrections to pre-cutover months (re-run `01_copy.sh` against a fresh copy first, after `bq rm -t` of the old one).
The raw table's `usage_start_time` cannot prune (partitions are by ingestion time), so the statement scans
the whole copy: 882 GB in the dry-run.

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
| `ResourceId` | `resource.global_name` | yes |
| `ResourceName` | `resource.name` | yes |
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
| `x_SubscriptionInstanceId` | `subscription.instance_id` | yes |
| `x_PriceEffectivePriceDefault` | `price.effective_price_default` | yes |
| `x_PriceListPriceConsumptionModel` | `price.list_price_consumption_model` | yes |
| `x_CostAtEffectivePriceDefault` | `CAST(cost_at_effective_price_default AS NUMERIC)` | yes |
| `x_CostAtListConsumptionModel` | `CAST(cost_at_list_consumption_model AS NUMERIC)` | yes |
| `x_ConsumptionModelId` | `consumption_model.id` | yes |
| `x_ConsumptionModelDescription` | `consumption_model.description` | yes |

Detailed-export columns not carried over: `consumption_model.applied_subscription_instance_id`,
`invoice.publisher_type`, `transaction_type` (FOCUS has no counterpart).

## NULL list

**No FOCUS column is NULL for every row.** Every FOCUS field has a detailed-export source or a derivation.
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
