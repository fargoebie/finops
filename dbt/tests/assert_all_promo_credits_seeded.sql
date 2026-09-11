{{ config(severity='warn') }}

-- Canary test: a PROMOTION credit is being applied that has no row in
-- seeds/credit_programs.csv, so its amount and end date are unknown and
-- fct_credit_runway cannot project exhaustion for it.
-- Fires as WARN so nightly runs surface new credits without blocking.
-- Fix: add a row to dbt/seeds/credit_programs.csv (amount and dates from
-- Console → Billing → Credits), then re-run dbt seed && dbt run.

select
    credit_id,
    credit_name,
    billing_account_id,
    applied_to_date_idr
from {{ ref('fct_credit_runway') }}
where is_unseeded
