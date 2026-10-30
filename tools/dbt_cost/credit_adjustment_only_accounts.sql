-- Billing accounts whose only stg_focus_billing rows are Credit/Adjustment rows with no x_credits.
-- int_charges (Usage/Purchase/Tax) and int_credits (unnested x_credits) never see such an account, which
-- is why int_customer_map reads int_billing_account_days (every stg row) instead of those two.
-- Expected result: empty, or the accounts that int_billing_account_days exists to keep.
-- Against the stg_focus_billing table this scans billing_account_id, charge_category and x_credits.
select
    billing_account_id,
    count(*)                    as rows_total,
    min(charge_date)            as first_charge_date,
    max(charge_date)            as last_charge_date
from `gcp-coe-492507.dbt_staging.stg_focus_billing`
group by billing_account_id
having countif(charge_category in ('Usage', 'Purchase', 'Tax')
               or array_length(x_credits) > 0) = 0
order by billing_account_id;
