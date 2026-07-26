-- Project-level monthly showback with full credit attribution.
-- Join charges + credits to produce a single summary row per project/month.

with charges as (
    select
        project_id,
        project_name,
        charge_month,
        billing_currency,
        sum(list_cost)          as gross_cost,
        sum(contracted_cost)    as contracted_cost,
        sum(effective_cost)     as effective_cost,
        sum(billed_cost)        as net_cost
    from {{ ref('int_charges') }}
    group by 1, 2, 3, 4
),

credits_pivot as (
    select
        project_id,
        charge_month,
        sum(credit_amount)                                                              as total_credits,
        sum(case when credit_type in (
                     'COMMITTED_USAGE_DISCOUNT',
                     'COMMITTED_USAGE_DISCOUNT_DOLLAR_BASE'
                 ) then credit_amount else 0 end)                                       as cud_credits,
        sum(case when credit_type = 'SUSTAINED_USAGE_DISCOUNT'
                 then credit_amount else 0 end)                                         as sud_credits,
        sum(case when credit_type = 'PROMOTION'
                 then credit_amount else 0 end)                                         as promotional_credits,
        sum(case when credit_type = 'FREE_TIER'
                 then credit_amount else 0 end)                                         as free_tier_credits,
        sum(case when credit_type not in (
                     'COMMITTED_USAGE_DISCOUNT',
                     'COMMITTED_USAGE_DISCOUNT_DOLLAR_BASE',
                     'SUSTAINED_USAGE_DISCOUNT',
                     'PROMOTION',
                     'FREE_TIER'
                 ) then credit_amount else 0 end)                                       as other_credits
    from {{ ref('int_credits') }}
    group by 1, 2
)

select
    c.project_id,
    c.project_name,
    c.charge_month,
    c.billing_currency,
    c.gross_cost,
    c.contracted_cost,
    c.effective_cost,
    c.net_cost,
    coalesce(cr.total_credits, 0)           as total_credits,
    coalesce(cr.cud_credits, 0)             as cud_credits,
    coalesce(cr.sud_credits, 0)             as sud_credits,
    coalesce(cr.promotional_credits, 0)     as promotional_credits,
    coalesce(cr.free_tier_credits, 0)       as free_tier_credits,
    coalesce(cr.other_credits, 0)           as other_credits,
    c.gross_cost - c.contracted_cost        as negotiated_savings
from charges c
left join credits_pivot cr
    on  c.project_id   = cr.project_id
    and c.charge_month = cr.charge_month
