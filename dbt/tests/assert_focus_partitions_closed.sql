{{ config(severity='warn', tags=['monitoring']) }}

-- Monitoring: stg_focus_billing loads each FOCUS export partition once, when it is 2 days old
-- (export_day <= current_date() - 2), on the evidence that partitions stop changing within about
-- 1.5 days. This returns FOCUS partitions modified more than 2 days after their partition day and
-- after stg_focus_billing was last created (full refresh), i.e. changes the append may have missed.
-- The July 2026 enablement backfill predates the stg table and is excluded by that condition.
-- Fix: widen the closed-partition lag in stg_focus_billing, then dbt run --full-refresh --target full_refresh.
-- Metadata only (INFORMATION_SCHEMA), about 20 MB billed.

{%- set focus = source('gcp_billing', 'focus_export') %}
{%- set stg = ref('stg_focus_billing') %}

select
    p.partition_id,
    p.last_modified_time,
    p.total_rows
from `{{ focus.database }}`.`{{ focus.schema }}`.INFORMATION_SCHEMA.PARTITIONS as p
where p.table_name = '{{ focus.identifier }}'
  and p.partition_id not in ('__NULL__', '__UNPARTITIONED__')
  and p.last_modified_time > timestamp_add(timestamp(parse_date('%Y%m%d', p.partition_id)), interval 2 day)
  and p.last_modified_time > (
      select t.creation_time
      from `{{ stg.database }}`.`{{ stg.schema }}`.INFORMATION_SCHEMA.TABLES as t
      where t.table_name = '{{ stg.identifier }}'
  )
