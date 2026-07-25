-- Usage, Purchase, and Tax charges — excludes Credit and Adjustment rows.
-- These are the rows that drive list_cost → contracted_cost → effective_cost → billed_cost.

select
    billing_account_id,
    project_id,
    project_name,
    service_name,
    service_category,
    region_id,
    charge_date,
    charge_month,
    charge_type,
    charge_category,
    charge_description,
    sku_id,
    billing_currency,
    list_cost,
    contracted_cost,
    effective_cost,
    billed_cost,
    pricing_quantity,
    pricing_unit,
    consumed_quantity,
    consumed_unit,
    commitment_discount_id,
    commitment_discount_name,
    commitment_discount_type,
    commitment_discount_category,
    commitment_discount_status
from {{ ref('stg_focus_billing') }}
where charge_type in ('Usage', 'Purchase', 'Tax')
