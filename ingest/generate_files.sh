#!/usr/bin/env bash
# Generate random binary files into the Hot/Cold storage inbox.
# Uses dd and /dev/urandom. See also: run_generate_cron.sh

set -euo pipefail

COUNT=1
OUTDIR="${HOME}/HC_storage_data/inbox"
MIN_BYTES=1024
MAX_BYTES=65536
PREFIX="obj"

usage() {
  cat <<'EOF'
Usage: generate_files.sh [options]

Create random binary files with dd and /dev/urandom.

Options:
  -n, --count N          Number of files to create (default: 1)
  -o, --outdir PATH      Output directory (default: ~/HC_storage_data/inbox)
      --min-bytes N      Minimum size in bytes (default: 1024)
      --max-bytes N      Maximum size in bytes (default: 65536)
      --prefix NAME      Filename prefix (default: obj)
  -h, --help             Show this help
EOF
}

die() {
  echo "error: $*" >&2
  exit 2
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    -n|--count)
      COUNT="${2:-}"
      shift 2
      ;;
    -o|--outdir)
      OUTDIR="${2:-}"
      shift 2
      ;;
    --min-bytes)
      MIN_BYTES="${2:-}"
      shift 2
      ;;
    --max-bytes)
      MAX_BYTES="${2:-}"
      shift 2
      ;;
    --prefix)
      PREFIX="${2:-}"
      shift 2
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

[[ "$COUNT" =~ ^[1-9][0-9]*$ ]] || die "--count must be a positive integer"
[[ "$MIN_BYTES" =~ ^[1-9][0-9]*$ ]] || die "--min-bytes must be a positive integer"
[[ "$MAX_BYTES" =~ ^[1-9][0-9]*$ ]] || die "--max-bytes must be a positive integer"
(( MAX_BYTES >= MIN_BYTES )) || die "--max-bytes must be >= --min-bytes"

OUTDIR="${OUTDIR/#\~/$HOME}"
mkdir -p "$OUTDIR"

random_size() {
  local span=$((MAX_BYTES - MIN_BYTES + 1))
  echo $((MIN_BYTES + (RANDOM % span)))
}

random_token() {
  head -c 4 /dev/urandom | od -An -tx1 | tr -d ' \n'
}

created=0
for ((i = 1; i <= COUNT; i++)); do
  size="$(random_size)"
  stamp="$(date +%Y%m%dT%H%M%S)"
  token="$(random_token)"
  name="${PREFIX}_${stamp}_${token}_${size}b.bin"
  path="${OUTDIR}/${name}"

  dd if=/dev/urandom of="$path" bs="$size" count=1 status=none

  actual="$(stat -c '%s' "$path")"
  echo "created ${path} (${actual} bytes)"
  created=$((created + 1))
  sleep 0.01 2>/dev/null || true
done

echo "done: ${created} file(s) in ${OUTDIR}"
