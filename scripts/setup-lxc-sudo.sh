#!/usr/bin/env bash
# Sets up the passwordless sudo rule for the GitHub Actions runner inside an LXC container.
# Run this on the Proxmox host as root.
#
# Usage (script):    sudo bash setup-lxc-sudo.sh <ctid> [runner-user]
# Usage (one-liner): sudo CTID=100 bash -c "$(curl -fsSL https://raw.githubusercontent.com/devpijnenburg/proxmox-runner-deploy/main/scripts/setup-lxc-sudo.sh)"
#
#   CTID / $1        - LXC container ID (e.g. 100)
#   RUNNER_USER / $2 - User running the runner inside the container (default: auto-detect)

set -euo pipefail

# Accept both env vars (one-liner) and positional args (direct invocation)
CTID="${CTID:-${1:-}}"
SUDOERS_FILE="/etc/sudoers.d/runner-deploy"

if [[ $EUID -ne 0 ]]; then
  echo "ERROR: this script must be run as root on the Proxmox host." >&2
  exit 1
fi

if [[ -z "$CTID" ]]; then
  read -rp "LXC container ID: " CTID
fi

if ! pct status "$CTID" &>/dev/null; then
  echo "ERROR: container ${CTID} not found." >&2
  exit 1
fi

if [[ "$(pct status "$CTID")" != *"running"* ]]; then
  echo "ERROR: container ${CTID} is not running." >&2
  exit 1
fi

# Accept runner user from env var, positional arg, or auto-detect
if [[ -n "${RUNNER_USER:-${2:-}}" ]]; then
  RUNNER_USER="${RUNNER_USER:-$2}"
else
  echo "==> Auto-detecting runner user inside container ${CTID}..."
  RUNNER_USER=$(pct exec "$CTID" -- bash -c "ps aux | grep 'run\.sh' | grep -v grep | awk '{print \$1}' | head -1")
  if [[ -z "$RUNNER_USER" ]]; then
    echo "WARNING: could not detect runner user automatically — defaulting to 'runner'."
    RUNNER_USER="runner"
  fi
fi

echo "==> Container  : ${CTID}"
echo "==> Runner user: ${RUNNER_USER}"
echo "==> Sudoers    : ${SUDOERS_FILE}"

# Check if rule already exists
EXISTING=$(pct exec "$CTID" -- bash -c "cat ${SUDOERS_FILE} 2>/dev/null || true")
if [[ -n "$EXISTING" ]]; then
  echo "Sudoers rule already exists inside container ${CTID}:"
  echo "  ${EXISTING}"
  echo "Nothing to do."
  exit 0
fi

pct exec "$CTID" -- bash -c "echo '${RUNNER_USER} ALL=(ALL) NOPASSWD: /usr/bin/bash' > ${SUDOERS_FILE} && chmod 440 ${SUDOERS_FILE}"

echo "==> Verifying..."
pct exec "$CTID" -- bash -c "cat ${SUDOERS_FILE}"

echo ""
echo "Done. The runner user '${RUNNER_USER}' can now run sudo bash without a password inside container ${CTID}."
