#!/usr/bin/env bash
# Regenerate seeds/billing_accounts.csv from the Cloud Billing API.
#
# The FOCUS export carries no billing-account display name — only
# BillingAccountId. This pulls displayName (plus master account and open flag)
# so marts can show the name Terralogiq and the customer actually use.
#
# GENERATED FILE: do not hand-edit seeds/billing_accounts.csv. Curated
# customer identity lives in seeds/customer_accounts.csv instead.
#
# Needs billing.accounts.list — your own credentials have it; the finops-vm SA
# does NOT (it would need roles/billing.viewer on the reseller account).
#
# Usage:  ./scripts/refresh_billing_accounts.sh && dbt seed && dbt run
set -euo pipefail

OUT="$(cd "$(dirname "$0")/.." && pwd)/seeds/billing_accounts.csv"
TMP="$(mktemp)"
trap 'rm -f "$TMP"' EXIT

printf 'billing_account_id,billing_account_name,master_billing_account_id,is_open\n' > "$TMP"
gcloud billing accounts list \
  --format="csv[no-heading](name.basename(),displayName,masterBillingAccount.basename(),open)" \
  >> "$TMP"

rows=$(( $(wc -l < "$TMP") - 1 ))
if [ "$rows" -lt 1 ]; then
  echo "refresh_billing_accounts: API returned no accounts; keeping existing seed" >&2
  exit 1
fi

mv "$TMP" "$OUT"
trap - EXIT
echo "wrote $OUT ($rows accounts)"
