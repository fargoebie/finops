# Plan: dbt cost — materialize instead of views

Status: **implemented, not yet run** (2026-10-30). Code is in the working tree; `dbt parse` and `dbt compile` pass; every model and tool query is dry-run. No real build has run yet. Next: the run order below. No Beads in this repo; this file is the tracker.

## Problem

Every model was a view, so every query re-ran `stg → int → fct` over the raw billing rows.
- **Cost:** about 7 TB per `dbt build`, and 130–270 GB per Metabase card even when filtered to one month. On 2026-10-30 about 31 TB, about $176.
- **Causes, all measured with dry runs:**
  - Wide nested columns. Over full history `x_Project` is about 115 GB per source, labels/tags about 195 GB, one NUMERIC column 10–18 GB.
  - Nothing pruned. The FOCUS export is partitioned by ingestion time (`_PARTITIONTIME`), so `ChargePeriodStart` filters never prune it.
  - Each of the 36 tests was a separate query over a view.

## Goal (done means)

- Metabase cards and mart tests read small tables (MB, not GB).
- Nightly `dbt run` at or under about 100 GB, measured with `INFORMATION_SCHEMA.JOBS_BY_USER` after the first incremental run.
- One-time full build about 1.4 TB.
- Mart contents unchanged: `tools/dbt_cost/compare_to_baseline.sql` shows no diff outside the rows fed by the newest two export days (see Design).
- A hard spend cap: `maximum_bytes_billed` in every dbt profile, so a mistake fails instead of billing.

## Design (as built)

```
finops_history.focus_billing_history   (frozen, partitioned by ChargePeriodStart)
FOCUS export                           (partitioned by _PARTITIONDATE = export day)
        │
stg_focus_billing          incremental TABLE (merge ON FALSE = append), partition charge_date, cluster billing_account_id, service_name
        │                  full refresh: history (< cutover) ∪ FOCUS (>= cutover) from closed export days
        │                  incremental:  FOCUS export days > max(export_day) and <= current_date - 2
        │                  drops x_labels, x_system_labels, x_project_labels, x_tags
        ├─ int_charges               incremental TABLE, insert_overwrite by charge_date, day-grain sums + row_count
        ├─ int_credits               incremental TABLE, same, over unnest(x_credits)
        └─ int_billing_account_days  incremental TABLE, same, per account × day over every stg row
                │
           int_customer_map          TABLE, from int_billing_account_days
                │
           fct_* (7)                 TABLEs, rebuilt nightly from the int tables
```

- **stg is append-only, keyed on `export_day` (`_PARTITIONDATE`).**
  - A FOCUS export partition is loaded once, after it has closed: `export_day <= current_date() - 2` (UTC). The free check on 2026-10-30 found modifications stop within about 1.5 days of the partition day (99 partitions; the only exceptions were the 2026-07-25/26 enablement backfill).
  - Incremental runs append `export_day > max(export_day)`, so a missed night self-heals. No DELETE: a DML DELETE bills every column of every partition it touches.
  - Full refresh applies the same `<= current_date() - 2` bound, so open days are never loaded half-finished.
  - History rows have `export_day` NULL and are only rebuilt by `--full-refresh`.
  - Consequence: dashboards lag the export by about two days.
  - Two concurrent appends would load the same export days twice, so cron and `deploy.sh dbt-run` wrap `dbt run` in `flock -n /var/lock/finops-dbt.lock`.
- **MERGE billing:** dbt-bigquery has no `append` strategy; `merge` without `unique_key` emits `MERGE … ON (FALSE) WHEN NOT MATCHED THEN INSERT`. Dry-run on an 899 GB target: billed bytes equal the source SELECT alone (13.33 GB both), so the target is not billed.
- **Int models** (`int_charges`, `int_credits`, `int_billing_account_days`) rebuild, by `insert_overwrite`, every stg `charge_date` partition whose `INFORMATION_SCHEMA.PARTITIONS.last_modified_time` is at or after the int's `max(built_at)`.
  - `built_at` is a data column (start of the build), not the int's own partition metadata, so background re-clustering cannot advance the watermark.
  - A failed night self-heals: `max(built_at)` stays at the last successful build.
  - The metadata query costs about 20 MB.
- **Aggregates carry only what the marts read** (audit in the 2026-10-30 handoff). `count(*)` in `fct_commitment_discounts.line_count` and `fct_credit_breakdown.credit_line_count` became `sum(row_count)`. Mart names, columns and types are unchanged.
- **`int_customer_map`** reads `int_billing_account_days`, which covers every stg row. `int_charges ∪ int_credits` would miss an account whose only rows are Credit/Adjustment rows without `x_Credits` (`tools/dbt_cost/credit_adjustment_only_accounts.sql` lists them).
- **Macros:** `dbt/macros/incremental_windows.sql` (`stg_focus_watermark`, `changed_upstream_partitions`). The watermark returns nothing without querying when stg is missing or still a view.

## Guardrails

- `maximum_bytes_billed`: 150 GB on the default target (`dev` locally, `prod` on the VM), and a `full_refresh` target with 1.5 TB and `timeout_seconds: 3600`. In `dbt/profiles.yml` (gitignored), `dbt/profiles.yml.example`, and `deploy.sh cmd_profiles`.
- Tests:
  - `assert_history_matches_focus_overlap` is tagged `reconciliation` (95.5 GB); exclude it from routine runs with `--exclude tag:reconciliation`.
  - `assert_focus_partitions_closed` is tagged `monitoring`, severity warn, about 20 MB. It warns if a FOCUS partition changed more than 2 days after its day and after stg was created, i.e. a change the append missed.
  - The 5 stg column tests are scoped to the last 7 charge days.
- Every model dry-run before its first real run (numbers in the 2026-10-30 handoff).

## Run order (remaining work)

1. `./infra/scripts/deploy.sh profiles`: writes the VM profile with the caps and the `full_refresh` target.
2. **Baseline:** `bq mk --dataset --location=asia-southeast2 gcp-coe-492507:scratch_cost_baseline`, then run `tools/dbt_cost/baseline_snapshot.sql`. Dry-run total about 1.89 TB (7 marts + `int_customer_map`). It must run before any dbt run replaces the views.
3. **Full build:** `dbt run --full-refresh --target full_refresh` (about 1.4 TB; largest query is stg at 924 GB). Under `flock` on the VM.
   - Until this has run, the nightly cron fails safely at the 150 GB cap, because every relation is still a view and takes the full-build path.
4. **Compare:** `tools/dbt_cost/compare_to_baseline.sql`. Expect diffs only in the newest charge_month and `fct_credit_runway`, because the rebuild omits the two open export days.
5. **Gate:** read the int table sizes from `INFORMATION_SCHEMA.PARTITIONS` (free). If seven nightly mart rebuilds exceed about 30 GB, make the marts incremental by month.
6. **First incremental:** `dbt run` on the default target, then `tools/dbt_cost/check_incremental.sql` (must return no rows), then measure bytes in `INFORMATION_SCHEMA.JOBS_BY_USER`. Before the first incremental, `dbt compile` and dry-run the compiled incremental SQL of stg and the three int models.
7. `dbt test --exclude tag:reconciliation`.
8. Docs: HANDOFF.md.

**Recovery.** After an outage long enough that the catch-up append exceeds 150 GB (about two weeks of export days), run `dbt run --target full_refresh` once, without `--full-refresh`. Use a full refresh only for schema changes (`on_schema_change` is ignore) or if `assert_focus_partitions_closed` warns.

## File ownership

| File | Change |
|---|---|
| `dbt/models/staging/stg_focus_billing.sql` | incremental append config, closed-day bounds, `export_day`, drop label/tag columns |
| `dbt/models/intermediate/int_charges.sql`, `int_credits.sql` | incremental day-grain aggregates, `row_count`, `built_at` |
| `dbt/models/intermediate/int_billing_account_days.sql` | new, account × day attributes for `int_customer_map` |
| `dbt/models/intermediate/int_customer_map.sql` | table, reads `int_billing_account_days` |
| `dbt/models/marts/*.sql` | tables; `count(*)` → `sum(row_count)` in two marts |
| `dbt/macros/incremental_windows.sql` | watermark and changed-partition macros |
| `dbt/dbt_project.yml` | intermediate and marts materialized as tables |
| `dbt/profiles.yml`, `dbt/profiles.yml.example`, `infra/scripts/deploy.sh` (`cmd_profiles`, `cmd_dbt_run`) | spend caps, `full_refresh` target, flock |
| `infra/scripts/vm-startup.sh` | cron under flock; full-refresh and recovery notes |
| `dbt/tests/assert_history_matches_focus_overlap.sql` | tag `reconciliation` |
| `dbt/tests/assert_focus_partitions_closed.sql` | new, tag `monitoring`, warn |
| `dbt/models/*/schema.yml` | docs; stg tests scoped to 7 days |
| `tools/dbt_cost/baseline_snapshot.sql`, `compare_to_baseline.sql`, `check_incremental.sql`, `credit_adjustment_only_accounts.sql` | baseline, diff, post-run check, coverage query |
| `AGENTS.md`, `docs/ROADMAP.md`, this plan | docs |

## Risks

- **Two-day data lag** by design. Late modifications to a partition older than 2 days are missed; `assert_focus_partitions_closed` warns, and a full refresh repairs.
- **Mart rebuild cost is unmeasured** until the int tables exist; see the gate in step 5.
- **Int correctness rests on stg partition `last_modified_time` being updated at DML commit.** `check_incremental.sql` verifies it exactly after the first incremental run. Re-clustering of stg only causes extra reprocessing.
- **Dropped label/tag columns** affect anyone querying stg for them, such as Nanda; query the source tables instead.
- **Ad-hoc users of `int_charges`/`int_credits`** lose row-level detail and `charge_category`; stg keeps it.
- **`dbt compile` / `docs generate` cost.** Once stg is a table, each run executes the watermark query (about 3.2 GB).

## Outcome (executed 2026-10-30)

- **Baseline snapshot:** 7 marts plus `int_customer_map` into `scratch_cost_baseline`, 1.72 TiB. The dataset has a 30-day default table expiration.
- **Full build:** `dbt run --full-refresh --target full_refresh`, PASS=12, 1.21 TiB.
  - stg: 868M rows, 860 GiB.
  - `int_charges`: 5.4M rows, 193 GiB.
  - `int_credits`: 1.4M rows, 138 GiB.
  - `int_billing_account_days`: 62k rows, 42 GiB.
  - Marts: 3.3 GiB in total.
- **Total billed for snapshot plus build:** 2.95 TiB, about $18.40.
  - In `JOBS_BY_USER`, a SCRIPT parent job repeats its children's bytes. Exclude `statement_type='SCRIPT'` when summing.
- **Compare to baseline:**
  - `int_customer_map` matches exactly.
  - Marts differ only in 2026-10 (the two open export days, by design) and `fct_credit_runway`.
  - Exception: `fct_customer_service_month` differed in every month, but only in the MoM columns. This was an existing bug: LAG partitioned by `customer_id` jumped to sibling accounts (e.g. Mapmaster.AI Production/Demo), nondeterministically.
  - Fixed to partition by `billing_account_id`, as `fct_customer_monthly` does. With the MoM columns excluded and USD rounded to 4 dp, the result matches the baseline exactly for every month before 2026-10.
- **First incremental run (no new closed export day):** 6.7 GB billed, about 3.4 of it the stg watermark and about 3.3 the marts.
  - A night with one new export day adds about 7 GB for the stg append plus about 13 GB for the ints, so about 27 GB a night (about $0.15).
- **Tests:** `dbt test --exclude tag:reconciliation` gives PASS=36 for 0.5 GB, against about 7 TB before. Both warn tests are now clear.
- **`check_incremental.sql`:** 0 mismatch rows (20 GB).
- **Remaining:**
  - Deploy to the VM (`deploy.sh profiles`, then sync) when `finops-vm` is rebuilt.
  - The first nightly run should be followed by `check_incremental.sql`.
  - `scratch_cost_baseline` tables expire on their own.
