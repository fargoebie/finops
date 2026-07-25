#!/usr/bin/env bash
# deploy.sh — build → push private AR → sync secrets → update Cloud Run
# Defaults pinned to demogcp-terra2021 (same project for deploy + BQ).
#
# Multi-container service: opencost-ui (ingress :9090) + opencost API sidecar (:9003).
#
# Image tags: this script owns day-2 container images (git sha). Cloud Run in
# OpenTofu ignores template containers[].image so tofu apply will not revert them.
#
# Typical agent flow:
#   ./infra/scripts/auth-from-secret.sh          # from GCP_SA_KEY_B64
#   cd infra && tofu apply                       # seed-if-empty secrets + service
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
# ui = FinOps SPA only (keeps API in-memory store). api|both restart the sidecar.
DEPLOY_TARGET="${DEPLOY_TARGET:-both}"
# After API container updates, rebuild cloud-cost from BigQuery (needs secret access).
REBUILD_AFTER_API_DEPLOY="${REBUILD_AFTER_API_DEPLOY:-true}"
REBUILD_WINDOW="${REBUILD_WINDOW:-30d}"

IMAGE="${AR_HOST}/${PROJECT_ID}/${AR_REPO}/opencost:${IMAGE_TAG}"
UI_IMAGE="${AR_HOST}/${PROJECT_ID}/${AR_REPO}/opencost-ui:${IMAGE_TAG}"

usage() {
  cat <<EOF
Usage: $(basename "$0") <command>

Project: ${PROJECT_ID}  Region: ${REGION}  Service: ${SERVICE}

Commands:
  push-image          Pull SOURCE_IMAGE and/or build ui-finops; push to private AR
  sync-secrets        Upload cloud-integration.json and optional ADMIN_TOKEN
  deploy-revision     Point Cloud Run containers at IMAGE_TAG (see DEPLOY_TARGET)
  rebuild-cloudcost   Admin rebuild of in-memory cloud-cost store from BigQuery
  all                 push-image && sync-secrets && deploy-revision
  print-env           Show resolved names

Env overrides:
  PROJECT_ID REGION NAME_PREFIX IMAGE_TAG SOURCE_IMAGE PLATFORM
  CLOUD_INTEGRATION_FILE  (default: infra/examples/cloud-integration.demogcp-terra2021.json)
  ADMIN_TOKEN_FILE
  DEPLOY_TARGET=ui|api|both   (default: both; prefer ui for SPA-only changes)
  REBUILD_AFTER_API_DEPLOY    (default: true; runs rebuild-cloudcost after api|both)
  REBUILD_WINDOW              (default: 30d)
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
UI_IMAGE=${UI_IMAGE}
RUNTIME_SA_EMAIL=${RUNTIME_SA_EMAIL}
DEPLOY_SA_EMAIL=${DEPLOY_SA_EMAIL}
SECRET_INTEGRATION=${SECRET_INTEGRATION}
SECRET_ADMIN=${SECRET_ADMIN}
STATE_BUCKET=${STATE_BUCKET}
CLOUD_INTEGRATION_FILE=${CLOUD_INTEGRATION_FILE}
DEPLOY_TARGET=${DEPLOY_TARGET}
REBUILD_AFTER_API_DEPLOY=${REBUILD_AFTER_API_DEPLOY}
REBUILD_WINDOW=${REBUILD_WINDOW}
EOF
}

cmd_push_image() {
  require_auth
  gcloud auth configure-docker "${AR_HOST}" --quiet

  case "${DEPLOY_TARGET}" in
    ui|api|both) ;;
    *)
      echo "DEPLOY_TARGET must be ui, api, or both (got: ${DEPLOY_TARGET})" >&2
      exit 1
      ;;
  esac

  if [[ "${DEPLOY_TARGET}" == "api" || "${DEPLOY_TARGET}" == "both" ]]; then
    docker pull --platform "${PLATFORM}" "${SOURCE_IMAGE}"
    docker tag "${SOURCE_IMAGE}" "${IMAGE}"
    docker push "${IMAGE}"
    echo "Pushed ${IMAGE}"
  else
    echo "Skipping API image push (DEPLOY_TARGET=${DEPLOY_TARGET})"
  fi

  if [[ "${DEPLOY_TARGET}" == "ui" || "${DEPLOY_TARGET}" == "both" ]]; then
    docker build --platform "${PLATFORM}" -t "${UI_IMAGE}" "${ROOT_DIR}/ui-finops"
    docker push "${UI_IMAGE}"
    echo "Pushed ${UI_IMAGE}"
  else
    echo "Skipping UI image build (DEPLOY_TARGET=${DEPLOY_TARGET})"
  fi
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

service_url() {
  gcloud run services describe "${SERVICE}" \
    --project="${PROJECT_ID}" \
    --region="${REGION}" \
    --format='value(status.url)'
}

admin_token() {
  if [[ -n "${ADMIN_TOKEN:-}" ]]; then
    printf '%s' "${ADMIN_TOKEN}"
    return 0
  fi
  if [[ -n "${ADMIN_TOKEN_FILE}" && -f "${ADMIN_TOKEN_FILE}" ]]; then
    tr -d '\n' <"${ADMIN_TOKEN_FILE}"
    return 0
  fi
  gcloud secrets versions access latest \
    --secret="${SECRET_ADMIN}" \
    --project="${PROJECT_ID}"
}

cmd_rebuild_cloudcost() {
  require_auth
  local url token
  url="$(service_url)"
  token="$(admin_token)"
  if [[ -z "${token}" ]]; then
    echo "No ADMIN_TOKEN available (env, ADMIN_TOKEN_FILE, or secret ${SECRET_ADMIN})" >&2
    exit 1
  fi
  echo "Rebuilding cloud cost for window=${REBUILD_WINDOW} via ${url}"
  # OpenCost cloud-cost store is in-memory; API restarts leave /cloudCost empty until refresh/rebuild.
  curl -sS -f -H "Authorization: Bearer ${token}" \
    "${url}/model/cloudCost/rebuild?window=${REBUILD_WINDOW}&commit=true" \
    | python3 -c 'import json,sys; d=json.load(sys.stdin); print(json.dumps(d, indent=2)[:2000])' \
    || curl -sS -f -H "Authorization: Bearer ${token}" \
      "${url}/cloudCost/rebuild?window=${REBUILD_WINDOW}&commit=true" \
      | python3 -c 'import json,sys; d=json.load(sys.stdin); print(json.dumps(d, indent=2)[:2000])'
  echo "Cloud cost rebuild requested"
}

cmd_deploy_revision() {
  require_auth
  case "${DEPLOY_TARGET}" in
    ui|api|both) ;;
    *)
      echo "DEPLOY_TARGET must be ui, api, or both (got: ${DEPLOY_TARGET})" >&2
      exit 1
      ;;
  esac

  # Non-container flags must come before --container (gcloud requirement).
  local -a args=(
    run services update "${SERVICE}"
    --project="${PROJECT_ID}"
    --region="${REGION}"
    --quiet
  )
  if [[ "${DEPLOY_TARGET}" == "ui" || "${DEPLOY_TARGET}" == "both" ]]; then
    args+=(--container=opencost-ui --image="${UI_IMAGE}")
  fi
  if [[ "${DEPLOY_TARGET}" == "api" || "${DEPLOY_TARGET}" == "both" ]]; then
    args+=(--container=opencost --image="${IMAGE}")
  fi
  gcloud "${args[@]}"
  echo "Deployed ${SERVICE} target=${DEPLOY_TARGET} ui=${UI_IMAGE} api=${IMAGE}"
  service_url

  if [[ "${DEPLOY_TARGET}" == "api" || "${DEPLOY_TARGET}" == "both" ]]; then
    if [[ "${REBUILD_AFTER_API_DEPLOY}" == "true" ]]; then
      echo "API image updated — waiting briefly, then rebuilding cloud-cost store"
      sleep 15
      cmd_rebuild_cloudcost || echo "WARN: rebuild-cloudcost failed; dashboard may stay empty until next refresh" >&2
    else
      echo "Skipped rebuild (REBUILD_AFTER_API_DEPLOY=${REBUILD_AFTER_API_DEPLOY}). Run: $0 rebuild-cloudcost"
    fi
  fi
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
    rebuild-cloudcost) cmd_rebuild_cloudcost ;;
    all) cmd_all ;;
    print-env) cmd_print_env ;;
    -h|--help|help|"") usage; [[ -n "${cmd}" ]] || exit 1 ;;
    *) echo "Unknown command: ${cmd}" >&2; usage; exit 1 ;;
  esac
}

main "$@"
