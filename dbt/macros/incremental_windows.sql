{#
  Incremental windows for the FOCUS pipeline (docs/plans/dbt-cost-materialization.md).

  stg_focus_billing is append-only, keyed on export_day = _PARTITIONDATE of the FOCUS export. An export
  partition is loaded once, after it has closed (export_day <= current_date() - 2; observed
  modifications stop within about 1.5 days). Each run appends the closed partitions after
  max(export_day), so a missed night self-heals. History rows have export_day NULL.
  assert_focus_partitions_closed (tag monitoring) warns if a loaded partition changed later.

  The incremental int models rebuild (insert_overwrite) every stg charge_date partition whose
  INFORMATION_SCHEMA.PARTITIONS last_modified_time is at or after the int's max(built_at), the start
  of its last successful build. built_at is a data column rather than the int's own partition
  metadata so that background re-clustering of the int cannot advance it.
#}

{#- Newest export day already in stg_focus_billing, as 'YYYY-MM-DD'. Evaluated once, at compile time.
    Returns none without querying when the relation is missing or not a table (e.g. still a view). -#}
{% macro stg_focus_watermark() %}
  {%- set relation = load_relation(this) if execute else none -%}
  {%- if relation is none or relation.type != 'table' -%}
    {{ return(none) }}
  {%- endif -%}
  {%- set sql -%}
    select cast(max(export_day) as string) from {{ this }}
  {%- endset -%}
  {%- set watermark = run_query(sql).columns[0].values()[0] -%}
  {%- if watermark is none -%}
    {{ exceptions.raise_compiler_error(this ~ " has no FOCUS rows (export_day is NULL everywhere). Rebuild it with --full-refresh.") }}
  {%- endif -%}
  {{ return(watermark) }}
{% endmacro %}


{#- WHERE predicate for an incremental int model: the upstream charge_date partitions modified at or
    after this model's last build (max(built_at)). Renders `false` when nothing changed. -#}
{% macro changed_upstream_partitions(upstream) %}
  {%- set sql -%}
    select p.partition_id
    from `{{ upstream.database }}`.`{{ upstream.schema }}`.INFORMATION_SCHEMA.PARTITIONS as p
    where p.table_name = '{{ upstream.identifier }}'
      and p.partition_id not in ('__NULL__', '__UNPARTITIONED__')
      and p.last_modified_time >= (
          select coalesce(max(t.built_at), timestamp '1970-01-01') from {{ this }} as t
      )
    order by p.partition_id
  {%- endset -%}
  {%- set ids = run_query(sql).columns[0].values() -%}
  {%- if ids | length == 0 -%}
    false
  {%- else -%}
    charge_date in ({% for i in ids %}date '{{ i[0:4] }}-{{ i[4:6] }}-{{ i[6:8] }}'{% if not loop.last %}, {% endif %}{% endfor %})
  {%- endif -%}
{% endmacro %}
