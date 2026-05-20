#!/usr/bin/env bash
# Deploys a GitHub Actions runner in a new LXC container on the Proxmox host.
# Uses community-scripts/ProxmoxVE for unattended LXC creation, then configures
# the runner inside the container via pct exec.
#
# Called by the deploy-runner.yml workflow as:
#   sudo --preserve-env=RUNNER_REPO,RUNNER_TOKEN,CTID bash scripts/deploy-runner.sh <name>
#
# Required env vars:
#   RUNNER_REPO   - Repository or org URL (e.g. https://github.com/org/repo)
#   RUNNER_TOKEN  - GitHub runner registration token
#   CTID          - LXC container ID to create

set -euo pipefail

RUNNER_NAME="${1:?Usage: $0 <runner-name>}"
RUNNER_REPO="${RUNNER_REPO:?RUNNER_REPO env var is required}"
RUNNER_TOKEN="${RUNNER_TOKEN:?RUNNER_TOKEN env var is required}"
CTID="${CTID:?CTID env var is required}"

SERVICE_NAME="actions-runner"
SUDOERS_FILE="/etc/sudoers.d/runner-deploy"

if [[ $EUID -ne 0 ]]; then
  echo "ERROR: this script must be run as root." >&2
  exit 1
fi

if pct status "$CTID" &>/dev/null; then
  echo "ERROR: container ${CTID} already exists." >&2
  exit 1
fi

# ── Create LXC via community-scripts (unattended) ─────────────────────────────
echo "==> Creating LXC container ${CTID} for runner '${RUNNER_NAME}'..."

export CTID
export HN="${RUNNER_NAME}"
export DISK_SIZE="8"
export CORE_COUNT="2"
export RAM_SIZE="2048"
export BRG="vmbr0"
export NET="dhcp"
export VERB="no"

bash -c "$(curl -fsSL https://raw.githubusercontent.com/community-scripts/ProxmoxVE/main/ct/github-runner.sh)"

# ── Wait for container to accept commands ─────────────────────────────────────
echo "==> Waiting for container ${CTID} to be ready..."
for i in $(seq 1 30); do
  if pct exec "$CTID" -- true 2>/dev/null; then
    break
  fi
  sleep 2
done

# ── Configure the runner ───────────────────────────────────────────────────────
echo "==> Configuring runner '${RUNNER_NAME}' inside container ${CTID}..."
pct exec "$CTID" -- sudo -u runner /opt/actions-runner/config.sh \
  --url "${RUNNER_REPO}" \
  --token "${RUNNER_TOKEN}" \
  --name "${RUNNER_NAME}" \
  --labels proxmox \
  --unattended

# ── Set up sudoers ─────────────────────────────────────────────────────────────
pct exec "$CTID" -- bash -c \
  "echo 'runner ALL=(ALL) NOPASSWD: SETENV: /usr/bin/bash' > ${SUDOERS_FILE} && chmod 440 ${SUDOERS_FILE}"

# ── Start the runner service ───────────────────────────────────────────────────
echo "==> Starting ${SERVICE_NAME} in container ${CTID}..."
pct exec "$CTID" -- systemctl start "${SERVICE_NAME}"

echo ""
echo "Runner '${RUNNER_NAME}' deployed in container ${CTID}."
echo "  Status: $(pct exec "$CTID" -- systemctl is-active ${SERVICE_NAME})"
