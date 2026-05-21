#!/usr/bin/env bash
# Installs the GitHub Actions bootstrap runner directly on the Proxmox host.
# The bootstrap runner is needed to run the deploy-runner workflow, which
# creates a new LXC container for each additional runner via community-scripts.
# Run once on the Proxmox host as root.
#
# Usage (unattended):
#   REPO_URL=https://github.com/org/repo TOKEN=<token> bash -c "$(curl -fsSL <url>)"
#
# Usage (interactief):
#   bash -c "$(curl -fsSL <url>)"
#
# Optional env vars:
#   RUNNER_NAME   display name for the runner (default: proxmox-bootstrap)

set -euo pipefail

REPO_URL="${REPO_URL:-}"
TOKEN="${TOKEN:-}"
RUNNER_NAME="${RUNNER_NAME:-proxmox-bootstrap}"
RUNNER_DIR="/opt/actions-runner-bootstrap"
SERVICE_NAME="actions-runner-bootstrap"
SUDOERS_FILE="/etc/sudoers.d/runner-deploy"

if [[ $EUID -ne 0 ]]; then
  echo "ERROR: this script must be run as root on the Proxmox host." >&2
  exit 1
fi

# ── Idempotentie: al geïnstalleerd? ───────────────────────────────────────────
if [[ -f "${RUNNER_DIR}/run.sh" ]]; then
  echo "Bootstrap runner already installed in ${RUNNER_DIR}."
  echo "  Status: $(systemctl is-active ${SERVICE_NAME} 2>/dev/null || echo 'unknown')"
  exit 0
fi

if [[ -z "$REPO_URL" ]]; then
  read -rp "GitHub repo URL (e.g. https://github.com/org/repo): " REPO_URL
fi
if [[ -z "$TOKEN" ]]; then
  echo "Get your token: repo Settings → Actions → Runners → New self-hosted runner → copy the token."
  read -rsp "Runner registration token: " TOKEN
  echo
fi

echo "==> Installing dependencies..."
apt-get update -qq
apt-get install -y --no-install-recommends curl ca-certificates git

if ! id runner &>/dev/null; then
  echo "==> Creating runner user..."
  useradd -m -s /bin/bash runner
fi

echo "==> Fetching latest GitHub Actions runner release..."
LATEST_TAG=$(curl -fsSL https://api.github.com/repos/actions/runner/releases/latest \
  | grep '"tag_name"' | head -1 | cut -d'"' -f4)
LATEST_VER="${LATEST_TAG#v}"
TARBALL="actions-runner-linux-x64-${LATEST_VER}.tar.gz"
DOWNLOAD_URL="https://github.com/actions/runner/releases/download/${LATEST_TAG}/${TARBALL}"

mkdir -p "${RUNNER_DIR}"
curl -fsSL "${DOWNLOAD_URL}" | tar -xz -C "${RUNNER_DIR}"
chown -R runner:runner "${RUNNER_DIR}"

echo "==> Configuring runner '${RUNNER_NAME}' with label 'proxmox'..."
cd "${RUNNER_DIR}" || { echo "ERROR: failed to enter ${RUNNER_DIR}" >&2; exit 1; }
runuser -u runner -- ./config.sh \
  --url "${REPO_URL}" \
  --token "${TOKEN}" \
  --name "${RUNNER_NAME}" \
  --labels proxmox \
  --unattended \
  || { echo "ERROR: runner configuration failed. Check token and repo URL." >&2; exit 1; }

echo "==> Installing systemd service..."
cat > "/etc/systemd/system/${SERVICE_NAME}.service" <<EOF
[Unit]
Description=GitHub Actions bootstrap runner (${RUNNER_NAME})
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
User=root
WorkingDirectory=${RUNNER_DIR}
ExecStart=${RUNNER_DIR}/run.sh
Restart=on-failure
RestartSec=10

[Install]
WantedBy=multi-user.target
EOF

systemctl daemon-reload
systemctl enable "${SERVICE_NAME}"
systemctl start "${SERVICE_NAME}"

sleep 2
if ! systemctl is-active "${SERVICE_NAME}" &>/dev/null; then
  echo "ERROR: service ${SERVICE_NAME} failed to start." >&2
  journalctl -u "${SERVICE_NAME}" -n 20 --no-pager >&2
  exit 1
fi

echo "==> Configuring sudoers..."
echo "runner ALL=(ALL) NOPASSWD: SETENV: /usr/bin/bash" > "${SUDOERS_FILE}"
chmod 440 "${SUDOERS_FILE}"

echo ""
echo "Bootstrap runner '${RUNNER_NAME}' installed on the Proxmox host."
echo "  Directory : ${RUNNER_DIR}"
echo "  Service   : $(systemctl is-active ${SERVICE_NAME})"
echo ""
echo "Check GitHub → Settings → Actions → Runners to confirm it's online with label 'proxmox'."
