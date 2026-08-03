#!/usr/bin/env bash
# Cron wrapper for check_aged_files.sh
# Stages inbox files older than 10 minutes into ready_for_hot/.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CHECKER="${SCRIPT_DIR}/check_aged_files.sh"

INBOX="${AGE_INBOX:-${HOME}/HC_storage_data/inbox}"
READY_DIR="${AGE_READY_DIR:-${HOME}/HC_storage_data/ready_for_hot}"
THRESHOLD_MINUTES="${AGE_THRESHOLD_MINUTES:-10}"
LOG_DIR="${AGE_LOG_DIR:-${HOME}/HC_storage_data/logs}"
LOCK_FILE="${AGE_LOCK_FILE:-${HOME}/HC_storage_data/check_aged_files.lock}"

mkdir -p "${INBOX}" "${READY_DIR}" "${LOG_DIR}" "$(dirname "${LOCK_FILE}")"

LOG_FILE="${LOG_DIR}/check_aged_files.log"

if [[ ! -x "${CHECKER}" ]]; then
  echo "$(date -Is) ERROR: checker not executable: ${CHECKER}" >>"${LOG_FILE}"
  exit 1
fi

exec 9>"${LOCK_FILE}"
if ! flock -n 9; then
  echo "$(date -Is) SKIP: previous check_aged_files run still in progress" >>"${LOG_FILE}"
  exit 0
fi

{
  echo "======== $(date -Is) START threshold=${THRESHOLD_MINUTES}m inbox=${INBOX} ========"
  set +e
  /usr/bin/env bash "${CHECKER}" \
    --inbox "${INBOX}" \
    --ready-dir "${READY_DIR}" \
    --threshold "${THRESHOLD_MINUTES}"
  status=$?
  set -e
  echo "======== $(date -Is) END status=${status} ========"
  exit "${status}"
} >>"${LOG_FILE}" 2>&1
