-- One row per credit per source billing row.
-- Credits are embedded in Usage rows as x_Credits (REPEATED RECORD).
-- UNNEST expands each credit record into its own row.
-- credit_amount is negative (reduces cost) per FOCUS convention.
--
-- GCP x_Credits.Type tokens:
--   COMMITTED_USAGE_DISCOUNT            resource-based CUD
--   COMMITTED_USAGE_DISCOUNT_DOLLAR_BASE spend-based CUD
--   SUSTAINED_USAGE_DISCOUNT            SUD
--   FREE_TIER                           free tier
--   PROMOTION                           promotional credit

select
    billing_account_id,
    project_id,
    project_name,
    service_name,
    region_id,
    charge_date,
    charge_month,
    sku_id,
    billing_currency,
    credit.Type       as credit_type,
    credit.Name       as credit_name,
    credit.FullName   as credit_full_name,
    credit.Id         as credit_id,
    credit.Amount     as credit_amount
from {{ ref('stg_focus_billing') }}, UNNEST(x_credits) AS credit
