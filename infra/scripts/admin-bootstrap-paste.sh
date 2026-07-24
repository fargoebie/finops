#!/usr/bin/env bash
# Crash-safe admin bootstrap for demogcp-terra2021 (no repo required on admin machine).
# - Suppresses giant IAM policy dumps (--format=none)
# - Writes base64 to a FILE; does not print the key to the terminal
#
# Usage: bash admin-bootstrap-paste.sh
set -euo pipefail

PROJECT_ID="demogcp-terra2021"
REGION="us-central1"
DEPLOY_SA_ID="opencost-deployer"
DEPLOY_SA_EMAIL="${DEPLOY_SA_ID}@${PROJECT_ID}.iam.gserviceaccount.com"
STATE_BUCKET="${PROJECT_ID}-tofu-state"
OUT_DIR="${HOME}/opencost-bootstrap"
mkdir -p "${OUT_DIR}"
KEY_OUT="${OUT_DIR}/opencost-deployer.json"
B64_OUT="${OUT_DIR}/opencost-deployer.b64"
LOG_OUT="${OUT_DIR}/bootstrap.log"

exec > >(tee -a "${LOG_OUT}") 2>&1

echo "[1/5] Project ${PROJECT_ID}"
gcloud config set project "${PROJECT_ID}" --quiet

echo "[2/5] Enable APIs"
gcloud services enable \
  iam.googleapis.com \
  cloudresourcemanager.googleapis.com \
  serviceusage.googleapis.com \
  storage.googleapis.com \
  --project="${PROJECT_ID}" --quiet

echo "[3/5] Create SA ${DEPLOY_SA_EMAIL}"
if ! gcloud iam service-accounts describe "${DEPLOY_SA_EMAIL}" --project="${PROJECT_ID}" --quiet >/dev/null 2>&1; then
  gcloud iam service-accounts create "${DEPLOY_SA_ID}" \
    --project="${PROJECT_ID}" \
    --display-name="OpenCost deployer" \
    --quiet
fi

echo "[4/5] Bind roles (output suppressed)"
ROLES=(
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

for ROLE in "${ROLES[@]}"; do
  echo "  - ${ROLE}"
  gcloud projects add-iam-policy-binding "${PROJECT_ID}" \
    --member="serviceAccount:${DEPLOY_SA_EMAIL}" \
    --role="${ROLE}" \
    --format=none \
    --quiet >/dev/null 2>&1 || \
  gcloud projects add-iam-policy-binding "${PROJECT_ID}" \
    --member="serviceAccount:${DEPLOY_SA_EMAIL}" \
    --role="${ROLE}" \
    --condition=None \
    --format=none \
    --quiet >/dev/null 2>&1
done

echo "[5/5] Create key + state bucket (base64 to FILE only)"
gcloud iam service-accounts keys create "${KEY_OUT}" \
  --iam-account="${DEPLOY_SA_EMAIL}" \
  --project="${PROJECT_ID}" \
  --quiet

python3 - <<PY
import base64, pathlib
raw = pathlib.Path("${KEY_OUT}").read_bytes()
pathlib.Path("${B64_OUT}").write_text(base64.b64encode(raw).decode("ascii"), encoding="ascii")
print("wrote", "${B64_OUT}", "chars", len(base64.b64encode(raw)))
PY
chmod 600 "${KEY_OUT}" "${B64_OUT}"

if ! gcloud storage buckets describe "gs://${STATE_BUCKET}" --project="${PROJECT_ID}" --quiet >/dev/null 2>&1; then
  gcloud storage buckets create "gs://${STATE_BUCKET}" \
    --project="${PROJECT_ID}" \
    --location="${REGION}" \
    --uniform-bucket-level-access \
    --quiet
fi
gcloud storage buckets update "gs://${STATE_BUCKET}" --versioning --quiet >/dev/null || true

echo
echo "DONE"
echo "Deployer SA: ${DEPLOY_SA_EMAIL}"
echo "State bucket: gs://${STATE_BUCKET}"
echo "Base64 file:  ${B64_OUT}"
echo "Cursor secret name: GCP_SA_KEY_B64"
echo "Copy from file (do not cat into a flaky terminal), then: rm -f '${KEY_OUT}' '${B64_OUT}'"
