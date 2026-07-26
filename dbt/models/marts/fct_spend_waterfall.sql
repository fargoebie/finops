-- Monthly spend waterfall per project/service/sku.
-- Shows exactly where money goes at each discount step:
--   list_cost          → gross price (no discounts)
--   contracted_cost    → after EDP / negotiated rate
--   effective_cost     → after pre-credit adjustments
--   billed_cost        → final amount charged
--
-- negotiated_savings = list_cost - contracted_cost  (EDP / contracted rate vs list)
-- credit_savings     = contracted_cost - effective_cost
-- other_adjustments  = effective_cost - billed_cost
-- total_discount     = list_cost - billed_cost

select
    project_id,
    project_name,
    service_name,
    region_id,
    sku_id,
    charge_month,
    billing_currency,

    sum(list_cost)                                  as list_cost,
    sum(contracted_cost)                            as contracted_cost,
    sum(effective_cost)                             as effective_cost,
    sum(billed_cost)                                as billed_cost,

    sum(list_cost) - sum(contracted_cost)           as negotiated_savings,
    sum(contracted_cost) - sum(effective_cost)      as credit_savings,
    sum(effective_cost) - sum(billed_cost)          as other_adjustments,
    sum(list_cost) - sum(billed_cost)               as total_discount

from {{ ref('int_charges') }}
group by 1, 2, 3, 4, 5, 6, 7
