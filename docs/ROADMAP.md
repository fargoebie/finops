# FinOps Roadmap

This document is a backlog of future ideas for the GCP FinOps analytics stack. Nothing here is a committed plan — items are collected for prioritisation and reference. The current stack (GCP FOCUS billing export → dbt Core → Metabase on e2-medium VM) is the baseline all ideas extend from.

---

## Section 1: Additional Billing Export Pipelines

The current pipeline ingests only the FOCUS billing export. GCP exposes three additional exports that each bring distinct analytical value. The common pattern across all three is a new staging model that maps source columns to a shared schema, enabling shared intermediate and mart logic.

### Adapter pattern (billing sources)

```
BigQuery sources
├── gcp_billing_export_focus_v1_*          (active — enabled)
├── gcp_billing_export_v1_*                (Idea A — Standard)
├── gcp_billing_export_resource_v1_*       (Idea A — Detailed)
├── cloud_pricing_export                   (Idea B — Pricing)
└── cloud_billing_commitment_usage_cost_*  (Idea C — CUD inventory)
        |
        v
Staging models (stg_*.sql)
  stg_focus_billing.sql         (active)
  stg_standard_billing.sql      (Idea A)
  stg_pricing.sql               (Idea B)
  stg_cud_commitments.sql       (Idea C)
        |
        v
Intermediate models
  int_charges / int_credits     (active; extended for Idea A union)
        |
        v
Mart models
  fct_spend_waterfall           (FOCUS only — waterfall columns)
  fct_credit_breakdown          (FOCUS only)
  fct_commitment_discounts      (FOCUS credits; extended by Idea C)
  fct_monthly_showback          (FOCUS; Idea A adds historical backfill)
  fct_sku_pricing               (Idea B — new)
  fct_cud_inventory             (Idea C — new)
```

---

### Idea A — Standard / Detailed Usage Cost Export

#### Use Case

The legacy GCP billing exports (`gcp_billing_export_v1_*` for Standard, `gcp_billing_export_resource_v1_*` for Detailed) predate FOCUS and are available to all GCP billing accounts. The primary use case is **historical backfill**: FOCUS export only starts accumulating data from the day it is enabled, so any GCP account with months or years of prior spend has that history only in the Standard export. The Detailed variant adds `resource.name` and `resource.global_name` columns, enabling resource-level label-based showback that FOCUS does not expose in the same way.

#### Architecture

Add a new `stg_standard_billing.sql` staging model that maps Standard/Detailed source columns to the same snake_case schema used by `stg_focus_billing`. Key column mappings:

| Standard column | Mapped to |
|----------------|-----------|
| `project.id` | `project_id` |
| `service.description` | `service_name` |
| `cost` | `billed_cost` |
| `credits[]` | `x_credits` |
| *(no list/contracted/effective)* | `list_cost = cost`, `contracted_cost = cost`, `effective_cost = cost` |

Two integration options:

1. **Union approach** — `stg_billing_all.sql` unions `stg_focus_billing` and `stg_standard_billing` with a `source_export` discriminator column. Shared intermediate and mart logic runs on the union. A `source_export = 'standard'` filter excludes rows from waterfall-specific marts that require multi-cost columns.
2. **Parallel marts** — keep FOCUS and Standard as separate lineage paths. FOCUS marts preserve full waterfall fidelity; Standard marts produce `fct_*_standard` variants for historical periods.

Option 2 is simpler to implement and avoids implicit schema coercion.

#### Justification

Any billing account that enables FOCUS export today has a gap in `fct_monthly_showback` for all prior months. Standard export fills that gap with `billed_cost` at minimum, enabling year-over-year trend analysis.

**Status: Idea / Not started**

---

### Idea B — Pricing Export

#### Use Case

The GCP pricing export (`cloud_pricing_export`) is not a billing row export — it is the SKU price catalogue: SKU id, description, pricing unit, tiered pricing tiers, region, and effective date. The primary use case is **what-if cost modelling**: given a workload's resource consumption, what would it cost in `us-east1` vs `europe-west1`? This also enables normalising costs across regions for fair multi-region showback. A secondary use case is detecting SKU price changes over time — GCP occasionally revises prices, and the pricing export version-histories those changes.

#### Architecture

New dbt source pointing at `cloud_pricing_export` → `stg_pricing.sql` → `fct_sku_pricing.sql` mart. This pipeline is independent of the billing row pipeline; the mart is not merged into `int_charges`. Cross-join `fct_sku_pricing` with billing data at query time (in Metabase or a separate mart) to produce "list price vs actual" or "regional price comparison" analyses.

The pricing export is typically enabled once at the billing account level and exports into a dataset separate from the billing export dataset. A new entry in `dbt/models/sources.yml` is required.

#### Justification

Enriches the existing waterfall with forward-looking price intelligence. Enables FinOps practitioners to answer "what would this workload cost if we moved regions?" without relying on manual lookups in the GCP pricing calculator.

**Status: Idea / Not started**

---

### Idea C — Committed Use Discounts (CUD) Export

#### Use Case

The `cloud_billing_commitment_usage_cost_v1_*` export contains CUD inventory rows: resource type (CPU/RAM/GPU), region, number of vCPUs or GB of RAM committed, commitment start and end dates, and utilisation. The primary use case is **CUD lifecycle management** — tracking which commitments expire within 30/60/90 days, which are underutilised, and where renewal or rightsizing is warranted.

#### Current gap

`fct_commitment_discounts` surfaces CUD credit *amounts* drawn from `x_Credits[type=COMMITTED_USAGE_DISCOUNT]` in the FOCUS export. It cannot show commitment *inventory* — how many cores were committed, when they expire, or what coverage ratio they represent.

#### Architecture

New dbt source pointing at `cloud_billing_commitment_usage_cost_v1_*` → `stg_cud_commitments.sql` → `fct_cud_inventory.sql` mart.

`fct_cud_inventory.sql` columns (indicative):

| Column | Source |
|--------|--------|
| `commitment_id` | CUD export row |
| `resource_type` | CPU / RAM / GPU |
| `region` | Commitment region |
| `committed_units` | vCPUs or GB |
| `utilisation_pct` | Used / committed |
| `commitment_start_date` | From CUD export |
| `commitment_end_date` | From CUD export |
| `days_until_expiry` | Calculated |

Join `fct_cud_inventory` with `fct_commitment_discounts` (via region + resource_type + month) to produce a coverage ratio: CUD credit savings / total eligible on-demand spend.

#### Justification

Medium-to-large GCP bills typically have 30–60% of compute covered by CUDs. A 5% improvement in CUD coverage on a $50k/month compute bill yields approximately $2,500/month in savings. Visibility into expiry dates and utilisation directly supports renewal decisions.

**Status: Idea / Not started**

---

## Section 2: Other Future Ideas

### Anomaly Detection

Add dbt tests or a scheduled BigQuery query that alerts when a project's spend spikes more than 20% week-over-week relative to its trailing four-week average. Alerts could be routed to Cloud Monitoring via a metric write from a Cloud Function, or posted to a Slack webhook, without requiring additional infrastructure beyond what is already deployed.

**Status: Idea / Not started**

---

### Budget vs Actuals

Pull GCP Budget API data or manually maintain budget targets as dbt seed files (`seeds/budgets.csv`), then build a `fct_budget_vs_actuals.sql` mart that joins budget lines to `fct_monthly_showback` on `project_id` and `month`. Exposes variance (actual - budget) and variance percentage, surfaced in Metabase as a traffic-light table per project.

**Status: Idea / Not started**

---

### Label / Tag Compliance

The `x_Labels` and `x_ProjectLabels` arrays are already present in `stg_focus_billing`. A mart that unnests those arrays and tests for required label keys (e.g. `env`, `team`, `cost-centre`) would surface the percentage of spend with each required label applied, broken down by project and service. This enables a label compliance score without any new data ingestion.

**Status: Idea / Not started**

---

### Multi-Billing-Account Support

The current stack assumes a single billing account. The pattern to extend it: parameterise `dbt/models/sources.yml` with one source config per billing account, union the staging models with a `billing_account_id` discriminator column, and propagate that column as a partition key through all intermediate and mart models. No schema changes to the marts themselves are required beyond adding the partition key.

**Status: Idea / Not started**

---

## Section 3: Features Inspired by Leading FinOps Tools

The ideas below are drawn from feature analysis of Finout, Ternary, ProsperOps, CloudZero, Harness CCM, and Apptio Cloudability. Each is filtered to GCP-specific applicability and scoped to the dbt + BigQuery + Metabase stack. None duplicate ideas already captured in Sections 1 and 2.

---

### Virtual Cost Allocation Rules

**Inspired by**: Finout (Virtual Tags), Apptio Cloudability (Business Mapping)

**Use Case**: GCP labels are applied at resource creation time and are often incomplete, inconsistent, or controlled by teams who cannot be forced to relabel retroactively. Virtual cost allocation rules let a FinOps team define mapping logic — e.g., "any charge in project `data-platform-prod` with service `BigQuery` belongs to team `Analytics`" — and apply that mapping retroactively to all historical billing rows, without touching GCP labels or requiring infrastructure changes.

**GCP Implementation**: Add a dbt seed file `seeds/cost_allocation_rules.csv` with columns `rule_priority`, `match_project_id_pattern`, `match_service_name_pattern`, `match_label_key`, `match_label_value`, `assigned_team`, `assigned_cost_centre`, `assigned_product`. Build an intermediate model `int_cost_allocation.sql` that LEFT JOINs `stg_focus_billing` rows against the seed using regex matching (BigQuery `REGEXP_CONTAINS`) in priority order, falling back to existing `x_Labels` values when no rule matches. Propagate `assigned_team` and `assigned_cost_centre` into `fct_monthly_showback` as additional grouping dimensions. Rules are updated by editing the seed and running `dbt seed && dbt run --select int_cost_allocation+`.

**Status: Idea / Not started**

---

### Effective Savings Rate and SUD Coverage Dashboard

**Inspired by**: ProsperOps (Effective Savings Rate, autonomous CUD management)

**Use Case**: The Effective Savings Rate (ESR) is a single percentage that captures total savings from all GCP discount mechanisms — resource-based CUDs, flexible spend-based CUDs, and Sustained Use Discounts (SUDs) — expressed as a fraction of what the same usage would have cost at on-demand list rates. GCP applies SUDs automatically on eligible Compute Engine usage based on the fraction of a month a VM runs, and these appear alongside CUD credits in the FOCUS export. Without a unified metric, it is impossible to tell whether the aggregate discount posture is improving or degrading month-over-month.

**GCP Implementation**: Both CUD and SUD credits are already in `int_credits`, identifiable by `charge_subcategory IN ('COMMITTED_USAGE_DISCOUNT', 'COMMITTED_USAGE_DISCOUNT_DOLLAR_BASE', 'SUSTAINED_USE_DISCOUNT')`. Build a new mart `fct_effective_savings_rate.sql` that calculates per-month, per-project: `total_discount_credits` (sum of absolute credit values), `on_demand_equivalent_cost` (sum of `list_cost` for eligible charge rows from `fct_spend_waterfall`), and `effective_savings_rate = total_discount_credits / on_demand_equivalent_cost`. Join against `fct_commitment_discounts` for CUD coverage ratio separately from SUD. Surface as a time-series Metabase line chart and a headline KPI tile showing current-month ESR vs prior 3-month average.

**Status: Idea / Not started**

---

### Unit Economics — Cost per Business Metric

**Inspired by**: CloudZero (Cost Per Customer, Cost Per Product, Cloud Efficiency Rate)

**Use Case**: Raw cloud spend totals are difficult to evaluate without business context. A team spending $20k/month on Cloud Run might be very efficient if they process 10M API requests, or very inefficient if they process 50k. Unit economics — cost per customer, cost per request, cost per inference call — translate raw spend into metrics that product and engineering teams can act on. CloudZero customers use this to detect when a new deployment increases cost-per-customer even if absolute spend is flat.

**GCP Implementation**: Add a dbt seed `seeds/business_metrics.csv` with columns `month`, `metric_name`, `metric_value` (e.g., `2025-06, active_customers, 4200`). Build a mart `fct_unit_economics.sql` that joins `fct_monthly_showback` totals against the seed on `month`, producing `cost_per_unit = net_billed_cost / metric_value` per project and metric. The seed is updated manually each month or replaced with a BigQuery external table sourced from a product analytics export. Metabase line charts show cost-per-unit trends over time. This requires no new GCP data sources; the only addition is the business metrics seed file.

**Status: Idea / Not started**

---

### Shared Cost Splitting

**Inspired by**: Apptio Cloudability (Shared Cost Allocation), Ternary (Cost Billing Rules, Dynamic Weighting)

**Use Case**: Many GCP projects serve as shared platforms — a shared data warehouse project, a shared networking VPC project, a shared CI/CD project. The cost of these projects cannot be attributed to a single team, but leaving them as unallocated in showback reports inflates the apparent cost of the platform team and hides the true cost of consuming teams. Shared cost splitting redistributes these central costs across consumers, either by a fixed weight or by a usage-based ratio derived from billing data itself.

**GCP Implementation**: Add a seed `seeds/shared_cost_splits.csv` with columns `source_project_id`, `target_team`, `split_method` (`fixed` or `proportional`), `fixed_weight`. Build a variant mart `fct_monthly_showback_allocated.sql` that identifies rows where `project_id` is in the shared project list, distributes their `net_billed_cost` to target teams according to `split_method`, and zeroes out the source project's allocated cost. For `proportional` splits, derive each team's weight from its share of total non-shared spend in that month, which is already computable from `fct_monthly_showback`. The allocated mart produces a view where shared project costs sum to zero and consuming teams carry the full redistributed cost.

**Status: Idea / Not started**

---

### GCP Recommender API — Idle Resource Inventory

**Inspired by**: Harness CCM (GCP Recommendations), GCP native (Cloud Recommender)

**Use Case**: GCP's Cloud Recommender service uses machine learning applied to actual resource utilisation to generate actionable rightsizing recommendations: idle Compute Engine VMs, oversized VM machine types, idle persistent disks, unused external IP addresses, and idle Cloud SQL instances. These recommendations exist in GCP but are not surfaced in billing data. Without integrating them, the dbt stack shows where money is being spent but not which specific resources are wasteful.

**GCP Implementation**: Write a Cloud Scheduler + Cloud Function (or a daily cron on the VM using `gcloud recommender recommendations list --recommender=google.compute.instance.IdleResourceRecommender`) that exports recommendations to a BigQuery table `finops_dbt.gcp_recommender_snapshot` with columns `recommender_id`, `project_id`, `resource_name`, `recommendation_type`, `estimated_monthly_savings_usd`, `state`, `snapshot_date`. Add a dbt source pointing at that table, build `stg_gcp_recommender.sql` and `fct_idle_resources.sql`. Join `fct_idle_resources` against `fct_monthly_showback` on `project_id` to show what fraction of a project's spend is flagged as saveable. Surface in Metabase as a savings opportunity table sorted by estimated monthly savings. Recommenders to include: `IdleResourceRecommender`, `MachineTypeRecommender`, `IdleDiskRecommender`, `AddressRecommender`.

**Status: Idea / Not started**

---

### Spend Commitment Ramp Tracking

**Inspired by**: Ternary (Ramp Plans, Contractual Obligation Tracking)

**Use Case**: Organisations with Google Cloud spend commitments (CCUDs or negotiated spend agreements) have contractual monthly spend targets that ramp over the contract term. Missing a ramp milestone may trigger shortfall fees or affect renewal terms. Tracking actual spend against the contracted ramp schedule in the same tool used for cost analytics closes the loop between commercial commitments and operational spend without requiring a separate spreadsheet.

**GCP Implementation**: Add a seed `seeds/spend_commitment_ramp.csv` with columns `contract_id`, `contract_name`, `month`, `committed_spend_usd`. Build a mart `fct_commitment_ramp.sql` that joins the seed against monthly totals from `fct_spend_waterfall` (sum of `billed_cost` across all projects) on `month`, producing `committed_spend`, `actual_spend`, `variance_usd`, `variance_pct`, and a `status` flag (`on_track`, `at_risk`, `shortfall`) where `at_risk` triggers when `actual_spend < committed_spend * 0.95`. Surface in Metabase as a bar chart per month with a committed ramp overlay line. The seed requires manual updates when contract terms change; no new GCP data sources are needed.

**Status: Idea / Not started**

---

### BigQuery Job-Level Cost Attribution

**Inspired by**: Harness CCM (BigQuery cost visibility), GCP native (INFORMATION_SCHEMA.JOBS_BY_PROJECT)

**Use Case**: BigQuery is frequently a top-3 GCP spend line item, but the FOCUS billing export shows BQ costs only at the SKU level attributed to the project running the query. It does not show which user, which scheduled dbt model, or which Metabase question drove a slot consumption spike. Job-level attribution via `INFORMATION_SCHEMA` closes this gap, enabling per-user and per-pipeline cost accountability within BigQuery itself.

**GCP Implementation**: Add a new dbt source pointing at `region-us.INFORMATION_SCHEMA.JOBS_BY_PROJECT` (a system view requiring no export setup, available on the existing finops-vm service account with `bigquery.jobUser`). Build `stg_bq_jobs.sql` staging: `job_id`, `user_email`, `creation_time`, `total_bytes_processed`, `total_slot_ms`, `statement_type`, `referenced_tables`. Compute `estimated_on_demand_cost_usd = total_bytes_processed / POW(1024, 4) * 6.25` in staging. Build `fct_bq_job_costs.sql` aggregated by `user_email`, `date`, and `referenced_table` with daily cost totals. Surface in Metabase as a top-10 most expensive users table and a top-10 most-scanned tables table per rolling 30-day window. `INFORMATION_SCHEMA.JOBS_BY_PROJECT` retains 180 days of history.

**Status: Idea / Not started**

---

### GKE Namespace Cost Allocation

**Inspired by**: Harness CCM (GKE namespace-level allocation), Ternary (Kubernetes cost integration)

**Use Case**: GKE cluster costs appear in the FOCUS billing export as Compute Engine charges attributed to the cluster project, with no visibility into which Kubernetes namespace or workload consumed which fraction of the cluster. For organisations running multiple applications or teams on shared GKE clusters, this makes it impossible to assign container costs in showback reports without a namespace-level allocation layer.

**GCP Implementation**: Enable GKE usage metering on each cluster (`--resource-usage-bigquery-dataset`). GCP writes per-namespace resource consumption rows to a designated BigQuery dataset (tables `gke_cluster_resource_consumption` and `gke_cluster_resource_usage`). Add a dbt source pointing at the GKE metering export. Build `stg_gke_usage.sql` and `fct_gke_namespace_costs.sql` that computes each namespace's share of cluster CPU and RAM consumption, then multiplies by the cluster's total billed cost from `stg_focus_billing` (matched on cluster project ID and month) to produce `namespace_allocated_cost_usd`. Add a seed `seeds/gke_namespace_team_map.csv` mapping namespaces to teams, and join this into `fct_monthly_showback` so namespace costs appear alongside project-level costs in the same showback mart.

**Status: Idea / Not started**

---

### Spend Forecasting with BigQuery ML

**Inspired by**: Apptio Cloudability (AI-backed forecasting), Ternary (budget breakpoints and actuals comparison)

**Use Case**: Month-end spend is only known in arrears. A forecast based on historical trends lets finance teams anticipate whether a project will breach budget before the month closes, and lets engineering teams detect workloads growing faster than planned. Static budget-vs-actuals (already in the roadmap as a separate idea) answers "how are we doing vs plan?" — forecasting answers "where will we end up if the current trajectory continues?"

**GCP Implementation**: Use BigQuery ML's `ARIMA_PLUS` time-series model trained on `fct_monthly_showback` monthly totals per project. Create the model once via a `CREATE OR REPLACE MODEL finops_dbt.spend_arima OPTIONS(model_type='ARIMA_PLUS', time_series_timestamp_col='month', time_series_data_col='net_billed_cost', time_series_id_col='project_id', ...)` statement, run as a dbt `run-operation` or standalone SQL. Build a mart `fct_spend_forecast.sql` that calls `ML.FORECAST(MODEL finops_dbt.spend_arima, STRUCT(3 AS horizon, 0.9 AS confidence_level))` to produce a `forecast_month`, `project_id`, `forecast_spend_usd`, `lower_bound`, `upper_bound` output table rebuilt on each dbt run. Surface in Metabase as a combined actuals-plus-forecast line chart per project. No new GCP data sources or external services are required.

**Status: Idea / Not started**

---

### Carbon Footprint per Project

**Inspired by**: GCP native (Carbon Footprint export), FinOps Foundation sustainability reporting guidelines

**Use Case**: GCP publishes a Carbon Footprint BigQuery export recording estimated gross and net carbon emissions (kgCO2e) per project, service, region, and month. As organisations face sustainability reporting requirements (Scope 3 cloud emissions for corporate ESG disclosures), correlating carbon output with cloud spend unlocks a carbon-per-dollar metric alongside cost data. This is a GCP-native data source available to all billing accounts at no additional charge; there is no equivalent multi-cloud normalization involved.

**GCP Implementation**: Enable the Carbon Footprint export in the GCP console (Billing > Carbon Footprint > Export) to a BigQuery dataset. Add a dbt source pointing at the export table. Build `stg_carbon_footprint.sql` staging `project_id`, `service`, `region`, `month`, `gross_carbon_kg_co2e`, `net_carbon_kg_co2e`. Build `fct_carbon_intensity.sql` that joins against `fct_monthly_showback` on `project_id` and `month` to produce `carbon_per_dollar = net_carbon_kg_co2e / net_billed_cost` and a month-over-month `carbon_intensity_delta`. Surface in Metabase as a carbon-intensity ranking table by project and a time-series of total net emissions. No VM changes or new infrastructure are required beyond enabling the export once in the console.

**Status: Idea / Not started**

---

## Section 4: Deferred Deployment Steps

These items were scoped during session work but could not be completed because they depend on external inputs (CIDR ranges, a live domain, or GCP state that does not yet exist). Each entry names its blocker and gives exact commands so the next operator can pick up immediately.

---

### Restrict Ingress CIDR

**Blocked on**: office or VPN CIDR

Currently `allowed_ingress_cidrs = []` (deny all) in `infra/terraform.tfvars`. Before exposing the VM on ports 80/443, set this to your office or VPN IP range in `infra/terraform.tfvars`, then run `tofu apply` to update the firewall rule.

Example:
```hcl
allowed_ingress_cidrs = ["203.0.113.0/24"]
```

---

### Bootstrap Tofu State Bucket and Provision Infrastructure

**Blocked on**: running commands (ready to go once CIDR is set)

```bash
cd infra/scripts && ./bootstrap-state-bucket.sh
cd .. && tofu init -backend-config=backend.hcl
tofu plan
tofu apply
```

`tofu apply` creates: finops-vm SA, e2-medium VM in asia-southeast2, VPC + subnet, static IP, Secret Manager secret skeleton, firewall rules, IAP bindings.

Cross-project note: tofu will grant `bigquery.dataViewer` on `terra-coe-finops`. This requires the operator running `tofu apply` to have `roles/resourcemanager.projectIamAdmin` or `roles/owner` on `terra-coe-finops`. If that permission is unavailable, run this manually after apply:

```bash
gcloud projects add-iam-policy-binding terra-coe-finops \
  --member="serviceAccount:finops-vm@gcp-coe-492507.iam.gserviceaccount.com" \
  --role="roles/bigquery.dataViewer"
```

---

### Seed Metabase DB Password

**Blocked on**: VM existing (after tofu apply)

```bash
cd infra && ./scripts/deploy.sh sync-secrets
```

Creates a version of the `finops-metabase-db-password` Secret Manager secret.

---

### Deploy App to VM

**Blocked on**: VM existing + secret seeded

```bash
cd infra && ./scripts/deploy.sh all
```

Syncs dbt models + Docker Compose + nginx config to VM, writes `profiles.yml` and `.env` with billing source vars, starts Metabase and PostgreSQL containers.

---

### Configure DNS and TLS

**Blocked on**: domain name + static IP (output from tofu apply)

Point an A record at the static IP output by `tofu output vm_ip` (or equivalent). Then on the VM via IAP SSH:

```bash
cd infra && ./scripts/deploy.sh ssh
# on VM:
certbot --nginx -d YOUR_DOMAIN
```

---

### Metabase First-Run Setup

**Blocked on**: TLS configured + Metabase accessible at domain

Open `https://YOUR_DOMAIN` in a browser.

- Create the admin account.
- Add a BigQuery database connection: project `gcp-coe-492507`, use Application Default Credentials (no JSON key -- VM SA identity is used automatically).
- Verify the `finops_dbt` dataset is visible under Admin → Databases.

---

### Wait for FOCUS Billing Export Data

**Blocked on**: GCP billing export lag (24-48h from enabling FOCUS export)

The billing table `gcp_billing_export_focus_01A09A_A37EA6_F0AC6C` in `terra-coe-finops` currently has 0 rows. Check with:

```bash
bq query --use_legacy_sql=false --project_id=gcp-coe-492507 \
  "SELECT COUNT(*) FROM \`terra-coe-finops.gcp_billing_immutable_01A09A_A37EA6_F0AC6C_asia_southeast2.gcp_billing_export_focus_01A09A_A37EA6_F0AC6C\`"
```

Once rows appear, trigger dbt:

```bash
cd infra && ./scripts/deploy.sh dbt-run
```

Verify all four mart tables populate in BigQuery: `fct_spend_waterfall`, `fct_credit_breakdown`, `fct_commitment_discounts`, `fct_monthly_showback`.
