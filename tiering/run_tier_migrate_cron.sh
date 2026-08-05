#!/usr/bin/env bash
# Cron/systemd-friendly wrapper for tier_migrate.py

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
WORKER="${SCRIPT_DIR}/tier_migrate.py"
ENV_FILE="${HC_ENV_FILE:-${HOME}/.hc_storage.env}"

if [[ -f "${ENV_FILE}" ]]; then
  set -a
  # shellcheck disable=SC1090
  source "${ENV_FILE}"
  set +a
fi

LOG_DIR="${HC_LOG_DIR:-${HOME}/HC_storage_data/logs}"
LOCK_FILE="${HOME}/HC_storage_data/tier_migrate.lock"
mkdir -p "${LOG_DIR}"
LOG_FILE="${LOG_DIR}/tier_migrate.log"

THRESHOLD="${TIER_AGE_THRESHOLD_MINUTES:-30}"

exec 9>"${LOCK_FILE}"
if ! flock -n 9; then
  echo "$(date -Is) SKIP: previous tier_migrate still running" >>"${LOG_FILE}"
  exit 0
fi

{
  echo "======== $(date -Is) START threshold=${THRESHOLD}m ========"
  set +e
  /usr/bin/python3 "${WORKER}" --threshold-minutes "${THRESHOLD}"
  status=$?
  set -e
  echo "======== $(date -Is) END status=${status} ========"
  exit "${status}"
} >>"${LOG_FILE}" 2>&1
