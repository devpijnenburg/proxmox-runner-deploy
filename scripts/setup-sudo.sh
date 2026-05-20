#!/usr/bin/env bash
# Configures the sudoers rule on the Proxmox host so the runner user
# can execute the deploy script with elevated privileges.
# Run this once on the Proxmox host before using the deploy workflow.

set -euo pipefail

SUDOERS_FILE="/etc/sudoers.d/runner-deploy"

if [[ $EUID -ne 0 ]]; then
  echo "ERROR: this script must be run as root (use sudo)." >&2
  exit 1
fi

if [[ -f "$SUDOERS_FILE" ]]; then
  echo "Sudoers rule already exists at ${SUDOERS_FILE} — nothing to do."
  exit 0
fi

echo "runner ALL=(ALL) NOPASSWD: /usr/bin/bash" > "$SUDOERS_FILE"
chmod 440 "$SUDOERS_FILE"

# Validate the file before leaving it in place
if ! visudo -cf "$SUDOERS_FILE"; then
  rm -f "$SUDOERS_FILE"
  echo "ERROR: generated sudoers file failed validation and was removed." >&2
  exit 1
fi

echo "Sudoers rule created at ${SUDOERS_FILE}."
