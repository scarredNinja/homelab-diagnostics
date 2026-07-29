#!/usr/bin/env bash
# automation/diagnostics/diagnose-services.sh
# Diagnoses Docker Swarm services, service logs, node health, and Uptime Kuma monitor states.

set -euo pipefail

MGR_HOST="10.0.60.30"
SSH_KEY="$HOME/.ssh/homelab_ed25519"
SSH_OPTS=(-i "$SSH_KEY" -o BatchMode=yes -o StrictHostKeyChecking=accept-new -o ConnectTimeout=5)

echo "### 🐳 Services Diagnostic"
echo ""

# Check SSH connection
if ! ssh "${SSH_OPTS[@]}" "docker@$MGR_HOST" "echo OK" >/dev/null 2>&1; then
    echo "❌ ERROR: Cannot connect to Swarm Manager ($MGR_HOST) via SSH."
    echo "Check if the manager-01 VM is running or if the SSH key is authorized."
    exit 1
fi

# ─── Section 1: Swarm Node Health ─────────────────────────────────────────────
echo "#### 1. Swarm Node Health"
echo "Checking Docker Swarm node statuses..."
echo "\`\`\`"

NODE_OUTPUT=$(ssh "${SSH_OPTS[@]}" "docker@$MGR_HOST" \
    'docker node ls --format "{{.Hostname}}\t{{.Status}}\t{{.Availability}}\t{{.ManagerStatus}}"' 2>/dev/null \
    || echo "ERROR: Failed to query Swarm nodes")

echo "$NODE_OUTPUT" | while IFS=$'\t' read -r hostname status availability manager; do
    if [ "$status" = "Ready" ]; then
        echo "✅ [${status}] ${hostname} (Availability: ${availability}${manager:+, Manager: $manager})"
    else
        echo "❌ [${status}] ${hostname} (Availability: ${availability}${manager:+, Manager: $manager})"
    fi
done

echo "\`\`\`"
echo ""

# Machine-readable node block for compile_status.py
echo "=== NODES_START ==="
echo "$NODE_OUTPUT"
echo "=== NODES_END ==="
echo ""

# ─── Section 2: Docker Swarm Service Replica Status ───────────────────────────
echo "#### 2. Docker Swarm Service Replica Status"
echo "Checking running vs desired replicas..."
echo "\`\`\`"

SWARM_REPORT=$(ssh "${SSH_OPTS[@]}" "docker@$MGR_HOST" '
    SERVICES=$(timeout 15 docker service ls --format "table {{.Name}}\t{{.Replicas}}\t{{.Image}}" 2>&1)
    echo "$SERVICES"

    # Extract degraded services names
    DEGRADED=$(echo "$SERVICES" | grep -v "Error" | awk '\''NR>1 {
        split($2, rep, "/");
        if (rep[1] != rep[2]) {
            print $1
        }
    }'\'')

    if [ -n "$DEGRADED" ]; then
        echo "=== DEGRADED_START ==="
        for svc in $DEGRADED; do
            echo "Retrieving task states for service: $svc"
            echo "---PS---"
            timeout 10 docker service ps "$svc" --no-trunc | head -n 5 2>&1
            echo "---END---"
        done
    fi
    true
' || echo "ERROR: Failed to run service diagnostics.")

# Print the overall service list
echo "$SWARM_REPORT" | sed '/=== DEGRADED_START ===/,$d'
echo "\`\`\`"
echo ""

# Print degraded service details if they exist
if echo "$SWARM_REPORT" | grep -q "=== DEGRADED_START ==="; then
    echo "⚠️ WARNING: Degraded services detected!"
    echo "\`\`\`"
    echo "$SWARM_REPORT" | sed -n '/=== DEGRADED_START ===/,$p' | tail -n +2
    echo "\`\`\`"
else
    echo "✅ All Swarm services are running with desired replicas."
fi
echo ""

# ─── Section 3: Service Log Error Scan ────────────────────────────────────────
echo "#### 3. Service Log Error Scan (last 100 lines)"
echo "Scanning all service logs in parallel (Traefik first)..."
echo ""

# Scan Traefik services first to surface routing issues
echo "##### Traefik Logs"
echo "\`\`\`"
TRAEFIK_ERRORS=$(ssh "${SSH_OPTS[@]}" "docker@$MGR_HOST" '
    docker service ls --format "{{.Name}}" | grep "^traefik" | \
    xargs -I {} -P 10 sh -c '\''
        LOGS=$(timeout 3 docker service logs {} --tail 100 2>&1)
        ERRORS=$(echo "$LOGS" | grep -i -E " ERR | ERROR |exception|fatal|panic" | grep -v "duplicate" | head -n 5)
        if [ -n "$ERRORS" ]; then
            echo "=== {} ==="
            echo "$ERRORS"
        fi
    '\''
' 2>/dev/null || echo "Could not scan Traefik logs")

if [ -n "$TRAEFIK_ERRORS" ]; then
    echo "$TRAEFIK_ERRORS"
    echo "⚠️ Traefik log errors detected above."
else
    echo "✅ No errors found in Traefik service logs."
fi
echo "\`\`\`"
echo ""

# Scan all other services in parallel
echo "##### All Other Services"
echo "\`\`\`"
OTHER_ERRORS=$(ssh "${SSH_OPTS[@]}" "docker@$MGR_HOST" '
    docker service ls --format "{{.Name}}" | grep -v "^traefik" | \
    xargs -I {} -P 30 sh -c '\''
        LOGS=$(timeout 3 docker service logs {} --tail 100 2>&1)
        ERRORS=$(echo "$LOGS" | grep -i -E " ERR | ERROR |exception|fatal|panic" | grep -v "duplicate" | head -n 3)
        if [ -n "$ERRORS" ]; then
            echo "=== {} ==="
            echo "$ERRORS"
        fi
    '\''
' 2>/dev/null || echo "Could not scan service logs")

if [ -n "$OTHER_ERRORS" ]; then
    echo "$OTHER_ERRORS"
else
    echo "✅ No significant errors found in other service logs."
fi
echo "\`\`\`"
echo ""

# ─── Section 3b: Traefik Health Deep-Check ────────────────────────────────────
echo "#### 3b. Traefik Health Deep-Check"
echo "Checking Traefik Swarm provider, docker-proxy connectivity, and route load..."
echo "\`\`\`"

TRAEFIK_HEALTH=$(ssh "${SSH_OPTS[@]}" "docker@$MGR_HOST" '
set -uo pipefail

# ── 1. Get the DMZ node IP (where Traefik runs) ───────────────────────────────
DMZ_IP=$(docker node inspect traefik-dmz-01 --format "{{.Status.Addr}}" 2>/dev/null || echo "")
if [ -z "$DMZ_IP" ]; then
    echo "❌ TRAEFIK_CHECK: Could not locate traefik-dmz-01 node — skipping deep-check."
    echo "=== TRAEFIK_STATUS === UNKNOWN"
    exit 0
fi

# ── 2. Check backend overlay network exists and has both containers ───────────
BACKEND_NET=$(docker network inspect traefik_traefik-backend --format "{{.Name}}" 2>/dev/null || echo "")
if [ -z "$BACKEND_NET" ]; then
    echo "❌ TRAEFIK_BACKEND_NET: traefik_traefik-backend overlay network NOT FOUND."
    echo "=== TRAEFIK_BACKEND_NET_MISSING ==="
else
    PROXY_ATTACHED=$(docker network inspect traefik_traefik-backend \
        --format "{{range .Containers}}{{.Name}} {{end}}" 2>/dev/null \
        | grep -c "traefik_docker-proxy" || echo "0")
    TRAEFIK_ATTACHED=$(docker network inspect traefik_traefik-backend \
        --format "{{range .Containers}}{{.Name}} {{end}}" 2>/dev/null \
        | grep -c "traefik_traefik" || echo "0")
    if [ "$PROXY_ATTACHED" -gt 0 ] && [ "$TRAEFIK_ATTACHED" -gt 0 ]; then
        echo "✅ TRAEFIK_BACKEND_NET: traefik_traefik-backend exists, both services attached."
    else
        echo "❌ TRAEFIK_BACKEND_NET: Network exists but missing container attachments (proxy=${PROXY_ATTACHED}, traefik=${TRAEFIK_ATTACHED})."
        echo "=== TRAEFIK_BACKEND_NET_MISSING ==="
    fi
fi

# ── 3. Check for docker-proxy DNS failure in recent Traefik logs ──────────────
PROXY_DNS_ERR=$(docker service logs traefik_traefik --tail 80 2>/dev/null \
    | grep -c "no such host\|lookup traefik_docker-proxy" || echo "0")
if [ "$PROXY_DNS_ERR" -gt 0 ]; then
    echo "❌ TRAEFIK_PROXY_DNS: docker-proxy DNS resolution failing (${PROXY_DNS_ERR} recent errors)."
    echo "   Recent error sample:"
    docker service logs traefik_traefik --tail 80 2>/dev/null \
        | grep "no such host\|lookup traefik_docker-proxy" | tail -2 | sed "s/^/   /"
    echo "=== TRAEFIK_PROXY_DOWN ==="
else
    echo "✅ TRAEFIK_PROXY_DNS: No docker-proxy DNS errors in recent logs."
fi

# ── 4. Query Traefik API for loaded swarm routes (exec into container) ─────────
# Traefik api.insecure=false means API is only on the internal port inside the
# container — we exec in and count routes from the swarm provider.
TRAEFIK_CTR=$(docker ps --filter name=traefik_traefik --filter status=running \
    --format "{{.ID}}" 2>/dev/null | head -1)

if [ -z "$TRAEFIK_CTR" ]; then
    echo "⚠️  TRAEFIK_API: No running Traefik container found on this manager node."
    echo "   (Traefik runs on traefik-dmz-01 worker — checking via SSH)"
    SWARM_ROUTE_COUNT=$(ssh -o BatchMode=yes -o StrictHostKeyChecking=accept-new \
        -o ConnectTimeout=5 docker@"$DMZ_IP" \
        "CTR=\$(docker ps --filter name=traefik_traefik --filter status=running --format \"{{.ID}}\" | head -1); \
         [ -n \"\$CTR\" ] && docker exec \"\$CTR\" wget -qO- http://localhost:8080/api/http/routers 2>/dev/null \
             | python3 -c \"import sys,json; d=json.load(sys.stdin); print(sum(1 for r in d if r.get(\\\"provider\\\",\\\"\\\").startswith(\\\"swarm\\\")))\" 2>/dev/null \
             || echo \"API_UNAVAILABLE\"" 2>/dev/null || echo "SSH_FAILED")
else
    SWARM_ROUTE_COUNT=$(docker exec "$TRAEFIK_CTR" \
        wget -qO- http://localhost:8080/api/http/routers 2>/dev/null \
        | python3 -c "import sys,json; d=json.load(sys.stdin); print(sum(1 for r in d if r.get(\"provider\",\"\").startswith(\"swarm\")))" 2>/dev/null \
        || echo "API_UNAVAILABLE")
fi

case "$SWARM_ROUTE_COUNT" in
    API_UNAVAILABLE|SSH_FAILED)
        echo "⚠️  TRAEFIK_ROUTES: Could not query Traefik API (${SWARM_ROUTE_COUNT}) — API not exposed externally (expected)."
        ;;
    0)
        # Count services that should have routes
        ENABLED_SVCS=$(docker service ls --format "{{.Name}}" 2>/dev/null | while read -r svc; do
            en=$(docker service inspect "$svc" --format "{{index .Spec.Labels \"traefik.enable\"}}" 2>/dev/null)
            [ "$en" = "true" ] && echo "$svc"
        done | wc -l)
        if [ "$ENABLED_SVCS" -gt 0 ]; then
            echo "❌ TRAEFIK_ROUTES: 0 swarm routes loaded despite ${ENABLED_SVCS} services with traefik.enable=true."
            echo "=== TRAEFIK_NO_SWARM_ROUTES ==="
        else
            echo "⚠️  TRAEFIK_ROUTES: 0 swarm routes — no services with traefik.enable=true found."
        fi
        ;;
    *)
        echo "✅ TRAEFIK_ROUTES: ${SWARM_ROUTE_COUNT} swarm-provider route(s) loaded."
        ;;
esac

# ── 5. Port sanity check on DMZ node ─────────────────────────────────────────
for port in 80 443; do
    if timeout 3 bash -c "echo >/dev/tcp/${DMZ_IP}/${port}" 2>/dev/null; then
        echo "✅ TRAEFIK_PORT_${port}: Accepting connections on ${DMZ_IP}:${port}."
    else
        echo "❌ TRAEFIK_PORT_${port}: NOT responding on ${DMZ_IP}:${port}."
    fi
done
' 2>/dev/null || echo "❌ TRAEFIK_CHECK: SSH to Swarm manager failed during Traefik deep-check.")

echo "$TRAEFIK_HEALTH"
echo "\`\`\`"
echo ""

# ─── Section 4: Active Alertmanager Alerts ─────────────────────────────────────
echo "#### 4. Active Alertmanager Alerts"
echo "Querying Prometheus Alertmanager..."
echo "\`\`\`"
ALERTS=$(ssh "${SSH_OPTS[@]}" "docker@$MGR_HOST" '
    if curl --silent --max-time 3 http://tasks.monitoring_alertmanager:9093/api/v2/alerts >/dev/null 2>&1; then
        curl --silent http://tasks.monitoring_alertmanager:9093/api/v2/alerts | jq -r ".[] | \"[\(.labels.severity | upcase)] \(.labels.alertname): \(.annotations.description // .annotations.summary // \"No description\")\""
    else
        echo "Could not reach Alertmanager internal service (tasks.monitoring_alertmanager:9093)."
    fi
' 2>/dev/null || echo "ERROR: Failed to run alert query.")

if [ -z "$ALERTS" ]; then
    echo "No active alerts in Alertmanager."
else
    echo "$ALERTS"
fi
echo "\`\`\`"
echo ""

# ─── Section 5: Uptime Kuma Monitor Statuses ──────────────────────────────────
echo "#### 5. Uptime Kuma Monitor Statuses"
echo "Querying Uptime Kuma API via overlay network..."
echo "\`\`\`"

# Use a temporary container on the arr overlay network (uptime-kuma is also on arr_arr_default)
# to query the Uptime Kuma API. Falls back gracefully if unreachable.
KUMA_STATUS=$(ssh "${SSH_OPTS[@]}" "docker@$MGR_HOST" "
python3 - <<'PYEOF'
import urllib.request
import json
import sys

base_url = 'http://uptime-kuma:3001'
slug = 'homelab'

def fetch(url):
    try:
        req = urllib.request.urlopen(url, timeout=5)
        return json.loads(req.read())
    except Exception as e:
        return None

config = fetch(f'{base_url}/api/status-page/{slug}')
heartbeats = fetch(f'{base_url}/api/status-page/heartbeat/{slug}')

if config is None or heartbeats is None:
    print('❌ Uptime Kuma API is unreachable (service may be down or starting up)')
    sys.exit(0)

# Build monitor ID -> name map
monitors = {}
for group in config.get('publicGroupList', []):
    for m in group.get('monitorList', []):
        monitors[str(m['id'])] = m.get('name', f\"Monitor {m['id']}\")

hb_list = heartbeats.get('heartbeatList', {})
down_count = 0
for mid, beats in hb_list.items():
    name = monitors.get(mid, f'Monitor {mid}')
    latest = beats[-1] if beats else None
    if latest is None:
        print(f'⚠️  {name}: No heartbeat data')
        continue
    status = latest.get('status', 0)
    msg = latest.get('msg', '')
    if status == 1:
        print(f'✅ {name}: UP')
    else:
        print(f'❌ {name}: DOWN ({msg})')
        down_count += 1

if down_count == 0:
    print(f'All {len(hb_list)} monitors UP')
else:
    print(f'WARNING: {down_count}/{len(hb_list)} monitors DOWN')
PYEOF
" 2>/dev/null || echo "❌ Could not query Uptime Kuma (overlay network unreachable from manager)")

echo "$KUMA_STATUS"
echo "\`\`\`"
echo ""

echo "#### 4. Container-Level Services (Compose)"
echo "Checking compose containers on worker-mediamanagement-01..."
echo "\`\`\`"
COMPOSE_HOST="10.0.50.51"
COMPOSE_REPORT=$(ssh "${SSH_OPTS[@]}" "docker@$COMPOSE_HOST" '
    containers=("gluetun" "compose-vpn-transmission-1")
    for c in "${containers[@]}"; do
        status=$(docker inspect --format "{{.State.Status}}" "$c" 2>/dev/null || echo "Missing")
        health=""
        if [ "$status" = "running" ]; then
            health_status=$(docker inspect --format "{{.State.Health.Status}}" "$c" 2>/dev/null || echo "none")
            if [ -n "$health_status" ] && [ "$health_status" != "none" ]; then
                health=" ($health_status)"
            fi
            echo "✅ $c: running$health"
        else
            echo "❌ $c: $status"
        fi
    done
' 2>/dev/null || echo "ERROR: Failed to query compose containers.")
echo "$COMPOSE_REPORT"
echo "\`\`\`"
echo ""
