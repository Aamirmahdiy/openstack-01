#!/usr/bin/env bash
# Check inbox files by age and stage those older than THRESHOLD_MINUTES
# into ready_for_hot/ for later Hot-storage upload (shell CLI or Python API).
#
# Age is based on filesystem mtime (minutes since last modification).
#
# Usage:
#   ./check_aged_files.sh
#   ./check_aged_files.sh --threshold 10
#   ./check_aged_files.sh --dry-run
#   AGE_THRESHOLD_MINUTES=10 ./check_aged_files.sh

set -euo pipefail

INBOX="${AGE_INBOX:-${HOME}/HC_storage_data/inbox}"
READY_DIR="${AGE_READY_DIR:-${HOME}/HC_storage_data/ready_for_hot}"
THRESHOLD_MINUTES="${AGE_THRESHOLD_MINUTES:-10}"
DRY_RUN=0

usage() {
  cat <<'EOF'
Usage: check_aged_files.sh [options]

Scan the inbox for files older than the age threshold and move them to
ready_for_hot/ so an upload job can send them to Hot storage later.

Options:
  -i, --inbox PATH         Inbox directory to scan
  -r, --ready-dir PATH     Destination for aged files
  -t, --threshold MINUTES  Age threshold in minutes (default: 10)
      --dry-run            Report only; do not move files
  -h, --help               Show this help

Environment overrides:
  AGE_INBOX, AGE_READY_DIR, AGE_THRESHOLD_MINUTES
EOF
}

die() {
  echo "error: $*" >&2
  exit 2
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    -i|--inbox)
      INBOX="${2:-}"
      shift 2
      ;;
    -r|--ready-dir)
      READY_DIR="${2:-}"
      shift 2
      ;;
    -t|--threshold)
      THRESHOLD_MINUTES="${2:-}"
      shift 2
      ;;
    --dry-run)
      DRY_RUN=1
      shift
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      die "unknown argument: $1"
      ;;
  esac
done

[[ "${THRESHOLD_MINUTES}" =~ ^[1-9][0-9]*$ ]] || die "--threshold must be a positive integer"

INBOX="${INBOX/#\~/$HOME}"
READY_DIR="${READY_DIR/#\~/$HOME}"

if [[ ! -d "${INBOX}" ]]; then
  echo "inbox missing: ${INBOX} (nothing to do)"
  exit 0
fi

mkdir -p "${READY_DIR}"

now_epoch="$(date +%s)"
scanned=0
aged=0
kept=0
skipped=0

# Only regular files directly in the inbox (no recursion into subdirs).
shopt -s nullglob
files=("${INBOX}"/*)
shopt -u nullglob

if [[ ${#files[@]} -eq 0 ]]; then
  echo "scanned=0 aged=0 kept=0 skipped=0 threshold_minutes=${THRESHOLD_MINUTES}"
  echo "inbox empty: ${INBOX}"
  exit 0
fi

for path in "${files[@]}"; do
  [[ -e "${path}" ]] || continue

  if [[ ! -f "${path}" ]]; then
    echo "SKIP not-a-regular-file $(basename "${path}")"
    skipped=$((skipped + 1))
    continue
  fi

  scanned=$((scanned + 1))
  base="$(basename "${path}")"
  mtime_epoch="$(stat -c '%Y' "${path}")"
  age_seconds=$((now_epoch - mtime_epoch))
  # Ceiling division so 10m+1s counts as aged when threshold is 10.
  age_minutes=$(( (age_seconds + 59) / 60 ))

  if (( age_seconds < THRESHOLD_MINUTES * 60 )); then
    echo "KEEP ${base} age_seconds=${age_seconds} age_minutes≈${age_minutes} (< ${THRESHOLD_MINUTES}m)"
    kept=$((kept + 1))
    continue
  fi

  dest="${READY_DIR}/${base}"
  if [[ -e "${dest}" ]]; then
    echo "SKIP destination-exists ${base} -> ${dest}"
    skipped=$((skipped + 1))
    continue
  fi

  if (( DRY_RUN )); then
    echo "AGED (dry-run) ${base} age_seconds=${age_seconds} age_minutes≈${age_minutes} would_move_to=${dest}"
  else
    mv -n "${path}" "${dest}"
    echo "AGED ${base} age_seconds=${age_seconds} age_minutes≈${age_minutes} moved_to=${dest}"
  fi
  aged=$((aged + 1))
done

echo "scanned=${scanned} aged=${aged} kept=${kept} skipped=${skipped} threshold_minutes=${THRESHOLD_MINUTES} dry_run=${DRY_RUN}"
echo "inbox=${INBOX}"
echo "ready_for_hot=${READY_DIR}"
