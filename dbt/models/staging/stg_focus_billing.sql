-- Staging view over GCP FOCUS billing export.
-- Renames PascalCase FOCUS columns to snake_case, coalesces nulls on cost/price
-- columns, and adds charge_date / charge_month for grouping.
-- x_credits (REPEATED RECORD) is passed through intact for UNNEST in int_credits.
-- No rows are filtered — full fidelity is the point.

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

    -- Platform: GMP if ServiceName is a known Maps/Places/... service, else GCP
    CASE WHEN ServiceName IN (
      'Maps API','Places API','Places API (New)','Places Aggregate API','Geocoding API',
      'Directions API','Google Maps Platform - Routes','Route Optimization API',
      'Maps Static API','Maps Elevation API','Google Maps Tile API',
      'Google Maps Platform Weather Service','Street View Static API'
    ) THEN 'GMP' ELSE 'GCP' END                              as platform,

    RegionId                                                 as region_id,
    RegionName                                               as region_name,
    AvailabilityZone                                         as availability_zone,

    -- Time dimensions
    DATE(ChargePeriodStart)                                  as charge_date,
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
    x_Credits                                                as x_credits,
    x_SystemLabels                                           as x_system_labels,
    x_Labels                                                 as x_labels,
    x_ProjectLabels                                          as x_project_labels,
    x_Tags                                                   as x_tags

from {{ source('gcp_billing', 'focus_export') }}
