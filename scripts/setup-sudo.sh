#!/usr/bin/env bash
# Configures the sudoers rule on the Proxmox host so the runner user
# can execute the deploy script with elevated privileges.
# Run this once on the Proxmox host before using the deploy workflow.

set -euo pipefail

SUDOERS_FILE="/etc/sudoers.d/runner-deploy"
RULE="runner ALL=(ALL) NOPASSWD: SETENV: /usr/bin/bash"

if [[ $EUID -ne 0 ]]; then
  echo "ERROR: this script must be run as root (use sudo)." >&2
  exit 1
fi

if [[ -f "$SUDOERS_FILE" ]]; then
  echo "Sudoers rule already exists at ${SUDOERS_FILE} — nothing to do."
  exit 0
fi

echo "$RULE" > "$SUDOERS_FILE"
chmod 440 "$SUDOERS_FILE"

echo "Sudoers rule created at ${SUDOERS_FILE}."
