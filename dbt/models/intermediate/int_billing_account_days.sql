-- One row per billing_account_id × charge_date over EVERY stg_focus_billing row, with the attributes
-- int_customer_map resolves customers from. int_charges and int_credits are not enough on their own:
-- an account whose only rows are Credit/Adjustment rows with no x_Credits appears in neither
-- (tools/dbt_cost/credit_adjustment_only_accounts.sql lists such accounts).
-- max, not any_value: the reseller account has NULL type on non-usage rows (see int_customer_map).
--
-- Incremental like int_charges: rebuilds the stg_focus_billing partitions changed since max(built_at)
-- (macros/incremental_windows.sql). --full-refresh rebuilds all.

{{ config(
    materialized='incremental',
    incremental_strategy='insert_overwrite',
    partition_by={'field': 'charge_date', 'data_type': 'date', 'granularity': 'day'},
    cluster_by=['billing_account_id']
) }}

select
    billing_account_id,
    charge_date,
    max(billing_account_type)   as billing_account_type,
    max(x_org_ancestor_name)    as x_org_ancestor_name,
    current_timestamp()         as built_at
from {{ ref('stg_focus_billing') }}
{%- if is_incremental() %}
where {{ changed_upstream_partitions(ref('stg_focus_billing')) }}
{%- endif %}
group by 1, 2
