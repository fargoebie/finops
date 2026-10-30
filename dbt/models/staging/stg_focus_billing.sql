-- Staging table over GCP FOCUS billing data.
-- Renames PascalCase FOCUS columns to snake_case, coalesces nulls on cost/price
-- columns, and adds charge_date / charge_month for grouping.
-- x_credits (REPEATED RECORD) is passed through intact for UNNEST in int_credits.
-- The label/tag arrays (x_Labels, x_SystemLabels, x_ProjectLabels, x_Tags) are not carried: nothing
-- downstream reads them and they are the widest columns. Query the source tables for them.
--
-- Source is a cutover union (var focus_cutover_date, UTC midnight). Each ChargePeriodStart is
-- served by exactly one source, so nothing is dropped or double counted:
--   ChargePeriodStart <  cutover : finops_history.focus_billing_history, the detailed export (2025-09+)
--                                  and the standard export (2025-01..08) converted to the FOCUS
--                                  schema (tools/history_backfill/; frozen)
--   ChargePeriodStart >= cutover : the live FOCUS export
-- FOCUS rows dated before the cutover (ramp-up days, 2026-07-01 tax rows) are deliberately excluded.
-- Both sides have identical columns, so SELECT * UNION ALL is position-safe.
--
-- Incremental table (docs/plans/dbt-cost-materialization.md). Partitioned by charge_date, clustered by
-- billing_account_id, service_name. export_day = _PARTITIONDATE of the FOCUS export; NULL on history rows.
-- Append-only: a FOCUS export partition is loaded once, after it has closed (export_day <=
-- current_date() - 2, UTC), so dashboards lag the export by about two days.
--   --full-refresh : history (< cutover) UNION ALL FOCUS (>= cutover) from closed export partitions.
--   incremental    : appends FOCUS closed export partitions after max(export_day) (merge ON FALSE).
--                    History is never read or touched. Never run two appends at once (cron uses flock).
-- A column change here needs --full-refresh (on_schema_change is ignore).

{{ config(
    materialized='incremental',
    incremental_strategy='merge',
    partition_by={'field': 'charge_date', 'data_type': 'date', 'granularity': 'day'},
    cluster_by=['billing_account_id', 'service_name']
) }}

select
    BillingAccountId                                         as billing_account_id,
    BillingAccountType                                       as billing_account_type,

    -- SubAccount = GCP project
    SubAccountId                                             as project_id,
    SubAccountName                                           as project_name,

    -- x_Project fields
    x_Project.Id                                             as x_project_id,
    x_Project.Number                                         as project_number,
    x_Project.Name                                           as x_project_name,
    (SELECT a.DisplayName FROM UNNEST(x_Project.Ancestors) a
      WHERE a.ResourceName LIKE 'organizations/%' LIMIT 1)   as x_org_ancestor_name,
    (SELECT a.ResourceName FROM UNNEST(x_Project.Ancestors) a
      WHERE a.ResourceName LIKE 'organizations/%' LIMIT 1)   as x_org_ancestor_resource_name,

    ProviderName                                             as provider_name,
    PublisherName                                            as publisher_name,
    ServiceName                                              as service_name,

    -- Platform: GMP if ServiceName is a known Maps/Places/... service, else GCP.
    -- Re-check when Google ships new Maps services: any ServiceName ending in ' API'
    -- that is absent here is silently counted as GCP.
    CASE WHEN ServiceName IN (
      'Maps API','Places API','Places API (New)','Places Aggregate API','Geocoding API',
      'Directions API','Google Maps Platform - Routes','Route Optimization API',
      'Maps Static API','Maps Elevation API','Google Maps Tile API',
      'Google Maps Platform Weather Service','Street View Static API',
      'Geolocation API','Distance Matrix API','Time Zone API','Roads API',
      'Isochrones API'
    ) THEN 'GMP' ELSE 'GCP' END                              as platform,

    RegionId                                                 as region_id,
    RegionName                                               as region_name,
    AvailabilityZone                                         as availability_zone,

    -- Time dimensions
    DATE(ChargePeriodStart)                                  as charge_date,
    export_day,
    TIMESTAMP_TRUNC(ChargePeriodStart, MONTH)                as charge_month,
    ChargePeriodStart                                        as charge_period_start,
    ChargePeriodEnd                                          as charge_period_end,
    BillingPeriodStart                                       as billing_period_start,
    BillingPeriodEnd                                         as billing_period_end,

    -- Charge classification
    ChargeCategory                                           as charge_category,
    ChargeClass                                              as charge_class,
    ChargeDescription                                        as charge_description,

    -- SKU
    SkuId                                                    as sku_id,
    SkuPriceId                                               as sku_price_id,
    BillingCurrency                                          as billing_currency,
    PricingCurrency                                          as pricing_currency,
    PricingCategory                                          as pricing_category,

    -- Unit prices
    COALESCE(ListUnitPrice, 0)                               as list_unit_price,
    COALESCE(ContractedUnitPrice, 0)                         as contracted_unit_price,

    -- Cost waterfall (credits are negative; COALESCE avoids NULL propagation)
    COALESCE(ListCost, 0)                                    as list_cost,
    COALESCE(ContractedCost, 0)                              as contracted_cost,
    COALESCE(EffectiveCost, 0)                               as effective_cost,
    COALESCE(BilledCost, 0)                                  as billed_cost,

    -- USD equivalents — derived ROW-LEVEL (no native USD column; all costs are IDR)
    SAFE_DIVIDE(COALESCE(ListCost,0),       NULLIF(x_CurrencyConversionRate,0)) as list_cost_usd,
    SAFE_DIVIDE(COALESCE(ContractedCost,0), NULLIF(x_CurrencyConversionRate,0)) as contracted_cost_usd,
    SAFE_DIVIDE(COALESCE(EffectiveCost,0),  NULLIF(x_CurrencyConversionRate,0)) as effective_cost_usd,
    SAFE_DIVIDE(COALESCE(BilledCost,0),     NULLIF(x_CurrencyConversionRate,0)) as billed_cost_usd,

    -- Pricing-currency equivalents
    COALESCE(PricingCurrencyContractedUnitPrice, 0)          as pricing_currency_contracted_unit_price,
    COALESCE(PricingCurrencyEffectiveCost, 0)                as pricing_currency_effective_cost,
    COALESCE(PricingCurrencyListUnitPrice, 0)                as pricing_currency_list_unit_price,
    x_CurrencyConversionRate                                 as x_currency_conversion_rate,

    -- Quantity
    PricingQuantity                                          as pricing_quantity,
    PricingUnit                                              as pricing_unit,
    ConsumedQuantity                                         as consumed_quantity,
    ConsumedUnit                                             as consumed_unit,

    -- Resource
    ResourceId                                               as resource_id,
    ResourceName                                             as resource_name,

    -- GCP extensions
    x_CostType                                               as x_cost_type,
    x_Location                                               as x_location,
    x_ServiceId                                              as x_service_id,
    x_SubscriptionInstanceId                                 as x_subscription_instance_id,
    x_ConsumptionModelId                                     as x_consumption_model_id,
    x_ConsumptionModelDescription                            as x_consumption_model_description,
    COALESCE(x_CostAtEffectivePriceDefault, 0)               as x_cost_at_effective_price_default,
    COALESCE(x_CostAtListConsumptionModel, 0)                as x_cost_at_list_consumption_model,
    COALESCE(x_PriceEffectivePriceDefault, 0)                as x_price_effective_price_default,
    COALESCE(x_PriceListPriceConsumptionModel, 0)            as x_price_list_price_consumption_model,
    x_ExportTime                                             as x_export_time,

    -- Nested/repeated — passed through intact
    x_Credits                                                as x_credits

from (
{%- if is_incremental() %}
    {%- set watermark = stg_focus_watermark() %}
    select *, _PARTITIONDATE as export_day
    from {{ source('gcp_billing', 'focus_export') }}
    where _PARTITIONDATE > date '{{ watermark }}'
      and _PARTITIONDATE <= date_sub(current_date(), interval 2 day)
      and ChargePeriodStart >= timestamp('{{ var("focus_cutover_date") }}')
{%- else %}
    select *, CAST(NULL AS DATE) as export_day
    from {{ source('finops_history', 'focus_billing_history') }}
    where ChargePeriodStart < timestamp('{{ var("focus_cutover_date") }}')
    union all
    select *, _PARTITIONDATE as export_day
    from {{ source('gcp_billing', 'focus_export') }}
    where _PARTITIONDATE <= date_sub(current_date(), interval 2 day)
      and ChargePeriodStart >= timestamp('{{ var("focus_cutover_date") }}')
{%- endif %}
) as focus_billing
