#!/usr/bin/env bash
# Install the lab ed25519 public key on sw-proxy / sw-hot / sw-cold (password once each).
# Requires: working SSH path to 172.30.201.247-249 (see INVENTORY.md network note).
# Usage:
#   SSHPASS='your-vm-password' ./infrastructure/install_ssh_keys.sh
# Or interactive (sshpass optional):
#   ./infrastructure/install_ssh_keys.sh

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PUBKEY_FILE="${PUBKEY_FILE:-$HOME/.ssh/id_ed25519.pub}"
USER_NAME="${SSH_USER:-bbdh}"
HOSTS=(172.30.201.247 172.30.201.248 172.30.201.249)

[[ -f "$PUBKEY_FILE" ]] || { echo "missing pubkey: $PUBKEY_FILE" >&2; exit 1; }
PUBKEY="$(cat "$PUBKEY_FILE")"

if [[ -z "${SSHPASS:-}" ]] && ! command -v sshpass >/dev/null; then
  echo "Set SSHPASS env var, or install sshpass, so keys can be pushed non-interactively." >&2
  echo "Example: SSHPASS='...' $0" >&2
fi

for ip in "${HOSTS[@]}"; do
  echo "=== installing key on ${USER_NAME}@${ip} ==="
  remote_cmd=$(cat <<EOF
mkdir -p ~/.ssh && chmod 700 ~/.ssh
touch ~/.ssh/authorized_keys && chmod 600 ~/.ssh/authorized_keys
grep -qxF '$PUBKEY' ~/.ssh/authorized_keys || echo '$PUBKEY' >> ~/.ssh/authorized_keys
echo OK
EOF
)
  if [[ -n "${SSHPASS:-}" ]] && command -v sshpass >/dev/null; then
    sshpass -e ssh -o StrictHostKeyChecking=accept-new \
      -o PreferredAuthentications=password -o PubkeyAuthentication=no \
      "${USER_NAME}@${ip}" "$remote_cmd"
  else
    ssh -o StrictHostKeyChecking=accept-new \
      "${USER_NAME}@${ip}" "$remote_cmd"
  fi
done

echo
echo "Test with: ssh -F ${ROOT}/ssh_config sw-proxy hostname"
