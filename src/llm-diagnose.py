#!/usr/bin/env python3
# automation/diagnostics/llm-diagnose.py
import sys
import os
import json
import argparse
import subprocess
import requests
import datetime
import re
import glob

OLLAMA_URL = os.environ.get("OLLAMA_URL", "http://localhost:11434").rstrip("/")
if not OLLAMA_URL.endswith("/api/chat"):
    OLLAMA_URL += "/api/chat"
OLLAMA_MODEL = os.environ.get("OLLAMA_MODEL", "qwen2.5-coder:7b")

PVE_HOST = "10.0.90.50"
MGR_HOST = "10.0.60.30"
SSH_KEY = os.path.expanduser("~/.ssh/homelab_ed25519")
SSH_OPTS = ["-i", SSH_KEY, "-o", "BatchMode=yes", "-o", "StrictHostKeyChecking=accept-new", "-o", "ConnectTimeout=5"]

# Resolve Obsidian vault path depending on environment (WSL vs Native Linux)
win_vaults = glob.glob("/mnt/c/Users/*/Documents/Notes/Home/10 - Projects/Monitoring logs.md")
if win_vaults:
    OBSIDIAN_LOG_PATH = win_vaults[0]
else:
    OBSIDIAN_LOG_PATH = os.path.expanduser("~/Documents/Notes/Home/10 - Projects/Monitoring logs.md")

# How many hours before re-sending a persistent alert
ALERT_REPEAT_HOURS = 12

# Non-destructive command whitelists for auto-remediation
REMEDIATION_WHITELIST = {
    "restic unlock": {
        "host": "root@" + PVE_HOST,
        "pattern": r"^(?:export RESTIC_PASSWORD_FILE=/etc/restic-password;\s*)?(?:\[ -f /etc/restic-backup\.conf \]\s*&&\s*source\s+/etc/restic-backup\.conf;\s*)?restic(?:\s+-r\s+\S+)?\s+unlock(?:\s+--\S+)?$"
    },
    "docker service update": {
        "host": "docker@" + MGR_HOST,
        "pattern": r"^docker service update (?:-d|--detach)?\s*--force [a-zA-Z0-9_-]+$"
    },
    "docker restart": {
        "host": "docker@10.0.50.51",
        "pattern": r"^docker restart (?:gluetun|compose-vpn-transmission-1)$"
    },
    "qm unlock": {
        "host": "root@" + PVE_HOST,
        "pattern": r"^qm unlock [0-9]+$"
    },
    "qm start": {
        "host": "root@" + PVE_HOST,
        "pattern": r"^qm start [0-9]+$"
    },
    "qm stop": {
        "host": "root@" + PVE_HOST,
        "pattern": r"^qm stop (?:206|207)$"
    },
    # Docker daemon restart on a specific Swarm node — host is dynamic
    "sudo systemctl restart docker": {
        "host": None,  # resolved dynamically from command metadata
        "pattern": r"^sudo systemctl restart docker$",
        "host_pattern": r"^docker@10\.0\.[0-9]+\.[0-9]+$"
    }
}


def ping_uptime_kuma_push(overall_status, summary):
    kuma_url = os.getenv("UPTIME_KUMA_PUSH_URL", "").strip()
    if not kuma_url:
        return
    status_param = "down" if overall_status == "Critical" else "up"
    msg = f"Status: {overall_status} - {summary[:50]}"
    try:
        url_sep = "&" if "?" in kuma_url else "?"
        push_endpoint = f"{kuma_url}{url_sep}status={status_param}&msg={requests.utils.quote(msg)}"
        requests.get(push_endpoint, timeout=5)
        print("Pushed heartbeat to Uptime Kuma.")
    except Exception as e:
        print(f"Failed to push to Uptime Kuma: {e}")

def normalize_command(cmd):
    if not cmd:
        return ""
    cmd = re.sub(r"\s+-(?:d|-detach)\b", "", cmd)
    cmd = " ".join(cmd.split())
    return cmd


def get_issue_signature(status_data):
    failing_domains = []
    domains = status_data.get("domains", {})
    for domain_name in ["backups", "services", "hardware", "network"]:
        domain_status = domains.get(domain_name, {}).get("status", "Healthy")
        if domain_status in ["Warning", "Critical"]:
            failing_domains.append(f"{domain_name}:{domain_status}")
            
    degraded_services = domains.get("services", {}).get("degraded_services", [])
    degraded_services = sorted([svc for svc in degraded_services if svc != "temp-secret-check"])
    
    nodes = domains.get("services", {}).get("nodes", [])
    down_nodes = sorted([n["hostname"] for n in nodes if n.get("status") != "Ready" and n.get("availability") != "Drain"])
    
    return {
        "failing_domains": failing_domains,
        "degraded_services": degraded_services,
        "down_nodes": down_nodes
    }


def get_historical_issue_signature(history_entry):
    failing_domains = []
    domains = history_entry.get("domains", {})
    for domain_name in ["backups", "services", "hardware", "network"]:
        domain_status = domains.get(domain_name, "Healthy")
        if domain_status in ["Warning", "Critical"]:
            failing_domains.append(f"{domain_name}:{domain_status}")
            
    degraded_services = history_entry.get("degraded_services", [])
    degraded_services = sorted([svc for svc in degraded_services if svc != "temp-secret-check"])
    
    nodes = history_entry.get("nodes", [])
    down_nodes = sorted([n["hostname"] for n in nodes if n.get("status") != "Ready" and n.get("availability") != "Drain"])
    
    return {
        "failing_domains": failing_domains,
        "degraded_services": degraded_services,
        "down_nodes": down_nodes
    }


def has_new_issues(sig_current, sig_past):
    past_domains = {}
    for fd in sig_past.get("failing_domains", []):
        if ":" in fd:
            d, s = fd.split(":", 1)
            past_domains[d] = s
            
    for fd in sig_current.get("failing_domains", []):
        if ":" in fd:
            d, s = fd.split(":", 1)
            if d not in past_domains:
                return True
            if s == "Critical" and past_domains[d] == "Warning":
                return True
                
    past_degraded = set(sig_past.get("degraded_services", []))
    for svc in sig_current.get("degraded_services", []):
        if svc not in past_degraded:
            return True
            
    past_down_nodes = set(sig_past.get("down_nodes", []))
    for node in sig_current.get("down_nodes", []):
        if node not in past_down_nodes:
            return True
            
    return False


def get_remediations_in_last_2_hours(output_dir, current_timestamp):
    try:
        now = datetime.datetime.fromisoformat(current_timestamp.replace("Z", "+00:00"))
    except Exception:
        now = datetime.datetime.now(datetime.timezone.utc)
        
    recent_entries = []
    
    date_today = now.strftime("%Y-%m-%d")
    date_yesterday = (now - datetime.timedelta(days=1)).strftime("%Y-%m-%d")
    
    for date_str in [date_yesterday, date_today]:
        history_file = os.path.join(output_dir, f"history-{date_str}.json")
        if os.path.exists(history_file):
            try:
                with open(history_file, "r", encoding="utf-8") as f:
                    data = json.load(f)
                    if isinstance(data, list):
                        recent_entries.extend(data)
            except Exception:
                pass
                
    executed_commands = []
    for entry in recent_entries:
        ts_str = entry.get("timestamp")
        if not ts_str:
            continue
        try:
            entry_ts = datetime.datetime.fromisoformat(ts_str.replace("Z", "+00:00"))
        except Exception:
            continue
            
        time_diff = (now - entry_ts).total_seconds()
        if 0 < time_diff <= 7200:
            remediations = entry.get("remediations", [])
            for rem in remediations:
                cmd = rem.get("command")
                if cmd:
                    executed_commands.append(cmd)
    return executed_commands


def load_recent_history(output_dir, timestamp):
    date_str = timestamp.split("T")[0]
    history_file = os.path.join(output_dir, f"history-{date_str}.json")
    history_data = []
    if os.path.exists(history_file):
        try:
            with open(history_file, "r", encoding="utf-8") as f:
                history_data = json.load(f)
        except Exception:
            pass
            
    if len(history_data) < 2:
        try:
            current_date = datetime.datetime.fromisoformat(timestamp)
            yesterday = current_date - datetime.timedelta(days=1)
            yesterday_str = yesterday.strftime("%Y-%m-%d")
            yesterday_file = os.path.join(output_dir, f"history-{yesterday_str}.json")
            if os.path.exists(yesterday_file):
                with open(yesterday_file, "r", encoding="utf-8") as f:
                    yesterday_data = json.load(f)
                if isinstance(yesterday_data, list):
                    history_data = yesterday_data + history_data
        except Exception:
            pass
    return history_data

def record_remediations_in_history(output_dir, timestamp, remediations):
    if not remediations:
        return
    date_str = timestamp.split("T")[0]
    history_file = os.path.join(output_dir, f"history-{date_str}.json")
    if not os.path.exists(history_file):
        return
    try:
        with open(history_file, "r", encoding="utf-8") as f:
            history_data = json.load(f)
        if history_data and history_data[-1]["timestamp"] == timestamp:
            history_data[-1]["remediations"] = remediations
            with open(history_file, "w", encoding="utf-8") as f:
                json.dump(history_data, f, indent=2)
            print(f"Recorded remediations in history-{date_str}.json.")
    except Exception as e:
        print(f"Failed to record remediations in history: {e}")

def mark_alert_sent_in_history(output_dir, timestamp, alert_type):
    """Mark general_alert_sent or backup_alert_sent as True in the current history entry."""
    date_str = timestamp.split("T")[0]
    history_file = os.path.join(output_dir, f"history-{date_str}.json")
    if not os.path.exists(history_file):
        return
    try:
        with open(history_file, "r", encoding="utf-8") as f:
            history_data = json.load(f)
        for entry in reversed(history_data):
            if entry["timestamp"] == timestamp:
                entry[alert_type] = True
                break
        with open(history_file, "w", encoding="utf-8") as f:
            json.dump(history_data, f, indent=2)
        print(f"Marked {alert_type}=True in history-{date_str}.json for this run.")
    except Exception as e:
        print(f"Failed to mark {alert_type} in history: {e}")


def should_send_alert(output_dir, current_status, alert_field, current_timestamp, status_data):
    """
    Returns (should_send, reason).

    Rules:
    - ALWAYS send if there is a new issue not present in the last run (bypass cooldown).
    - If the signature is identical/no new issues:
      - SUPPRESS if the most recent sent alert was less than ALERT_REPEAT_HOURS ago.
      - RE-SEND if the most recent sent alert was >= ALERT_REPEAT_HOURS ago.
    """
    try:
        history_data = load_recent_history(output_dir, current_timestamp)
    except Exception:
        return True, "Could not read history — sending alert."

    if not history_data:
        return True, "No history found — sending first alert."

    past_entries = history_data[:-1]

    if not past_entries:
        return True, "First run ever — sending alert."

    sig_current = get_issue_signature(status_data)
    last_entry = past_entries[-1]
    sig_last_run = get_historical_issue_signature(last_entry)

    if has_new_issues(sig_current, sig_last_run):
        return True, "New issue(s) detected since last run — alerting immediately."

    last_alert_time = None
    for entry in reversed(past_entries):
        if entry.get(alert_field):
            try:
                last_alert_time = datetime.datetime.fromisoformat(entry["timestamp"].replace("Z", "+00:00"))
            except Exception:
                pass
            break

    if last_alert_time is None:
        return True, "No previous alert found in history — sending alert."

    try:
        now = datetime.datetime.fromisoformat(current_timestamp.replace("Z", "+00:00"))
    except Exception:
        now = datetime.datetime.now(datetime.timezone.utc)

    hours_elapsed = (now - last_alert_time).total_seconds() / 3600
    if hours_elapsed >= ALERT_REPEAT_HOURS:
        return True, f"Status persisted for {hours_elapsed:.1f}h (>= {ALERT_REPEAT_HOURS}h threshold) — re-sending alert."
    else:
        remaining = ALERT_REPEAT_HOURS - hours_elapsed
        return False, f"Duplicate alert suppressed — last sent {hours_elapsed:.1f}h ago (next in {remaining:.1f}h)."


def ssh_execute(host, command, timeout=15):
    print(f"Executing remote command on {host}: {command}")
    cmd = ["ssh"] + SSH_OPTS + [host, command]
    try:
        res = subprocess.run(cmd, stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True, timeout=timeout)
        return res.returncode, res.stdout, res.stderr
    except subprocess.TimeoutExpired:
        return -1, "", "SSH connection timed out."
    except Exception as e:
        return -1, "", str(e)


def execute_remediation(cmd_str, output_dir=None, current_timestamp=None, dynamic_host=None):
    """Execute a whitelisted remediation command.

    For 'sudo systemctl restart docker', dynamic_host must be provided
    (e.g. 'docker@10.0.60.41').
    """
    original_cmd = cmd_str.strip()
    if original_cmd == "restic unlock":
        cmd_str = 'export RESTIC_PASSWORD_FILE=/etc/restic-password; [ -f /etc/restic-backup.conf ] && source /etc/restic-backup.conf; restic -r "${RESTIC_REPO:-/mnt/docker-backups}" unlock --remove-all'

    if output_dir and current_timestamp:
        recent_commands = get_remediations_in_last_2_hours(output_dir, current_timestamp)
        norm_original = normalize_command(original_cmd)
        norm_expanded = normalize_command(cmd_str)
        
        is_cooldown = False
        for rc in recent_commands:
            norm_rc = normalize_command(rc)
            if norm_rc == norm_original or norm_rc == norm_expanded:
                is_cooldown = True
                break
                
        if is_cooldown:
            print(f"Skipped (cooldown): Command '{original_cmd}' was executed in the last 2 hours.")
            return "Skipped (cooldown)"

    matched = False
    target_host = None

    for key, rule in REMEDIATION_WHITELIST.items():
        if key in cmd_str:
            if re.match(rule["pattern"], cmd_str.strip()):
                matched = True
                if rule.get("host") is None:
                    # Dynamic host — validate against host_pattern
                    if dynamic_host and re.match(rule.get("host_pattern", ""), dynamic_host):
                        target_host = dynamic_host
                    else:
                        return f"Skipped — dynamic host '{dynamic_host}' failed whitelist validation."
                else:
                    target_host = rule["host"]
                break

    if not matched or not target_host:
        print(f"Skipping command '{cmd_str}' as it does not match safety whitelist patterns.")
        return "Skipped (Not whitelisted)"

    code, out, err = ssh_execute(target_host, cmd_str)
    if code == 0:
        return f"SUCCESS: {out.strip()}"
    else:
        return f"FAILED (Code: {code}): {err.strip()}"


def get_proxmox_vm_list():
    """Retrieve VM list from Proxmox. Returns a dict of {vm_name: {vmid, status}}."""
    code, out, err = ssh_execute(f"root@{PVE_HOST}", "qm list")
    vms = {}
    if code != 0:
        print(f"Could not query Proxmox VM list: {err}")
        return vms
    for line in out.strip().splitlines()[1:]:  # skip header
        parts = line.split()
        if len(parts) >= 3:
            vmid = parts[0]
            name = parts[1]
            status = parts[2]
            vms[name] = {"vmid": vmid, "status": status}
    return vms


def get_node_ip_from_proxmox(vmid):
    """Get the primary IPv4 address of a running VM via the QEMU Guest Agent."""
    code, out, err = ssh_execute(
        f"root@{PVE_HOST}",
        f"qm agent {vmid} network-get-interfaces"
    )
    if code != 0:
        return None
    try:
        ifaces = json.loads(out)
        for iface in ifaces:
            # Skip loopback
            if iface.get("name") == "lo":
                continue
            for addr in iface.get("ip-addresses", []):
                if addr.get("ip-address-type") == "ipv4":
                    ip = addr.get("ip-address", "")
                    if not ip.startswith("127."):
                        return ip
    except Exception as e:
        print(f"Could not parse guest agent network interfaces: {e}")
def is_dev_node(hostname):
    """Check if a node hostname belongs to the dev environment."""
    if not hostname:
        return False
    h = str(hostname).lower()
    return h.startswith("dev-") or h.startswith("dev_") or h in ["dev-node-01", "dev-runner-01"]


def is_dev_service(service_name):
    """Check if a service belongs to the dev stack/environment."""
    if not service_name:
        return False
    name = str(service_name).lower()
    return name.startswith("dev-") or name.startswith("dev_") or name.startswith("woodpecker_") or name.startswith("forgejo_")


def remediate_down_nodes(nodes, output_dir=None, current_timestamp=None):
    """
    Given the list of Swarm node dicts (from status.json), attempt to recover
    any nodes whose status is not 'Ready'. Skips dev nodes (dev-node-01, dev-runner-01, etc.)
    which are turned on/off manually.

    Returns a list of remediation result dicts.
    """
    if not nodes:
        return []

    down_nodes = [n for n in nodes if n.get("status") != "Ready" and n.get("availability") != "Drain"]
    if not down_nodes:
        print("All Swarm nodes are Ready — no node recovery needed.")
        return []

    print(f"Detected {len(down_nodes)} down Swarm node(s): {[n['hostname'] for n in down_nodes]}")
    pve_vms = get_proxmox_vm_list()
    results = []

    for node in down_nodes:
        hostname = node["hostname"]
        if is_dev_node(hostname):
            print(f"Skipping auto-recovery for dev node '{hostname}' (dev nodes are managed manually).")
            continue

        vm_info = pve_vms.get(hostname)

        if not vm_info:
            msg = f"Node '{hostname}' not found in Proxmox VM list — cannot auto-recover."
            print(msg)
            results.append({"node": hostname, "action": "none", "result": msg})
            continue

        vmid = vm_info["vmid"]
        vm_status = vm_info["status"]
        print(f"Node '{hostname}' Proxmox VM status: {vm_status} (VMID {vmid})")

        if vm_status == "stopped":
            # Boot the VM
            cmd = f"qm start {vmid}"
            res = execute_remediation(cmd, output_dir=output_dir, current_timestamp=current_timestamp)
            results.append({"node": hostname, "action": f"qm start {vmid}", "result": res})

        elif vm_status == "running":
            # VM is running but Docker daemon is unresponsive — restart it
            node_ip = get_node_ip_from_proxmox(vmid)
            if not node_ip:
                msg = f"Could not determine IP for VM {vmid} ({hostname}) — skipping Docker restart."
                print(msg)
                results.append({"node": hostname, "action": "systemctl restart docker", "result": msg})
                continue

            dynamic_host = f"docker@{node_ip}"
            cmd = "sudo systemctl restart docker"
            res = execute_remediation(cmd, output_dir=output_dir, current_timestamp=current_timestamp, dynamic_host=dynamic_host)
            results.append({"node": hostname, "action": f"{cmd} on {dynamic_host}", "result": res})

        else:
            msg = f"VM '{hostname}' (VMID {vmid}) is in state '{vm_status}' — no auto-recovery action defined."
            print(msg)
            results.append({"node": hostname, "action": "none", "result": msg})
    return results

def remediate_traefik_issues(traefik_data, output_dir=None, current_timestamp=None):
    """
    Check Traefik metadata flags and trigger a service update if needed.
    """
    if not traefik_data:
        return []

    if not traefik_data.get("needs_redeploy", False):
        print("Traefik deep-check passed — no Traefik recovery needed.")
        return []

    print("Detected Traefik deep-check failure. Attempting auto-remediation...")
    cmd = "docker service update --force traefik_traefik"
    res = execute_remediation(cmd, output_dir=output_dir, current_timestamp=current_timestamp)

    return [{
        "node": "traefik-dmz-01",
        "action": cmd,
        "result": res
    }]


def check_host_cpu_circuit_breaker(hardware_data):
    """
    Check if the hypervisor is under heavy CPU or load contention.
    Returns (can_remediate: bool, reason: str).
    """
    if not hardware_data:
        return True, "No hardware telemetry available."

    metrics = hardware_data.get("metrics", {})
    load_1m = metrics.get("load_1m")
    cpu_steal = metrics.get("cpu_steal_pct", 0.0)

    # 24 hyperthreads on HP DL360p Gen8 (2x Intel Xeon E5-2630)
    if load_1m is not None and load_1m > 24.0:
        return False, f"Host 1m load average ({load_1m:.1f}) exceeds physical hyperthread threshold (24.0)."

    if cpu_steal is not None and cpu_steal > 30.0:
        return False, f"Host CPU steal ({cpu_steal:.1f}%) exceeds hypervisor headroom threshold (30.0%)."

    return True, "Host CPU headroom is healthy."


def get_service_remediation_priority(service_name):
    """
    Dependency-aware priority ordering for service recovery:
    1: Databases / Datastores (Postgres, Mongo, InfluxDB, Redis)
    2: Core Infrastructure (Traefik, Forgejo, Woodpecker, NetBox)
    3: Telemetry & Monitoring (Prometheus, Loki, Alertmanager, Grafana)
    4: Frontends & Dashboards (Homepage, Uptime Kuma, Arr stack)
    """
    name = service_name.lower()
    if any(db in name for db in ["_db", "postgres", "mongo", "influxdb", "redis"]):
        return 1
    if any(core in name for core in ["traefik", "forgejo", "woodpecker", "netbox"]):
        return 2
    if any(mon in name for mon in ["prometheus", "alertmanager", "loki", "grafana", "exporter", "promtail", "cadvisor"]):
        return 3
    return 4


def remediate_degraded_services(degraded_services, hardware_data=None, output_dir=None, current_timestamp=None, max_services=2, stagger_delay=20):
    """
    Restart degraded services with:
    1. Hypervisor CPU circuit breaker.
    2. Dependency-aware priority sorting (Databases first).
    3. Capping at max_services per run (default 2).
    4. Stagger delay (default 20s) between successive service restarts.
    5. Skipping services recently force-updated in the past 2 hours.
    """
    if not degraded_services:
        return []

    services = [s for s in degraded_services if s != "temp-secret-check" and not is_dev_service(s)]
    ignored_dev_services = [s for s in degraded_services if is_dev_service(s)]
    if ignored_dev_services:
        print(f"Skipping auto-remediation for dev services: {ignored_dev_services} (dev nodes/services are managed manually).")

    if not services:
        return []

    # Check hypervisor circuit breaker
    if hardware_data:
        can_remediate, reason = check_host_cpu_circuit_breaker(hardware_data)
        if not can_remediate:
            print(f"⚠️ Circuit Breaker Tripped: Skipping automated service restarts — {reason}")
            return [{
                "node": "swarm-manager",
                "action": "skipped_circuit_breaker",
                "result": f"Circuit breaker tripped: {reason}",
                "service": "all"
            }]

    # Filter out services currently in 2-hour cooldown
    eligible_services = []
    if output_dir and current_timestamp:
        recent_commands = get_remediations_in_last_2_hours(output_dir, current_timestamp)
        for svc in services:
            cmd = f"docker service update -d --force {svc}"
            norm_cmd = normalize_command(cmd)
            is_cooldown = any(normalize_command(rc) == norm_cmd for rc in recent_commands)
            if is_cooldown:
                print(f"Skipped (cooldown): Service '{svc}' was already force-updated in the past 2 hours.")
            else:
                eligible_services.append(svc)
    else:
        eligible_services = services

    if not eligible_services:
        print("No eligible degraded services to remediate (all in 2h cooldown).")
        return []

    # Sort by dependency priority and select top N
    sorted_services = sorted(eligible_services, key=get_service_remediation_priority)
    to_remediate = sorted_services[:max_services]

    print(f"Eligible degraded service(s): {eligible_services}. Selected top {len(to_remediate)} priority target(s): {to_remediate}")

    results = []
    import time
    for idx, svc in enumerate(to_remediate):
        if idx > 0 and stagger_delay > 0:
            print(f"Staggering: waiting {stagger_delay}s before remediating next service '{svc}'...")
            time.sleep(stagger_delay)

        cmd = f"docker service update -d --force {svc}"
        res = execute_remediation(cmd, output_dir=output_dir, current_timestamp=current_timestamp)
        results.append({
            "node": "swarm-manager",
            "action": cmd,
            "result": res,
            "service": svc
        })
    return results


def remediate_high_cpu_steal(hardware_data, output_dir=None, current_timestamp=None):
    """
    If host CPU steal > 30%, safely shut down non-critical dev VMs (206, 207)
    to relieve hypervisor CPU contention on Proxmox VE.
    """
    metrics = hardware_data.get("metrics", {})
    cpu_steal = metrics.get("cpu_steal_pct", 0.0)

    if cpu_steal <= 30.0:
        return []

    print(f"Detected high host CPU steal ({cpu_steal}% > 30%). Evaluating safe dev VM shutdown (206, 207)...")
    pve_vms = get_proxmox_vm_list()
    results = []

    # Dev VMs safe for automated shutdown
    dev_vm_ids = ["206", "207"]
    for vm_name, info in pve_vms.items():
        vmid = str(info.get("vmid", ""))
        status = info.get("status", "")
        if vmid in dev_vm_ids and status == "running":
            cmd = f"qm stop {vmid}"
            res = execute_remediation(cmd, output_dir=output_dir, current_timestamp=current_timestamp)
            results.append({
                "node": f"pve-host (VM {vmid} - {vm_name})",
                "action": cmd,
                "result": res
            })
    return results


def run_ollama(status_data):
    # Build a compact summary of nodes for the prompt
    nodes = status_data.get("domains", {}).get("services", {}).get("nodes", [])
    node_summary = ""
    if nodes:
        down = [n["hostname"] for n in nodes if n["status"] != "Ready"]
        node_summary = f"\nSwarm nodes: {len(nodes)} total, {len(down)} down ({', '.join(down) if down else 'none'})."

    # Hardware & Network summaries
    hw_metrics = status_data.get("domains", {}).get("hardware", {}).get("metrics", {})
    net_nics = status_data.get("domains", {}).get("network", {}).get("synology_nics", {})

    system_prompt = (
        "You are the Homelab Monitor Assistant. You analyze JSON telemetry from backups, services, hardware, and networks.\n"
        "Your task is to identify issues, analyze PVE hardware resourcing, ARC sizing, CPU steal, dual-NIC segregation, suggest non-destructive remediations, and produce a summary.\n"
        "Guidelines:\n"
        "1. PVE Hardware Resourcing & CPU Headroom: Check host load average vs 24-core limit and CPU steal (> 30%). If host is saturated, do NOT recommend mass restarts. Identify whether dev VMs (VM 206/207) or VirtIO-FS / I/O locks are causing CPU starvation.\n"
        "2. ZFS ARC Sizing: Verify ARC size vs target max and cache hit rate (> 80% is healthy). Check host swap zvol usage.\n"
        "3. Dual-NIC Segregation: Verify Synology NIC 1 (10.0.100.20 VLAN 100) handles high-bandwidth media / NFS traffic and NIC 2 (10.0.60.80 VLAN 60) handles management / backups without crossing or dropping traffic.\n"
        "4. Staggered Service Remediation: Recommend AT MOST 2 highest-priority root-cause services. Prioritize datastores/databases (*_db, postgres, mongo, influxdb) before frontend dashboards (homepage, uptime-kuma).\n"
        "5. Output format: You MUST respond with a JSON block followed by a Markdown report.\n\n"
        "Format your response EXACTLY like this:\n"
        "```json\n"
        "{\n"
        "  \"overall_status\": \"Healthy\" | \"Warning\" | \"Critical\",\n"
        "  \"analysis_summary\": \"Conversational summary of health\",\n"
        "  \"remediations\": [\n"
        "     {\"command\": \"docker service update -d --force stackname_servicename\", \"description\": \"Restart degraded service\"},\n"
        "     {\"command\": \"docker restart container_name\", \"description\": \"Restart stuck container\"},\n"
        "     {\"command\": \"qm stop 206\", \"description\": \"Stop dev VM 206 to relieve high CPU steal\"}\n"
        "  ]\n"
        "}\n"
        "```\n"
        "Followed by your detailed Markdown report.\n"
        "Whitelisted remediation commands are:\n"
        "- `restic unlock` (if repository is reported locked)\n"
        "- `docker service update -d --force <service_name>` (if replica counts do not match; max 2 services)\n"
        "- `docker restart <container_name>` (if container status is not running/healthy; whitelisted for `gluetun` and `compose-vpn-transmission-1`)\n"
        "- `qm start <vmid>` (if a non-dev Proxmox VM/Swarm node is stopped; do NOT auto-start dev VMs 206/207 or dev-* nodes)\n"
        "- `qm stop 206` / `qm stop 207` (if host CPU steal > 30% and dev VMs need to be suspended)\n"
        "- `sudo systemctl restart docker` (if a Swarm node VM is running but Docker is unresponsive)\n"
        "- Do not attempt auto-remediation on dev nodes (dev-node-01, dev-runner-01) or dev-* services as they are manually powered on/off when needed.\n"
        "Do not suggest other auto-remediations."
        + node_summary
    )

    user_prompt = f"Telemetry JSON:\n{json.dumps(status_data, indent=2)}"

    payload = {
        "model": OLLAMA_MODEL,
        "messages": [
            {"role": "system", "content": system_prompt},
            {"role": "user", "content": user_prompt}
        ],
        "stream": False
    }

    try:
        r = requests.post(OLLAMA_URL, json=payload, timeout=60)
        r.raise_for_status()
        resp_json = r.json()
        return resp_json.get("message", {}).get("content", "")
    except Exception as e:
        print(f"Ollama connection failed: {e}. Falling back to rule-based parser.")
        return None


def fallback_rule_based_diagnosis(status_data):
    overall = status_data["overall_status"]
    summary = f"Homelab health status is {overall}."
    remediations = []

    # Down nodes
    nodes = status_data.get("domains", {}).get("services", {}).get("nodes", [])
    for node in nodes:
        if node.get("status") != "Ready" and node.get("availability") != "Drain":
            summary += f" Node '{node['hostname']}' is Down."

    # Degraded services
    services_log = status_data["domains"]["services"]["log"]
    if status_data["domains"]["services"]["status"] != "Healthy":
        degraded_services = []
        # Split log to only parse docker service ls output (before degraded details)
        service_ls_part = services_log.split("=== DEGRADED_START ===")[0]
        for line in service_ls_part.split("\n"):
            match = re.search(r"(\d+)/(\d+)", line)
            if match:
                running, desired = match.groups()
                if running != desired:
                    parts = line.split()
                    if len(parts) > 0 and parts[0] != "NAME":
                        svc_name = parts[0]
                        if not is_dev_service(svc_name):
                            degraded_services.append(svc_name)
        for svc in sorted(degraded_services, key=get_service_remediation_priority)[:2]:
            remediations.append({
                "command": f"docker service update -d --force {svc}",
                "description": f"Force update degraded Swarm service {svc}"
            })
            
        # Check compose containers
        for line in services_log.split("\n"):
            if "❌" in line:
                for container in ["gluetun", "compose-vpn-transmission-1"]:
                    if container in line:
                        remediations.append({
                            "command": f"docker restart {container}",
                            "description": f"Restart stuck compose container {container} on media VM"
                        })
    backups_log = status_data["domains"]["backups"]["log"]
    if "locked" in backups_log.lower() or "repository is locked" in backups_log.lower():
        remediations.append({
            "command": "restic unlock",
            "description": "Unlock locked restic repository"
        })

    # High CPU Steal remediation
    hw_metrics = status_data.get("domains", {}).get("hardware", {}).get("metrics", {})
    if hw_metrics.get("cpu_steal_pct", 0.0) > 30.0:
        summary += f" High Host CPU Steal detected ({hw_metrics['cpu_steal_pct']}%)."
        remediations.append({
            "command": "qm stop 206",
            "description": "Stop dev VM 206 to mitigate high CPU steal"
        })

    # D-State tasks
    if hw_metrics.get("d_state_detected"):
        summary += " D-State (I/O wait) tasks detected on host."

    # Synology Dual-NIC
    syn_nics = status_data.get("domains", {}).get("network", {}).get("synology_nics", {})
    for k, v in syn_nics.items():
        if v.get("status") == "DOWN":
            summary += f" Synology interface {v.get('ip')} (VLAN {v.get('vlan')}) is DOWN."

    analysis = {
        "overall_status": overall,
        "analysis_summary": summary,
        "remediations": remediations
    }

    markdown = f"""# Homelab Health Report — {datetime.datetime.now().strftime("%Y-%m-%d %H:%M:%S")}
Overall Status: **{overall}**

## Diagnostics Summary
- **Backups**: {status_data["domains"]["backups"]["status"]}
- **Services**: {status_data["domains"]["services"]["status"]}
- **Hardware**: {status_data["domains"]["hardware"]["status"]}
- **Network**: {status_data["domains"]["network"]["status"]}
"""
    return json.dumps(analysis), markdown


def send_discord_alert(webhook_url, title, summary, details, status):
    if not webhook_url:
        return

    color = 65280  # Green
    if status == "Warning":
        color = 16753920  # Orange
    elif status == "Critical":
        color = 16711680  # Red

    payload = {
        "embeds": [
            {
                "title": title,
                "description": summary,
                "color": color,
                "fields": [
                    {"name": "Detailed Breakdown", "value": details[:1024]}
                ],
                "timestamp": datetime.datetime.now(datetime.timezone.utc).isoformat()
            }
        ]
    }

    try:
        requests.post(webhook_url, json=payload, timeout=5)
    except Exception as e:
        print(f"Failed to send Discord alert: {e}")


def update_obsidian_log(markdown_report):
    try:
        os.makedirs(os.path.dirname(OBSIDIAN_LOG_PATH), exist_ok=True)
        if not os.path.exists(OBSIDIAN_LOG_PATH):
            with open(OBSIDIAN_LOG_PATH, "w", encoding="utf-8") as f:
                f.write("# Homelab Monitoring Logs\n\n")
        with open(OBSIDIAN_LOG_PATH, "a", encoding="utf-8") as f:
            f.write(f"\n\n---\n\n{markdown_report}\n")
        print("Updated Obsidian monitoring log note.")
    except Exception as e:
        print(f"Failed to write to Obsidian note: {e}")


def main():
    parser = argparse.ArgumentParser(description="LLM Diagnoser for Homelab")
    parser.add_argument("--status", required=True, help="Path to status.json")
    parser.add_argument("--remediate", action="store_true", help="Run auto-remediations")
    parser.add_argument("--alerts-webhook", default="", help="Discord Alerts Webhook URL")
    parser.add_argument("--backups-webhook", default="", help="Discord Backups Webhook URL")
    args = parser.parse_args()

    if not os.path.exists(args.status):
        print(f"Status file not found at {args.status}")
        sys.exit(1)

    with open(args.status, "r", encoding="utf-8") as f:
        status_data = json.load(f)

    output_dir = os.path.dirname(args.status)
    current_timestamp = status_data["timestamp"]
    hw_data = status_data.get("domains", {}).get("hardware", {})

    # ── Node Recovery ──────────────────────────────────────────────────────────
    node_remediation_results = []
    nodes = status_data.get("domains", {}).get("services", {}).get("nodes", [])
    if args.remediate and nodes:
        node_remediation_results = remediate_down_nodes(nodes, output_dir=output_dir, current_timestamp=current_timestamp)

    # ── Traefik & Degraded Services Recovery ───────────────────────────────────
    traefik_remediation_results = []
    degraded_services_results = []
    cpu_steal_remediation_results = []
    if args.remediate:
        traefik_data = status_data.get("domains", {}).get("services", {}).get("traefik", {})
        traefik_remediation_results = remediate_traefik_issues(traefik_data, output_dir=output_dir, current_timestamp=current_timestamp)
        
        degraded_services = status_data.get("domains", {}).get("services", {}).get("degraded_services", [])
        degraded_services_results = remediate_degraded_services(
            degraded_services,
            hardware_data=hw_data,
            output_dir=output_dir,
            current_timestamp=current_timestamp,
            max_services=2,
            stagger_delay=20
        )

        # High CPU Steal remediation (dev VM suspensions)
        cpu_steal_remediation_results = remediate_high_cpu_steal(hw_data, output_dir=output_dir, current_timestamp=current_timestamp)

    # ── LLM / Rule-based Diagnosis ─────────────────────────────────────────────
    ollama_output = run_ollama(status_data)

    json_block = None
    markdown_report = ""

    if ollama_output:
        json_match = re.search(r"```json\s*(\{.*?\})\s*```", ollama_output, re.DOTALL)
        if json_match:
            try:
                json_block = json_match.group(1)
                markdown_report = ollama_output[json_match.end():].strip()
            except Exception:
                pass

    if not json_block:
        json_block, markdown_report = fallback_rule_based_diagnosis(status_data)

    try:
        analysis = json.loads(json_block)
    except Exception as e:
        print(f"Failed to parse analysis JSON: {e}")
        analysis = {
            "overall_status": status_data["overall_status"],
            "analysis_summary": "Diagnostics run complete.",
            "remediations": []
        }

    print(f"Analysis Summary: {analysis.get('analysis_summary')}")

    # ── Service-level Remediations (Non-service items like restic or compose) ──
    remediations_run = []
    remediations_list = []
    if args.remediate and analysis.get("remediations"):
        print("Evaluating auto-remediations...")
        for rem in analysis["remediations"]:
            cmd = rem.get("command", "").strip()
            desc = rem.get("description", "")
            if not cmd or "traefik_traefik" in cmd:
                continue
            # Docker service updates are already handled centrally by remediate_degraded_services()
            if "docker service update" in cmd:
                continue
            is_handled = False
            for sr in degraded_services_results:
                if sr.get('action') == cmd:
                    is_handled = True
                    break
            if is_handled:
                continue
            print(f"Remediation suggested: {desc} ({cmd})")
            res = execute_remediation(cmd, output_dir=output_dir, current_timestamp=current_timestamp)
            print(f"Result: {res}")
            remediations_run.append(f"- **Remediation**: `{cmd}` ({desc})\n  **Result**: {res}")
            remediations_list.append({"command": cmd, "description": desc, "result": res})

    # Append node recovery results
    if node_remediation_results:
        for nr in node_remediation_results:
            remediations_run.append(
                f"- **Node Recovery** `{nr['node']}`: `{nr['action']}`\n  **Result**: {nr['result']}"
            )
            remediations_list.append({
                "command": nr["action"],
                "description": f"Node recovery for {nr['node']}",
                "result": nr["result"]
            })

    # Append Traefik recovery results
    if traefik_remediation_results:
        for tr in traefik_remediation_results:
            remediations_run.append(
                f"- **Traefik Recovery** `{tr['node']}`: `{tr['action']}`\n  **Result**: {tr['result']}"
            )
            remediations_list.append({
                "command": tr["action"],
                "description": f"Traefik recovery for {tr['node']}",
                "result": tr["result"]
            })

    # Append degraded services recovery results
    if degraded_services_results:
        for dr in degraded_services_results:
            remediations_run.append(
                f"- **Service Recovery** `{dr['node']}`: `{dr['action']}`\n  **Result**: {dr['result']}"
            )
            remediations_list.append({
                "command": dr["action"],
                "description": f"Service recovery for {dr['service']}",
                "result": dr["result"]
            })

    # Append CPU steal dev VM shutdown results
    if cpu_steal_remediation_results:
        for cr in cpu_steal_remediation_results:
            remediations_run.append(
                f"- **CPU Contention Mitigation** `{cr['node']}`: `{cr['action']}`\n  **Result**: {cr['result']}"
            )
            remediations_list.append({
                "command": cr["action"],
                "description": f"CPU steal mitigation for {cr['node']}",
                "result": cr["result"]
            })

    if remediations_list:
        record_remediations_in_history(output_dir, current_timestamp, remediations_list)

    # ── Obsidian Report ────────────────────────────────────────────────────────
    node_section = ""
    if nodes:
        down_nodes = [n for n in nodes if n["status"] != "Ready"]
        node_section = f"\n### Swarm Nodes\n"
        for n in nodes:
            icon = "✅" if n["status"] == "Ready" else "❌"
            node_section += f"- {icon} **{n['hostname']}**: {n['status']} (Avail: {n['availability']})\n"
        if node_remediation_results:
            node_section += "\n**Node Recovery Actions:**\n"
            for nr in node_remediation_results:
                node_section += f"- `{nr['node']}` → `{nr['action']}`: {nr['result']}\n"
        if traefik_remediation_results:
            node_section += "\n**Traefik Recovery Actions:**\n"
            for tr in traefik_remediation_results:
                node_section += f"- `{tr['node']}` → `{tr['action']}`: {tr['result']}\n"
        if degraded_services_results:
            node_section += "\n**Service Recovery Actions:**\n"
            for dr in degraded_services_results:
                node_section += f"- `{dr['node']}` → `{dr['action']}` (service: `{dr['service']}`): {dr['result']}\n"
        if cpu_steal_remediation_results:
            node_section += "\n**CPU Contention Mitigation Actions:**\n"
            for cr in cpu_steal_remediation_results:
                node_section += f"- `{cr['node']}` → `{cr['action']}`: {cr['result']}\n"

    obsidian_content = f"""## Report — {datetime.datetime.now().strftime("%Y-%m-%d %H:%M:%S")}
Overall Health: **{analysis.get('overall_status')}**

### Summary
{analysis.get('analysis_summary')}
{node_section}
{markdown_report}
"""
    if remediations_run:
        obsidian_content += "\n### Executed Auto-Remediations\n" + "\n".join(remediations_run) + "\n"

    update_obsidian_log(obsidian_content)

    # ── Discord Alerts ─────────────────────────────────────────────────────────
    overall_status = analysis.get("overall_status", status_data["overall_status"])
    had_remediations = bool(remediations_run)

    if overall_status in ["Warning", "Critical"]:
        send_general, reason = should_send_alert(
            output_dir, overall_status, "general_alert_sent", current_timestamp, status_data
        )
        # Always send if remediations were executed
        if had_remediations:
            send_general = True
            reason = "Remediations were executed — forcing alert."

        if send_general:
            print(f"Sending general Discord alert: {reason}")
            node_lines = ""
            if nodes:
                down_nodes = [n["hostname"] for n in nodes if n["status"] != "Ready"]
                if down_nodes:
                    node_lines = f"\n• Down nodes: {', '.join(down_nodes)}"
            details = (
                f"• Backups: {status_data['domains']['backups']['status']}\n"
                f"• Services: {status_data['domains']['services']['status']}\n"
                f"• Hardware: {status_data['domains']['hardware']['status']}\n"
                f"• Network: {status_data['domains']['network']['status']}"
                + node_lines
                + f"\n\n**Insights**: {analysis.get('analysis_summary')}"
            )
            if had_remediations:
                details += "\n\n**Auto-remediations triggered.**"

            send_discord_alert(
                args.alerts_webhook,
                f"[{overall_status.upper()}] Homelab Health Summary",
                analysis.get("analysis_summary"),
                details,
                overall_status
            )
            mark_alert_sent_in_history(output_dir, current_timestamp, "general_alert_sent")
        else:
            print(f"Skipping duplicate general Discord alert for status: {overall_status} — {reason}")

    # ── Backup-specific Discord Alert ──────────────────────────────────────────
    backup_status = status_data["domains"]["backups"]["status"]
    if backup_status in ["Warning", "Critical"] and args.backups_webhook:
        send_backup, reason = should_send_alert(
            output_dir, backup_status, "backup_alert_sent", current_timestamp, status_data
        )
        if had_remediations:
            send_backup = True
            reason = "Remediations were executed — forcing backup alert."

        if send_backup:
            print(f"Sending backup Discord alert: {reason}")
            send_discord_alert(
                args.backups_webhook,
                f"[{backup_status.upper()}] Backup Job Status Alert",
                "Backup health warning or critical status detected.",
                status_data["domains"]["backups"]["log"][:1000],
                backup_status
            )
            mark_alert_sent_in_history(output_dir, current_timestamp, "backup_alert_sent")
        else:
            print(f"Skipping duplicate backups Discord alert — {reason}")

    # ── Uptime Kuma Heartbeat ──────────────────────────────────────────────────
    ping_uptime_kuma_push(overall_status, analysis.get("analysis_summary", "Diagnostics run complete."))


if __name__ == "__main__":
    main()
