#!/usr/bin/env bash
# automation/diagnostics/diagnose-backups.sh
# Diagnoses backup jobs, NFS mounts, ZFS snapshots, and storage pools.

set -euo pipefail

PVE_HOST="10.0.90.50"
SSH_KEY="$HOME/.ssh/homelab_ed25519"
SSH_OPTS=(-i "$SSH_KEY" -o BatchMode=yes -o StrictHostKeyChecking=accept-new -p 22)

echo "### 💾 Backups Diagnostic"
echo ""

# Check SSH connection
if ! ssh "${SSH_OPTS[@]}" "root@$PVE_HOST" "echo OK" >/dev/null 2>&1; then
    echo "❌ ERROR: Cannot connect to Proxmox Host ($PVE_HOST) via SSH."
    echo "Check if your SSH key is authorized or if the host is down."
    exit 1
fi

echo "#### 1. Restic Off-site Backups (Synology REST server)"
echo "Checking Restic backup status and locks..."

# Run restic lock check on PVE host
# Restic password file is located at /etc/restic-password
# Restic repo is in /etc/restic-backup.conf
RESTIC_CHECK=$(ssh "${SSH_OPTS[@]}" "root@$PVE_HOST" '
    if [ -f /etc/restic-password ] && [ -f /etc/restic-backup.conf ]; then
        export RESTIC_PASSWORD_FILE="/etc/restic-password"
        source /etc/restic-backup.conf
        repo="${RESTIC_REPO:-rest:http://10.0.100.20:8000/}"
        locks=$(restic -r "$repo" list locks 2>&1)
        if echo "$locks" | grep -q "lock"; then
            echo "WARN: Repository is locked!"
            echo "$locks"
        else
            echo "OK: No active locks found."
        fi
    else
        echo "ERROR: Restic configuration files not found on PVE host."
    fi
' 2>/dev/null || echo "ERROR: Failed to run restic check.")

echo "$RESTIC_CHECK"
echo ""

echo "Last 10 lines of Restic Backup Log:"
echo "\`\`\`"
ssh "${SSH_OPTS[@]}" "root@$PVE_HOST" "tail -n 10 /var/log/restic-backup.log 2>/dev/null || echo 'Log file not found.'"
echo "\`\`\`"
echo ""

echo "#### 2. VM vzdump Backups"
echo "Last 10 lines of VM Backup Log:"
echo "\`\`\`"
ssh "${SSH_OPTS[@]}" "root@$PVE_HOST" "tail -n 10 /var/log/vm-backup.log 2>/dev/null || echo 'Log file not found.'"
echo "\`\`\`"
echo ""

echo "#### 3. ZFS Snapshots"
echo "Last 10 lines of ZFS Snapshot Log:"
echo "\`\`\`"
ssh "${SSH_OPTS[@]}" "root@$PVE_HOST" "tail -n 10 /var/log/zfs-snapshot.log 2>/dev/null || echo 'Log file not found.'"
echo "\`\`\`"
echo ""

echo "#### 4. Disk & Storage Utilization"
echo "Parsing disk metrics from node_exporter textfile collector:"
echo "\`\`\`"
ssh "${SSH_OPTS[@]}" "root@$PVE_HOST" '
    PROM_FILE="/var/lib/node_exporter/textfile_collector/disk_space.prom"
    if [ -f "$PROM_FILE" ]; then
        grep -v "^#" "$PROM_FILE" | grep -E "zfs_pool_free_bytes|zfs_dataset_used_bytes|synology_volume_free_bytes" | while read -r line; do
            metric=$(echo "$line" | cut -d"{" -f1)
            labels=$(echo "$line" | cut -d"{" -f2 | cut -d"}" -f1)
            val=$(echo "$line" | awk "{print \$NF}")
            
            # Convert bytes to GiB/TiB for readability
            if [ "$val" -ne 0 ]; then
                if [ "$val" -gt 1099511627776 ]; then
                    readable="$(echo "scale=2; $val / 1099511627776" | bc) TiB"
                else
                    readable="$(echo "scale=2; $val / 1073741824" | bc) GiB"
                fi
            else
                readable="0"
            fi
            echo "$metric{$labels} = $readable ($val bytes)"
        done
    else
        echo "Disk space prom file not found. Running zpool list..."
        zpool list -o name,size,alloc,free,cap,health
    fi
' 2>/dev/null || echo "ERROR: Failed to retrieve disk space metrics."
echo "\`\`\`"
