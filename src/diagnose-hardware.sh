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

echo "#### 1. Proxmox VE Host Load, CPU Steal & Memory"
echo "\`\`\`"
ssh "${SSH_OPTS[@]}" "root@$PVE_HOST" "uptime"
echo ""
ssh "${SSH_OPTS[@]}" "root@$PVE_HOST" "free -h"
echo ""
echo "--- Host CPU Metrics (iostat / vmstat / mpstat / top) ---"
ssh "${SSH_OPTS[@]}" "root@$PVE_HOST" '
    if command -v mpstat >/dev/null 2>&1; then
        echo "mpstat (CPU steal and breakdown):"
        mpstat 1 2 | tail -n 2
    elif command -v vmstat >/dev/null 2>&1; then
        echo "vmstat (usr, sys, id, wa, st):"
        vmstat 1 2 | tail -n 1 | awk "{printf \"usr: %s%%, sys: %s%%, id: %s%%, wa: %s%%, st: %s%%\n\", \$13, \$14, \$15, \$16, \$17}"
    elif command -v iostat >/dev/null 2>&1; then
        echo "iostat CPU:"
        iostat -c 1 2 | tail -n 3
    else
        top -bn1 | grep "Cpu(s)" || true
    fi
' 2>/dev/null || echo "Could not capture CPU metrics."
echo "\`\`\`"
echo ""

echo "#### 2. ZFS ARC Stats & Host Swap Zvol"
echo "\`\`\`"
ssh "${SSH_OPTS[@]}" "root@$PVE_HOST" '
    if [ -f /proc/spl/kstat/zfs/arcstats ]; then
        python3 -c '\''
import sys

stats = {}
try:
    with open("/proc/spl/kstat/zfs/arcstats", "r") as f:
        for line in f:
            parts = line.split()
            if len(parts) >= 3:
                try:
                    stats[parts[0]] = int(parts[2], 0)
                except Exception:
                    pass
    size = stats.get("size", 0)
    c_max = stats.get("c_max", 0)
    hits = stats.get("hits", 0)
    misses = stats.get("misses", 0)
    total_access = hits + misses
    hit_rate = (hits / total_access * 100) if total_access > 0 else 0.0

    print(f"ARC Size: {size / (1024**3):.2f} GiB / Target Max: {c_max / (1024**3):.2f} GiB")
    print(f"ARC Hit Rate: {hit_rate:.2f}% (Hits: {hits}, Misses: {misses})")
except Exception as e:
    print(f"Error reading arcstats: {e}")
'\'' 2>/dev/null || cat /proc/spl/kstat/zfs/arcstats | grep -E "size|c_max|hits|misses" | head -10
    else
        echo "arcstats not found (/proc/spl/kstat/zfs/arcstats missing)."
    fi
    echo ""
    echo "Swap / Zvol status:"
    swapon --show 2>/dev/null || cat /proc/swaps
' 2>/dev/null || echo "Could not capture ZFS ARC / swap info."
echo "\`\`\`"
echo ""

echo "#### 3. ZFS Pools & Dataset Properties (docker-data, tsdb, db)"
echo "\`\`\`"
ssh "${SSH_OPTS[@]}" "root@$PVE_HOST" "zpool status -x"
echo ""
ssh "${SSH_OPTS[@]}" "root@$PVE_HOST" "zpool list"
echo ""
echo "--- Key Datasets Properties & Snapshots ---"
ssh "${SSH_OPTS[@]}" "root@$PVE_HOST" '
    zfs list -o name,recordsize,compression,compressratio,used,avail -r rpool 2>/dev/null | grep -E "NAME|docker-data|docker-tsdb|docker-db" || zfs list -o name,recordsize,compression,used,avail 2>/dev/null
    echo ""
    echo "Recent Snapshots for Key Datasets:"
    zfs list -t snapshot -o name,creation,used -s creation 2>/dev/null | grep -E "docker-data|docker-tsdb|docker-db" | tail -n 10 || echo "No key dataset snapshots found."
' 2>/dev/null || echo "Could not query dataset properties."
echo "\`\`\`"
echo ""

echo "#### 4. VirtIO-FS & D-State Task Detection"
echo "\`\`\`"
ssh "${SSH_OPTS[@]}" "root@$PVE_HOST" '
    d_tasks=$(ps aux | awk '\''$8 ~ /D/'\'' | grep -v "USER" || true)
    if [ -n "$d_tasks" ]; then
        echo "⚠️ WARNING: D-State (uninterruptible sleep / I/O wait) processes detected:"
        echo "$d_tasks"
    else
        echo "✅ No D-State hung tasks detected on host."
    fi
    echo ""
    echo "VirtIO-FS Daemons / QEMU vhost-user-fs:"
    ps aux | grep -E "virtiofsd|vhost-user-fs" | grep -v grep || echo "No virtiofsd standalone daemons running."
' 2>/dev/null || echo "Could not check D-state tasks."
echo "\`\`\`"
echo ""

echo "#### 5. Proxmox Running VMs and Resource Allocation vs Active Consumption"
echo "\`\`\`"
ssh "${SSH_OPTS[@]}" "root@$PVE_HOST" "export PATH=\$PATH:/usr/sbin:/sbin; qm list"
echo ""
ssh "${SSH_OPTS[@]}" "root@$PVE_HOST" '
    export PATH=$PATH:/usr/sbin:/sbin
    if command -v pvesh >/dev/null 2>&1; then
        echo "--- Active QEMU VM Resource Usage ---"
        pvesh get /nodes/localhost/qemu --output-format json-pretty 2>/dev/null | python3 -c '\''
import sys, json
try:
    vms = json.load(sys.stdin)
    print(f"{\"VMID\":<8} {\"NAME\":<26} {\"STATUS\":<10} {\"CPU%\":<8} {\"MEM (USED/MAX)\":<22}")
    for vm in sorted(vms, key=lambda x: int(x.get("vmid", 0))):
        vmid = str(vm.get("vmid", ""))
        name = str(vm.get("name", ""))
        status = str(vm.get("status", ""))
        cpu = f"{vm.get(\"cpu\", 0)*100:.1f}%"
        mem = vm.get("mem", 0) / (1024**3)
        maxmem = vm.get("maxmem", 0) / (1024**3)
        mem_str = f"{mem:.1f}G / {maxmem:.1f}G"
        print(f"{vmid:<8} {name:<26} {status:<10} {cpu:<8} {mem_str:<22}")
except Exception as e:
    print(f"Error parsing pvesh output: {e}")
'\'' 2>/dev/null || true
    fi
' 2>/dev/null || true
echo "\`\`\`"
echo ""

echo "#### 6. Disk Temperature / SMART warnings (HP DL360p Gen8)"
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
