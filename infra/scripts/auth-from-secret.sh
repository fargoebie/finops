#!/usr/bin/env bash
# Materialize GOOGLE_APPLICATION_CREDENTIALS from Cloud Agent secret GCP_SA_KEY_B64.
#
# Cursor Cloud Agent: set secret GCP_SA_KEY_B64 = base64 -w0 of opencost-deployer.json
# Then on the agent:
#   ./infra/scripts/auth-from-secret.sh
#
# Does NOT require interactive gcloud ADC login.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=env.sh
source "${SCRIPT_DIR}/env.sh"

usage() {
  cat <<EOF
Usage: $(basename "$0") [--print-email]

Reads env \$${GCP_SA_KEY_B64_VAR} (base64 SA JSON), writes:
  ${GOOGLE_APPLICATION_CREDENTIALS}

Exports GOOGLE_APPLICATION_CREDENTIALS and CLOUDSDK_CORE_PROJECT=${PROJECT_ID}.
EOF
}

if [[ "${1:-}" == "-h" || "${1:-}" == "--help" ]]; then
  usage
  exit 0
fi

SECRET_VAL="${!GCP_SA_KEY_B64_VAR:-}"
if [[ -z "${SECRET_VAL}" ]]; then
  echo "Missing env ${GCP_SA_KEY_B64_VAR}." >&2
  echo "Add a Cloud Agent secret named ${GCP_SA_KEY_B64_VAR} with:" >&2
  echo "  base64 -w0 opencost-deployer.json" >&2
  exit 1
fi

umask 077
mkdir -p "$(dirname "${GOOGLE_APPLICATION_CREDENTIALS}")"
# Accept raw base64 (with or without whitespace/newlines)
echo "${SECRET_VAL}" | tr -d '[:space:]' | base64 -d > "${GOOGLE_APPLICATION_CREDENTIALS}"
chmod 600 "${GOOGLE_APPLICATION_CREDENTIALS}"

# Basic sanity: must be JSON with client_email
if ! grep -q '"client_email"' "${GOOGLE_APPLICATION_CREDENTIALS}"; then
  echo "Decoded file does not look like a GCP SA key JSON." >&2
  exit 1
fi

export GOOGLE_APPLICATION_CREDENTIALS
export CLOUDSDK_CORE_PROJECT="${PROJECT_ID}"
export CLOUDSDK_AUTH_CREDENTIAL_FILE_OVERRIDE="${GOOGLE_APPLICATION_CREDENTIALS}"

CLIENT_EMAIL="$(python3 -c "import json; print(json.load(open('${GOOGLE_APPLICATION_CREDENTIALS}'))['client_email'])")"
echo "ADC file: ${GOOGLE_APPLICATION_CREDENTIALS}"
echo "SA email: ${CLIENT_EMAIL}"
echo "Project:  ${PROJECT_ID}"

if command -v gcloud >/dev/null 2>&1; then
  gcloud auth activate-service-account --key-file="${GOOGLE_APPLICATION_CREDENTIALS}" --project="${PROJECT_ID}" --quiet
  gcloud config set project "${PROJECT_ID}" --quiet
  echo "gcloud activated as ${CLIENT_EMAIL}"
else
  echo "gcloud not installed; GOOGLE_APPLICATION_CREDENTIALS is set for tofu/SDKs."
fi

if [[ "${1:-}" == "--print-email" ]]; then
  echo "${CLIENT_EMAIL}"
fi
