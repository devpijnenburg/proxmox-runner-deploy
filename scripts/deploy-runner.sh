#!/usr/bin/env bash
# Deploys a GitHub Actions self-hosted runner on a Proxmox host.
# Inspired by https://github.com/community-scripts/ProxmoxVE/blob/main/install/github-runner-install.sh
#
# Usage: deploy-runner.sh <runner-name>
# Env vars required:
#   RUNNER_TOKEN  - GitHub runner registration token
#   RUNNER_REPO   - Repository or org URL (e.g. https://github.com/org/repo)
#   RUNNER_NAME   - Runner display name (same as argument, kept for clarity)

set -euo pipefail

RUNNER_NAME="${1:?Usage: $0 <runner-name>}"
RUNNER_REPO="${RUNNER_REPO:?RUNNER_REPO env var is required}"
RUNNER_TOKEN="${RUNNER_TOKEN:?RUNNER_TOKEN env var is required}"
RUNNER_DIR="/opt/actions-runner-${RUNNER_NAME}"
SERVICE_NAME="actions-runner-${RUNNER_NAME}"

# ── Guard: must run as root ─────────────────────────────────────────────────
if [[ $EUID -ne 0 ]]; then
  echo "ERROR: this script must be run as root (use sudo)." >&2
  exit 1
fi

# ── Abort if this named runner already exists ────────────────────────────────
if systemctl list-units --full --all | grep -q "${SERVICE_NAME}.service"; then
  echo "ERROR: runner '${RUNNER_NAME}' already exists (service ${SERVICE_NAME} found)." >&2
  exit 1
fi

echo "==> Installing dependencies"
apt-get install -y --no-install-recommends git curl ca-certificates

# ── Create dedicated runner user (non-sudo) ──────────────────────────────────
if ! id runner &>/dev/null; then
  echo "==> Creating runner user"
  useradd -m -s /bin/bash runner
fi

# ── Download latest runner binary ────────────────────────────────────────────
echo "==> Fetching latest runner release"
LATEST_TAG=$(curl -fsSL "https://api.github.com/repos/actions/runner/releases/latest" \
  | grep '"tag_name"' | head -1 | cut -d'"' -f4)
LATEST_VER="${LATEST_TAG#v}"
TARBALL="actions-runner-linux-x64-${LATEST_VER}.tar.gz"
DOWNLOAD_URL="https://github.com/actions/runner/releases/download/${LATEST_TAG}/${TARBALL}"

echo "==> Downloading ${TARBALL}"
mkdir -p "${RUNNER_DIR}"
curl -fsSL "${DOWNLOAD_URL}" | tar -xz -C "${RUNNER_DIR}"

# ── Set ownership ─────────────────────────────────────────────────────────────
chown -R runner:runner "${RUNNER_DIR}"

# ── Configure the runner ──────────────────────────────────────────────────────
echo "==> Configuring runner '${RUNNER_NAME}'"
cd "${RUNNER_DIR}"
sudo -u runner ./config.sh \
  --url "${RUNNER_REPO}" \
  --token "${RUNNER_TOKEN}" \
  --name "${RUNNER_NAME}" \
  --unattended

# ── Create systemd service ────────────────────────────────────────────────────
echo "==> Creating systemd service ${SERVICE_NAME}"
cat > "/etc/systemd/system/${SERVICE_NAME}.service" <<EOF
[Unit]
Description=GitHub Actions self-hosted runner (${RUNNER_NAME})
Documentation=https://docs.github.com/en/actions/hosting-your-own-runners
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
User=runner
WorkingDirectory=${RUNNER_DIR}
ExecStart=${RUNNER_DIR}/run.sh
Restart=on-failure
RestartSec=10

[Install]
WantedBy=multi-user.target
EOF

systemctl daemon-reload
systemctl enable "${SERVICE_NAME}"

# ── Start the runner ──────────────────────────────────────────────────────────
echo "==> Starting ${SERVICE_NAME}"
systemctl start "${SERVICE_NAME}"

echo ""
echo "Runner '${RUNNER_NAME}' deployed successfully."
echo "  Directory : ${RUNNER_DIR}"
echo "  Service   : ${SERVICE_NAME}"
echo "  Status    : $(systemctl is-active ${SERVICE_NAME})"
