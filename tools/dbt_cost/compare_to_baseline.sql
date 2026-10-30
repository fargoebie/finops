-- Full-row diff of every mart and of int_customer_map against the baseline from baseline_snapshot.sql
-- (docs/plans/dbt-cost-materialization.md, step 7). Run after the full rebuild:
--   bq --project_id=gcp-coe-492507 --location=asia-southeast2 query --use_legacy_sql=false \
--      --max_rows=1000 < tools/dbt_cost/compare_to_baseline.sql
--
-- Pass = the second result set is empty. Each row is one mart row present on only one side
-- (EXCEPT DISTINCT both ways), with the row as JSON.
--
-- Columns are compared exactly, except FLOAT64 (the *_usd columns), which are ROUND(x, 4): they are
-- sums of row-level IDR / x_CurrencyConversionRate, and summing day-grain partial sums instead of raw
-- rows changes the last bits. A difference above 0.0001 USD is real.
--
-- Expected non-zero diffs: the views read every FOCUS row, while the rebuilt stg_focus_billing loads
-- only closed export partitions (export_day <= current_date - 2), so rows fed by the newest two export
-- days differ by design. That means the newest charge_month (plus, in the first days of a month, the
-- previous month's month-start Tax rows) and fct_credit_runway (as_of_date, burn and staleness move with
-- the newest day). A row in any older charge_month, or in int_customer_map, is a regression unless the
-- account first appeared in the last two export days. fct_credit_runway.credit_name comes from
-- ANY_VALUE and can differ if one credit_id has more than one FullName. ROUND(x, 4) can, very rarely,
-- flag an otherwise identical row whose float sits on a rounding boundary.
--
-- Reads only the small baseline and mart tables.

select
    m.snapshot_at,
    m.focus_last_modified                                       as focus_last_modified_at_snapshot,
    (select max(last_modified_time) from `terra-coe-finops.gcp_billing_immutable_01A09A_A37EA6_F0AC6C_asia_southeast2.INFORMATION_SCHEMA.PARTITIONS`
      where table_name = 'gcp_billing_export_focus_01A09A_A37EA6_F0AC6C')                           as focus_last_modified_now,
    (select max(last_modified_time)
       from `gcp-coe-492507.dbt_staging.INFORMATION_SCHEMA.PARTITIONS`
      where table_name = 'stg_focus_billing')                   as stg_last_built
from `gcp-coe-492507.scratch_cost_baseline._snapshot_meta` as m;

with
-- fct_spend_waterfall
fct_spend_waterfall_b as (
    select
        project_id,
        project_name,
        service_name,
        region_id,
        sku_id,
        charge_month,
        billing_currency,
        list_cost,
        contracted_cost,
        effective_cost,
        billed_cost,
        negotiated_savings,
        credit_savings,
        other_adjustments,
        total_discount
    from `gcp-coe-492507.scratch_cost_baseline.fct_spend_waterfall`
),
fct_spend_waterfall_a as (
    select
        project_id,
        project_name,
        service_name,
        region_id,
        sku_id,
        charge_month,
        billing_currency,
        list_cost,
        contracted_cost,
        effective_cost,
        billed_cost,
        negotiated_savings,
        credit_savings,
        other_adjustments,
        total_discount
    from `gcp-coe-492507.finops_dbt.fct_spend_waterfall`
),

-- fct_credit_breakdown
fct_credit_breakdown_b as (
    select
        project_id,
        project_name,
        service_name,
        region_id,
        charge_month,
        credit_type,
        billing_currency,
        credit_line_count,
        total_credit_amount
    from `gcp-coe-492507.scratch_cost_baseline.fct_credit_breakdown`
),
fct_credit_breakdown_a as (
    select
        project_id,
        project_name,
        service_name,
        region_id,
        charge_month,
        credit_type,
        billing_currency,
        credit_line_count,
        total_credit_amount
    from `gcp-coe-492507.finops_dbt.fct_credit_breakdown`
),

-- fct_commitment_discounts
fct_commitment_discounts_b as (
    select
        project_id,
        project_name,
        service_name,
        charge_month,
        commitment_discount_type,
        billing_currency,
        line_count,
        total_cud_credit
    from `gcp-coe-492507.scratch_cost_baseline.fct_commitment_discounts`
),
fct_commitment_discounts_a as (
    select
        project_id,
        project_name,
        service_name,
        charge_month,
        commitment_discount_type,
        billing_currency,
        line_count,
        total_cud_credit
    from `gcp-coe-492507.finops_dbt.fct_commitment_discounts`
),

-- fct_monthly_showback
fct_monthly_showback_b as (
    select
        project_id,
        project_name,
        charge_month,
        billing_currency,
        gross_cost,
        contracted_cost,
        effective_cost,
        net_cost,
        total_credits,
        cud_credits,
        sud_credits,
        promotional_credits,
        free_tier_credits,
        other_credits,
        negotiated_savings
    from `gcp-coe-492507.scratch_cost_baseline.fct_monthly_showback`
),
fct_monthly_showback_a as (
    select
        project_id,
        project_name,
        charge_month,
        billing_currency,
        gross_cost,
        contracted_cost,
        effective_cost,
        net_cost,
        total_credits,
        cud_credits,
        sud_credits,
        promotional_credits,
        free_tier_credits,
        other_credits,
        negotiated_savings
    from `gcp-coe-492507.finops_dbt.fct_monthly_showback`
),

-- fct_customer_monthly
fct_customer_monthly_b as (
    select
        billing_account_id,
        billing_account_name,
        customer_name,
        customer_id,
        billing_account_type,
        account_class,
        platform,
        charge_month,
        billing_currency,
        gross_cost_idr,
        contracted_cost_idr,
        effective_cost_idr,
        net_cost_idr,
        round(gross_cost_usd, 4) as gross_cost_usd,
        round(contracted_cost_usd, 4) as contracted_cost_usd,
        round(effective_cost_usd, 4) as effective_cost_usd,
        round(net_cost_usd, 4) as net_cost_usd,
        total_credits_idr,
        cud_credits_idr,
        sud_credits_idr,
        promo_credits_idr,
        free_tier_credits_idr,
        other_credits_idr,
        promo_credit_coverage_pct,
        is_credit_funded,
        effective_discount_pct,
        mom_prev_net_cost_idr,
        round(mom_prev_net_cost_usd, 4) as mom_prev_net_cost_usd,
        mom_delta_idr,
        round(mom_delta_usd, 4) as mom_delta_usd,
        mom_delta_pct
    from `gcp-coe-492507.scratch_cost_baseline.fct_customer_monthly`
),
fct_customer_monthly_a as (
    select
        billing_account_id,
        billing_account_name,
        customer_name,
        customer_id,
        billing_account_type,
        account_class,
        platform,
        charge_month,
        billing_currency,
        gross_cost_idr,
        contracted_cost_idr,
        effective_cost_idr,
        net_cost_idr,
        round(gross_cost_usd, 4) as gross_cost_usd,
        round(contracted_cost_usd, 4) as contracted_cost_usd,
        round(effective_cost_usd, 4) as effective_cost_usd,
        round(net_cost_usd, 4) as net_cost_usd,
        total_credits_idr,
        cud_credits_idr,
        sud_credits_idr,
        promo_credits_idr,
        free_tier_credits_idr,
        other_credits_idr,
        promo_credit_coverage_pct,
        is_credit_funded,
        effective_discount_pct,
        mom_prev_net_cost_idr,
        round(mom_prev_net_cost_usd, 4) as mom_prev_net_cost_usd,
        mom_delta_idr,
        round(mom_delta_usd, 4) as mom_delta_usd,
        mom_delta_pct
    from `gcp-coe-492507.finops_dbt.fct_customer_monthly`
),

-- fct_customer_service_month
fct_customer_service_month_b as (
    select
        billing_account_id,
        customer_name,
        customer_id,
        billing_account_type,
        platform,
        service_name,
        charge_month,
        billing_currency,
        gross_cost_idr,
        effective_cost_idr,
        net_cost_idr,
        round(effective_cost_usd, 4) as effective_cost_usd,
        round(net_cost_usd, 4) as net_cost_usd,
        mom_prev_net_cost_idr,
        round(mom_prev_net_cost_usd, 4) as mom_prev_net_cost_usd,
        mom_delta_idr,
        round(mom_delta_usd, 4) as mom_delta_usd,
        mom_delta_pct
    from `gcp-coe-492507.scratch_cost_baseline.fct_customer_service_month`
),
fct_customer_service_month_a as (
    select
        billing_account_id,
        customer_name,
        customer_id,
        billing_account_type,
        platform,
        service_name,
        charge_month,
        billing_currency,
        gross_cost_idr,
        effective_cost_idr,
        net_cost_idr,
        round(effective_cost_usd, 4) as effective_cost_usd,
        round(net_cost_usd, 4) as net_cost_usd,
        mom_prev_net_cost_idr,
        round(mom_prev_net_cost_usd, 4) as mom_prev_net_cost_usd,
        mom_delta_idr,
        round(mom_delta_usd, 4) as mom_delta_usd,
        mom_delta_pct
    from `gcp-coe-492507.finops_dbt.fct_customer_service_month`
),

-- fct_credit_runway
fct_credit_runway_b as (
    select
        credit_id,
        credit_name,
        billing_account_id,
        billing_account_name,
        customer_name,
        account_class,
        as_of_date,
        total_amount_idr,
        start_date,
        end_date,
        first_applied,
        last_applied,
        applied_to_date_idr,
        burn_per_day_idr,
        days_stale,
        is_active,
        remaining_idr,
        consumed_pct,
        days_to_exhaustion,
        projected_exhaustion_date,
        days_to_end_date,
        runway_days,
        is_granted_not_yet_used,
        is_unseeded,
        notes
    from `gcp-coe-492507.scratch_cost_baseline.fct_credit_runway`
),
fct_credit_runway_a as (
    select
        credit_id,
        credit_name,
        billing_account_id,
        billing_account_name,
        customer_name,
        account_class,
        as_of_date,
        total_amount_idr,
        start_date,
        end_date,
        first_applied,
        last_applied,
        applied_to_date_idr,
        burn_per_day_idr,
        days_stale,
        is_active,
        remaining_idr,
        consumed_pct,
        days_to_exhaustion,
        projected_exhaustion_date,
        days_to_end_date,
        runway_days,
        is_granted_not_yet_used,
        is_unseeded,
        notes
    from `gcp-coe-492507.finops_dbt.fct_credit_runway`
),

-- int_customer_map
int_customer_map_b as (
    select
        billing_account_id,
        billing_account_name,
        billing_account_type,
        account_class,
        customer_name,
        customer_id,
        is_seed_resolved,
        is_ancestry_resolved
    from `gcp-coe-492507.scratch_cost_baseline.int_customer_map`
),
int_customer_map_a as (
    select
        billing_account_id,
        billing_account_name,
        billing_account_type,
        account_class,
        customer_name,
        customer_id,
        is_seed_resolved,
        is_ancestry_resolved
    from `gcp-coe-492507.dbt_intermediate.int_customer_map`
)

select 'fct_spend_waterfall' as mart, 'only_in_baseline' as side, d.charge_month as charge_month, to_json_string(d) as row_json
from (select * from fct_spend_waterfall_b except distinct select * from fct_spend_waterfall_a) as d
union all
select 'fct_spend_waterfall', 'only_in_rebuild', d.charge_month, to_json_string(d)
from (select * from fct_spend_waterfall_a except distinct select * from fct_spend_waterfall_b) as d
union all
select 'fct_credit_breakdown' as mart, 'only_in_baseline' as side, d.charge_month as charge_month, to_json_string(d) as row_json
from (select * from fct_credit_breakdown_b except distinct select * from fct_credit_breakdown_a) as d
union all
select 'fct_credit_breakdown', 'only_in_rebuild', d.charge_month, to_json_string(d)
from (select * from fct_credit_breakdown_a except distinct select * from fct_credit_breakdown_b) as d
union all
select 'fct_commitment_discounts' as mart, 'only_in_baseline' as side, d.charge_month as charge_month, to_json_string(d) as row_json
from (select * from fct_commitment_discounts_b except distinct select * from fct_commitment_discounts_a) as d
union all
select 'fct_commitment_discounts', 'only_in_rebuild', d.charge_month, to_json_string(d)
from (select * from fct_commitment_discounts_a except distinct select * from fct_commitment_discounts_b) as d
union all
select 'fct_monthly_showback' as mart, 'only_in_baseline' as side, d.charge_month as charge_month, to_json_string(d) as row_json
from (select * from fct_monthly_showback_b except distinct select * from fct_monthly_showback_a) as d
union all
select 'fct_monthly_showback', 'only_in_rebuild', d.charge_month, to_json_string(d)
from (select * from fct_monthly_showback_a except distinct select * from fct_monthly_showback_b) as d
union all
select 'fct_customer_monthly' as mart, 'only_in_baseline' as side, d.charge_month as charge_month, to_json_string(d) as row_json
from (select * from fct_customer_monthly_b except distinct select * from fct_customer_monthly_a) as d
union all
select 'fct_customer_monthly', 'only_in_rebuild', d.charge_month, to_json_string(d)
from (select * from fct_customer_monthly_a except distinct select * from fct_customer_monthly_b) as d
union all
select 'fct_customer_service_month' as mart, 'only_in_baseline' as side, d.charge_month as charge_month, to_json_string(d) as row_json
from (select * from fct_customer_service_month_b except distinct select * from fct_customer_service_month_a) as d
union all
select 'fct_customer_service_month', 'only_in_rebuild', d.charge_month, to_json_string(d)
from (select * from fct_customer_service_month_a except distinct select * from fct_customer_service_month_b) as d
union all
select 'fct_credit_runway' as mart, 'only_in_baseline' as side, cast(null as timestamp) as charge_month, to_json_string(d) as row_json
from (select * from fct_credit_runway_b except distinct select * from fct_credit_runway_a) as d
union all
select 'fct_credit_runway', 'only_in_rebuild', cast(null as timestamp), to_json_string(d)
from (select * from fct_credit_runway_a except distinct select * from fct_credit_runway_b) as d
union all
select 'int_customer_map' as mart, 'only_in_baseline' as side, cast(null as timestamp) as charge_month, to_json_string(d) as row_json
from (select * from int_customer_map_b except distinct select * from int_customer_map_a) as d
union all
select 'int_customer_map', 'only_in_rebuild', cast(null as timestamp), to_json_string(d)
from (select * from int_customer_map_a except distinct select * from int_customer_map_b) as d
order by mart, charge_month, side;
