-- Exact post-run check of the incremental pipeline (docs/plans/dbt-cost-materialization.md).
-- Run after a nightly `dbt run`, the same UTC day:
--   bq --project_id=gcp-coe-492507 --location=asia-southeast2 query --use_legacy_sql=false \
--      --maximum_bytes_billed=50000000000 < tools/dbt_cost/check_incremental.sql
-- Pass = no rows. Each row is one key whose two sides differ (NUMERIC sums, so exact).
--   stg_vs_focus      per export_day, the last 7 closed export days (current_date-8 .. current_date-2):
--                     stg rows and sum(billed_cost) vs the FOCUS partition (ChargePeriodStart >= cutover).
--   int_charges_vs_stg  per charge_date >= current_date-45 (covers the month-start Tax partition):
--                     sum(billed_cost) and sum(row_count) vs stg Usage/Purchase/Tax rows.
--   int_credits_vs_stg  per charge_date >= current_date-45: sum(credit_amount) and sum(row_count) vs
--                     stg unnest(x_credits).
-- The cutover literal must equal var focus_cutover_date in dbt/dbt_project.yml.

with
focus_by_export_day as (
    select
        _PARTITIONDATE                      as k,
        count(*)                            as n,
        sum(coalesce(BilledCost, 0))        as amount
    from `terra-coe-finops.gcp_billing_immutable_01A09A_A37EA6_F0AC6C_asia_southeast2.gcp_billing_export_focus_01A09A_A37EA6_F0AC6C`
    where _PARTITIONDATE between date_sub(current_date(), interval 8 day)
                             and date_sub(current_date(), interval 2 day)
      and ChargePeriodStart >= timestamp('2026-07-26')
    group by 1
),
stg_by_export_day as (
    select
        export_day                          as k,
        count(*)                            as n,
        sum(billed_cost)                    as amount
    from `gcp-coe-492507.dbt_staging.stg_focus_billing`
    where charge_date >= date '2026-07-26'
      and export_day between date_sub(current_date(), interval 8 day)
                         and date_sub(current_date(), interval 2 day)
    group by 1
),
stg_charges_by_day as (
    select
        charge_date                         as k,
        count(*)                            as n,
        sum(billed_cost)                    as amount
    from `gcp-coe-492507.dbt_staging.stg_focus_billing`
    where charge_date >= date_sub(current_date(), interval 45 day)
      and charge_category in ('Usage', 'Purchase', 'Tax')
    group by 1
),
int_charges_by_day as (
    select
        charge_date                         as k,
        sum(row_count)                      as n,
        sum(billed_cost)                    as amount
    from `gcp-coe-492507.dbt_intermediate.int_charges`
    where charge_date >= date_sub(current_date(), interval 45 day)
    group by 1
),
stg_credits_by_day as (
    select
        charge_date                         as k,
        count(*)                            as n,
        sum(c.Amount)                       as amount
    from `gcp-coe-492507.dbt_staging.stg_focus_billing`, unnest(x_credits) as c
    where charge_date >= date_sub(current_date(), interval 45 day)
    group by 1
),
int_credits_by_day as (
    select
        charge_date                         as k,
        sum(row_count)                      as n,
        sum(credit_amount)                  as amount
    from `gcp-coe-492507.dbt_intermediate.int_credits`
    where charge_date >= date_sub(current_date(), interval 45 day)
    group by 1
),
diffs as (
    select 'stg_vs_focus' as check_name, coalesce(s.k, f.k) as k,
           s.n as left_rows, f.n as right_rows, s.amount as left_amount, f.amount as right_amount
    from stg_by_export_day s full outer join focus_by_export_day f on s.k = f.k
    union all
    select 'int_charges_vs_stg', coalesce(i.k, s.k), i.n, s.n, i.amount, s.amount
    from int_charges_by_day i full outer join stg_charges_by_day s on i.k = s.k
    union all
    select 'int_credits_vs_stg', coalesce(i.k, s.k), i.n, s.n, i.amount, s.amount
    from int_credits_by_day i full outer join stg_credits_by_day s on i.k = s.k
)

select *
from diffs
where left_rows is distinct from right_rows
   or left_amount is distinct from right_amount
order by check_name, k;
