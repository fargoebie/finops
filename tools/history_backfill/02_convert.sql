-- History backfill: convert the DETAILED (resource-level) billing export into the FOCUS export's shape.
--
-- One CREATE statement. Output columns are the FOCUS export's columns in the same order, with the
-- same names, types, modes and STRUCT field names, so
--   SELECT * FROM focus_billing_history UNION ALL SELECT * FROM <focus export>
-- is position-safe. The column mapping and its evidence live in README.md.
--
-- {{SRC}} is substituted before running. Real run: gcp-coe-492507.finops_history.resource_export_raw
-- (see README.md); check_schema.py dry-runs it against the live se1 source. Substitute WITH the
-- backticks:
--   sed 's|{{SRC}}|`gcp-coe-492507.finops_history.resource_export_raw`|g' 02_convert.sql | bq query ...
--
-- The table covers 2026-01-01 <= usage < 2026-10-01 (UTC). Rows before the cutover (dbt var
-- focus_cutover_date, 2026-07-26 00:00 UTC) are the history that stg_focus_billing reads. Rows from the
-- cutover on overlap the live FOCUS export and are a TEST FIXTURE ONLY: stg_focus_billing filters them out
-- and assert_history_matches_focus_overlap compares them with FOCUS. check_schema.py checks that the
-- window contains the dbt cutover.

-- Frozen history 2026-01-01 <= usage < cutover, plus the overlap fixture cutover <= usage < 2026-10-01.
CREATE OR REPLACE TABLE `gcp-coe-492507.finops_history.focus_billing_history`
PARTITION BY DATE(ChargePeriodStart)
CLUSTER BY BillingAccountId, ServiceName
AS
SELECT
  s.location.zone                                              AS AvailabilityZone,
  s.billed_cost_idr                                            AS BilledCost,
  s.billing_account_id                                         AS BillingAccountId,
  s.currency                                                   AS BillingCurrency,
  TIMESTAMP(PARSE_DATE('%Y%m', s.invoice.month), 'America/Los_Angeles')             AS BillingPeriodStart,
  TIMESTAMP(LAST_DAY(PARSE_DATE('%Y%m', s.invoice.month)), 'America/Los_Angeles')   AS BillingPeriodEnd,
  CASE s.cost_type
    WHEN 'regular'        THEN 'Usage'
    WHEN 'tax'            THEN 'Tax'
    WHEN 'adjustment'     THEN 'Adjustment'
    WHEN 'rounding_error' THEN 'Adjustment'
  END                                                          AS ChargeCategory,
  IF(s.adjustment_info.type IS NOT NULL, 'correction', NULL)   AS ChargeClass,
  s.sku.description                                            AS ChargeDescription,
  s.usage_start_time                                           AS ChargePeriodStart,
  s.usage_end_time                                             AS ChargePeriodEnd,
  CAST(s.usage.amount AS NUMERIC)                              AS ConsumedQuantity,
  s.usage.unit                                                 AS ConsumedUnit,
  CAST(s.cost AS NUMERIC)                                      AS ContractedCost,
  s.price.effective_price                                      AS ContractedUnitPrice,
  CAST(s.cost_at_list AS NUMERIC)                              AS ListCost,
  s.price.list_price                                           AS ListUnitPrice,
  CASE
    WHEN s.cost_type != 'regular' THEN NULL
    WHEN REGEXP_CONTAINS(s.sku.description, r'^Commitment v1')
      OR EXISTS (SELECT 1 FROM UNNEST(s.credits) AS c WHERE c.type = 'COMMITTED_USAGE_DISCOUNT')
      THEN 'committed'
    ELSE 'standard'
  END                                                          AS PricingCategory,
  CAST(s.usage.amount_in_pricing_units AS NUMERIC)             AS PricingQuantity,
  s.usage.pricing_unit                                         AS PricingUnit,
  'Google Cloud'                                               AS ProviderName,
  IF(s.seller_name = 'Google', 'Google Cloud', s.seller_name)  AS PublisherName,
  s.location.region                                            AS RegionId,
  CASE s.location.region
    WHEN 'africa-south1' THEN 'Johannesburg'
    WHEN 'asia-east1' THEN 'Taiwan'
    WHEN 'asia-east2' THEN 'Hong Kong'
    WHEN 'asia-northeast1' THEN 'Tokyo'
    WHEN 'asia-northeast2' THEN 'Osaka'
    WHEN 'asia-northeast3' THEN 'Seoul'
    WHEN 'asia-south1' THEN 'Mumbai'
    WHEN 'asia-south2' THEN 'Delhi'
    WHEN 'asia-southeast1' THEN 'Singapore'
    WHEN 'asia-southeast2' THEN 'Jakarta'
    WHEN 'australia-southeast1' THEN 'Sydney'
    WHEN 'australia-southeast2' THEN 'Melbourne'
    WHEN 'europe-central2' THEN 'Warsaw'
    WHEN 'europe-north1' THEN 'Finland'
    WHEN 'europe-southwest1' THEN 'Madrid'
    WHEN 'europe-west1' THEN 'Belgium'
    WHEN 'europe-west10' THEN 'Berlin'
    WHEN 'europe-west12' THEN 'Turin'
    WHEN 'europe-west2' THEN 'London'
    WHEN 'europe-west3' THEN 'Frankfurt'
    WHEN 'europe-west4' THEN 'Netherlands'
    WHEN 'europe-west6' THEN 'Zurich'
    WHEN 'europe-west8' THEN 'Milan'
    WHEN 'europe-west9' THEN 'Paris'
    WHEN 'me-central1' THEN 'Doha'
    WHEN 'me-central2' THEN 'Dammam'
    WHEN 'me-west1' THEN 'Tel Aviv'
    WHEN 'northamerica-northeast1' THEN 'Montréal'
    WHEN 'northamerica-northeast2' THEN 'Toronto'
    WHEN 'southamerica-east1' THEN 'São Paulo'
    WHEN 'southamerica-west1' THEN 'Santiago'
    WHEN 'us-central1' THEN 'Iowa'
    WHEN 'us-east1' THEN 'South Carolina'
    WHEN 'us-east4' THEN 'Northern Virginia'
    WHEN 'us-east5' THEN 'Columbus'
    WHEN 'us-south1' THEN 'Dallas'
    WHEN 'us-west1' THEN 'Oregon'
    WHEN 'us-west2' THEN 'Los Angeles'
    WHEN 'us-west3' THEN 'Salt Lake City'
    WHEN 'us-west4' THEN 'Las Vegas'
  END                                                          AS RegionName,
  s.resource.global_name                                       AS ResourceId,
  s.resource.name                                              AS ResourceName,
  s.service.description                                        AS ServiceName,
  IF(s.cost_type = 'regular', s.sku.id, NULL)                  AS SkuId,
  CONCAT('SKU ID: ', s.sku.id, ', Price Tier Start Amount: ',
         CAST(s.price.tier_start_amount AS STRING))            AS SkuPriceId,
  s.project.id                                                 AS SubAccountId,
  s.project.name                                               AS SubAccountName,
  ARRAY(
    SELECT AS STRUCT
      c.name                      AS Name,
      CAST(c.amount AS NUMERIC)   AS Amount,
      c.full_name                 AS FullName,
      c.id                        AS Id,
      c.type                      AS Type
    FROM UNNEST(s.credits) AS c
  )                                                            AS x_Credits,
  CASE s.cost_type
    WHEN 'regular'        THEN 'USAGE'
    WHEN 'tax'            THEN 'TAX'
    WHEN 'adjustment'     THEN 'ADJUSTMENT'
    WHEN 'rounding_error' THEN 'ROUNDING'
  END                                                          AS x_CostType,
  s.currency_conversion_rate                                   AS x_CurrencyConversionRate,
  s.export_time                                                AS x_ExportTime,
  s.location.location                                          AS x_Location,
  STRUCT(
    s.project.id                AS Id,
    s.project.number            AS Number,
    s.project.name              AS Name,
    s.project.ancestry_numbers  AS AncestryNumbers,
    ARRAY(
      SELECT AS STRUCT a.resource_name AS ResourceName, a.display_name AS DisplayName
      FROM UNNEST(s.project.ancestors) AS a
    )                           AS Ancestors
  )                                                            AS x_Project,
  s.service.id                                                 AS x_ServiceId,
  -- FOCUS renames 7 system-label keys to goog-* and omits all others (reservation_*, backupdr).
  ARRAY(
    SELECT AS STRUCT m.focus_key AS Key, l.value AS Value
    FROM UNNEST(s.system_labels) AS l
    JOIN UNNEST([
      STRUCT('compute.googleapis.com/cores'                      AS src_key, 'goog-compute-cores'                      AS focus_key),
      STRUCT('compute.googleapis.com/cores_milliscale_multiplier', 'goog-compute-cores-milliscale-multiplier'),
      STRUCT('compute.googleapis.com/is_unused_reservation',      'goog-compute-is-unused-reservation'),
      STRUCT('compute.googleapis.com/machine_spec',               'goog-compute-machine-spec'),
      STRUCT('compute.googleapis.com/memory',                     'goog-compute-memory'),
      STRUCT('cloud-invoice.googleapis.com/sku_id',               'goog-cloud-invoice-sku-id'),
      STRUCT('storage.googleapis.com/object_state',               'goog-storage-object-state')
    ]) AS m ON m.src_key = l.key
  )                                                            AS x_SystemLabels,
  ARRAY(SELECT AS STRUCT l.key AS Key, l.value AS Value
        FROM UNNEST(s.labels) AS l)                            AS x_Labels,
  ARRAY(SELECT AS STRUCT l.key AS Key, l.value AS Value
        FROM UNNEST(s.project.labels) AS l)                    AS x_ProjectLabels,
  ARRAY(
    SELECT AS STRUCT
      t.key         AS Key,
      t.value       AS Value,
      t.inherited   AS x_Inherited,
      t.namespace   AS x_Namespace
    FROM UNNEST(s.tags) AS t
  )                                                            AS x_Tags,
  s.billed_cost_idr                                            AS EffectiveCost,
  s.currency                                                   AS PricingCurrency,
  s.price.effective_price                                      AS PricingCurrencyContractedUnitPrice,
  s.billed_cost_idr                                            AS PricingCurrencyEffectiveCost,
  s.price.list_price                                           AS PricingCurrencyListUnitPrice,
  CASE
    WHEN s.billing_account_id != '01A09A-A37EA6-F0AC6C' THEN 'Resold'
    WHEN s.cost_type = 'regular' THEN 'Reseller'
  END                                                          AS BillingAccountType,
  s.subscription.instance_id                                   AS x_SubscriptionInstanceId,
  s.price.effective_price_default                              AS x_PriceEffectivePriceDefault,
  s.price.list_price_consumption_model                         AS x_PriceListPriceConsumptionModel,
  CAST(s.cost_at_effective_price_default AS NUMERIC)           AS x_CostAtEffectivePriceDefault,
  CAST(s.cost_at_list_consumption_model AS NUMERIC)            AS x_CostAtListConsumptionModel,
  s.consumption_model.id                                       AS x_ConsumptionModelId,
  s.consumption_model.description                              AS x_ConsumptionModelDescription
FROM (
  -- billed = cost + SUM(credits). Credits are negative. NUMERIC arithmetic keeps it exact.
  -- COALESCE is load-bearing: SUM over an empty credits array is NULL.
  SELECT
    t.*,
    CAST(t.cost AS NUMERIC)
      + COALESCE((SELECT SUM(CAST(c.amount AS NUMERIC)) FROM UNNEST(t.credits) AS c), 0) AS billed_cost_idr
  FROM {{SRC}} AS t
) AS s
WHERE s.usage_start_time >= TIMESTAMP '2026-01-01'
  AND s.usage_start_time <  TIMESTAMP '2026-10-01';
