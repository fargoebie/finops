{{ config(severity='warn') }}

-- Canary test: alert when a Resold billing account has no customer mapping.
-- Fires as WARN (not ERROR) so nightly runs surface gaps without blocking the pipeline.
-- Fix: add a row to dbt/seeds/customer_accounts.csv and re-run dbt seed && dbt run.

select
    billing_account_id,
    billing_account_type,
    customer_name
from {{ ref('int_customer_map') }}
where billing_account_type = 'Resold'
  and customer_name = '(unmapped)'
