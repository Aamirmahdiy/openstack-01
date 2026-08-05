#!/usr/bin/env bash
# Upload staged files from ready_for_hot/ to the Swift Hot container using the
# OpenStack `swift` CLI (TempAuth).
#
# Safety: claim each file with mv into uploading_hot/ first so a parallel
# Python uploader cannot grab the same object. Only remove/claim-complete
# after a successful upload + HEAD verification.
#
# Usage:
#   set -a; source ~/.hc_storage.env; set +a   # optional
#   ./upload_hot_cli.sh
#   ./upload_hot_cli.sh --dry-run
#   ./upload_hot_cli.sh --ready-dir ~/HC_storage_data/ready_for_hot

set -euo pipefail

READY_DIR="${READY_FOR_HOT:-${HOME}/HC_storage_data/ready_for_hot}"
UPLOADING_DIR="${UPLOADING_HOT:-${HOME}/HC_storage_data/uploading_hot}"
UPLOADED_DIR="${UPLOADED_HOT:-${HOME}/HC_storage_data/uploaded_hot}"
HOT_CONTAINER="${HOT_CONTAINER:-hot-objects}"
DRY_RUN=0

# TempAuth env (swift client)
ST_AUTH="${ST_AUTH:-http://172.30.201.247:8080/auth/v1.0}"
ST_USER="${ST_USER:-test:tester}"
ST_KEY="${ST_KEY:-testing}"

usage() {
  cat <<'EOF'
Usage: upload_hot_cli.sh [options]

Upload files from ready_for_hot/ to Swift Hot storage via the `swift` CLI.

Options:
  -r, --ready-dir PATH   Source directory (default: ~/HC_storage_data/ready_for_hot)
      --dry-run          List what would be uploaded; do not change anything
  -h, --help             Show help

Required tools: swift (python3-swiftclient), md5sum
Required env (or defaults above): ST_AUTH, ST_USER, ST_KEY, HOT_CONTAINER
EOF
}

die() { echo "error: $*" >&2; exit 2; }

while [[ $# -gt 0 ]]; do
  case "$1" in
    -r|--ready-dir) READY_DIR="${2:-}"; shift 2 ;;
    --dry-run) DRY_RUN=1; shift ;;
    -h|--help) usage; exit 0 ;;
    *) die "unknown argument: $1" ;;
  esac
done

READY_DIR="${READY_DIR/#\~/$HOME}"
UPLOADING_DIR="${UPLOADING_DIR/#\~/$HOME}"
UPLOADED_DIR="${UPLOADED_DIR/#\~/$HOME}"

command -v swift >/dev/null 2>&1 || die "swift CLI not found — install python3-swiftclient on the laptop"
command -v md5sum >/dev/null 2>&1 || die "md5sum not found"

export ST_AUTH ST_USER ST_KEY

mkdir -p "${READY_DIR}" "${UPLOADING_DIR}" "${UPLOADED_DIR}"

# Fail fast if auth/proxy is down (unless dry-run)
if (( ! DRY_RUN )); then
  if ! swift stat >/dev/null 2>&1; then
    die "cannot authenticate to Swift (ST_AUTH=${ST_AUTH}). Is the proxy up? Fix RHEL repos + install Swift first."
  fi
fi

shopt -s nullglob
files=("${READY_DIR}"/*)
shopt -u nullglob

scanned=0
uploaded=0
failed=0
skipped=0

if [[ ${#files[@]} -eq 0 ]]; then
  echo "scanned=0 uploaded=0 failed=0 skipped=0 ready_dir=${READY_DIR}"
  echo "nothing to upload"
  exit 0
fi

for path in "${files[@]}"; do
  [[ -f "${path}" ]] || { echo "SKIP not-a-file $(basename "${path}")"; skipped=$((skipped + 1)); continue; }
  scanned=$((scanned + 1))
  base="$(basename "${path}")"
  local_md5="$(md5sum "${path}" | awk '{print $1}')"
  size="$(stat -c '%s' "${path}")"
  ingested_at="$(date -u +%Y-%m-%dT%H:%M:%SZ)"

  if (( DRY_RUN )); then
    echo "WOULD_UPLOAD ${base} size=${size} md5=${local_md5} container=${HOT_CONTAINER}"
    uploaded=$((uploaded + 1))
    continue
  fi

  claim="${UPLOADING_DIR}/${base}"
  if [[ -e "${claim}" ]]; then
    echo "SKIP already-claiming ${base}"
    skipped=$((skipped + 1))
    continue
  fi

  # Claim: atomic move out of ready_for_hot so another uploader cannot take it
  if ! mv -n "${path}" "${claim}"; then
    echo "SKIP claim-failed ${base}"
    skipped=$((skipped + 1))
    continue
  fi

  echo "UPLOAD_START ${base} size=${size} md5=${local_md5}"

  set +e
  swift upload "${HOT_CONTAINER}" "${claim}" \
    --object-name "${base}" \
    -H "X-Object-Meta-Tier: hot" \
    -H "X-Object-Meta-Ingested-At: ${ingested_at}" \
    -H "X-Object-Meta-Upload-Method: cli" \
    -H "X-Object-Meta-Original-Size: ${size}"
  up_rc=$?
  set -e

  if (( up_rc != 0 )); then
    echo "UPLOAD_FAIL ${base} rc=${up_rc} — returning to ready_for_hot"
    mv -n "${claim}" "${READY_DIR}/${base}" || true
    failed=$((failed + 1))
    continue
  fi

  # Verify with HEAD: etag must match local md5 (Swift etag is MD5 for non-SLO)
  set +e
  remote_etag="$(swift stat "${HOT_CONTAINER}" "${base}" 2>/dev/null | awk -F': ' 'tolower($1) ~ /etag/ {gsub(/ /,"",$2); print tolower($2); exit}')"
  set -e
  remote_etag="${remote_etag//\"/}"

  if [[ -z "${remote_etag}" || "${remote_etag}" != "${local_md5}" ]]; then
    echo "VERIFY_FAIL ${base} local_md5=${local_md5} remote_etag=${remote_etag:-none} — returning to ready_for_hot (remote object left for manual check)"
    mv -n "${claim}" "${READY_DIR}/${base}" || true
    failed=$((failed + 1))
    continue
  fi

  dest="${UPLOADED_DIR}/${base}"
  mv -f "${claim}" "${dest}"
  echo "UPLOAD_OK ${base} etag=${remote_etag} archived=${dest}"
  uploaded=$((uploaded + 1))
done

echo "scanned=${scanned} uploaded=${uploaded} failed=${failed} skipped=${skipped} dry_run=${DRY_RUN}"
echo "ready=${READY_DIR} uploading=${UPLOADING_DIR} uploaded=${UPLOADED_DIR} container=${HOT_CONTAINER}"
(( failed == 0 ))
