-- Baseline snapshot of every mart and of int_customer_map, taken from the CURRENT view-based models before the switch to
-- tables (docs/plans/dbt-cost-materialization.md, step 1). compare_to_baseline.sql diffs against it.
--
-- Run once, before any `dbt run` of the materialized models (dbt replaces these views with tables):
--   bq mk --dataset --location=asia-southeast2 gcp-coe-492507:scratch_cost_baseline
--   bq --project_id=gcp-coe-492507 --location=asia-southeast2 query --use_legacy_sql=false \
--      --maximum_bytes_billed=2000000000000 < tools/dbt_cost/baseline_snapshot.sql
--
-- Cost: each SELECT re-runs a view chain over the raw billing rows. Dry-run total 2026-10-30:
-- about 1.89 TB (7 marts 1.72 TB + int_customer_map 0.16 TB). Run the full rebuild right after this script: the
-- FOCUS export keeps landing, so rows for the newest charge days can differ if it advances in
-- between. _snapshot_meta records the export's state at snapshot time.
--
-- CREATE TABLE, not CREATE OR REPLACE: re-running after the switch must fail, not overwrite the
-- baseline with post-switch data.

create table `gcp-coe-492507.scratch_cost_baseline._snapshot_meta` as
select
    current_timestamp()      as snapshot_at,
    max(last_modified_time)  as focus_last_modified
from `terra-coe-finops.gcp_billing_immutable_01A09A_A37EA6_F0AC6C_asia_southeast2.INFORMATION_SCHEMA.PARTITIONS`
where table_name = 'gcp_billing_export_focus_01A09A_A37EA6_F0AC6C';

create table `gcp-coe-492507.scratch_cost_baseline.fct_spend_waterfall` as
select * from `gcp-coe-492507.finops_dbt.fct_spend_waterfall`;

create table `gcp-coe-492507.scratch_cost_baseline.fct_credit_breakdown` as
select * from `gcp-coe-492507.finops_dbt.fct_credit_breakdown`;

create table `gcp-coe-492507.scratch_cost_baseline.fct_commitment_discounts` as
select * from `gcp-coe-492507.finops_dbt.fct_commitment_discounts`;

create table `gcp-coe-492507.scratch_cost_baseline.fct_monthly_showback` as
select * from `gcp-coe-492507.finops_dbt.fct_monthly_showback`;

create table `gcp-coe-492507.scratch_cost_baseline.fct_customer_monthly` as
select * from `gcp-coe-492507.finops_dbt.fct_customer_monthly`;

create table `gcp-coe-492507.scratch_cost_baseline.fct_customer_service_month` as
select * from `gcp-coe-492507.finops_dbt.fct_customer_service_month`;

create table `gcp-coe-492507.scratch_cost_baseline.fct_credit_runway` as
select * from `gcp-coe-492507.finops_dbt.fct_credit_runway`;

create table `gcp-coe-492507.scratch_cost_baseline.int_customer_map` as
select * from `gcp-coe-492507.dbt_intermediate.int_customer_map`;
