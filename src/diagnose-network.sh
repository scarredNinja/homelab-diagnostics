#!/usr/bin/env bash
# automation/diagnostics/diagnose-network.sh
# Diagnoses network connectivity, VLAN gateways, DNS resolution, Traefik TLS certificates, and Gluetun VPN status.

set -euo pipefail

SSH_KEY="$HOME/.ssh/homelab_ed25519"
SSH_OPTS=(-i "$SSH_KEY" -o BatchMode=yes -o StrictHostKeyChecking=accept-new -o ConnectTimeout=5)
WORKER_HOST="10.0.50.51"

echo "### 🌐 Network Diagnostic"
echo ""

echo "#### 1. VLAN Gateways Reachability"
echo "Pinging VLAN gateways (pfSense)..."
echo "\`\`\`"
gateways=(
    "10.0.90.1:Management VLAN Gateway"
    "10.0.60.1:Services VLAN Gateway"
    "10.0.50.1:Workers VLAN Gateway"
    "10.0.100.1:Storage VLAN Gateway"
)

for gw_info in "${gateways[@]}"; do
    gw_ip="${gw_info%%:*}"
    gw_name="${gw_info#*:}"
    if ping -c 2 -W 2 "$gw_ip" >/dev/null 2>&1; then
        echo "✅ [UP] $gw_name ($gw_ip)"
    else
        echo "❌ [DOWN] $gw_name ($gw_ip)"
    fi
done
echo "\`\`\`"
echo ""

echo "#### 2. DNS Resolution (Pi-holes)"
echo "Testing DNS resolution on Pi-hole servers..."
echo "\`\`\`"
piholes=(
    "10.0.60.20:Pi-hole 1"
    "10.0.60.21:Pi-hole 2"
)

test_domains=(
    "pve.home.purvishome.com"
    "pihole.home.purvishome.com"
    "google.com"
)

# Inline Python script to check if a specific DNS server resolves a domain
python_dns_check() {
    local server="$1"
    local domain="$2"
    python3 -c "
import socket
import struct
import sys

def check_dns(server, domain):
    try:
        # Transaction ID, flags (query), questions=1, answers=0, authority=0, additional=0
        packet = struct.pack('>HHHHHH', 0x1234, 0x0100, 1, 0, 0, 0)
        for part in domain.split('.'):
            packet += struct.pack('B', len(part)) + part.encode('utf-8')
        packet += b'\x00'
        packet += struct.pack('>HH', 1, 1) # Type A, Class IN
        
        sock = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
        sock.settimeout(2.0)
        sock.sendto(packet, (server, 53))
        data, _ = sock.recvfrom(512)
        if len(data) < 12:
            return False
        _, flags, _, answers, _, _ = struct.unpack('>HHHHHH', data[:12])
        # Return True if no error (flags & 0x000f == 0) and at least one answer
        return (flags & 0x000f) == 0 and answers > 0
    except Exception:
        return False

sys.exit(0 if check_dns('$server', '$domain') else 1)
"
}

for ph_info in "${piholes[@]}"; do
    ph_ip="${ph_info%%:*}"
    ph_name="${ph_info#*:}"
    echo "Checking $ph_name ($ph_ip):"
    
    # Check if host is pingable first
    if ! ping -c 1 -W 1 "$ph_ip" >/dev/null 2>&1; then
        echo "  ❌ Host is UNREACHABLE via ping"
        continue
    fi

    # Test DNS query resolution
    for domain in "${test_domains[@]}"; do
        if python_dns_check "$ph_ip" "$domain"; then
            echo "  ✅ Resolves $domain"
        else
            echo "  ❌ Failed to resolve $domain"
        fi
    done
done
echo "\`\`\`"
echo ""

echo "#### 3. Traefik Certificates (TLS)"
echo "Checking expiration of TLS certificates on Traefik ingress..."
echo "\`\`\`"
certs_domains=(
    "pihole.home.purvishome.com"
    "pve.home.purvishome.com"
    "uptime-kuma.home.purvishome.com"
)

for domain in "${certs_domains[@]}"; do
    echo "Domain: $domain"
    # Query certificate expiration via openssl. If DNS is not resolving locally, fallback to local Traefik host (10.0.60.30)
    if timeout 5 openssl s_client -connect "$domain":443 -servername "$domain" -showcerts </dev/null 2>/dev/null | openssl x509 -noout -enddate -subject >/tmp/cert_info 2>/dev/null; then
        expiry_date=$(grep "notAfter=" /tmp/cert_info | cut -d= -f2)
        subject=$(grep "subject=" /tmp/cert_info | cut -d= -f2-)
        echo "  ✅ Subject: $subject"
        echo "  ✅ Expiry Date: $expiry_date"
    elif timeout 5 openssl s_client -connect 10.0.60.30:443 -servername "$domain" -showcerts </dev/null 2>/dev/null | openssl x509 -noout -enddate -subject >/tmp/cert_info 2>/dev/null; then
        expiry_date=$(grep "notAfter=" /tmp/cert_info | cut -d= -f2)
        subject=$(grep "subject=" /tmp/cert_info | cut -d= -f2-)
        echo "  ✅ Subject: $subject (via Swarm IP)"
        echo "  ✅ Expiry Date: $expiry_date"
    else
        echo "  ❌ Failed to retrieve certificate info for $domain"
    fi
done
rm -f /tmp/cert_info
echo "\`\`\`"
echo ""

echo "#### 4. Gluetun WireGuard Tunnel Status (worker-mediamanagement-01)"
echo "Querying Gluetun VPN container on $WORKER_HOST..."
echo "\`\`\`"

# Check Gluetun status using a single SSH command to minimize connection latency overhead.
set +e
GLUETUN_RESULT=$(ssh "${SSH_OPTS[@]}" "docker@$WORKER_HOST" '
    if ! docker ps -q -f name=gluetun >/dev/null 2>&1; then
        echo "ERROR: Gluetun container is not running!"
        exit 0
    fi
    echo "STATUS: Gluetun container is running."
    vpn_ip=$(timeout 10 docker exec gluetun wget -T 5 -qO- https://ipinfo.io/ip 2>/dev/null || \
             timeout 10 docker exec gluetun curl --max-time 5 -s https://ipinfo.io/ip 2>/dev/null || echo "failed")
    if [ "$vpn_ip" != "failed" ] && [ -n "$vpn_ip" ]; then
        vpn_country=$(timeout 10 docker exec gluetun wget -T 5 -qO- https://ipinfo.io/country 2>/dev/null || \
                      timeout 10 docker exec gluetun curl --max-time 5 -s https://ipinfo.io/country 2>/dev/null | tr -d "\r\n")
        echo "VPN: $vpn_ip ($vpn_country)"
    else
        echo "VPN: failed"
    fi
    echo "LOGS:"
    docker logs gluetun 2>&1 | tail -n 10
' 2>&1)
SSH_EXIT=$?
set -e

if [ $SSH_EXIT -ne 0 ]; then
    echo "❌ ERROR: Cannot connect to $WORKER_HOST via SSH (Exit code: $SSH_EXIT)."
    echo "Check if the VM is running or if the SSH key is authorized."
    echo "Raw SSH Output: $GLUETUN_RESULT"
else
    # Parse and print the combined results
    if echo "$GLUETUN_RESULT" | grep -q "ERROR:"; then
        echo "❌ $(echo "$GLUETUN_RESULT" | grep "ERROR:")"
    else
        # Parse and reconstruct output
        echo "✅ $(echo "$GLUETUN_RESULT" | grep "STATUS:")"
        vpn_info=$(echo "$GLUETUN_RESULT" | grep "VPN:")
        if echo "$vpn_info" | grep -q "failed"; then
            echo "❌ ERROR: Could not fetch public IP from inside Gluetun container. Tunnel might be down."
        else
            echo "✅ ${vpn_info#VPN: }"
        fi
        echo ""
        echo "Gluetun logs snippet:"
        echo "$GLUETUN_RESULT" | sed -n '/LOGS:/,$p' | tail -n +2
    fi
fi
echo "\`\`\`"
