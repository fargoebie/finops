-- Customer × platform × service × month service-trend mart.
-- Grain: billing_account_id × platform × service_name × charge_month.
-- Measures: effective/billed IDR+USD, gross IDR.
-- MoM LAG partitioned by customer_id × platform × service_name.

{{ config(materialized='view') }}

with charges as (
    select
        billing_account_id,
        platform,
        service_name,
        charge_month,
        billing_currency,
        sum(list_cost)           as gross_cost_idr,
        sum(effective_cost)      as effective_cost_idr,
        sum(billed_cost)         as net_cost_idr,
        sum(effective_cost_usd)  as effective_cost_usd,
        sum(billed_cost_usd)     as net_cost_usd
    from {{ ref('int_charges') }}
    group by 1, 2, 3, 4, 5
)

select
    c.billing_account_id,
    m.customer_name,
    m.customer_id,
    m.billing_account_type,
    c.platform,
    c.service_name,
    c.charge_month,
    c.billing_currency,
    c.gross_cost_idr,
    c.effective_cost_idr,
    c.net_cost_idr,
    c.effective_cost_usd,
    c.net_cost_usd,
    -- MoM: previous month net cost per customer × platform × service
    LAG(c.net_cost_idr) OVER (
        PARTITION BY m.customer_id, c.platform, c.service_name ORDER BY c.charge_month
    ) as mom_prev_net_cost_idr,
    LAG(c.net_cost_usd) OVER (
        PARTITION BY m.customer_id, c.platform, c.service_name ORDER BY c.charge_month
    ) as mom_prev_net_cost_usd,
    c.net_cost_idr - LAG(c.net_cost_idr) OVER (
        PARTITION BY m.customer_id, c.platform, c.service_name ORDER BY c.charge_month
    ) as mom_delta_idr,
    c.net_cost_usd - LAG(c.net_cost_usd) OVER (
        PARTITION BY m.customer_id, c.platform, c.service_name ORDER BY c.charge_month
    ) as mom_delta_usd,
    SAFE_DIVIDE(
        c.net_cost_idr - LAG(c.net_cost_idr) OVER (
            PARTITION BY m.customer_id, c.platform, c.service_name ORDER BY c.charge_month
        ),
        NULLIF(LAG(c.net_cost_idr) OVER (
            PARTITION BY m.customer_id, c.platform, c.service_name ORDER BY c.charge_month
        ), 0)
    ) as mom_delta_pct
from charges c
inner join {{ ref('int_customer_map') }} m
    on c.billing_account_id = m.billing_account_id
