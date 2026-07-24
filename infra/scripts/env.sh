#!/usr/bin/env bash
# Shared defaults for demogcp-terra2021 (deploy + BQ billing export in the SAME project).
# Source from other scripts:  # shellcheck source=env.sh
#   source "$(dirname "${BASH_SOURCE[0]}")/env.sh"

export PROJECT_ID="${PROJECT_ID:-demogcp-terra2021}"
# Same-project layout: billing export lives here too.
export BILLING_PROJECT_ID="${BILLING_PROJECT_ID:-${PROJECT_ID}}"

export REGION="${REGION:-us-central1}"
export ZONE="${ZONE:-us-central1-a}"
export NAME_PREFIX="${NAME_PREFIX:-opencost}"

export DEPLOY_SA_ID="${DEPLOY_SA_ID:-opencost-deployer}"
export RUNTIME_SA_ID="${RUNTIME_SA_ID:-opencost-cloudcost}"
export DEPLOY_SA_EMAIL="${DEPLOY_SA_EMAIL:-${DEPLOY_SA_ID}@${PROJECT_ID}.iam.gserviceaccount.com}"
export RUNTIME_SA_EMAIL="${RUNTIME_SA_EMAIL:-${RUNTIME_SA_ID}@${PROJECT_ID}.iam.gserviceaccount.com}"

export STATE_BUCKET="${STATE_BUCKET:-${PROJECT_ID}-tofu-state}"
export AR_HOST="${REGION}-docker.pkg.dev"
export AR_REPO="${AR_REPO:-${NAME_PREFIX}}"
export SERVICE="${SERVICE:-${NAME_PREFIX}-cloudcost}"
export SECRET_INTEGRATION="${SECRET_INTEGRATION:-${NAME_PREFIX}-cloud-integration}"
export SECRET_ADMIN="${SECRET_ADMIN:-${NAME_PREFIX}-admin-token}"

# Cloud Agent secret name (base64 of deployer SA JSON)
export GCP_SA_KEY_B64_VAR="${GCP_SA_KEY_B64_VAR:-GCP_SA_KEY_B64}"

# Where auth-from-secret.sh writes the decoded key (never commit)
export GOOGLE_APPLICATION_CREDENTIALS="${GOOGLE_APPLICATION_CREDENTIALS:-${HOME}/.config/gcloud/opencost-deployer.json}"
