#!/usr/bin/env bash
# deploy.sh — build → push private AR → (optional) sync secrets → update Cloud Run revision
#
# Conventions (keep in sync with *.tf):
#   AR repo:   ${REGION}-docker.pkg.dev/${PROJECT_ID}/${NAME_PREFIX}/opencost
#   Service:   ${NAME_PREFIX}-cloudcost
#   Secrets:   ${NAME_PREFIX}-cloud-integration, ${NAME_PREFIX}-admin-token
#   Runtime SA:${NAME_PREFIX}-cloudcost@${PROJECT_ID}.iam.gserviceaccount.com
#
# Prerequisites:
#   - gcloud authenticated with permission to push AR + actAs runtime SA
#   - tofu applied at least once (AR, SA, secrets, Cloud Run skeleton)
#   - cloud-integration.json uses authorizerType GCPWorkloadIdentity (no private keys)
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
INFRA_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

PROJECT_ID="${PROJECT_ID:-$(gcloud config get-value project 2>/dev/null)}"
REGION="${REGION:-us-central1}"
NAME_PREFIX="${NAME_PREFIX:-opencost}"
IMAGE_TAG="${IMAGE_TAG:-$(git -C "${ROOT_DIR}" rev-parse --short HEAD 2>/dev/null || date +%Y%m%d%H%M%S)}"
PLATFORM="${PLATFORM:-linux/amd64}"
SOURCE_IMAGE="${SOURCE_IMAGE:-ghcr.io/opencost/opencost:latest}"
CLOUD_INTEGRATION_FILE="${CLOUD_INTEGRATION_FILE:-}"
ADMIN_TOKEN_FILE="${ADMIN_TOKEN_FILE:-}"

AR_HOST="${REGION}-docker.pkg.dev"
IMAGE="${AR_HOST}/${PROJECT_ID}/${NAME_PREFIX}/opencost:${IMAGE_TAG}"
SERVICE="${NAME_PREFIX}-cloudcost"
SECRET_INTEGRATION="${NAME_PREFIX}-cloud-integration"
SECRET_ADMIN="${NAME_PREFIX}-admin-token"

usage() {
  cat <<EOF
Usage: $(basename "$0") <command>

Commands:
  push-image       Retag/pull SOURCE_IMAGE and push to private Artifact Registry
  sync-secrets     Upload cloud-integration.json and/or ADMIN_TOKEN to Secret Manager
  deploy-revision  Deploy IMAGE_TAG to Cloud Run (does not bake secret literals)
  all              push-image && sync-secrets (if files set) && deploy-revision

Env:
  PROJECT_ID REGION NAME_PREFIX IMAGE_TAG SOURCE_IMAGE PLATFORM
  CLOUD_INTEGRATION_FILE  Path to cloud-integration.json (WI authorizer)
  ADMIN_TOKEN_FILE        Path to file containing ADMIN_TOKEN string
EOF
}

require_project() {
  if [[ -z "${PROJECT_ID}" || "${PROJECT_ID}" == "(unset)" ]]; then
    echo "PROJECT_ID is required" >&2
    exit 1
  fi
}

cmd_push_image() {
  require_project
  gcloud auth configure-docker "${AR_HOST}" --quiet
  docker pull --platform "${PLATFORM}" "${SOURCE_IMAGE}"
  docker tag "${SOURCE_IMAGE}" "${IMAGE}"
  docker push "${IMAGE}"
  echo "Pushed ${IMAGE}"
}

cmd_sync_secrets() {
  require_project
  if [[ -n "${CLOUD_INTEGRATION_FILE}" ]]; then
    [[ -f "${CLOUD_INTEGRATION_FILE}" ]] || { echo "missing ${CLOUD_INTEGRATION_FILE}" >&2; exit 1; }
    # Refuse obvious private-key material in integration JSON (principle B / WI).
    if grep -q 'PRIVATE KEY' "${CLOUD_INTEGRATION_FILE}"; then
      echo "Refusing to upload cloud-integration.json containing a private key. Use GCPWorkloadIdentity." >&2
      exit 1
    fi
    gcloud secrets versions add "${SECRET_INTEGRATION}" \
      --project="${PROJECT_ID}" \
      --data-file="${CLOUD_INTEGRATION_FILE}"
    echo "Updated secret ${SECRET_INTEGRATION}"
  else
    echo "CLOUD_INTEGRATION_FILE unset; skipping integration secret"
  fi

  if [[ -n "${ADMIN_TOKEN_FILE}" ]]; then
    [[ -f "${ADMIN_TOKEN_FILE}" ]] || { echo "missing ${ADMIN_TOKEN_FILE}" >&2; exit 1; }
    gcloud secrets versions add "${SECRET_ADMIN}" \
      --project="${PROJECT_ID}" \
      --data-file="${ADMIN_TOKEN_FILE}"
    echo "Updated secret ${SECRET_ADMIN}"
  else
    echo "ADMIN_TOKEN_FILE unset; skipping admin token secret"
  fi
}

cmd_deploy_revision() {
  require_project
  gcloud run services update "${SERVICE}" \
    --project="${PROJECT_ID}" \
    --region="${REGION}" \
    --image="${IMAGE}" \
    --quiet
  echo "Deployed ${SERVICE} -> ${IMAGE}"
  gcloud run services describe "${SERVICE}" \
    --project="${PROJECT_ID}" \
    --region="${REGION}" \
    --format='value(status.url)'
}

cmd_all() {
  cmd_push_image
  if [[ -n "${CLOUD_INTEGRATION_FILE}" || -n "${ADMIN_TOKEN_FILE}" ]]; then
    cmd_sync_secrets
  fi
  cmd_deploy_revision
}

main() {
  local cmd="${1:-}"
  case "${cmd}" in
    push-image) cmd_push_image ;;
    sync-secrets) cmd_sync_secrets ;;
    deploy-revision) cmd_deploy_revision ;;
    all) cmd_all ;;
    -h|--help|help|"") usage; [[ -n "${cmd}" ]] || exit 1 ;;
    *) echo "Unknown command: ${cmd}" >&2; usage; exit 1 ;;
  esac
}

main "$@"
