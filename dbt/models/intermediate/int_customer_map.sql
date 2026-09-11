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
        NULLIF(customer_name, '')  as cn,
        NULLIF(customer_id, '')    as cid,
        NULLIF(account_class, '')  as cls
    from {{ ref('customer_accounts') }}
),

-- Display names come from the Cloud Billing API (the FOCUS export has none).
-- TRIM because a few displayNames carry stray whitespace/tabs.
names as (
    select
        billing_account_id,
        NULLIF(TRIM(billing_account_name), '') as ban
    from {{ ref('billing_accounts') }}
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
        s.cls,
        n.ban,
        -- ancestry is a customer signal only when it is NOT the reseller's own org
        NULLIF(o.x_org_ancestor_name, r.org) as anc
    from observed o
    cross join reseller_org r
    left join seed s using (billing_account_id)
    left join names n using (billing_account_id)
)

select
    billing_account_id,
    COALESCE(ban, '(unnamed)')                                          as billing_account_name,
    billing_account_type,
    -- production | trial | internal, from the seed. 'unclassified' means a new
    -- billing account has appeared in the export with no seed row yet.
    COALESCE(cls, 'unclassified')                                       as account_class,
    COALESCE(cn, anc, '(unmapped)')                                     as customer_name,
    COALESCE(cid, LOWER(REGEXP_REPLACE(
        COALESCE(cn, anc, 'unmapped'), r'[^a-zA-Z0-9]+', '_')))         as customer_id,
    cn  IS NOT NULL                                                     as is_seed_resolved,
    anc IS NOT NULL                                                     as is_ancestry_resolved
from resolved
