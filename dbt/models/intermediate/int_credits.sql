-- Credit rows only — preserves the full ChargeSubcategory label.
--
-- GCP credit subcategories include (non-exhaustive):
--   'Enterprise Discount Program'
--   'Committed Use Discount: Spend'
--   'Committed Use Discount: Usage'
--   'Sustained Use Discount'
--   'Promotion'
--   'Reseller Discount'
--   'Free Tier'
--
-- credit_amount is always negative (reduces billed cost).

select
    billing_account_id,
    project_id,
    project_name,
    service_name,
    service_category,
    region_id,
    charge_date,
    charge_month,
    charge_subcategory                  as credit_type,
    charge_description,
    sku_id,
    billing_currency,
    billed_cost                         as credit_amount,
    commitment_discount_id,
    commitment_discount_name,
    commitment_discount_type,
    commitment_discount_category
from {{ ref('stg_focus_billing') }}
where charge_type = 'Credit'
