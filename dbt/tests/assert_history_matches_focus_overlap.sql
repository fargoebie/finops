-- Reconciliation: the detailed-export conversion must reproduce the live FOCUS export.
-- focus_billing_history also holds rows from the cutover to overlap_end, where the live FOCUS export
-- has data too. stg_focus_billing never reads those rows; they are a fixture. If the converted rows agree
-- with FOCUS, the pre-cutover rows that only the conversion covers can be trusted.
--
-- Returns one row per failing group; `check_name` says which check failed:
--   * cost_grain:   per (billing account, project, month, charge category, service). Fails when missing on
--                   either side, or |difference| >= 0.01 (IDR) in list, contracted or billed cost or in
--                   total credits (sum of x_Credits.Amount), or >= 0.001 in billed USD (row-level
--                   BilledCost / x_CurrencyConversionRate, summed).
--   * credit_grain: per (billing account, month, credit Type, credit Id) over unnest(x_Credits), summing
--                   Amount. Fails when missing on either side or |difference| >= 0.01.
-- Compare sums, never row counts: FOCUS splits rows more finely than the detailed export.
--
-- Caveats:
--   * ChargePeriodStart is not a partition key of the FOCUS export, so this scans most of that table.
--   * The history table is frozen when it is built. Google keeps posting corrections to recent usage in
--     the live FOCUS export (rows arrive ~7 days late), so this can turn red later without the
--     conversion being wrong. Rebuild focus_billing_history to re-baseline.
--   * Reconcile only after the most recent ~3 days have settled (overlap_end is well past that).
-- overlap_end must equal the upper bound of the window in tools/history_backfill/02_convert.sql.

{% set cutover = var('focus_cutover_date') %}
{% set overlap_end = '2026-10-01' %}

{% if not ('2026-01-01' <= cutover < overlap_end) %}
    {{ exceptions.raise_compiler_error("focus_cutover_date (" ~ cutover ~ ") must satisfy 2026-01-01 <= cutover < " ~ overlap_end ~ " (the history window); otherwise the overlap window is empty or inverted and this test would pass vacuously.") }}
{% endif %}

with hist as (
    select
        BillingAccountId,
        coalesce(SubAccountId, '(null)')                                as SubAccountId,
        timestamp_trunc(ChargePeriodStart, month)                       as charge_month,
        ChargeCategory,
        coalesce(ServiceName, '(null)')                                 as ServiceName,
        sum(coalesce(ListCost, 0))                                      as list_cost,
        sum(coalesce(ContractedCost, 0))                                as contracted_cost,
        sum(coalesce(BilledCost, 0))                                    as billed_cost,
        sum(safe_divide(coalesce(BilledCost, 0), nullif(x_CurrencyConversionRate, 0))) as billed_usd,
        sum(coalesce((select sum(c.Amount) from unnest(x_Credits) c), 0)) as credits
    from {{ source('finops_history', 'focus_billing_history') }}
    where ChargePeriodStart >= timestamp('{{ cutover }}')
      and ChargePeriodStart <  timestamp('{{ overlap_end }}')
    group by 1, 2, 3, 4, 5
),

live as (
    select
        BillingAccountId,
        coalesce(SubAccountId, '(null)')                                as SubAccountId,
        timestamp_trunc(ChargePeriodStart, month)                       as charge_month,
        ChargeCategory,
        coalesce(ServiceName, '(null)')                                 as ServiceName,
        sum(coalesce(ListCost, 0))                                      as list_cost,
        sum(coalesce(ContractedCost, 0))                                as contracted_cost,
        sum(coalesce(BilledCost, 0))                                    as billed_cost,
        sum(safe_divide(coalesce(BilledCost, 0), nullif(x_CurrencyConversionRate, 0))) as billed_usd,
        sum(coalesce((select sum(c.Amount) from unnest(x_Credits) c), 0)) as credits
    from {{ source('gcp_billing', 'focus_export') }}
    where ChargePeriodStart >= timestamp('{{ cutover }}')
      and ChargePeriodStart <  timestamp('{{ overlap_end }}')
    group by 1, 2, 3, 4, 5
),

hist_credits as (
    select
        BillingAccountId,
        timestamp_trunc(ChargePeriodStart, month)                       as charge_month,
        coalesce(c.Type, '(null)')                                      as credit_type,
        coalesce(c.Id, '(null)')                                        as credit_id,
        sum(coalesce(c.Amount, 0))                                      as credit_amount
    from {{ source('finops_history', 'focus_billing_history') }}, unnest(x_Credits) c
    where ChargePeriodStart >= timestamp('{{ cutover }}')
      and ChargePeriodStart <  timestamp('{{ overlap_end }}')
    group by 1, 2, 3, 4
),

live_credits as (
    select
        BillingAccountId,
        timestamp_trunc(ChargePeriodStart, month)                       as charge_month,
        coalesce(c.Type, '(null)')                                      as credit_type,
        coalesce(c.Id, '(null)')                                        as credit_id,
        sum(coalesce(c.Amount, 0))                                      as credit_amount
    from {{ source('gcp_billing', 'focus_export') }}, unnest(x_Credits) c
    where ChargePeriodStart >= timestamp('{{ cutover }}')
      and ChargePeriodStart <  timestamp('{{ overlap_end }}')
    group by 1, 2, 3, 4
),

cost_grain_failures as (
    select
        'cost_grain'                                      as check_name,
        coalesce(h.BillingAccountId, l.BillingAccountId)  as billing_account_id,
        coalesce(h.SubAccountId, l.SubAccountId)          as sub_account_id,
        coalesce(h.charge_month, l.charge_month)          as charge_month,
        coalesce(h.ChargeCategory, l.ChargeCategory)      as charge_category,
        coalesce(h.ServiceName, l.ServiceName)            as service_name,
        cast(null as string)                              as credit_type,
        cast(null as string)                              as credit_id,
        case
            when l.BillingAccountId is null then 'missing_in_focus'
            when h.BillingAccountId is null then 'missing_in_history'
            else 'amount_mismatch'
        end                                               as failure,
        h.list_cost        as history_list_cost,        l.list_cost        as focus_list_cost,
        h.contracted_cost  as history_contracted_cost,  l.contracted_cost  as focus_contracted_cost,
        h.billed_cost      as history_billed_cost,      l.billed_cost      as focus_billed_cost,
        h.billed_usd       as history_billed_usd,       l.billed_usd       as focus_billed_usd,
        h.credits          as history_credits,          l.credits          as focus_credits
    from hist h
    full outer join live l
        on  h.BillingAccountId = l.BillingAccountId
        and h.SubAccountId     = l.SubAccountId
        and h.charge_month     = l.charge_month
        and h.ChargeCategory   = l.ChargeCategory
        and h.ServiceName      = l.ServiceName
    where h.BillingAccountId is null
       or l.BillingAccountId is null
       or abs(coalesce(h.list_cost, 0)       - coalesce(l.list_cost, 0))       >= 0.01
       or abs(coalesce(h.contracted_cost, 0) - coalesce(l.contracted_cost, 0)) >= 0.01
       or abs(coalesce(h.billed_cost, 0)     - coalesce(l.billed_cost, 0))     >= 0.01
       or abs(coalesce(h.billed_usd, 0)      - coalesce(l.billed_usd, 0))      >= 0.001
       or abs(coalesce(h.credits, 0)         - coalesce(l.credits, 0))         >= 0.01
),

credit_grain_failures as (
    select
        'credit_grain'                                    as check_name,
        coalesce(h.BillingAccountId, l.BillingAccountId)  as billing_account_id,
        cast(null as string)                              as sub_account_id,
        coalesce(h.charge_month, l.charge_month)          as charge_month,
        cast(null as string)                              as charge_category,
        cast(null as string)                              as service_name,
        coalesce(h.credit_type, l.credit_type)            as credit_type,
        coalesce(h.credit_id, l.credit_id)                as credit_id,
        case
            when l.BillingAccountId is null then 'missing_in_focus'
            when h.BillingAccountId is null then 'missing_in_history'
            else 'amount_mismatch'
        end                                               as failure,
        cast(null as numeric) as history_list_cost,        cast(null as numeric) as focus_list_cost,
        cast(null as numeric) as history_contracted_cost,  cast(null as numeric) as focus_contracted_cost,
        cast(null as numeric) as history_billed_cost,      cast(null as numeric) as focus_billed_cost,
        cast(null as float64) as history_billed_usd,       cast(null as float64) as focus_billed_usd,
        h.credit_amount       as history_credits,          l.credit_amount       as focus_credits
    from hist_credits h
    full outer join live_credits l
        on  h.BillingAccountId = l.BillingAccountId
        and h.charge_month     = l.charge_month
        and h.credit_type      = l.credit_type
        and h.credit_id        = l.credit_id
    where h.BillingAccountId is null
       or l.BillingAccountId is null
       or abs(coalesce(h.credit_amount, 0) - coalesce(l.credit_amount, 0)) >= 0.01
)

select * from cost_grain_failures
union all
select * from credit_grain_failures
