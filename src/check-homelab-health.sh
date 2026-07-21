#!/usr/bin/env bash
# automation/diagnostics/check-homelab-health.sh
# Orchestrator script for homelab monitoring and auto-remediation.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REMEDIATE=false

# Parse arguments
while [[ $# -gt 0 ]]; do
    case "$1" in
        --remediate)
            REMEDIATE=true
            shift
            ;;
        *)
            echo "Unknown option: $1" >&2
            echo "Usage: $0 [--remediate]" >&2
            exit 1
            ;;
    esac
done

# Ensure SSH sockets directory exists for connection multiplexing
mkdir -p "$HOME/.ssh/sockets"

# Load local environment configuration if present (e.g. UPTIME_KUMA_PUSH_URL)
CONFIG_ENV="$(dirname "$SCRIPT_DIR")/config/config.env"
if [[ ! -f "$CONFIG_ENV" ]]; then
    CONFIG_ENV="$SCRIPT_DIR/config.env"
fi
if [[ -f "$CONFIG_ENV" ]]; then
    # shellcheck source=/dev/null
    source "$CONFIG_ENV"
    export UPTIME_KUMA_PUSH_URL
    export OLLAMA_URL
    export OLLAMA_MODEL
    export STATUS_DATA_DIR
fi

# Set default STATUS_DATA_DIR if not set
STATUS_DATA_DIR="${STATUS_DATA_DIR:-$HOME/status-dashboard-data}"

# Resolve host.docker.internal gateway inside WSL if it doesn't resolve or connect automatically
if [ -n "${OLLAMA_URL:-}" ] && [[ "$OLLAMA_URL" == *"host.docker.internal"* ]]; then
    if ! timeout 1 bash -c "cat < /dev/null > /dev/tcp/host.docker.internal/11434" 2>/dev/null; then
        GW_IP=$(ip route | grep default | awk '{print $3}' || true)
        if [ -n "$GW_IP" ]; then
            OLLAMA_URL=${OLLAMA_URL/host.docker.internal/$GW_IP}
        fi
    fi
fi



PVE_HOST="10.0.90.50"
SSH_KEY="$HOME/.ssh/homelab_ed25519"
SSH_OPTS=(
    -i "$SSH_KEY"
    -o BatchMode=yes
    -o StrictHostKeyChecking=accept-new
    -o ConnectTimeout=5
    -o ControlMaster=auto
    -o ControlPath="$HOME/.ssh/sockets/%r@%h:%p"
    -o ControlPersist=60s
)

# Temporary files to store diagnostic logs
BACKUP_LOG=$(mktemp)
SERVICES_LOG=$(mktemp)
HARDWARE_LOG=$(mktemp)
NETWORK_LOG=$(mktemp)

cleanup() {
    rm -f "$BACKUP_LOG" "$SERVICES_LOG" "$HARDWARE_LOG" "$NETWORK_LOG"
}
trap cleanup EXIT

echo "=== Running Homelab Diagnostics (Parallel) ==="

# Execute check scripts in parallel for high performance
bash "$SCRIPT_DIR/diagnose-backups.sh" > "$BACKUP_LOG" 2>&1 &
bash "$SCRIPT_DIR/diagnose-services.sh" > "$SERVICES_LOG" 2>&1 &
bash "$SCRIPT_DIR/diagnose-hardware.sh" > "$HARDWARE_LOG" 2>&1 &
bash "$SCRIPT_DIR/diagnose-network.sh" > "$NETWORK_LOG" 2>&1 &

# Wait for all background diagnostic gathers to complete
wait
echo "All domain diagnostic gathers complete."

# Determine paths
STATUS_JSON="$STATUS_DATA_DIR/status.json"
mkdir -p "$STATUS_DATA_DIR"

# Compile to structured JSON status.json
echo "Compiling structured status JSON..."
python3 "$SCRIPT_DIR/compile_status.py" "$BACKUP_LOG" "$SERVICES_LOG" "$HARDWARE_LOG" "$NETWORK_LOG" "$STATUS_JSON"

# Retrieve webhook URLs from Proxmox VE via SSH
echo "Retrieving Discord Alert Webhooks..."
set +e
DISCORD_ALERTS_WEBHOOK=$(ssh "${SSH_OPTS[@]}" "root@$PVE_HOST" 'cat /etc/alertmanager/discord-webhook 2>/dev/null' || echo -n "")
DISCORD_BACKUPS_WEBHOOK=$(ssh "${SSH_OPTS[@]}" "root@$PVE_HOST" '[[ -f /etc/backup-alerts.conf ]] && source /etc/backup-alerts.conf && echo -n "$DISCORD_WEBHOOK_URL"' 2>/dev/null || echo -n "")
set -e

# Execute LLM Diagnoser
echo "Executing LLM Diagnose & Action runner..."
REMEDIATE_FLAG=""
if [ "$REMEDIATE" = true ]; then
    REMEDIATE_FLAG="--remediate"
fi

python3 "$SCRIPT_DIR/llm-diagnose.py" \
    --status "$STATUS_JSON" \
    $REMEDIATE_FLAG \
    --alerts-webhook "$DISCORD_ALERTS_WEBHOOK" \
    --backups-webhook "$DISCORD_BACKUPS_WEBHOOK"

# If we ran remediations, wait and perform a verification check
if [ "$REMEDIATE" = true ]; then
    echo "Waiting 10 seconds for service updates to propagate..."
    sleep 10
    echo "=== Running Post-Remediation Verification ==="
    # Run diagnose-services.sh again to check current status
    VERIFY_LOG=$(mktemp)
    bash "$SCRIPT_DIR/diagnose-services.sh" > "$VERIFY_LOG" 2>&1
    
    # Parse the output and print broken services
    DEGRADED=$(grep -v "Error" "$VERIFY_LOG" | awk '
        $2 ~ /^[0-9]+\/[0-9]+$/ {
            split($2, rep, "/");
            if (rep[1] != rep[2]) {
                print "  - Swarm Service: " $1 " (" $2 " replicas)"
            }
        }
    ' || true)
    
    COMPOSE_DEGRADED=$(grep -E '❌ (gluetun|compose-vpn-transmission-1)' "$VERIFY_LOG" || true)
    
    if [ -z "$DEGRADED" ] && [ -z "$COMPOSE_DEGRADED" ]; then
        echo "✅ Verification complete. All services are running with desired replicas!"
    else
        echo "⚠️ WARNING: The following services may still be degraded or starting up:"
        if [ -n "$DEGRADED" ]; then
            echo "$DEGRADED"
        fi
        if [ -n "$COMPOSE_DEGRADED" ]; then
            echo "  - Compose Container: $COMPOSE_DEGRADED"
        fi
    fi
    rm -f "$VERIFY_LOG"
fi


# Sync files to Docker Swarm manager-01 for Nginx dashboard
echo "Dashboard files updated locally. Syncthing will synchronize them to the server."

echo "=== Health check completed ==="
