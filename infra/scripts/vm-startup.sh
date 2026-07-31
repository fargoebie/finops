#!/usr/bin/env bash
# First-boot startup script for the FinOps e2-medium VM.
# Runs as root via GCE metadata. Idempotent — safe to re-run.
set -euo pipefail

# ── Docker ──────────────────────────────────────────────────────────────────
if ! command -v docker >/dev/null 2>&1; then
  apt-get update -qq
  apt-get install -y -qq ca-certificates curl gnupg lsb-release
  install -m 0755 -d /etc/apt/keyrings
  curl -fsSL https://download.docker.com/linux/debian/gpg \
    | gpg --dearmor -o /etc/apt/keyrings/docker.gpg
  chmod a+r /etc/apt/keyrings/docker.gpg
  echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.gpg] \
    https://download.docker.com/linux/debian $(lsb_release -cs) stable" \
    | tee /etc/apt/sources.list.d/docker.list
  apt-get update -qq
  apt-get install -y -qq docker-ce docker-ce-cli containerd.io docker-compose-plugin
  systemctl enable docker
fi

# ── Cloud Ops Agent ──────────────────────────────────────────────────────────
if ! systemctl is-active --quiet google-cloud-ops-agent 2>/dev/null; then
  curl -sSO https://dl.google.com/cloudagents/add-google-cloud-ops-agent-repo.sh
  bash add-google-cloud-ops-agent-repo.sh --also-install
fi

# ── nginx + Certbot ──────────────────────────────────────────────────────────
if ! command -v nginx >/dev/null 2>&1; then
  apt-get install -y -qq nginx certbot python3-certbot-nginx
  systemctl enable nginx
fi

# Self-signed cert so TLS is up by default (upgrade later: certbot --nginx -d DOMAIN).
NGINX_CRT="/etc/nginx/ssl/metabase-selfsigned.crt"
NGINX_KEY="/etc/nginx/ssl/metabase-selfsigned.key"
if [[ ! -f "${NGINX_CRT}" || ! -f "${NGINX_KEY}" ]]; then
  mkdir -p /etc/nginx/ssl
  EXT_IP="$(curl -s -H 'Metadata-Flavor: Google' \
    http://metadata.google.internal/computeMetadata/v1/instance/network-interfaces/0/access-configs/0/external-ip || true)"
  SAN="DNS:finops-vm"
  [[ -n "${EXT_IP}" ]] && SAN="IP:${EXT_IP},${SAN}"
  openssl req -x509 -nodes -newkey rsa:2048 -days 825 \
    -keyout "${NGINX_KEY}" -out "${NGINX_CRT}" \
    -subj "/CN=finops-metabase" -addext "subjectAltName=${SAN}"
  chmod 600 "${NGINX_KEY}"
fi
# The site config itself is installed by deploy.sh nginx-setup, which copies
# nginx/metabase.conf (referencing the cert above) and reloads nginx.

# ── dbt-bigquery ────────────────────────────────────────────────────────────
if [[ ! -x /opt/dbt-venv/bin/dbt ]]; then
  apt-get install -y -qq python3-pip python3-venv
  python3 -m venv /opt/dbt-venv
  /opt/dbt-venv/bin/pip install --quiet "dbt-bigquery>=1.8,<2.0"
  ln -sf /opt/dbt-venv/bin/dbt /usr/local/bin/dbt
fi

# ── App directory ────────────────────────────────────────────────────────────
mkdir -p /opt/finops/nginx /opt/finops/dbt

# ── Metabase BigQuery SA key ────────────────────────────────────────────────
gcloud secrets versions access latest \
  --secret="finops-metabase-bq-key" \
  --project="gcp-coe-492507" \
  > /opt/finops/metabase-bq-key.json
chmod 600 /opt/finops/metabase-bq-key.json

# ── dbt daily cron ───────────────────────────────────────────────────────────
CRON_LINE="0 6 * * * root set -a && source /opt/finops/dbt/.env && set +a && cd /opt/finops/dbt && /usr/local/bin/dbt deps --profiles-dir . && /usr/local/bin/dbt run --profiles-dir . >> /var/log/dbt-cron.log 2>&1"
if ! grep -qF "dbt run" /etc/cron.d/finops-dbt 2>/dev/null; then
  echo "${CRON_LINE}" > /etc/cron.d/finops-dbt
  chmod 0644 /etc/cron.d/finops-dbt
fi

echo "VM startup complete"
