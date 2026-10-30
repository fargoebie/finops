-- Credits unnested from x_Credits, aggregated to day grain.
-- Credits are embedded in Usage rows as x_Credits (REPEATED RECORD).
-- UNNEST expands each credit record into its own row before aggregation.
-- credit_amount is negative (reduces cost) per FOCUS convention.
--
-- GCP x_Credits.Type tokens:
--   COMMITTED_USAGE_DISCOUNT            resource-based CUD
--   COMMITTED_USAGE_DISCOUNT_DOLLAR_BASE spend-based CUD
--   SUSTAINED_USAGE_DISCOUNT            SUD
--   FREE_TIER                           free tier
--   PROMOTION                           promotional credit
--
-- Grain: the dimensions the marts read × charge_date. row_count is the number of unnested credit records behind each
-- row, so marts use sum(row_count) where they used count(*). Row-level detail stays in stg_focus_billing.
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
    billing_currency,
    charge_date,
    charge_month,
    credit.Type         as credit_type,
    credit.Id           as credit_id,
    credit.FullName     as credit_full_name,
    sum(credit.Amount)  as credit_amount,
    count(*)            as row_count,
    current_timestamp() as built_at
from {{ ref('stg_focus_billing') }}, UNNEST(x_credits) AS credit
{%- if is_incremental() %}
where {{ changed_upstream_partitions(ref('stg_focus_billing')) }}
{%- endif %}
group by 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12
