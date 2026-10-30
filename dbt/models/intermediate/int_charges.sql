-- Usage, Purchase, and Tax charges — excludes Credit and Adjustment rows.
-- These are the rows that drive list_cost → contracted_cost → effective_cost → billed_cost.
--
-- Aggregated to day grain over only the dimensions the marts read. Measures are sums; row_count is the number of
-- stg_focus_billing rows behind each row, so marts use sum(row_count) where they used count(*).
-- Row-level detail stays in stg_focus_billing.
--
-- Incremental: rebuilds (insert_overwrite) the charge_date partitions of stg_focus_billing modified
-- since this table was last built (macros/incremental_windows.sql). built_at is that build time, kept
-- as data so background re-clustering cannot move it. --full-refresh rebuilds all.

{{ config(
    materialized='incremental',
    incremental_strategy='insert_overwrite',
    partition_by={'field': 'charge_date', 'data_type': 'date', 'granularity': 'day'},
    cluster_by=['billing_account_id', 'service_name']
) }}

select
    billing_account_id,
    project_id,
    project_name,
    service_name,
    platform,
    region_id,
    sku_id,
    billing_currency,
    charge_date,
    charge_month,
    sum(list_cost)              as list_cost,
    sum(contracted_cost)        as contracted_cost,
    sum(effective_cost)         as effective_cost,
    sum(billed_cost)            as billed_cost,
    sum(list_cost_usd)          as list_cost_usd,
    sum(contracted_cost_usd)    as contracted_cost_usd,
    sum(effective_cost_usd)     as effective_cost_usd,
    sum(billed_cost_usd)        as billed_cost_usd,
    count(*)                    as row_count,
    current_timestamp()         as built_at
from {{ ref('stg_focus_billing') }}
where charge_category in ('Usage', 'Purchase', 'Tax')
{%- if is_incremental() %}
  and {{ changed_upstream_partitions(ref('stg_focus_billing')) }}
{%- endif %}
group by 1, 2, 3, 4, 5, 6, 7, 8, 9, 10
