#!/usr/bin/env bash
# History backfill step 1: copy the detailed billing export into finops_history and verify the copy.
#
#   1. create dataset gcp-coe-492507:finops_history (asia-southeast2, PHYSICAL storage billing)
#   2. bq cp the raw detailed export (asia-southeast1) cross-region -> finops_history.resource_export_raw
#   3. verify row count and SUM(cost) of the copy against the source, each query in its own region
#
# The raw copy is kept on purpose: 02_convert.sql reads it, and a rebuild needs no second copy.
# The source table is LIVE (rows are appended daily), so the comparison is limited to partitions
# strictly before the day the copy was made; those partitions no longer change.
# Verification scans only the cost column: about 6 GB per side.
#
# Re-running is safe: an existing dataset or copy is kept and just re-verified.
# Delete the copy yourself (bq rm -t ...) if you really want a fresh one.
#
# Needs: gcloud auth login (bq uses it); BigQuery Data Viewer on the source, and dataset create +
# Data Editor + Job User on gcp-coe-492507. Do not run until the pre-flight in README.md is done.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../../infra/scripts/env.sh
source "${SCRIPT_DIR}/../../infra/scripts/env.sh"

HISTORY_DATASET="${HISTORY_DATASET:-finops_history}"
HISTORY_LOCATION="${HISTORY_LOCATION:-${REGION}}"          # asia-southeast2
RAW_TABLE="${RAW_TABLE:-resource_export_raw}"

SRC_PROJECT="${SRC_PROJECT:-terralogiq-billing-export-new}"
SRC_DATASET="${SRC_DATASET:-tes_billing_export}"
SRC_TABLE="${SRC_TABLE:-gcp_billing_export_resource_v1_01A09A_A37EA6_F0AC6C}"
SRC_LOCATION="${SRC_LOCATION:-asia-southeast1}"

SRC_BQ="${SRC_PROJECT}:${SRC_DATASET}.${SRC_TABLE}"          # bq cp / show syntax
DST_BQ="${PROJECT_ID}:${HISTORY_DATASET}.${RAW_TABLE}"
SRC_SQL="${SRC_PROJECT}.${SRC_DATASET}.${SRC_TABLE}"         # standard SQL syntax
DST_SQL="${PROJECT_ID}.${HISTORY_DATASET}.${RAW_TABLE}"

if ! command -v bq >/dev/null 2>&1; then
  echo "bq required (gcloud components)" >&2
  exit 1
fi

bqp() { bq --project_id="${PROJECT_ID}" "$@"; }

# --- 1. dataset ---------------------------------------------------------------------------
if bqp show --dataset "${PROJECT_ID}:${HISTORY_DATASET}" >/dev/null 2>&1; then
  echo "Dataset exists: ${PROJECT_ID}:${HISTORY_DATASET}"
else
  echo "Creating ${PROJECT_ID}:${HISTORY_DATASET} in ${HISTORY_LOCATION} with PHYSICAL storage billing."
  echo "NOTE: switching a dataset's storage billing model is one-way for 14 days."
  bqp mk --dataset \
    --location="${HISTORY_LOCATION}" \
    --storage_billing_model=PHYSICAL \
    "${PROJECT_ID}:${HISTORY_DATASET}"
fi

# --- 2. cross-region copy -----------------------------------------------------------------
# bq cp across regions only writes to a table that does not exist yet (write_empty).
# No --location: pinning the job to the destination region makes bq report the source dataset "Not found".
if bqp show "${DST_BQ}" >/dev/null 2>&1; then
  echo "Copy exists, skipping bq cp: ${DST_BQ}"
else
  echo "Copying ${SRC_BQ} -> ${DST_BQ} (cross-region, 915 GB logical / ~30 GB physical)"
  bqp cp -n "${SRC_BQ}" "${DST_BQ}"
fi

# --- 3. verify ----------------------------------------------------------------------------
# Cutoff = UTC date the copy table was created. Partitions before it were closed when it ran.
created_ms="$(bqp show --format=json "${DST_BQ}" | python3 -c 'import json,sys; print(json.load(sys.stdin)["creationTime"])')"
cutoff="$(python3 -c 'import datetime,sys; print(datetime.datetime.fromtimestamp(int(sys.argv[1])/1000, datetime.timezone.utc).date())' "${created_ms}")"
echo "Verifying partitions before ${cutoff} (UTC date of the copy)"

# Exact comparison: CAST to NUMERIC makes the sum order-independent.
check_sql() {
  printf "SELECT COUNT(*) AS n, CAST(SUM(CAST(cost AS NUMERIC)) AS STRING) AS cost_sum FROM \`%s\` WHERE _PARTITIONTIME < TIMESTAMP('%s')" "$1" "${cutoff}"
}
run_check() {  # $1 = location, $2 = table (SQL syntax); prints "n,cost_sum"
  bqp --location="$1" query --quiet --nouse_legacy_sql --format=csv "$(check_sql "$2")" | tail -n 1
}

src_result="$(run_check "${SRC_LOCATION}" "${SRC_SQL}")"
dst_result="$(run_check "${HISTORY_LOCATION}" "${DST_SQL}")"
echo "source (${SRC_LOCATION}): rows,cost_sum = ${src_result}"
echo "copy   (${HISTORY_LOCATION}): rows,cost_sum = ${dst_result}"

if [[ -z "${src_result}" || "${src_result}" != "${dst_result}" ]]; then
  echo "MISMATCH: the copy does not match the source. Do not run 02_convert.sql." >&2
  exit 1
fi
echo "OK: ${DST_BQ} matches the source (rows and SUM(cost))."
