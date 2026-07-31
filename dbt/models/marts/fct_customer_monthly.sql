-- Customer × platform × month BOD mart.
-- Grain: billing_account_id × platform × charge_month.
-- Carries IDR (native) and USD (row-level derived) for gross/contracted/effective/net.
-- Credits split into cud/sud/promo/free_tier/other (IDR).
-- MoM deltas via LAG partitioned by customer_id × platform.

{{ config(materialized='view') }}

with charges as (
    select
        billing_account_id,
        platform,
        charge_month,
        billing_currency,
        sum(list_cost)           as gross_cost_idr,
        sum(contracted_cost)     as contracted_cost_idr,
        sum(effective_cost)      as effective_cost_idr,
        sum(billed_cost)         as net_cost_idr,
        sum(list_cost_usd)       as gross_cost_usd,
        sum(contracted_cost_usd) as contracted_cost_usd,
        sum(effective_cost_usd)  as effective_cost_usd,
        sum(billed_cost_usd)     as net_cost_usd
    from {{ ref('int_charges') }}
    group by 1, 2, 3, 4
),

credits_agg as (
    select
        billing_account_id,
        platform,
        charge_month,
        sum(credit_amount) as total_credits_idr,
        sum(case when credit_type in (
                     'COMMITTED_USAGE_DISCOUNT',
                     'COMMITTED_USAGE_DISCOUNT_DOLLAR_BASE'
                 ) then credit_amount else 0 end) as cud_credits_idr,
        sum(case when credit_type = 'SUSTAINED_USAGE_DISCOUNT'
                 then credit_amount else 0 end)   as sud_credits_idr,
        sum(case when credit_type = 'PROMOTION'
                 then credit_amount else 0 end)   as promo_credits_idr,
        sum(case when credit_type = 'FREE_TIER'
                 then credit_amount else 0 end)   as free_tier_credits_idr,
        sum(case when credit_type not in (
                     'COMMITTED_USAGE_DISCOUNT',
                     'COMMITTED_USAGE_DISCOUNT_DOLLAR_BASE',
                     'SUSTAINED_USAGE_DISCOUNT',
                     'PROMOTION',
                     'FREE_TIER'
                 ) then credit_amount else 0 end) as other_credits_idr
    from {{ ref('int_credits') }}
    group by 1, 2, 3
),

joined as (
    select
        c.billing_account_id,
        m.customer_name,
        m.customer_id,
        m.billing_account_type,
        c.platform,
        c.charge_month,
        c.billing_currency,
        c.gross_cost_idr,
        c.contracted_cost_idr,
        c.effective_cost_idr,
        c.net_cost_idr,
        c.gross_cost_usd,
        c.contracted_cost_usd,
        c.effective_cost_usd,
        c.net_cost_usd,
        coalesce(cr.total_credits_idr,    0) as total_credits_idr,
        coalesce(cr.cud_credits_idr,      0) as cud_credits_idr,
        coalesce(cr.sud_credits_idr,      0) as sud_credits_idr,
        coalesce(cr.promo_credits_idr,    0) as promo_credits_idr,
        coalesce(cr.free_tier_credits_idr,0) as free_tier_credits_idr,
        coalesce(cr.other_credits_idr,    0) as other_credits_idr,
        SAFE_DIVIDE(c.effective_cost_idr, NULLIF(c.gross_cost_idr, 0)) as effective_discount_pct
    from charges c
    inner join {{ ref('int_customer_map') }} m
        on c.billing_account_id = m.billing_account_id
    left join credits_agg cr
        on  c.billing_account_id = cr.billing_account_id
        and c.platform           = cr.platform
        and c.charge_month       = cr.charge_month
)

select
    billing_account_id,
    customer_name,
    customer_id,
    billing_account_type,
    platform,
    charge_month,
    billing_currency,
    gross_cost_idr,
    contracted_cost_idr,
    effective_cost_idr,
    net_cost_idr,
    gross_cost_usd,
    contracted_cost_usd,
    effective_cost_usd,
    net_cost_usd,
    total_credits_idr,
    cud_credits_idr,
    sud_credits_idr,
    promo_credits_idr,
    free_tier_credits_idr,
    other_credits_idr,
    -- ALL-IN discount off list (effective_cost already includes credits; effective = contracted + credits).
    -- Rate-only discount (pre-credit) = 1 - contracted/gross. do NOT AVG across rows — aggregate 1 - SUM(effective)/SUM(gross).
    -- effective_discount_pct: 0 means no discount, 1 means full discount
    1 - SAFE_DIVIDE(effective_cost_idr, NULLIF(gross_cost_idr, 0)) as effective_discount_pct,
    -- MoM: previous month net cost (NULL until second month accrues).
    -- Partition by billing_account_id (the mart grain) NOT customer_id: a
    -- customer can hold many billing accounts, and partitioning by customer_id
    -- would sequence sibling accounts within one month and fabricate deltas.
    -- Customer-level MoM = SUM(mom_delta_*) across the customer's accounts.
    LAG(net_cost_idr) OVER (
        PARTITION BY billing_account_id, platform ORDER BY charge_month
    ) as mom_prev_net_cost_idr,
    LAG(net_cost_usd) OVER (
        PARTITION BY billing_account_id, platform ORDER BY charge_month
    ) as mom_prev_net_cost_usd,
    net_cost_idr - LAG(net_cost_idr) OVER (
        PARTITION BY billing_account_id, platform ORDER BY charge_month
    ) as mom_delta_idr,
    net_cost_usd - LAG(net_cost_usd) OVER (
        PARTITION BY billing_account_id, platform ORDER BY charge_month
    ) as mom_delta_usd,
    SAFE_DIVIDE(
        net_cost_idr - LAG(net_cost_idr) OVER (
            PARTITION BY billing_account_id, platform ORDER BY charge_month
        ),
        NULLIF(LAG(net_cost_idr) OVER (
            PARTITION BY billing_account_id, platform ORDER BY charge_month
        ), 0)
    ) as mom_delta_pct
from joined
