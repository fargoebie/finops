-- Staging view over GCP FOCUS billing export.
-- Renames FOCUS columns to snake_case, coalesces nulls on cost columns,
-- and adds charge_date / charge_month for grouping.
-- No rows are filtered — full fidelity is the point.

select
    billing_account_id,
    billing_account_name,

    -- SubAccount = GCP project
    sub_account_id                                          as project_id,
    sub_account_name                                        as project_name,

    service_name,
    service_category,
    region_id,
    availability_zone_id,

    -- Time dimensions
    date(charge_period_start)                               as charge_date,
    timestamp_trunc(charge_period_start, month)             as charge_month,
    charge_period_start,
    charge_period_end,
    billing_period_start,
    billing_period_end,

    -- Charge classification
    charge_type,
    charge_category,
    charge_subcategory,
    charge_description,
    charge_frequency,

    -- SKU
    sku_id,
    sku_price_id,
    billing_currency,

    -- Unit prices
    coalesce(list_unit_price, 0)                            as list_unit_price,
    coalesce(contracted_unit_price, 0)                      as contracted_unit_price,

    -- Cost waterfall (credits are negative; coalesce avoids NULL propagation)
    coalesce(list_cost, 0)                                  as list_cost,
    coalesce(contracted_cost, 0)                            as contracted_cost,
    coalesce(effective_cost, 0)                             as effective_cost,
    coalesce(billed_cost, 0)                                as billed_cost,

    -- Quantity
    pricing_quantity,
    pricing_unit,
    consumed_quantity,
    consumed_unit,

    -- Commitment discounts
    commitment_discount_id,
    commitment_discount_name,
    commitment_discount_type,
    commitment_discount_category,
    commitment_discount_status,

    -- Resource
    resource_id,
    resource_name,
    resource_type

from {{ source('gcp_billing', 'focus_export') }}
