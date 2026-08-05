#!/usr/bin/env bash
# Cron wrapper for upload_hot_cli.sh — flock + log like the other ingest jobs.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
UPLOADER="${SCRIPT_DIR}/upload_hot_cli.sh"
ENV_FILE="${HC_ENV_FILE:-${HOME}/.hc_storage.env}"

if [[ -f "${ENV_FILE}" ]]; then
  set -a
  # shellcheck disable=SC1090
  source "${ENV_FILE}"
  set +a
fi

READY_DIR="${READY_FOR_HOT:-${HOME}/HC_storage_data/ready_for_hot}"
LOG_DIR="${HC_LOG_DIR:-${HOME}/HC_storage_data/logs}"
LOCK_FILE="${HOME}/HC_storage_data/upload_hot_cli.lock"

mkdir -p "${READY_DIR}" "${LOG_DIR}" "$(dirname "${LOCK_FILE}")"
LOG_FILE="${LOG_DIR}/upload_hot_cli.log"

if [[ ! -x "${UPLOADER}" ]]; then
  echo "$(date -Is) ERROR: uploader not executable: ${UPLOADER}" >>"${LOG_FILE}"
  exit 1
fi

exec 9>"${LOCK_FILE}"
if ! flock -n 9; then
  echo "$(date -Is) SKIP: previous upload_hot_cli run still in progress" >>"${LOG_FILE}"
  exit 0
fi

{
  echo "======== $(date -Is) START ready=${READY_DIR} ========"
  set +e
  /usr/bin/env bash "${UPLOADER}" --ready-dir "${READY_DIR}"
  status=$?
  set -e
  echo "======== $(date -Is) END status=${status} ========"
  exit "${status}"
} >>"${LOG_FILE}" 2>&1
