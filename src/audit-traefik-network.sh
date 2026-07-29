#!/usr/bin/env bash
# automation/diagnostics/audit-traefik-network.sh
#
# Performs a comprehensive audit of the network topology, Traefik configs,
# Pi-hole split-horizon records, and Swarm-label routing definitions.
# Prints a structured audit report with actionable remediation advice.
#
# Usage:
#   bash automation/diagnostics/audit-traefik-network.sh

set -euo pipefail

MGR_HOST="10.0.60.30"
SSH_KEY="$HOME/.ssh/homelab_ed25519"
SSH_OPTS=(-i "$SSH_KEY" -o BatchMode=yes -o StrictHostKeyChecking=accept-new -o ConnectTimeout=5)

TRAEFIK_LAN_IP="10.0.60.40"
PIHOLE_PRIMARY="10.0.60.20"
PIHOLE_SECONDARY="10.0.60.21"

AUDIT_DOMAINS=(
  "pihole.home.purvishome.com"
  "pihole2.home.purvishome.com"
  "synology.home.purvishome.com"
  "pfsense.home.purvishome.com"
  "pve.home.purvishome.com"
  "extreme.home.purvishome.com"
  "pdu.home.purvishome.com"
  "transmission.home.purvishome.com"
  "portainer.home.purvishome.com"
  "grafana.home.purvishome.com"
  "uptime-kuma.home.purvishome.com"
)

echo "=== 🛡️  Traefik & Network Configuration Audit ==="
echo "Timestamp: $(date -u '+%Y-%m-%dT%H:%M:%SZ')"
echo ""

# ──────────────────────────────────────────────────────────────────────────────
# 1. Static Configuration Audit (traefik.yaml)
# ──────────────────────────────────────────────────────────────────────────────
echo "---"
echo "#### 1. Traefik Static Configuration (traefik.yaml)"
STATIC_CONF="/home/scarredninja/source/repos/homelab-diagnostics/config/traefik/traefik.yaml"
if [ ! -f "$STATIC_CONF" ]; then
  STATIC_CONF="/home/scarredninja/source/repos/docker-swarm-home/config/traefik/traefik.yaml"
fi

if [ -f "$STATIC_CONF" ]; then
  # Check for entryPoints timeouts
  if grep -q "respondingTimeouts" "$STATIC_CONF"; then
    echo "  ✅ PASS: entryPoints.websecure.transport.respondingTimeouts is configured."
  else
    echo "  ❌ FAIL: respondingTimeouts is MISSING in traefik.yaml."
    echo "           Dead connections from clients can hang indefinite Go routines."
  fi

  # Check for Secure API Dashboard settings
  if grep -A 2 "api:" "$STATIC_CONF" | grep -q "insecure: false"; then
    echo "  ✅ PASS: API dashboard is secured (insecure: false)."
  else
    echo "  ⚠️  WARN: API dashboard insecure is not set to false or is missing."
  fi
else
  echo "  ⚠️  WARN: traefik.yaml not found at local path $STATIC_CONF. Skipping local analysis."
fi

# ──────────────────────────────────────────────────────────────────────────────
# 2. Dynamic Configs & serversTransports Audit (network-devices.yml)
# ──────────────────────────────────────────────────────────────────────────────
echo "---"
echo "#### 2. ServersTransports & TLS Reuse (network-devices.yml)"
DEV_CONF="/home/scarredninja/source/repos/homelab-diagnostics/config/traefik/dynamic/network-devices.yml"
if [ ! -f "$DEV_CONF" ]; then
  DEV_CONF="/home/scarredninja/source/repos/docker-swarm-home/config/traefik/dynamic/network-devices.yml"
fi

if [ -f "$DEV_CONF" ]; then
  # Check if insecureTransport has forwardingTimeouts
  if grep -A 5 "insecureTransport:" "$DEV_CONF" | grep -q "forwardingTimeouts"; then
    echo "  ✅ PASS: insecureTransport has forwardingTimeouts configured."
  else
    echo "  ❌ FAIL: insecureTransport has NO forwardingTimeouts defined."
    echo "           This causes Traefik to run full TLS handshakes on every single request"
    echo "           to Proxmox, pfSense, Extreme, and PDU."
  fi
else
  echo "  ⚠️  WARN: network-devices.yml not found."
fi

# ──────────────────────────────────────────────────────────────────────────────
# 3. Pi-hole DNS Overrides Verification
# ──────────────────────────────────────────────────────────────────────────────
echo "---"
echo "#### 3. Pi-hole DNS Record Consistency"

audit_dns_server() {
  local ip="$1"
  local name="$2"
  echo "Checking $name ($ip)..."
  if ! ping -c 1 -W 1 "$ip" >/dev/null 2>&1; then
    echo "  ❌ DNS SERVER UNREACHABLE"
    return
  fi

  for dom in "${AUDIT_DOMAINS[@]}"; do
    local res
    res=$(dig +short +timeout=1 "@$ip" "$dom" 2>/dev/null | grep -E '^[0-9]' | head -1 || echo "")
    if [ "$res" = "$TRAEFIK_LAN_IP" ]; then
      echo "  ✅ $dom -> $res"
    elif [ -z "$res" ]; then
      echo "  ❌ $dom -> (NO RECORD)"
    else
      echo "  ⚠️  $dom -> $res (Expected $TRAEFIK_LAN_IP - potential Hairpin NAT loop!)"
    fi
  done
}

audit_dns_server "$PIHOLE_PRIMARY" "Primary Pi-hole"
echo ""
audit_dns_server "$PIHOLE_SECONDARY" "Secondary Pi-hole"

# ──────────────────────────────────────────────────────────────────────────────
# 4. Swarm Stack Labels Audit
# ──────────────────────────────────────────────────────────────────────────────
echo "---"
echo "#### 4. Docker Swarm Stack Labels & Endpoint Modes"

if ssh "${SSH_OPTS[@]}" "docker@$MGR_HOST" "echo OK" >/dev/null 2>&1; then
  # Query all Traefik enabled services and print their configs
  ssh "${SSH_OPTS[@]}" "docker@$MGR_HOST" 'bash -s' <<'REMOTE_AUDIT'
    SVCS=$(docker service ls --format "{{.Name}}" | while read -r s; do
      en=$(docker service inspect "$s" --format '{{index .Spec.Labels "traefik.enable"}}' 2>/dev/null || echo "")
      [ "$en" = "true" ] && echo "$s"
    done)

    for s in $SVCS; do
      ep=$(docker service inspect "$s" --format '{{.Spec.EndpointSpec.Mode}}' 2>/dev/null || echo "vip")
      ep="${ep:-vip}"
      net=$(docker service inspect "$s" --format '{{range .Spec.TaskTemplate.Networks}}{{.Target}} {{end}}' 2>/dev/null || echo "")
      
      # Warn if VIP mode is used instead of dnsrr for high load services
      if [ "$ep" = "vip" ]; then
        echo "  ⚠️  Service '$s' is in VIP load-balancing mode. (Consider dnsrr if experiencing drops)"
      else
        echo "  ✅ Service '$s' is in DNSRR mode."
      fi
    done
REMOTE_AUDIT
else
  echo "  ⏭️  Skipped - Swarm manager SSH is unreachable from this audit runner."
fi

echo ""
echo "=== Audit Completed ==="
