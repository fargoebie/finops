-- One row per billing_account_id with resolved customer identity.
-- Priority: seed CSV → org ancestry (excluding the reseller's own org) → '(unmapped)'.
-- customer_id is the roll-up key so a customer's multiple billing IDs collapse.
--
-- NOTE: Terralogiq (the reseller) provisions many customers' projects under its
-- OWN GCP org (terralogiq.com), so that ancestry is NOT a customer signal — it
-- just means "hosted by Terralogiq". We null it out (reseller_org, derived from
-- the Reseller-type account) so those accounts fall to '(unmapped)' until seeded.

{{ config(materialized='view') }}

with seed as (
    select
        billing_account_id,
        NULLIF(customer_name, '') as cn,
        NULLIF(customer_id, '')   as cid
    from {{ ref('customer_accounts') }}
),

observed as (
    select
        billing_account_id,
        any_value(billing_account_type) as billing_account_type,
        max(x_org_ancestor_name)        as x_org_ancestor_name
    from {{ ref('stg_focus_billing') }}
    group by 1
),

reseller_org as (
    select max(x_org_ancestor_name) as org
    from observed
    where billing_account_type = 'Reseller'
),

resolved as (
    select
        o.billing_account_id,
        o.billing_account_type,
        s.cn,
        s.cid,
        -- ancestry is a customer signal only when it is NOT the reseller's own org
        NULLIF(o.x_org_ancestor_name, r.org) as anc
    from observed o
    cross join reseller_org r
    left join seed s using (billing_account_id)
)

select
    billing_account_id,
    billing_account_type,
    COALESCE(cn, anc, '(unmapped)')                                     as customer_name,
    COALESCE(cid, LOWER(REGEXP_REPLACE(
        COALESCE(cn, anc, 'unmapped'), r'[^a-zA-Z0-9]+', '_')))         as customer_id,
    cn  IS NOT NULL                                                     as is_seed_resolved,
    anc IS NOT NULL                                                     as is_ancestry_resolved
from resolved
