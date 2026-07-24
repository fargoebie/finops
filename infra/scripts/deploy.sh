#!/usr/bin/env bash
# deploy.sh — build → push private AR → sync secrets → update Cloud Run
# Defaults pinned to demogcp-terra2021 (same project for deploy + BQ).
#
# Typical agent flow:
#   ./infra/scripts/auth-from-secret.sh          # from GCP_SA_KEY_B64
#   ./infra/scripts/deploy.sh all
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "${SCRIPT_DIR}/../.." && pwd)"
# shellcheck source=env.sh
source "${SCRIPT_DIR}/env.sh"

IMAGE_TAG="${IMAGE_TAG:-$(git -C "${ROOT_DIR}" rev-parse --short HEAD 2>/dev/null || date +%Y%m%d%H%M%S)}"
PLATFORM="${PLATFORM:-linux/amd64}"
SOURCE_IMAGE="${SOURCE_IMAGE:-ghcr.io/opencost/opencost:latest}"
CLOUD_INTEGRATION_FILE="${CLOUD_INTEGRATION_FILE:-${SCRIPT_DIR}/../examples/cloud-integration.demogcp-terra2021.json}"
ADMIN_TOKEN_FILE="${ADMIN_TOKEN_FILE:-}"

IMAGE="${AR_HOST}/${PROJECT_ID}/${AR_REPO}/opencost:${IMAGE_TAG}"

usage() {
  cat <<EOF
Usage: $(basename "$0") <command>

Project: ${PROJECT_ID}  Region: ${REGION}  Service: ${SERVICE}

Commands:
  push-image       Pull SOURCE_IMAGE, push to private Artifact Registry
  sync-secrets     Upload cloud-integration.json and optional ADMIN_TOKEN
  deploy-revision  Point Cloud Run at IMAGE_TAG
  all              push-image && sync-secrets && deploy-revision
  print-env        Show resolved names

Env overrides:
  PROJECT_ID REGION NAME_PREFIX IMAGE_TAG SOURCE_IMAGE PLATFORM
  CLOUD_INTEGRATION_FILE  (default: infra/examples/cloud-integration.demogcp-terra2021.json)
  ADMIN_TOKEN_FILE
EOF
}

require_auth() {
  if [[ -z "${GOOGLE_APPLICATION_CREDENTIALS:-}" || ! -f "${GOOGLE_APPLICATION_CREDENTIALS}" ]]; then
    if [[ -n "${GCP_SA_KEY_B64:-}" ]]; then
      echo "GOOGLE_APPLICATION_CREDENTIALS missing; running auth-from-secret.sh"
      "${SCRIPT_DIR}/auth-from-secret.sh"
      # shellcheck source=env.sh
      source "${SCRIPT_DIR}/env.sh"
    else
      echo "No credentials. Set GCP_SA_KEY_B64 or run ./auth-from-secret.sh" >&2
      exit 1
    fi
  fi
  if ! command -v gcloud >/dev/null 2>&1; then
    echo "gcloud is required for deploy.sh" >&2
    exit 1
  fi
  gcloud config set project "${PROJECT_ID}" --quiet
}

cmd_print_env() {
  cat <<EOF
PROJECT_ID=${PROJECT_ID}
BILLING_PROJECT_ID=${BILLING_PROJECT_ID}
REGION=${REGION}
SERVICE=${SERVICE}
IMAGE=${IMAGE}
RUNTIME_SA_EMAIL=${RUNTIME_SA_EMAIL}
DEPLOY_SA_EMAIL=${DEPLOY_SA_EMAIL}
SECRET_INTEGRATION=${SECRET_INTEGRATION}
SECRET_ADMIN=${SECRET_ADMIN}
STATE_BUCKET=${STATE_BUCKET}
CLOUD_INTEGRATION_FILE=${CLOUD_INTEGRATION_FILE}
EOF
}

cmd_push_image() {
  require_auth
  gcloud auth configure-docker "${AR_HOST}" --quiet
  docker pull --platform "${PLATFORM}" "${SOURCE_IMAGE}"
  docker tag "${SOURCE_IMAGE}" "${IMAGE}"
  docker push "${IMAGE}"
  echo "Pushed ${IMAGE}"
}

cmd_sync_secrets() {
  require_auth
  if [[ -f "${CLOUD_INTEGRATION_FILE}" ]]; then
    if grep -q 'PRIVATE KEY' "${CLOUD_INTEGRATION_FILE}"; then
      echo "Refusing cloud-integration.json with a private key. Use GCPWorkloadIdentity." >&2
      exit 1
    fi
    # Ensure dataset/table placeholders were edited
    if grep -q 'REPLACE_' "${CLOUD_INTEGRATION_FILE}"; then
      echo "Edit ${CLOUD_INTEGRATION_FILE}: replace REPLACE_* dataset/table placeholders." >&2
      exit 1
    fi
    gcloud secrets versions add "${SECRET_INTEGRATION}" \
      --project="${PROJECT_ID}" \
      --data-file="${CLOUD_INTEGRATION_FILE}"
    echo "Updated secret ${SECRET_INTEGRATION}"
  else
    echo "No file at CLOUD_INTEGRATION_FILE=${CLOUD_INTEGRATION_FILE}; skipping"
  fi

  if [[ -n "${ADMIN_TOKEN_FILE}" && -f "${ADMIN_TOKEN_FILE}" ]]; then
    gcloud secrets versions add "${SECRET_ADMIN}" \
      --project="${PROJECT_ID}" \
      --data-file="${ADMIN_TOKEN_FILE}"
    echo "Updated secret ${SECRET_ADMIN}"
  else
    echo "ADMIN_TOKEN_FILE unset; skipping admin token"
  fi
}

cmd_deploy_revision() {
  require_auth
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
  cmd_sync_secrets
  cmd_deploy_revision
}

main() {
  local cmd="${1:-}"
  case "${cmd}" in
    push-image) cmd_push_image ;;
    sync-secrets) cmd_sync_secrets ;;
    deploy-revision) cmd_deploy_revision ;;
    all) cmd_all ;;
    print-env) cmd_print_env ;;
    -h|--help|help|"") usage; [[ -n "${cmd}" ]] || exit 1 ;;
    *) echo "Unknown command: ${cmd}" >&2; usage; exit 1 ;;
  esac
}

main "$@"
