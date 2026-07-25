-- Committed Use Discount (CUD) utilisation and coverage.
-- Covers both spend-based (Spend) and resource-based (Usage) CUDs.
-- commitment_discount_status = 'Used' | 'Unused' shows utilisation.

select
    project_id,
    project_name,
    service_name,
    charge_month,
    commitment_discount_id,
    commitment_discount_name,
    commitment_discount_type,
    commitment_discount_category,
    commitment_discount_status,
    billing_currency,
    count(*)                            as line_count,
    sum(list_cost)                      as list_cost,
    sum(contracted_cost)                as contracted_cost,
    sum(billed_cost)                    as billed_cost

from {{ ref('int_charges') }}
where commitment_discount_id is not null
group by 1, 2, 3, 4, 5, 6, 7, 8, 9, 10
