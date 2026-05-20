#!/usr/bin/env bash
# Creates an LXC container on the Proxmox host and installs a GitHub Actions
# bootstrap runner inside it with the 'proxmox' label and sudoers configured.
# Run once on the Proxmox host as root.
#
# Usage (unattended):
#   REPO_URL=https://github.com/org/repo TOKEN=<token> sudo bash create-bootstrap-runner.sh
#
# Usage (interactive):
#   sudo bash create-bootstrap-runner.sh
#
# Optional env vars (all have defaults):
#   RUNNER_NAME   display name for the runner      (default: github-runner)
#   CT_ID         LXC container ID                 (default: next available)
#   CT_HOSTNAME   container hostname               (default: github-runner)
#   CT_MEMORY     RAM in MB                        (default: 2048)
#   CT_CORES      CPU cores                        (default: 2)
#   CT_DISK       disk size in GB                  (default: 8)
#   CT_BRIDGE     network bridge                   (default: vmbr0)
#   CT_STORAGE    Proxmox storage for rootfs       (default: local-lvm)

set -euo pipefail

SERVICE_NAME="actions-runner"
SUDOERS_FILE="/etc/sudoers.d/runner-deploy"

# ── Parameters ─────────────────────────────────────────────────────────────────
REPO_URL="${REPO_URL:-}"
TOKEN="${TOKEN:-}"
RUNNER_NAME="${RUNNER_NAME:-github-runner}"
CT_ID="${CT_ID:-$(pvesh get /cluster/nextid)}"
CT_HOSTNAME="${CT_HOSTNAME:-github-runner}"
CT_MEMORY="${CT_MEMORY:-2048}"
CT_CORES="${CT_CORES:-2}"
CT_DISK="${CT_DISK:-8}"
CT_BRIDGE="${CT_BRIDGE:-vmbr0}"
CT_STORAGE="${CT_STORAGE:-local-lvm}"

# ── Root check ─────────────────────────────────────────────────────────────────
if [[ $EUID -ne 0 ]]; then
  echo "ERROR: this script must be run as root on the Proxmox host." >&2
  exit 1
fi

# ── Interactive prompts for required values ────────────────────────────────────
if [[ -z "$REPO_URL" ]]; then
  read -rp "GitHub repo URL (e.g. https://github.com/org/repo): " REPO_URL
fi
if [[ -z "$TOKEN" ]]; then
  echo "Get your token: repo Settings → Actions → Runners → New self-hosted runner → copy the token."
  read -rsp "Runner registration token: " TOKEN
  echo
fi

echo "==> Container ID  : ${CT_ID}"
echo "==> Hostname      : ${CT_HOSTNAME}"
echo "==> Runner name   : ${RUNNER_NAME}"
echo "==> Repo URL      : ${REPO_URL}"
echo "==> Storage       : ${CT_STORAGE}"
echo "==> Bridge        : ${CT_BRIDGE}"
echo ""

# ── Find or download a Debian 12 template ─────────────────────────────────────
echo "==> Looking for Debian 12 template in local storage..."
TEMPLATE=$(pveam list local 2>/dev/null | awk '/debian-12/{print $1}' | tail -1)
if [[ -z "$TEMPLATE" ]]; then
  echo "==> Not found locally — downloading..."
  pveam update
  TEMPLATE_NAME=$(pveam available --section system | awk '/debian-12/{print $2}' | tail -1)
  if [[ -z "$TEMPLATE_NAME" ]]; then
    echo "ERROR: no Debian 12 template available via pveam." >&2
    exit 1
  fi
  pveam download local "$TEMPLATE_NAME"
  TEMPLATE="local:vztmpl/${TEMPLATE_NAME}"
fi
echo "==> Using template: ${TEMPLATE}"

# ── Create and start LXC container ────────────────────────────────────────────
echo "==> Creating LXC container ${CT_ID}..."
pct create "$CT_ID" "$TEMPLATE" \
  --hostname "$CT_HOSTNAME" \
  --memory "$CT_MEMORY" \
  --cores "$CT_CORES" \
  --rootfs "${CT_STORAGE}:${CT_DISK}" \
  --net0 "name=eth0,bridge=${CT_BRIDGE},ip=dhcp" \
  --unprivileged 1 \
  --features "nesting=1" \
  --onboot 1

pct start "$CT_ID"

echo "==> Waiting for container to be ready..."
for i in $(seq 1 20); do
  if pct exec "$CT_ID" -- true 2>/dev/null; then
    break
  fi
  sleep 2
done

# ── Install dependencies ───────────────────────────────────────────────────────
echo "==> Installing dependencies..."
pct exec "$CT_ID" -- bash -c "
  apt-get update -qq
  apt-get install -y --no-install-recommends curl ca-certificates git
"

# ── Create runner user ─────────────────────────────────────────────────────────
echo "==> Creating runner user..."
pct exec "$CT_ID" -- bash -c "
  if ! id runner &>/dev/null; then
    useradd -m -s /bin/bash runner
  fi
"

# ── Download latest runner binary ─────────────────────────────────────────────
echo "==> Fetching latest GitHub Actions runner release..."
pct exec "$CT_ID" -- bash -c "
  LATEST_TAG=\$(curl -fsSL https://api.github.com/repos/actions/runner/releases/latest \
    | grep '\"tag_name\"' | head -1 | cut -d'\"' -f4)
  LATEST_VER=\"\${LATEST_TAG#v}\"
  TARBALL=\"actions-runner-linux-x64-\${LATEST_VER}.tar.gz\"
  DOWNLOAD_URL=\"https://github.com/actions/runner/releases/download/\${LATEST_TAG}/\${TARBALL}\"
  echo \"Downloading \${TARBALL}...\"
  mkdir -p /opt/actions-runner
  curl -fsSL \"\$DOWNLOAD_URL\" | tar -xz -C /opt/actions-runner
  chown -R runner:runner /opt/actions-runner
"

# ── Configure the runner ───────────────────────────────────────────────────────
echo "==> Configuring runner '${RUNNER_NAME}' with label 'proxmox'..."
pct exec "$CT_ID" -- bash -c "
  cd /opt/actions-runner
  sudo -u runner ./config.sh \
    --url '${REPO_URL}' \
    --token '${TOKEN}' \
    --name '${RUNNER_NAME}' \
    --labels proxmox \
    --unattended
"

# ── Create systemd service ─────────────────────────────────────────────────────
echo "==> Installing systemd service..."
pct exec "$CT_ID" -- bash -c "
cat > /etc/systemd/system/${SERVICE_NAME}.service <<'UNIT'
[Unit]
Description=GitHub Actions self-hosted runner
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
User=runner
WorkingDirectory=/opt/actions-runner
ExecStart=/opt/actions-runner/run.sh
Restart=on-failure
RestartSec=10

[Install]
WantedBy=multi-user.target
UNIT
systemctl daemon-reload
systemctl enable ${SERVICE_NAME}
systemctl start ${SERVICE_NAME}
"

# ── Set up sudoers ─────────────────────────────────────────────────────────────
echo "==> Configuring sudoers..."
pct exec "$CT_ID" -- bash -c "
  echo 'runner ALL=(ALL) NOPASSWD: SETENV: /usr/bin/bash' > ${SUDOERS_FILE}
  chmod 440 ${SUDOERS_FILE}
"

# ── Summary ────────────────────────────────────────────────────────────────────
STATUS=$(pct exec "$CT_ID" -- systemctl is-active "${SERVICE_NAME}" 2>/dev/null || echo "unknown")
echo ""
echo "Bootstrap runner '${RUNNER_NAME}' deployed in container ${CT_ID}."
echo "  Container : ${CT_ID} (${CT_HOSTNAME})"
echo "  Service   : ${STATUS}"
echo ""
echo "Check GitHub → Settings → Actions → Runners to confirm it's online with label 'proxmox'."
