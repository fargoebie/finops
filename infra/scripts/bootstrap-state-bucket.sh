#!/usr/bin/env bash
# Create versioned GCS bucket for OpenTofu state: demogcp-terra2021-tofu-state
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=env.sh
source "${SCRIPT_DIR}/env.sh"

if ! command -v gcloud >/dev/null 2>&1; then
  echo "gcloud required" >&2
  exit 1
fi

gcloud config set project "${PROJECT_ID}" --quiet
gcloud services enable storage.googleapis.com --project="${PROJECT_ID}" --quiet

if gcloud storage buckets describe "gs://${STATE_BUCKET}" --project="${PROJECT_ID}" >/dev/null 2>&1; then
  echo "Bucket exists: gs://${STATE_BUCKET}"
else
  gcloud storage buckets create "gs://${STATE_BUCKET}" \
    --project="${PROJECT_ID}" \
    --location="${REGION}" \
    --uniform-bucket-level-access
  echo "Created gs://${STATE_BUCKET}"
fi

gcloud storage buckets update "gs://${STATE_BUCKET}" --versioning
echo "Versioning enabled on gs://${STATE_BUCKET}"
echo "Use infra/backend.hcl with bucket = \"${STATE_BUCKET}\""
