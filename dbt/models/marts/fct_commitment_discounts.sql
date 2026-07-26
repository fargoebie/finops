-- CUD credits by project/service/month, sourced from x_Credits UNNEST.
-- Covers both resource-based (COMMITTED_USAGE_DISCOUNT) and
-- spend-based (COMMITTED_USAGE_DISCOUNT_DOLLAR_BASE) CUDs.

select
    project_id,
    project_name,
    service_name,
    charge_month,
    credit_type                     as commitment_discount_type,
    billing_currency,
    count(*)                        as line_count,
    sum(credit_amount)              as total_cud_credit

from {{ ref('int_credits') }}
where credit_type in (
    'COMMITTED_USAGE_DISCOUNT',
    'COMMITTED_USAGE_DISCOUNT_DOLLAR_BASE'
)
group by 1, 2, 3, 4, 5, 6
