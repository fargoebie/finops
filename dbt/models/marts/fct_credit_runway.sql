-- Sales / promotional credit runway: how long until each credit is gone.
-- Grain: credit_id × billing_account_id.
--
-- Burn comes from the billing export. Total amount and end date do NOT exist in
-- the export, and no API exposes them (cloudbilling v1/v1beta have no credits
-- resource; the Cloud Channel API has no credit schema) — they are transcribed
-- by hand into seeds/credit_programs.csv from Console → Billing → Credits.
-- Rows with NULL total_amount_idr / end_date are simply awaiting transcription;
-- burn and staleness still work without them.

{{ config(materialized='view') }}

with bounds as (
    -- Burn and projections use complete days only (the export's final day is
    -- always partial). Staleness is measured against the latest day present,
    -- so a credit applying on that partial day reads as 0 days stale, not -1.
    select
        max(charge_date)                            as latest_day,
        date_sub(max(charge_date), interval 1 day)  as last_complete_day
    from {{ ref('int_credits') }}
),

observed as (
    select
        c.credit_id,
        c.billing_account_id,
        any_value(c.credit_full_name)            as credit_name_observed,
        min(c.charge_date)                       as first_applied,
        max(c.charge_date)                       as last_applied,
        -sum(c.credit_amount)                    as applied_to_date_idr,
        -- trailing 7 complete days
        -sum(case when c.charge_date
                       between date_sub(b.last_complete_day, interval 6 day)
                           and b.last_complete_day
                  then c.credit_amount else 0 end) / 7 as burn_per_day_idr
    from {{ ref('int_credits') }} c
    cross join bounds b
    where c.credit_type = 'PROMOTION'
    group by c.credit_id, c.billing_account_id
),

joined as (
    select
        coalesce(o.credit_id, s.credit_id)                   as credit_id,
        coalesce(s.credit_name, o.credit_name_observed)      as credit_name,
        coalesce(o.billing_account_id, s.billing_account_id) as billing_account_id,
        s.total_amount_idr,
        s.start_date,
        s.end_date,
        s.notes,
        o.first_applied,
        o.last_applied,
        o.applied_to_date_idr,
        o.burn_per_day_idr,
        o.credit_id is null as is_granted_not_yet_used,
        s.credit_id is null as is_unseeded
    from observed o
    full outer join {{ ref('credit_programs') }} s
        on o.credit_id = s.credit_id
)

select
    j.credit_id,
    j.credit_name,
    j.billing_account_id,
    m.billing_account_name,
    m.customer_name,
    m.account_class,
    b.last_complete_day                                          as as_of_date,

    -- transcribed (NULL until filled in from the Console)
    j.total_amount_idr,
    j.start_date,
    j.end_date,

    -- observed
    j.first_applied,
    j.last_applied,
    j.applied_to_date_idr,
    j.burn_per_day_idr,
    date_diff(b.latest_day, j.last_applied, day)                 as days_stale,
    -- still applying within a day of the newest data we have
    coalesce(date_diff(b.latest_day, j.last_applied, day) <= 1, false)
                                                                 as is_active,

    -- derived runway. NULL while total_amount_idr is untranscribed.
    j.total_amount_idr - j.applied_to_date_idr                   as remaining_idr,
    SAFE_DIVIDE(j.applied_to_date_idr, NULLIF(j.total_amount_idr, 0))
                                                                 as consumed_pct,
    case
        when j.burn_per_day_idr > 0 and j.total_amount_idr is not null
        then cast(floor(SAFE_DIVIDE(j.total_amount_idr - j.applied_to_date_idr,
                                    j.burn_per_day_idr)) as int64)
    end                                                          as days_to_exhaustion,
    case
        when j.burn_per_day_idr > 0 and j.total_amount_idr is not null
        then date_add(b.last_complete_day, interval cast(floor(SAFE_DIVIDE(
                 j.total_amount_idr - j.applied_to_date_idr,
                 j.burn_per_day_idr)) as int64) day)
    end                                                          as projected_exhaustion_date,
    date_diff(j.end_date, b.last_complete_day, day)              as days_to_end_date,

    -- Whichever bites first: running out of money, or running out of time.
    -- NULL when neither is known (amount and end_date both untranscribed).
    NULLIF(least(
        coalesce(case
            when j.burn_per_day_idr > 0 and j.total_amount_idr is not null
            then cast(floor(SAFE_DIVIDE(j.total_amount_idr - j.applied_to_date_idr,
                                        j.burn_per_day_idr)) as int64)
        end, 2147483647),
        coalesce(date_diff(j.end_date, b.last_complete_day, day), 2147483647)
    ), 2147483647)                                               as runway_days,

    j.is_granted_not_yet_used,
    j.is_unseeded,
    j.notes
from joined j
cross join bounds b
left join {{ ref('int_customer_map') }} m
    on j.billing_account_id = m.billing_account_id
