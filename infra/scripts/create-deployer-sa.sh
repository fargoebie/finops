#!/usr/bin/env bash
# One-time: create deployer SA in demogcp-terra2021, print base64 for Cloud Agent secret.
#
# Run on a machine that already has admin gcloud access (not the keyless agent).
# Output: instructions to set GCP_SA_KEY_B64 — does not commit the key.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=env.sh
source "${SCRIPT_DIR}/env.sh"

KEY_OUT="${KEY_OUT:-${TMPDIR:-/tmp}/opencost-deployer-${PROJECT_ID}.json}"
B64_OUT="${B64_OUT:-${KEY_OUT}.b64}"

if ! command -v gcloud >/dev/null 2>&1; then
  echo "gcloud is required to create the deployer SA." >&2
  exit 1
fi

echo "Project: ${PROJECT_ID} (deploy + BQ same project)"
gcloud config set project "${PROJECT_ID}" --quiet

gcloud services enable \
  iam.googleapis.com \
  cloudresourcemanager.googleapis.com \
  serviceusage.googleapis.com \
  --project="${PROJECT_ID}" --quiet

if ! gcloud iam service-accounts describe "${DEPLOY_SA_EMAIL}" --project="${PROJECT_ID}" >/dev/null 2>&1; then
  gcloud iam service-accounts create "${DEPLOY_SA_ID}" \
    --project="${PROJECT_ID}" \
    --display-name="OpenCost deployer (tofu/deploy.sh)"
  echo "Created ${DEPLOY_SA_EMAIL}"
else
  echo "SA already exists: ${DEPLOY_SA_EMAIL}"
fi

# Deploy roles on the single project (trim later with custom roles if desired).
DEPLOY_ROLES=(
  roles/run.admin
  roles/artifactregistry.admin
  roles/secretmanager.admin
  roles/compute.networkAdmin
  roles/iam.serviceAccountAdmin
  roles/iam.serviceAccountUser
  roles/serviceusage.serviceUsageAdmin
  roles/monitoring.editor
  roles/storage.admin
  roles/resourcemanager.projectIamAdmin
)

for ROLE in "${DEPLOY_ROLES[@]}"; do
  gcloud projects add-iam-policy-binding "${PROJECT_ID}" \
    --member="serviceAccount:${DEPLOY_SA_EMAIL}" \
    --role="${ROLE}" \
    --condition=None \
    --quiet >/dev/null
  echo "Bound ${ROLE}"
done

# New key (rotate by deleting old keys in console if needed)
gcloud iam service-accounts keys create "${KEY_OUT}" \
  --iam-account="${DEPLOY_SA_EMAIL}" \
  --project="${PROJECT_ID}"

base64 -w0 "${KEY_OUT}" > "${B64_OUT}" 2>/dev/null || base64 "${KEY_OUT}" | tr -d '\n' > "${B64_OUT}"
chmod 600 "${KEY_OUT}" "${B64_OUT}"

cat <<EOF

=== Cloud Agent secret ===
Name:  GCP_SA_KEY_B64
Value: (contents of ${B64_OUT} — single line, no quotes)

On the agent after the secret is injected:
  ./infra/scripts/auth-from-secret.sh

Local key file (delete after copying into Cursor secrets):
  ${KEY_OUT}
  ${B64_OUT}

Runtime SA (created later by tofu; NO key):
  ${RUNTIME_SA_EMAIL}
EOF
