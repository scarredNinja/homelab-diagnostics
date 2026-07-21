#!/usr/bin/env bash
# automation/systemd/install-systemd-timer.sh
# Installs or updates the homelab-health user-scope systemd timer.
# Safe to re-run after any changes to the .service or .timer files.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SYSTEMD_USER_DIR="$HOME/.config/systemd/user"
SERVICE_NAME="homelab-health"

echo "=== Installing homelab-health systemd user timer ==="
echo "Source: $SCRIPT_DIR"
echo "Destination: $SYSTEMD_USER_DIR"
echo ""

mkdir -p "$SYSTEMD_USER_DIR"

# Copy unit files from repo into user systemd directory
cp "$SCRIPT_DIR/$SERVICE_NAME.service" "$SYSTEMD_USER_DIR/$SERVICE_NAME.service"
cp "$SCRIPT_DIR/$SERVICE_NAME.timer"   "$SYSTEMD_USER_DIR/$SERVICE_NAME.timer"
echo "✅ Copied $SERVICE_NAME.service and $SERVICE_NAME.timer"

# Reload daemon so systemd picks up any changes
systemctl --user daemon-reload
echo "✅ systemd user daemon reloaded"

# Enable and start the timer (idempotent)
systemctl --user enable --now "$SERVICE_NAME.timer"
echo "✅ $SERVICE_NAME.timer enabled and started"

echo ""
echo "=== Timer Status ==="
systemctl --user status "$SERVICE_NAME.timer" --no-pager -l
echo ""
echo "=== Next Trigger ==="
systemctl --user list-timers "$SERVICE_NAME.timer" --no-pager
