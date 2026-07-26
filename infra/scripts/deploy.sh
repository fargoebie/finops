#!/usr/bin/env bash
# deploy.sh — sync files to VM and manage services
# Typical flow:
#   ./infra/scripts/auth-from-secret.sh   # from GCP_SA_KEY_B64
#   cd infra && tofu apply                # provision VM + secrets
#   ./infra/scripts/deploy.sh all         # sync files + start stack
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "${SCRIPT_DIR}/../.." && pwd)"
# shellcheck source=env.sh
source "${SCRIPT_DIR}/env.sh"

usage() {
  cat <<EOF
Usage: $(basename "$0") <command>

Project: ${PROJECT_ID}  Zone: ${ZONE}  VM: ${VM_NAME}

Commands:
  sync          Copy docker-compose.yml, nginx/, dbt/ to VM at /opt/finops
  profiles       Write dbt profiles.yml on VM from env vars
  nginx-setup    Copy nginx config, enable site, reload (run certbot manually after)
  restart       Pull latest images and restart docker compose stack on VM
  dbt-run       Trigger dbt run on VM (tail last 20 lines)
  sync-secrets  Rotate Metabase DB password in Secret Manager
  all           sync && profiles && restart
  ssh           Open IAP SSH session to VM
  print-env     Show resolved env vars

Env overrides: PROJECT_ID REGION ZONE NAME_PREFIX VM_NAME SECRET_MB_DB_PASS
EOF
}

require_auth() {
  command -v gcloud >/dev/null 2>&1 || { echo "gcloud required" >&2; exit 1; }
  if [[ -n "${GOOGLE_APPLICATION_CREDENTIALS:-}" && -f "${GOOGLE_APPLICATION_CREDENTIALS}" ]]; then
    : # explicit key file — use as-is
  elif [[ -n "${GCP_SA_KEY_B64:-}" ]]; then
    echo "GOOGLE_APPLICATION_CREDENTIALS missing; running auth-from-secret.sh"
    "${SCRIPT_DIR}/auth-from-secret.sh"
    source "${SCRIPT_DIR}/env.sh"
  elif [[ -f "${HOME}/.config/gcloud/application_default_credentials.json" ]]; then
    : # ADC credentials file present — gcloud commands will use it automatically
  else
    echo "No credentials. Run: gcloud auth application-default login" >&2
    exit 1
  fi
  gcloud config set project "${PROJECT_ID}" --quiet
}

cmd_ssh() {
  require_auth
  gcloud compute ssh "${VM_NAME}" \
    --zone="${ZONE}" --tunnel-through-iap --project="${PROJECT_ID}"
}

cmd_sync() {
  require_auth
  gcloud compute ssh "${VM_NAME}" \
    --zone="${ZONE}" --tunnel-through-iap --project="${PROJECT_ID}" \
    --command="mkdir -p /opt/finops/nginx /opt/finops/dbt"
  gcloud compute scp --recurse \
    --tunnel-through-iap --zone="${ZONE}" --project="${PROJECT_ID}" \
    "${ROOT_DIR}/docker-compose.yml" \
    "${VM_NAME}:/opt/finops/docker-compose.yml"
  gcloud compute scp --recurse \
    --tunnel-through-iap --zone="${ZONE}" --project="${PROJECT_ID}" \
    "${ROOT_DIR}/nginx/." \
    "${VM_NAME}:/opt/finops/nginx/"
  gcloud compute scp --recurse \
    --tunnel-through-iap --zone="${ZONE}" --project="${PROJECT_ID}" \
    "${ROOT_DIR}/dbt/." \
    "${VM_NAME}:/opt/finops/dbt/"
  echo "Synced to ${VM_NAME}:/opt/finops/"
}

cmd_profiles() {
  require_auth
  local out_project="${DBT_OUTPUT_PROJECT_ID:-${PROJECT_ID}}"
  gcloud compute ssh "${VM_NAME}" \
    --zone="${ZONE}" --tunnel-through-iap --project="${PROJECT_ID}" \
    --command="mkdir -p /opt/finops/dbt && \
printf 'finops:\n  target: prod\n  outputs:\n    prod:\n      type: bigquery\n      method: oauth\n      project: ${out_project}\n      dataset: finops_dbt\n      location: asia-southeast2\n      timeout_seconds: 300\n      threads: 4\n' > /opt/finops/dbt/profiles.yml && \
printf 'DBT_BILLING_PROJECT_ID=terra-coe-finops\nDBT_BILLING_DATASET=gcp_billing_immutable_01A09A_A37EA6_F0AC6C_asia_southeast2\nDBT_FOCUS_TABLE=gcp_billing_export_focus_01A09A_A37EA6_F0AC6C\nDBT_OUTPUT_DATASET=finops_dbt\nDBT_OUTPUT_PROJECT_ID=${out_project}\n' > /opt/finops/dbt/.env && \
echo 'profiles.yml and .env written'"
}

cmd_nginx_setup() {
  require_auth
  gcloud compute ssh "${VM_NAME}" \
    --zone="${ZONE}" --tunnel-through-iap --project="${PROJECT_ID}" \
    --command="set -euo pipefail
sudo cp /opt/finops/nginx/metabase.conf /etc/nginx/sites-available/metabase
sudo ln -sf /etc/nginx/sites-available/metabase /etc/nginx/sites-enabled/metabase
sudo rm -f /etc/nginx/sites-enabled/default
sudo nginx -t && sudo systemctl reload nginx
echo 'nginx configured — run certbot manually: certbot --nginx -d YOUR_DOMAIN'"
}

cmd_restart() {
  require_auth
  local secret="${SECRET_MB_DB_PASS}"
  local project="${PROJECT_ID}"
  gcloud compute ssh "${VM_NAME}" \
    --zone="${ZONE}" --tunnel-through-iap --project="${PROJECT_ID}" \
    --command="set -euo pipefail
MB_DB_PASS=\"\$(gcloud secrets versions access latest --secret='${secret}' --project='${project}')\"
export MB_DB_PASS
cd /opt/finops
docker compose pull --quiet
docker compose up -d
docker compose ps"
}

cmd_dbt_run() {
  require_auth
  gcloud compute ssh "${VM_NAME}" \
    --zone="${ZONE}" --tunnel-through-iap --project="${PROJECT_ID}" \
    --command="cd /opt/finops/dbt && dbt run --profiles-dir . 2>&1 | tail -30"
}

cmd_sync_secrets() {
  require_auth
  local password
  password="$(openssl rand -base64 32 | tr -d '\n=')"
  printf '%s' "${password}" | \
    gcloud secrets versions add "${SECRET_MB_DB_PASS}" \
      --project="${PROJECT_ID}" --data-file=-
  echo "Rotated ${SECRET_MB_DB_PASS}. Run './deploy.sh restart' to apply."
}

cmd_print_env() {
  cat <<EOF
PROJECT_ID=${PROJECT_ID}
BILLING_PROJECT_ID=${BILLING_PROJECT_ID}
REGION=${REGION}
ZONE=${ZONE}
VM_NAME=${VM_NAME}
RUNTIME_SA_EMAIL=${RUNTIME_SA_EMAIL}
SECRET_MB_DB_PASS=${SECRET_MB_DB_PASS}
STATE_BUCKET=${STATE_BUCKET}
EOF
}

main() {
  local cmd="${1:-}"
  case "${cmd}" in
    sync)          cmd_sync ;;
    profiles)      cmd_profiles ;;
    nginx-setup)   cmd_nginx_setup ;;
    restart)       cmd_restart ;;
    dbt-run)       cmd_dbt_run ;;
    sync-secrets)  cmd_sync_secrets ;;
    all)           cmd_sync && cmd_profiles && cmd_restart ;;
    ssh)           cmd_ssh ;;
    print-env)     cmd_print_env ;;
    -h|--help|help|"") usage; [[ -n "${cmd}" ]] || exit 1 ;;
    *) echo "Unknown: ${cmd}" >&2; usage; exit 1 ;;
  esac
}

main "$@"
