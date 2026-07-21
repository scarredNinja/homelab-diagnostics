#!/usr/bin/env bash
# automation/diagnostics/diagnose-hardware.sh
# Diagnoses hardware resources, ZFS health, and VM allocations on Proxmox VE.

set -euo pipefail

PVE_HOST="10.0.90.50"
SSH_KEY="$HOME/.ssh/homelab_ed25519"
SSH_OPTS=(-i "$SSH_KEY" -o BatchMode=yes -o StrictHostKeyChecking=accept-new)

echo "### 🖥️ Hardware & Host Diagnostic"
echo ""

# Check SSH connection
if ! ssh "${SSH_OPTS[@]}" "root@$PVE_HOST" "echo OK" >/dev/null 2>&1; then
    echo "❌ ERROR: Cannot connect to Proxmox Host ($PVE_HOST) via SSH."
    echo "Check if your SSH key is authorized or if the host is down."
    exit 1
fi

echo "#### 1. Proxmox VE Host Load & Memory"
echo "\`\`\`"
ssh "${SSH_OPTS[@]}" "root@$PVE_HOST" "uptime"
echo ""
ssh "${SSH_OPTS[@]}" "root@$PVE_HOST" "free -h"
echo "\`\`\`"
echo ""

echo "#### 2. ZFS Pools Health Status"
echo "\`\`\`"
ssh "${SSH_OPTS[@]}" "root@$PVE_HOST" "zpool status -x"
echo ""
ssh "${SSH_OPTS[@]}" "root@$PVE_HOST" "zpool list"
echo "\`\`\`"
echo ""

echo "#### 3. Proxmox running VMs and resource allocation"
echo "\`\`\`"
ssh "${SSH_OPTS[@]}" "root@$PVE_HOST" "export PATH=\$PATH:/usr/sbin:/sbin; qm list"
echo "\`\`\`"
echo ""

echo "#### 4. Disk Temperature / SMART warnings (HP DL360p Gen8)"
echo "\`\`\`"
ssh "${SSH_OPTS[@]}" "root@$PVE_HOST" '
    if command -v smartctl >/dev/null 2>&1; then
        echo "Running SMART checks on ZFS pool disks..."
        # Query SMART status for SAS/SATA drives
        for dev in $(ls /dev/sd[a-z] /dev/cciss/c*d* 2>/dev/null); do
            echo -n "$dev: "
            smartctl -H "$dev" 2>/dev/null | grep -E "result:|test" || echo "SMART check failed or not supported"
        done
    else
        echo "smartctl tool not installed on host."
    fi
' 2>/dev/null || echo "ERROR: Failed to run SMART check."
echo "\`\`\`"
echo ""
