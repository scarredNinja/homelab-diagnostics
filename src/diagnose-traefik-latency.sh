#!/usr/bin/env bash
# automation/diagnostics/diagnose-traefik-latency.sh
#
# Diagnoses Traefik slow response times and timeouts across five root-cause
# categories. Optimised for Docker Swarm service backends (highest priority),
# then file-provider static-IP and hostname-based routes.
#
# Checks (priority order for Swarm-heavy setups):
#   1. Swarm VIP Staleness          — stale/non-routable VIP causes 30 s hangs
#   2. IPv6 Dual-Stack Timeout      — missing IPv6 routing stalls ~5–10 s
#   3. DNS Resolution & Split-Horizon — Pi-hole hairpin NAT, gluetun hostname
#   4. TCP Keep-Alive / Stale Conns — Go idle timeout 90 s default, no config set
#   5. Middleware & TLS Overhead    — HTTPS backend re-handshake on every request
#
# Output: Markdown-formatted report (matches diagnose-*.sh suite conventions).
#
# ── HOW TO RUN ─────────────────────────────────────────────────────────────────
# Two supported run environments. Set DMZ_DIRECT=true|false in the config
# block below to match where you are running from.
#
# MODE A — FROM PROXMOX HOST (recommended, simpler)
#   Proxmox (10.0.90.50) has direct L3 routes to all VLANs via pfSense.
#   No agent forwarding or jump hosts required.
#   Set: DMZ_DIRECT="true"
#   Requirements:
#     - homelab_ed25519 key (or a Proxmox-local key) authorised on:
#         docker@10.0.60.30 (manager)  AND  docker@<traefik-dmz-01-ip>
#   Run:
#     bash automation/diagnostics/diagnose-traefik-latency.sh \
#       2>&1 | tee /tmp/traefik-latency-$(date +%Y%m%d-%H%M%S).log
#
# MODE B — FROM WORKSTATION (Pop!_OS)
#   Uses SSH agent forwarding so the manager can reach the DMZ node using
#   your workstation key — no keys need to be stored on the manager.
#   Set: DMZ_DIRECT="false"
#   Requirements:
#     - ssh-agent running with homelab key loaded:
#         eval "$(ssh-agent -s)" && ssh-add ~/.ssh/homelab_ed25519
#     - Key authorised on docker@<traefik-dmz-01-ip>:
#         ssh-copy-id -i ~/.ssh/homelab_ed25519 docker@<dmz-ip>
#   Run:
#     bash automation/diagnostics/diagnose-traefik-latency.sh \
#       2>&1 | tee /tmp/traefik-latency-$(date +%Y%m%d-%H%M%S).log
#
# ── DMZ SSH STRATEGY ───────────────────────────────────────────────────────────
# DMZ_DIRECT=true  (Proxmox): SSH runs directly from this host to dmz-01.
# DMZ_DIRECT=false (workstation): Script hops workstation → manager (-A) → dmz.
#   Script payloads are base64-encoded to survive the nested SSH quoting.

set -euo pipefail

# ── Configuration ──────────────────────────────────────────────────────────────
MGR_HOST="10.0.60.30"
SSH_KEY="$HOME/.ssh/homelab_ed25519"
SSH_OPTS=(-i "$SSH_KEY" -o BatchMode=yes -o StrictHostKeyChecking=accept-new -o ConnectTimeout=5)

# ── Run-mode: set to match where you are running this script ─────────────────
#
#  true  — Proxmox (or any host with direct L3 access to all VLANs)
#           SSH goes directly: this host → manager, this host → dmz-01
#           No ssh-agent or jump hosts required.
#
#  false — Workstation (Pop!_OS or similar, no direct DMZ route)
#           SSH goes: workstation → manager (-A) → dmz-01 (forwarded agent)
#           Requires ssh-agent with homelab key loaded.
#
DMZ_DIRECT="${DMZ_DIRECT:-true}"

# Internal DNS: Pi-hole should resolve *.home.purvishome.com → Traefik's LAN IP.
# This is the IP your workstation/LAN clients use to reach Traefik on port 443.
# Adjust if your DMZ node has a different LAN-facing address.
TRAEFIK_LAN_IP="10.0.60.40"
PIHOLE_PRIMARY="10.0.60.20"
PIHOLE_SECONDARY="10.0.60.21"

# Swarm service names to probe in the VIP DNS check (stack_service format)
SWARM_STACK_SVCS=(
  "monitoring_grafana"
  "monitoring_prometheus"
  "controller_unifi"
  "homepage_homepage"
  "portainer_portainer"
  "arr_radarr"
  "arr_sonarr"
)

# ── Helpers ────────────────────────────────────────────────────────────────────

# Run a bash heredoc on the Traefik DMZ node.
#
# DMZ_DIRECT=true  (Proxmox): SSH goes directly from this host to dmz-01.
# DMZ_DIRECT=false (workstation): payload tunnelled via manager using agent
#   forwarding (workstation → manager -A → dmz-01).
#
# Script content is base64-encoded before passing to avoid quoting issues
# across nested SSH calls. Base64 alphabet has no shell special characters.
#
# Usage:
#   result=$(dmz_bash_run <<'SCRIPT'
#     echo "hello from dmz"
#   SCRIPT)
dmz_bash_run() {
  local script encoded
  script=$(cat)  # consume the heredoc from stdin
  encoded=$(printf '%s' "$script" | base64 -w0)

  if [[ "$DMZ_DIRECT" == "true" ]]; then
    # Direct path (Proxmox): decode and pipe to bash on the DMZ node
    printf '%s' "$encoded" | base64 -d | \
      ssh "${SSH_OPTS[@]}" "docker@${DMZ_IP}" bash -s
  else
    # Agent-forwarding tunnel (workstation → manager → dmz)
    ssh -A "${SSH_OPTS[@]}" "docker@${MGR_HOST}" \
      "printf '%s' '${encoded}' | base64 -d | \
      ssh -o BatchMode=yes -o StrictHostKeyChecking=accept-new -o ConnectTimeout=5 \
      docker@${DMZ_IP} bash -s"
  fi
}

# Print a fenced-code-block section header
print_section() { echo ""; echo "\`\`\`"; }

# Close a fenced-code block
end_section() { echo "\`\`\`"; echo ""; }

# ── Header ─────────────────────────────────────────────────────────────────────
echo "### 🔍 Traefik Latency Diagnostic"
echo "Timestamp: $(date -u '+%Y-%m-%dT%H:%M:%SZ')"
echo "Manager  : $MGR_HOST"
echo "Run mode : $([ "$DMZ_DIRECT" = true ] && echo 'direct (Proxmox)' || echo 'agent-forward (workstation)')"
echo ""

# ── Pre-flight: SSH agent (workstation mode only) ─────────────────────────────
AGENT_OK=false
if [[ "$DMZ_DIRECT" == "false" ]]; then
  if [[ -z "${SSH_AUTH_SOCK:-}" ]]; then
    echo "⚠️  SSH_AUTH_SOCK not set — ssh-agent is not running."
    echo "   In-container (DMZ) checks will be skipped. To fix:"
    echo "     eval \"\$(ssh-agent -s)\" && ssh-add $SSH_KEY"
  else
    KEY_FP=$(ssh-keygen -l -f "${SSH_KEY}.pub" 2>/dev/null | awk '{print $2}' || true)
    if [[ -n "$KEY_FP" ]] && ssh-add -l 2>/dev/null | grep -qF "$KEY_FP"; then
      echo "✅ SSH agent OK — homelab key loaded ($KEY_FP)"
      AGENT_OK=true
    else
      echo "⚠️  SSH agent running but homelab key not loaded. Run: ssh-add $SSH_KEY"
      AGENT_OK=true  # still attempt; -A may forward other valid identities
    fi
  fi
else
  # Proxmox (direct) mode — no agent forwarding needed
  AGENT_OK=true
fi

# ── Pre-flight: SSH to manager ────────────────────────────────────────────────
if ! ssh "${SSH_OPTS[@]}" "docker@$MGR_HOST" "echo OK" >/dev/null 2>&1; then
  echo "❌ FATAL: Cannot SSH to Swarm manager ($MGR_HOST)."
  echo "   Check that $SSH_KEY is authorised on docker@$MGR_HOST."
  exit 1
fi
echo "✅ SSH → Swarm manager ($MGR_HOST) OK"

# ── Resolve traefik-dmz-01 IP from Swarm ──────────────────────────────────────
DMZ_IP=$(ssh "${SSH_OPTS[@]}" "docker@$MGR_HOST" \
  'docker node inspect traefik-dmz-01 --format "{{.Status.Addr}}" 2>/dev/null || echo ""')

if [[ -z "$DMZ_IP" ]]; then
  echo "❌ FATAL: Cannot resolve traefik-dmz-01 node IP from Swarm manager."
  echo "   Verify the node is online: docker node ls"
  exit 1
fi
echo "✅ traefik-dmz-01 IP resolved: $DMZ_IP"

# ── Pre-flight: DMZ node reachability ───────────────────────────────────────────
DMZ_REACHABLE=false
set +e
if [[ "$DMZ_DIRECT" == "true" ]]; then
  # Proxmox: direct SSH from this host to traefik-dmz-01
  DMZ_TEST=$(ssh "${SSH_OPTS[@]}" "docker@${DMZ_IP}" "echo OK" 2>&1)
  DMZ_EXIT=$?
  MODE_LABEL="direct"
else
  # Workstation: manager uses agent-forwarded key to reach DMZ node
  DMZ_TEST=$(ssh -A "${SSH_OPTS[@]}" "docker@${MGR_HOST}" \
    "ssh -o BatchMode=yes -o StrictHostKeyChecking=accept-new -o ConnectTimeout=5 \
    docker@${DMZ_IP} echo OK" 2>&1)
  DMZ_EXIT=$?
  MODE_LABEL="via manager (agent forward)"
fi
set -e

if [[ $DMZ_EXIT -eq 0 && "$DMZ_TEST" == *"OK"* ]]; then
  echo "✅ SSH → traefik-dmz-01 ($DMZ_IP) $MODE_LABEL OK"
  DMZ_REACHABLE=true
else
  echo ""
  echo "⚠️  Cannot reach traefik-dmz-01 ($DMZ_IP) $MODE_LABEL."
  echo "   In-container checks (1b, 2a, 3a, 3b, 4a) will be skipped."
  if [[ "$DMZ_DIRECT" == "true" ]]; then
    echo "   Fix: add the public key in $SSH_KEY.pub to"
    echo "        /home/docker/.ssh/authorized_keys on traefik-dmz-01, then re-run."
    echo "   Quick: ssh-copy-id -i $SSH_KEY docker@$DMZ_IP"
  else
    echo "   Fix: load key in agent (ssh-add $SSH_KEY) and ensure"
    echo "        the public key is authorised on docker@$DMZ_IP."
  fi
fi
echo ""

# ══════════════════════════════════════════════════════════════════════════════
# CHECK 1 — Swarm VIP Staleness  [HIGHEST PRIORITY for Swarm services]
# ══════════════════════════════════════════════════════════════════════════════
echo "---"
echo "#### 🔴 Check 1 — Swarm VIP Staleness (Highest Priority)"
echo ""
echo "Docker Swarm services use a VIP (Virtual IP) for load-balancing by default."
echo "After a container restart or node failure, the VIP can become stale while the"
echo "Swarm control plane propagates the change. Traefik may pick this stale VIP,"
echo "causing requests to hang for ~30 s until the TCP connection times out."
echo ""
echo "**Fix (if confirmed):** Prefix Swarm service names with \`tasks.\` in Traefik labels"
echo "to bypass the VIP and route directly to task IPs, or set \`endpoint_mode: dnsrr\`"
echo "on the affected services."
echo ""

echo "##### 1a. Services with traefik.enable=true — endpoint mode and VIP"
print_section

# shellcheck disable=SC2087
ssh "${SSH_OPTS[@]}" "docker@$MGR_HOST" 'bash -s' <<'REMOTE_VIP'
set -uo pipefail

ENABLED_SVCS=$(docker service ls --format "{{.Name}}" | while read -r svc; do
  en=$(docker service inspect "$svc" \
    --format '{{index .Spec.Labels "traefik.enable"}}' 2>/dev/null || echo "")
  [ "$en" = "true" ] && echo "$svc"
done)

if [ -z "$ENABLED_SVCS" ]; then
  echo "⚠️  No services found with traefik.enable=true"
  exit 0
fi

ANY_VIP_ISSUE=false
printf "%-42s %-10s %-16s %s\n" "SERVICE" "MODE" "VIP" "REPLICAS (run/desired)"

for svc in $ENABLED_SVCS; do
  VIP=$(docker service inspect "$svc" \
    --format '{{range .Endpoint.VirtualIPs}}{{.Addr}}{{end}}' 2>/dev/null \
    | head -1 | cut -d/ -f1)
  DESIRED=$(docker service inspect "$svc" \
    --format '{{.Spec.Mode.Replicated.Replicas}}' 2>/dev/null || echo "?")
  RUNNING=$(docker service ps "$svc" \
    --filter desired-state=running \
    --format '{{.CurrentState}}' 2>/dev/null \
    | grep -c "Running" || true)
  EP_MODE=$(docker service inspect "$svc" \
    --format '{{.Spec.EndpointSpec.Mode}}' 2>/dev/null || echo "vip")
  EP_MODE="${EP_MODE:-vip}"

  FLAG=""
  if [ "$RUNNING" -lt "${DESIRED:-1}" ] 2>/dev/null; then
    FLAG=" ⚠️  DEGRADED"
    ANY_VIP_ISSUE=true
  fi
  printf "%-42s %-10s %-16s %s/%s%s\n" \
    "$svc" "$EP_MODE" "${VIP:-none}" "$RUNNING" "${DESIRED:-?}" "$FLAG"
done

echo ""
echo "VIP endpoint mode = requests always hit VIP first. Under load, a stale VIP"
echo "silently drops connections until Swarm GC cleans it (can take 30–90 s)."
echo "Services in 'dnsrr' mode bypass VIP entirely — preferred for Traefik backends."
if "$ANY_VIP_ISSUE"; then
  echo "⚠️  One or more services have fewer running replicas than desired — stale VIP likely."
fi
REMOTE_VIP

end_section

echo "##### 1b. VIP vs tasks.* DNS resolution from inside Traefik container"
print_section

if [[ "$DMZ_REACHABLE" == "true" ]]; then
  # Expand the array locally before base64 encoding — the heredoc is NOT quoted
  # so local variables are substituted before the script is sent to the DMZ node.
  SVC_LIST="${SWARM_STACK_SVCS[*]}"
  dmz_bash_run <<REMOTE_CTR_DNS
TRAEFIK_CTR=\$(docker ps --filter name=traefik_traefik --filter status=running \
  --format "{{.ID}}" | head -1)

if [ -z "\$TRAEFIK_CTR" ]; then
  echo "❌ No running Traefik container found on traefik-dmz-01."
  exit 0
fi
echo "Traefik container: \$TRAEFIK_CTR"
echo ""
printf "%-36s %-22s %-22s %s\\n" "SERVICE" "VIP nslookup" "tasks.* nslookup" "MATCH?"

for svc in ${SVC_LIST}; do
  VIP_RES=\$(docker exec "\$TRAEFIK_CTR" \
    sh -c "nslookup \$svc 2>&1 | awk '/^Address/ && !/127/ {print \\\$3}' | head -1" \
    2>/dev/null || echo "ERR")
  TASKS_RES=\$(docker exec "\$TRAEFIK_CTR" \
    sh -c "nslookup tasks.\$svc 2>&1 | awk '/^Address/ && !/127/ {print \\\$3}' | head -1" \
    2>/dev/null || echo "ERR")

  if [ "\$VIP_RES" = "ERR" ] && [ "\$TASKS_RES" = "ERR" ]; then
    MATCH="(service not found)"
  elif [ "\$VIP_RES" = "\$TASKS_RES" ]; then
    MATCH="OK same"
  else
    MATCH="DIFFER - VIP may be stale"
  fi
  printf "%-36s %-22s %-22s %s\\n" "\$svc" "\${VIP_RES:-N/A}" "\${TASKS_RES:-N/A}" "\$MATCH"
done
REMOTE_CTR_DNS

else
  echo "Skipped - DMZ node not reachable via SSH."
fi

end_section

# ══════════════════════════════════════════════════════════════════════════════
# CHECK 2 — IPv6 Dual-Stack Timeout
# ══════════════════════════════════════════════════════════════════════════════
echo "---"
echo "#### 🟠 Check 2 — IPv6 Dual-Stack Timeout"
echo ""
echo "If Pi-hole returns AAAA records for your internal domains and IPv6 routing"
echo "is absent in the DMZ VLAN, Traefik stalls ~5–10 s before falling back to IPv4."
echo ""

echo "##### 2a. IPv6 status on traefik-dmz-01 host + Docker daemon"
print_section

if [[ "$DMZ_REACHABLE" == "true" ]]; then
  dmz_bash_run <<'REMOTE_IPV6'
if [ -f /proc/net/if_inet6 ] && [ -s /proc/net/if_inet6 ]; then
  echo "WARNING: IPv6 interfaces active on traefik-dmz-01:"
  column -t /proc/net/if_inet6 2>/dev/null || cat /proc/net/if_inet6
  echo ""
  echo "Action: if IPv6 routing to backend VLANs is not configured, disable IPv6:"
  echo "  echo 'net.ipv6.conf.all.disable_ipv6=1' | sudo tee /etc/sysctl.d/99-no-ipv6.conf"
  echo "  sudo sysctl --system"
else
  echo "OK: No active IPv6 interfaces on traefik-dmz-01."
fi
echo ""
if docker info 2>/dev/null | grep -q "IPv6: true"; then
  echo "WARNING: Docker daemon has IPv6 enabled. Check /etc/docker/daemon.json."
else
  echo "OK: Docker daemon IPv6 is disabled."
fi
REMOTE_IPV6

else
  echo "Skipped - DMZ node not reachable via SSH."
fi

end_section

echo "##### 2b. IPv4 vs IPv6 curl timing to Traefik LAN IP ($TRAEFIK_LAN_IP)"
print_section
echo "Connecting via Traefik LAN IP with SNI header for a Swarm-backed domain."
echo ""

set +e
echo -n "IPv4 (-4): "
curl -4 -sk --max-time 8 -o /dev/null \
  -w "HTTP %{http_code}  connect=%{time_connect}s  total=%{time_total}s\n" \
  "https://$TRAEFIK_LAN_IP" -H "Host: portainer.home.purvishome.com" 2>/dev/null \
  || echo "FAILED/TIMEOUT"

echo -n "IPv6 (-6): "
curl -6 -sk --max-time 5 -o /dev/null \
  -w "HTTP %{http_code}  connect=%{time_connect}s  total=%{time_total}s\n" \
  "https://[$TRAEFIK_LAN_IP]" -H "Host: portainer.home.purvishome.com" 2>/dev/null \
  || echo "FAILED/TIMEOUT (no IPv6 route — this is expected if IPv6 is disabled)"
set -e

echo ""
echo "Interpretation: if IPv4 responds instantly and IPv6 times out → dual-stack culprit."
end_section

# ══════════════════════════════════════════════════════════════════════════════
# CHECK 3 — DNS Resolution & Split-Horizon
# ══════════════════════════════════════════════════════════════════════════════
echo "---"
echo "#### 🟡 Check 3 — DNS Resolution & Split-Horizon"
echo ""
echo "Verifies Pi-hole returns Traefik's LAN IP for internal domains (not Cloudflare's"
echo "public IP), and that Traefik can resolve the \`gluetun\` hostname used by the"
echo "Transmission file-provider route."
echo ""

echo "##### 3a. Traefik container /etc/resolv.conf"
print_section

if [[ "$DMZ_REACHABLE" == "true" ]]; then
  dmz_bash_run <<'REMOTE_RESOLV'
TRAEFIK_CTR=$(docker ps --filter name=traefik_traefik --filter status=running \
  --format "{{.ID}}" | head -1)
if [ -z "$TRAEFIK_CTR" ]; then
  echo "No Traefik container running."
  exit 0
fi

echo "--- /etc/resolv.conf (inside Traefik container) ---"
docker exec "$TRAEFIK_CTR" cat /etc/resolv.conf
echo ""

if docker exec "$TRAEFIK_CTR" cat /etc/resolv.conf 2>/dev/null | grep -q "127.0.0.11"; then
  echo "OK: Nameserver is 127.0.0.11 (Docker embedded DNS) - correct."
else
  echo "WARNING: 127.0.0.11 not present. Traefik may use an external DNS path,"
  echo "  which can cause slow resolution or DNS loops through Pi-hole."
fi
REMOTE_RESOLV

else
  echo "Skipped - DMZ node not reachable via SSH."
fi

end_section

echo "##### 3b. 'gluetun' hostname resolution timing from Traefik container"
print_section
echo "Used by vpn-transmission.yml (file-provider). Failure = Transmission unreachable."
echo ""

if [[ "$DMZ_REACHABLE" == "true" ]]; then
  dmz_bash_run <<'REMOTE_GLUETUN'
TRAEFIK_CTR=$(docker ps --filter name=traefik_traefik --filter status=running \
  --format "{{.ID}}" | head -1)
if [ -z "$TRAEFIK_CTR" ]; then echo "No Traefik container."; exit 0; fi

START=$(date +%s%3N)
RESULT=$(docker exec "$TRAEFIK_CTR" nslookup gluetun 2>&1 || echo "NXDOMAIN/FAILED")
ELAPSED=$(( $(date +%s%3N) - START ))
echo "Resolution time: ${ELAPSED} ms"
echo ""
echo "$RESULT"
echo ""

if echo "$RESULT" | grep -qiE "NXDOMAIN|FAILED|can.t resolve|server can.t find"; then
  echo "FAIL: 'gluetun' not resolvable from Traefik container."
  echo "  Ensure gluetun is running and joined to the traefik-public overlay network."
elif [ "$ELAPSED" -gt 200 ]; then
  echo "WARN: Resolution took ${ELAPSED} ms (> 200 ms threshold) - DNS may be slow."
else
  echo "OK: 'gluetun' resolved in ${ELAPSED} ms."
fi
REMOTE_GLUETUN

else
  echo "Skipped - DMZ node not reachable via SSH."
fi

end_section

echo "##### 3c. Pi-hole split-horizon — internal domains resolve to Traefik LAN IP"
print_section
echo "Expected: *.home.purvishome.com → $TRAEFIK_LAN_IP (not a Cloudflare/public IP)"
echo ""

TEST_DOMAINS_PIHOLE=(
  "portainer.home.purvishome.com"
  "grafana.home.purvishome.com"
  "uptime-kuma.home.purvishome.com"
  "pihole.home.purvishome.com"
)

for ph_ip in "$PIHOLE_PRIMARY" "$PIHOLE_SECONDARY"; do
  echo "--- Pi-hole ($ph_ip) ---"
  if ! ping -c 1 -W 1 "$ph_ip" >/dev/null 2>&1; then
    echo "❌ UNREACHABLE"
    continue
  fi
  for domain in "${TEST_DOMAINS_PIHOLE[@]}"; do
    RESOLVED=$(dig +short +timeout=2 "@${ph_ip}" "$domain" 2>/dev/null | grep -E '^[0-9]' | head -1 || echo "")
    if [[ "$RESOLVED" == "$TRAEFIK_LAN_IP" ]]; then
      printf "  ✅ %-44s → %s (correct)\n" "$domain" "$RESOLVED"
    elif [[ -z "$RESOLVED" ]]; then
      printf "  ❌ %-44s → NO ANSWER (missing Pi-hole local DNS record?)\n" "$domain"
    else
      printf "  ⚠️  %-44s → %s (expected %s — HAIRPIN NAT RISK!)\n" \
        "$domain" "$RESOLVED" "$TRAEFIK_LAN_IP"
    fi
  done
  echo ""
done

end_section

# ══════════════════════════════════════════════════════════════════════════════
# CHECK 4 — TCP Keep-Alive / Stale Connections
# ══════════════════════════════════════════════════════════════════════════════
echo "---"
echo "#### 🔵 Check 4 — TCP Keep-Alive / Stale Connections"
echo ""
echo "Traefik reuses keep-alive connections to backends. If a backend closes the"
echo "connection while Traefik still considers it open, the next request stalls until"
echo "the Go HTTP \`ResponseHeaderTimeout\` fires (default: unlimited — i.e. hangs forever)."
echo "traefik.yaml has NO \`respondingTimeouts\` configured. See 4c for the fix."
echo ""

echo "##### 4a. Backend TCP reachability from Traefik DMZ node"
print_section
echo "(Tests the exact network path Traefik traverses to reach each backend)"
echo ""

if [[ "$DMZ_REACHABLE" == "true" ]]; then
  dmz_bash_run <<'REMOTE_TCP'
TRAEFIK_CTR=$(docker ps --filter name=traefik_traefik --filter status=running \
  --format "{{.ID}}" | head -1)
USE_CTR=false
[ -n "$TRAEFIK_CTR" ] && USE_CTR=true

BACKENDS_SERIAL="pihole-1|10.0.60.20|80 pihole-2|10.0.60.21|80 synology|10.0.100.20|5000 pfsense|10.0.60.1|443 proxmox|10.0.90.50|8006 extreme|10.0.90.30|443 pdu|10.0.90.31|443 homeassistant|10.0.60.42|8123 portainer|10.0.60.30|9000"

for entry in $BACKENDS_SERIAL; do
  name=$(echo "$entry" | cut -d'|' -f1)
  ip=$(echo "$entry" | cut -d'|' -f2)
  port=$(echo "$entry" | cut -d'|' -f3)

  START=$(date +%s%3N)
  if $USE_CTR; then
    OK=$(docker exec "$TRAEFIK_CTR" \
      sh -c "nc -w 2 -z $ip $port >/dev/null 2>&1 && echo OK || echo FAIL" 2>/dev/null)
  else
    OK=$(nc -w 2 -z "$ip" "$port" >/dev/null 2>&1 && echo OK || echo FAIL)
  fi
  ELAPSED=$(( $(date +%s%3N) - START ))

  if [ "$OK" = "OK" ]; then
    printf "  OK  %-36s %s ms\n" "$name ($ip:$port)" "$ELAPSED"
  else
    printf "  FAIL %-35s UNREACHABLE (%s ms)\n" "$name ($ip:$port)" "$ELAPSED"
  fi
done
REMOTE_TCP

else
  echo "Skipped - DMZ node not reachable via SSH."
fi

end_section

echo "##### 4b. Traefik log scan — connection and timeout error patterns (last 300 lines)"
print_section

# shellcheck disable=SC2087
ssh "${SSH_OPTS[@]}" "docker@$MGR_HOST" 'bash -s' <<'REMOTE_LOGS'
PATTERN="connection refused|connection reset by peer|dial tcp|context deadline exceeded|EOF|no route to host|i/o timeout|net/http: request canceled|TLS handshake timeout|upstream timed out|service selected"
set +e
TRAEFIK_LOGS=$(docker service logs traefik_traefik --tail 300 2>/dev/null)
set -e

if [ -z "$TRAEFIK_LOGS" ]; then
  echo "⚠️  No logs available from traefik_traefik service."
  exit 0
fi

MATCHES=$(echo "$TRAEFIK_LOGS" | grep -iE "$PATTERN" 2>/dev/null || true)
COUNT=$(echo "$MATCHES" | grep -c . || true)

if [ "$COUNT" -eq 0 ]; then
  echo "✅ No error patterns found in last 300 Traefik log lines."
else
  echo "⚠️  Found $COUNT matching log line(s):"
  echo ""
  echo "$MATCHES" | tail -25
fi
REMOTE_LOGS

end_section

echo "##### 4c. Missing timeout configuration — recommended traefik.yaml additions"
print_section
cat <<'YAML_ADVICE'
# ── ADD to traefik.yaml to prevent indefinite backend hangs ──────────────────
# These settings cap how long Traefik waits on a backend response.
# Without them, a stale keep-alive connection can block a goroutine indefinitely.
#
# Place under the websecure (and optionally web) entryPoint:

entryPoints:
  websecure:
    address: ':443'
    transport:
      respondingTimeouts:
        readTimeout:  30s   # max time to read request body from client
        writeTimeout: 60s   # max time to write response to client
        idleTimeout:  30s   # overrides Go default of 90 s for idle keep-alive

# ── For aggressive backend appliances (pfSense, Proxmox, Extreme, PDU) ───────
# Add forwardingTimeouts to prevent stale upstream TCP connections:
#
# serversTransports:
#   insecureTransport:
#     insecureSkipVerify: true
#     forwardingTimeouts:
#       dialTimeout:           5s    # max time to establish TCP connection
#       responseHeaderTimeout: 20s   # max time waiting for first response byte
#       idleConnTimeout:       15s   # max idle keep-alive time to backend
YAML_ADVICE
end_section

# ══════════════════════════════════════════════════════════════════════════════
# CHECK 5 — Middleware & TLS Overhead Baseline
# ══════════════════════════════════════════════════════════════════════════════
echo "---"
echo "#### 🟢 Check 5 — Middleware & TLS Overhead Baseline"
echo ""
echo "Measures the delta between hitting Traefik and hitting the backend directly."
echo "Also flags HTTPS backends using insecureSkipVerify (no TLS session reuse)."
echo ""

echo "##### 5a. End-to-end timing: via Traefik vs direct backend"
print_section
printf "%-44s %-14s %-14s %s\n" "DOMAIN" "VIA TRAEFIK" "DIRECT" "TRAEFIK OVERHEAD"
echo ""

declare -A DIRECT_MAP=(
  ["portainer.home.purvishome.com"]="http://10.0.60.30:9000"
  ["pihole.home.purvishome.com"]="http://10.0.60.20:80"
  ["homeassistant.home.purvishome.com"]="http://10.0.60.42:8123"
  ["pve.home.purvishome.com"]="https://10.0.90.50:8006"
)

set +e
for domain in "${!DIRECT_MAP[@]}"; do
  direct_url="${DIRECT_MAP[$domain]}"

  TRAEFIK_T=$(curl -sk --max-time 10 -o /dev/null \
    -w "%{time_total}" "https://$domain" 2>/dev/null || echo "TIMEOUT")

  DIRECT_T=$(curl -sk --max-time 10 -o /dev/null \
    -w "%{time_total}" "$direct_url" 2>/dev/null || echo "TIMEOUT")

  if [[ "$TRAEFIK_T" == "TIMEOUT" || "$DIRECT_T" == "TIMEOUT" ]]; then
    OVERHEAD="N/A"
  else
    OVERHEAD=$(awk "BEGIN{printf \"%.3f\", $TRAEFIK_T - $DIRECT_T}")
    # Flag overhead > 500 ms
    OVERHEAD_FLAG=$(awk "BEGIN{exit ($OVERHEAD > 0.500) ? 0 : 1}" 2>/dev/null \
      && echo " ⚠️ HIGH" || echo "")
    OVERHEAD="${OVERHEAD}s${OVERHEAD_FLAG}"
  fi

  printf "%-44s %-14s %-14s %s\n" \
    "$domain" "${TRAEFIK_T}s" "${DIRECT_T}s" "$OVERHEAD"
done
set -e

end_section

echo "##### 5b. HTTPS backends using insecureSkipVerify — TLS re-handshake on every request"
print_section
cat <<'TLS_NOTE'
The following file-provider backends terminate TLS at the device (self-signed cert)
and are configured with insecureSkipVerify. Because the cert cannot be validated,
TLS session tickets cannot be cached across requests — Traefik performs a full
TLS handshake (ClientHello → ServerHello → Finished) for EVERY upstream request.

  ❗ pfsense      → https://10.0.60.1:443    insecureSkipVerify=true
  ❗ proxmox      → https://10.0.90.50:8006  insecureSkipVerify=true
  ❗ extreme      → https://10.0.90.30:443   insecureSkipVerify=true
  ❗ pdu          → https://10.0.90.31:443   insecureSkipVerify=true

Typical overhead: 5–30 ms per request (hardware dependent).
Mitigation: add forwardingTimeouts.idleConnTimeout (see Check 4c) to keep
  the TLS connection alive between requests where possible.
  Or, if device firmware allows it, enable TLS session ticket support.
TLS_NOTE
end_section

echo "##### 5c. Middleware chain review — routes with multiple middlewares"
print_section
echo "Route breakdown from dynamic config (file-provider):"
echo ""
cat <<'MW_SUMMARY'
  pihole.home.purvishome.com    : internal-only → pihole-headers → pihole-redirect   (3 middlewares)
  pihole2.home.purvishome.com   : internal-only → pihole-headers-2 → pihole-redirect-2 (3 middlewares)
  synology.home.purvishome.com  : internal-only → synology-headers  (2 middlewares)
  pfsense.home.purvishome.com   : internal-only → pfsense-headers   (2 middlewares)
  pve.home.purvishome.com       : internal-only → proxmox-headers   (2 middlewares)
  extreme.home.purvishome.com   : internal-only                     (1 middleware)
  pdu.home.purvishome.com       : internal-only                     (1 middleware)
  homeassistant.home.*          : internal-only                     (1 middleware)
  portainer.home.*              : internal-only                     (1 middleware)
  unifi.home.* (Swarm label)    : internal-only@file                (1 middleware)

All Swarm-label routes (Traefik auto-discovered) use only internal-only.
ipAllowList is a lightweight in-memory CIDR check — negligible overhead.
pihole-redirect regex is evaluated per-request — minimal impact.
MW_SUMMARY
end_section

# ══════════════════════════════════════════════════════════════════════════════
# SUMMARY & RECOMMENDED ACTIONS
# ══════════════════════════════════════════════════════════════════════════════
echo "---"
echo "### 📋 Summary — Recommended Actions by Check"
echo ""
cat <<'SUMMARY'
| Check | Likely culprit indicators | Recommended fix |
|-------|--------------------------|-----------------|
| **1 — Swarm VIP** | Replicas degraded; VIP ≠ task IPs; intermittent under load | Prefix backend with `tasks.<service>` OR set `endpoint_mode: dnsrr` |
| **2 — IPv6** | IPv6 interfaces present on dmz-01; curl -6 times out | Disable IPv6 via sysctl; ensure Docker daemon IPv6=false |
| **3 — DNS** | Pi-hole returns wrong IP; gluetun resolve >200 ms | Add local DNS overrides in Pi-hole; ensure gluetun on traefik-public overlay |
| **4 — Stale conn** | Log shows `connection reset` / `dial tcp`; nc fails | Add `respondingTimeouts` + `forwardingTimeouts` to `traefik.yaml` (see 4c) |
| **5 — TLS overhead** | Traefik overhead >500 ms vs direct | Add `idleConnTimeout` to `insecureTransport` serversTransport |

### Next steps

1. Review the output above section by section — start with **Check 1** (most likely for Swarm).
2. Enable DEBUG logging temporarily to capture one slow request's full trace:
   ```yaml
   # traefik.yaml — change temporarily, redeploy, then revert to INFO
   log:
     level: DEBUG
   ```
   Capture:
   ```bash
   ssh docker@10.0.60.30 'docker service logs traefik_traefik --since 2m --follow' \
     | tee /tmp/traefik-debug-$(date +%Y%m%d-%H%M%S).log
   ```
3. Apply the fix for the failing check, redeploy Traefik, re-run this script to confirm.
4. Restore `log.level: INFO`.
SUMMARY
