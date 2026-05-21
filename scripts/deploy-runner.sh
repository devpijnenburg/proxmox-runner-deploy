#!/usr/bin/env bash
# Deploys a GitHub Actions runner in a new LXC container on the Proxmox host.
# Creates the container directly with pct create (no community-scripts dependency),
# installs the runner binary, and configures it via pct exec.
#
# Called by the deploy-runner.yml workflow as:
#   RUNNER_REPO=... RUNNER_TOKEN=... CTID=... bash scripts/deploy-runner.sh <name>
#
# Required env vars:
#   RUNNER_REPO        - Repository or org URL (e.g. https://github.com/org/repo)
#   RUNNER_TOKEN       - GitHub runner registration token
#   CTID               - LXC container ID to create
# Optional env vars:
#   CONTAINER_PASSWORD - Root password for Proxmox console access (random if unset)

set -euo pipefail

RUNNER_NAME="${1:?Usage: $0 <runner-name>}"
RUNNER_REPO="${RUNNER_REPO:?RUNNER_REPO env var is required}"
RUNNER_TOKEN="${RUNNER_TOKEN:?RUNNER_TOKEN env var is required}"
CTID="${CTID:?CTID env var is required}"
CONTAINER_PASSWORD="${CONTAINER_PASSWORD:-}"

SERVICE_NAME="actions-runner"
SUDOERS_FILE="/etc/sudoers.d/runner-deploy"
CORRECT_RULE="runner ALL=(ALL) NOPASSWD: SETENV: /usr/bin/bash"

if [[ $EUID -ne 0 ]]; then
  echo "ERROR: this script must be run as root." >&2
  exit 1
fi

[[ "$CTID" =~ ^[0-9]+$ ]] || { echo "ERROR: CTID '${CTID}' is not a valid integer." >&2; exit 1; }

if pct status "$CTID" &>/dev/null; then
  echo "ERROR: container ${CTID} already exists." >&2
  echo "  To remove: pct stop ${CTID} && pct destroy ${CTID}" >&2
  exit 1
fi

# ── Find storage for container rootfs ─────────────────────────────────────────
STORAGE=$(pvesm status --content rootdir 2>/dev/null | awk 'NR>1 {print $1; exit}')
if [[ -z "$STORAGE" ]]; then
  STORAGE="local-lvm"
fi
echo "==> Using storage: ${STORAGE}"

# ── Find or download a Debian template ────────────────────────────────────────
TEMPLATE=$(pveam list local 2>/dev/null | awk '/debian-12/ {print $1}' | tail -1)
if [[ -z "$TEMPLATE" ]]; then
  echo "==> No Debian 12 template found, downloading..."
  pveam update
  TEMPLATE_NAME=$(pveam available --section system 2>/dev/null | awk '/debian-12/ {print $2}' | tail -1)
  if [[ -z "$TEMPLATE_NAME" ]]; then
    echo "ERROR: no Debian 12 template available via pveam." >&2
    exit 1
  fi
  pveam download local "$TEMPLATE_NAME"
  TEMPLATE="local:vztmpl/${TEMPLATE_NAME}"
fi
echo "==> Using template: ${TEMPLATE}"

# ── Create LXC container ───────────────────────────────────────────────────────
echo "==> Creating LXC container ${CTID} for runner '${RUNNER_NAME}'..."
pct create "$CTID" "$TEMPLATE" \
  --hostname "$RUNNER_NAME" \
  --memory 2048 \
  --cores 2 \
  --rootfs "${STORAGE}:8" \
  --net0 name=eth0,bridge=vmbr0,ip=dhcp \
  --unprivileged 1 \
  --features nesting=1,keyctl=1 \
  --onboot 1

pct start "$CTID"

# ── Set root password for Proxmox console access ──────────────────────────────
if [[ -z "$CONTAINER_PASSWORD" ]]; then
  CONTAINER_PASSWORD=$(head -c 32 /dev/urandom | base64 | tr -d '+/=' | cut -c1-16)
  echo "==> Generated container root password: ${CONTAINER_PASSWORD}"
fi
pct exec "$CTID" -- bash -c "echo 'root:${CONTAINER_PASSWORD}' | chpasswd" 2>/dev/null || true

# ── Wait for container to accept commands ─────────────────────────────────────
echo "==> Waiting for container ${CTID} to be ready..."
for i in $(seq 1 30); do
  if pct exec "$CTID" -- true 2>/dev/null; then
    break
  fi
  if [[ $i -eq 30 ]]; then
    echo "ERROR: container ${CTID} did not become ready in time." >&2
    exit 1
  fi
  sleep 2
done

# ── Install dependencies inside container ─────────────────────────────────────
echo "==> Installing dependencies in container ${CTID}..."
pct exec "$CTID" -- bash -c "
  apt-get update -qq
  apt-get install -y --no-install-recommends curl ca-certificates git
"

# ── Create runner user ─────────────────────────────────────────────────────────
pct exec "$CTID" -- bash -c "id runner &>/dev/null || useradd -m -s /bin/bash runner"

# ── Download and install runner binary ────────────────────────────────────────
echo "==> Installing GitHub Actions runner binary..."
LATEST_TAG=$(curl -fsSL https://api.github.com/repos/actions/runner/releases/latest \
  | grep '"tag_name"' | head -1 | cut -d'"' -f4)
LATEST_VER="${LATEST_TAG#v}"

pct exec "$CTID" -- bash -c "
  mkdir -p /opt/actions-runner
  curl -fsSL https://github.com/actions/runner/releases/download/${LATEST_TAG}/actions-runner-linux-x64-${LATEST_VER}.tar.gz \
    | tar -xz -C /opt/actions-runner
  chown -R runner:runner /opt/actions-runner
"

# ── Create systemd service ─────────────────────────────────────────────────────
pct exec "$CTID" -- bash -c "cat > /etc/systemd/system/actions-runner.service <<'SVCEOF'
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
SVCEOF
systemctl daemon-reload
systemctl enable actions-runner"

# ── Configure the runner ───────────────────────────────────────────────────────
echo "==> Configuring runner '${RUNNER_NAME}' inside container ${CTID}..."
pct exec "$CTID" -- runuser -u runner -- /opt/actions-runner/config.sh \
  --url "${RUNNER_REPO}" \
  --token "${RUNNER_TOKEN}" \
  --name "${RUNNER_NAME}" \
  --labels proxmox \
  --unattended \
  || { echo "ERROR: runner configuration failed." >&2; exit 1; }

# ── Set up sudoers ─────────────────────────────────────────────────────────────
EXISTING=$(pct exec "$CTID" -- bash -c "cat ${SUDOERS_FILE} 2>/dev/null || true")
if [[ "$EXISTING" != "$CORRECT_RULE" ]]; then
  pct exec "$CTID" -- bash -c \
    "mkdir -p /etc/sudoers.d && echo '${CORRECT_RULE}' > ${SUDOERS_FILE} && chmod 440 ${SUDOERS_FILE}"
fi

# ── Start the runner service ───────────────────────────────────────────────────
echo "==> Starting ${SERVICE_NAME} in container ${CTID}..."
pct exec "$CTID" -- systemctl start "${SERVICE_NAME}"

STATUS=$(pct exec "$CTID" -- systemctl is-active "${SERVICE_NAME}" 2>/dev/null || echo "failed")
if [[ "$STATUS" != "active" ]]; then
  echo "ERROR: service not active (status: ${STATUS}). Recent logs:" >&2
  pct exec "$CTID" -- journalctl -u "${SERVICE_NAME}" -n 20 --no-pager >&2
  exit 1
fi

echo ""
echo "Runner '${RUNNER_NAME}' deployed in container ${CTID}."
echo "  Status  : ${STATUS}"
echo "  Console : login as root with the container password set above"
