-- One row per credit type per project/service/month.
-- Primary Metabase source for "what credits am I getting and why?" questions.

select
    project_id,
    project_name,
    service_name,
    service_category,
    region_id,
    charge_month,
    credit_type,
    billing_currency,
    count(*)                            as credit_line_count,
    sum(credit_amount)                  as total_credit_amount

from {{ ref('int_credits') }}
group by 1, 2, 3, 4, 5, 6, 7, 8
