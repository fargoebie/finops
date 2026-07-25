#!/usr/bin/env bash
# Shared defaults for demogcp-terra2021.
# Source: source "$(dirname "${BASH_SOURCE[0]}")/env.sh"

export PROJECT_ID="${PROJECT_ID:-demogcp-terra2021}"
export BILLING_PROJECT_ID="${BILLING_PROJECT_ID:-${PROJECT_ID}}"
export REGION="${REGION:-us-central1}"
export ZONE="${ZONE:-us-central1-a}"
export NAME_PREFIX="${NAME_PREFIX:-finops}"

export DEPLOY_SA_ID="${DEPLOY_SA_ID:-opencost-deployer}"
export DEPLOY_SA_EMAIL="${DEPLOY_SA_EMAIL:-${DEPLOY_SA_ID}@${PROJECT_ID}.iam.gserviceaccount.com}"
export RUNTIME_SA_ID="${RUNTIME_SA_ID:-${NAME_PREFIX}-vm}"
export RUNTIME_SA_EMAIL="${RUNTIME_SA_EMAIL:-${RUNTIME_SA_ID}@${PROJECT_ID}.iam.gserviceaccount.com}"

export STATE_BUCKET="${STATE_BUCKET:-${PROJECT_ID}-tofu-state}"
export VM_NAME="${VM_NAME:-${NAME_PREFIX}-vm}"
export SECRET_MB_DB_PASS="${SECRET_MB_DB_PASS:-${NAME_PREFIX}-metabase-db-password}"

# Cloud Agent secret name (base64 of deployer SA JSON)
export GCP_SA_KEY_B64_VAR="${GCP_SA_KEY_B64_VAR:-GCP_SA_KEY_B64}"
export GOOGLE_APPLICATION_CREDENTIALS="${GOOGLE_APPLICATION_CREDENTIALS:-${HOME}/.config/gcloud/opencost-deployer.json}"
