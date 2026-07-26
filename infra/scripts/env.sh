#!/usr/bin/env bash
# Shared defaults for gcp-coe-492507.
# Source: source "$(dirname "${BASH_SOURCE[0]}")/env.sh"

export PROJECT_ID="${PROJECT_ID:-gcp-coe-492507}"
export BILLING_PROJECT_ID="${BILLING_PROJECT_ID:-${PROJECT_ID}}"
export REGION="${REGION:-asia-southeast2}"
export ZONE="${ZONE:-asia-southeast2-a}"
export NAME_PREFIX="${NAME_PREFIX:-finops}"

export DEPLOY_SA_ID="${DEPLOY_SA_ID:-finops-deployer}"
export DEPLOY_SA_EMAIL="${DEPLOY_SA_EMAIL:-${DEPLOY_SA_ID}@${PROJECT_ID}.iam.gserviceaccount.com}"
export RUNTIME_SA_ID="${RUNTIME_SA_ID:-${NAME_PREFIX}-vm}"
export RUNTIME_SA_EMAIL="${RUNTIME_SA_EMAIL:-${RUNTIME_SA_ID}@${PROJECT_ID}.iam.gserviceaccount.com}"

export STATE_BUCKET="${STATE_BUCKET:-${PROJECT_ID}-tofu-state}"
export VM_NAME="${VM_NAME:-${NAME_PREFIX}-vm}"
export SECRET_MB_DB_PASS="${SECRET_MB_DB_PASS:-${NAME_PREFIX}-metabase-db-password}"

# Cloud Agent secret name (base64 of deployer SA JSON)
export GCP_SA_KEY_B64_VAR="${GCP_SA_KEY_B64_VAR:-GCP_SA_KEY_B64}"
export GOOGLE_APPLICATION_CREDENTIALS="${GOOGLE_APPLICATION_CREDENTIALS:-${HOME}/.config/gcloud/finops-deployer.json}"

# dbt BigQuery source (billing export lives in a separate project)
export DBT_BILLING_PROJECT_ID="${DBT_BILLING_PROJECT_ID:-terra-coe-finops}"
export DBT_BILLING_DATASET="${DBT_BILLING_DATASET:-gcp_billing_immutable_01A09A_A37EA6_F0AC6C_asia_southeast2}"
export DBT_FOCUS_TABLE="${DBT_FOCUS_TABLE:-gcp_billing_export_focus_01A09A_A37EA6_F0AC6C}"
export DBT_OUTPUT_DATASET="${DBT_OUTPUT_DATASET:-finops_dbt}"
export DBT_OUTPUT_PROJECT_ID="${DBT_OUTPUT_PROJECT_ID:-${PROJECT_ID}}"
