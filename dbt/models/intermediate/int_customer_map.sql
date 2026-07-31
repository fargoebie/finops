-- One row per billing_account_id with resolved customer identity.
-- Priority: seed CSV → org ancestry → '(unmapped)'.
-- customer_id is the roll-up key so a customer's multiple billing IDs collapse.

{{ config(materialized='view') }}

with seed as (
    select
        billing_account_id,
        NULLIF(customer_name, '') as cn,
        NULLIF(customer_id, '')   as cid
    from {{ ref('customer_accounts') }}
),

observed as (
    select distinct
        billing_account_id,
        billing_account_type,
        x_org_ancestor_name
    from {{ ref('stg_focus_billing') }}
)

select
    o.billing_account_id,
    o.billing_account_type,
    COALESCE(s.cn, o.x_org_ancestor_name, '(unmapped)')                             as customer_name,
    COALESCE(s.cid, LOWER(REGEXP_REPLACE(
        COALESCE(s.cn, o.x_org_ancestor_name, 'unmapped'), r'[^a-zA-Z0-9]+', '_'))) as customer_id,
    s.cn IS NOT NULL                                                                 as is_seed_resolved,
    o.x_org_ancestor_name IS NOT NULL                                                as is_ancestry_resolved
from observed o
left join seed s using (billing_account_id)
