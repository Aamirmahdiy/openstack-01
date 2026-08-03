#!/usr/bin/env bash
# Cron wrapper for generate_files.sh
# - Uses absolute paths (cron has a minimal environment)
# - Prevents overlapping runs with flock
# - Appends timestamped logs
# - Exits non-zero on failure so cron can mail/alert if configured

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
GENERATOR="${SCRIPT_DIR}/generate_files.sh"

# Defaults suitable for this project; override via env in the crontab if needed.
COUNT="${GENERATE_COUNT:-3}"
OUTDIR="${GENERATE_OUTDIR:-${HOME}/HC_storage_data/inbox}"
LOG_DIR="${GENERATE_LOG_DIR:-${HOME}/HC_storage_data/logs}"
LOCK_FILE="${GENERATE_LOCK_FILE:-${HOME}/HC_storage_data/generate_files.lock}"
MIN_BYTES="${GENERATE_MIN_BYTES:-1024}"
MAX_BYTES="${GENERATE_MAX_BYTES:-65536}"

mkdir -p "${OUTDIR}" "${LOG_DIR}" "$(dirname "${LOCK_FILE}")"

LOG_FILE="${LOG_DIR}/generate_files.log"

if [[ ! -x "${GENERATOR}" ]]; then
  echo "$(date -Is) ERROR: generator not executable: ${GENERATOR}" >>"${LOG_FILE}"
  exit 1
fi

# Non-blocking lock: if a previous run is still going, skip this tick.
exec 9>"${LOCK_FILE}"
if ! flock -n 9; then
  echo "$(date -Is) SKIP: previous generate_files run still in progress" >>"${LOG_FILE}"
  exit 0
fi

{
  echo "======== $(date -Is) START count=${COUNT} outdir=${OUTDIR} ========"
  set +e
  /usr/bin/env bash "${GENERATOR}" \
    -n "${COUNT}" \
    -o "${OUTDIR}" \
    --min-bytes "${MIN_BYTES}" \
    --max-bytes "${MAX_BYTES}"
  status=$?
  set -e
  echo "======== $(date -Is) END status=${status} ========"
  exit "${status}"
} >>"${LOG_FILE}" 2>&1
