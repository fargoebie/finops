-- Usage, Purchase, and Tax charges — excludes Credit and Adjustment rows.
-- These are the rows that drive list_cost → contracted_cost → effective_cost → billed_cost.

select
    billing_account_id,
    project_id,
    project_name,
    service_name,
    platform,
    region_id,
    charge_date,
    charge_month,
    charge_category,
    charge_description,
    sku_id,
    billing_currency,
    list_cost,
    contracted_cost,
    effective_cost,
    billed_cost,
    list_cost_usd,
    contracted_cost_usd,
    effective_cost_usd,
    billed_cost_usd,
    pricing_quantity,
    pricing_unit,
    consumed_quantity,
    consumed_unit
from {{ ref('stg_focus_billing') }}
where charge_category in ('Usage', 'Purchase', 'Tax')
