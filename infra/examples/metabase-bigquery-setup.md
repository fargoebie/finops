# Metabase → BigQuery Connection Setup

After Metabase first boots:

1. Open `https://YOUR_DOMAIN`, complete the Metabase setup wizard.
2. Go to **Admin → Databases → Add database**.
3. Select **BigQuery**.
4. **Authentication:** Use Application Default Credentials (the VM service account handles this automatically — no JSON key needed).
5. **Project ID:** `YOUR_GCP_PROJECT_ID`
6. **Dataset filters:** add `finops_dbt` to restrict Metabase to the dbt output dataset.
7. Click **Save**.

Metabase will sync the schema. You should see the four mart tables:

- `fct_spend_waterfall`
- `fct_credit_breakdown`
- `fct_commitment_discounts`
- `fct_monthly_showback`

## Required dbt env vars (`profiles.yml` or VM environment)

| Variable | Example |
|----------|---------|
| `DBT_PROJECT_ID` | `demogcp-terra2021` |
| `DBT_BILLING_PROJECT_ID` | `demogcp-terra2021` |
| `DBT_BILLING_DATASET` | `export_billing_demogcp_detailed` |
| `DBT_FOCUS_TABLE` | `gcp_billing_export_focus_v1_01E5F4_66804E_8286B7` |
| `DBT_OUTPUT_DATASET` | `finops_dbt` |

## Troubleshooting

**Metabase shows no tables after connecting:**
- Confirm dbt ran successfully: `./scripts/deploy.sh dbt-run`
- Check `finops_dbt` dataset exists in BigQuery: `bq ls demogcp-terra2021:finops_dbt`
- Force a schema sync in Metabase: **Admin → Databases → finops_dbt → Sync database schema now**

**BigQuery authentication error in Metabase:**
- Confirm the VM is running as `finops-vm@demogcp-terra2021.iam.gserviceaccount.com` (not the default Compute SA)
- Confirm the SA has `roles/bigquery.dataViewer`, `roles/bigquery.jobUser`, `roles/bigquery.user` on the project

**dbt cannot find FOCUS export table:**
- Confirm the FOCUS export is enabled (not standard or resource-level export)
- Check the table name matches `DBT_FOCUS_TABLE` exactly
- GCP FOCUS export can have a 24–48 h lag on a new billing account
