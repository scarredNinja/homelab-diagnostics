#!/usr/bin/env python3
# automation/diagnostics/compile_status.py
import sys
import json
import os
import datetime
import re


def parse_log(file_path):
    if not os.path.exists(file_path):
        return "Log file not found.", "Unknown"
    with open(file_path, "r", encoding="utf-8") as f:
        content = f.read().strip()

    # Determine basic status by looking at log patterns
    status = "Healthy"
    content_lower = content.lower()
    
    # Check for warnings: word-boundary match for error, fail, locked!, degraded, or ❌ symbol
    content_clean = content_lower.replace("smart check failed or not supported", "smart check not supported")
    has_error = re.search(r"\berror\b", content_clean) is not None
    has_fail = re.search(r"\bfaile?[sd]?\b", content_clean) is not None
    
    # Exclude "0 failed" from triggering failure warnings if no other failures exist
    if has_fail and "0 failed" in content_lower:
        fail_occurrences = len(re.findall(r"\bfaile?[sd]?\b", content_lower))
        zero_fail_occurrences = content_lower.count("0 failed")
        if fail_occurrences <= zero_fail_occurrences:
            has_fail = False
            
    has_warning_indicators = "❌" in content or "locked!" in content_lower or "degraded" in content_lower
    
    if has_error or has_fail or has_warning_indicators:
        status = "Warning"
        
    has_critical = re.search(r"\bcritical\b", content_lower) is not None
    has_down = re.search(r"\bdown\b", content_lower) is not None
    
    if has_critical or has_down:
        if "❌" in content or "[down]" in content_lower or has_fail:
            status = "Critical"

    return content, status

def parse_node_statuses(services_log):
    """Extract Swarm node statuses from the NODES_START/NODES_END block."""
    nodes = []
    match = re.search(r"=== NODES_START ===\n(.*?)\n=== NODES_END ===", services_log, re.DOTALL)
    if not match:
        return nodes

    block = match.group(1).strip()
    for line in block.splitlines():
        line = line.strip()
        if not line:
            continue
        parts = line.split("\t")
        if len(parts) >= 3:
            hostname = parts[0]
            status = parts[1]
            availability = parts[2]
            manager_status = parts[3] if len(parts) > 3 else ""
            nodes.append({
                "hostname": hostname,
                "status": status,
                "availability": availability,
                "manager_status": manager_status
            })
    return nodes

def parse_degraded_services(services_log):
    """Extract degraded services from the service logs."""
    degraded = []
    # Look for lines in the replica status table (e.g. "service_name  replicated  0/1 ...")
    # Skip header lines or lines starting with special characters
    lines = services_log.splitlines()
    in_table = False
    for line in lines:
        if "=== DEGRADED_START ===" in line:
            break
        if "running vs desired replicas" in line:
            in_table = True
            continue
        if in_table and line.strip() and not line.startswith("===") and not line.startswith("NAME"):
            parts = line.split()
            if len(parts) >= 2:
                name = parts[0]
                replicas = parts[1]
                if "/" in replicas:
                    try:
                        running, desired = map(int, replicas.split("/"))
                        if running < desired:
                            degraded.append(name)
                    except ValueError:
                        pass
    return degraded

def parse_traefik_status(services_log):
    """Parse Traefik deep-check markers from the services log."""
    proxy_down = "=== TRAEFIK_PROXY_DOWN ===" in services_log
    no_swarm_routes = "=== TRAEFIK_NO_SWARM_ROUTES ===" in services_log
    backend_net_missing = "=== TRAEFIK_BACKEND_NET_MISSING ===" in services_log

    # If proxy is down, backend net is missing, or we have 0 swarm routes, Traefik needs a remediation restart/update.
    needs_redeploy = proxy_down or no_swarm_routes or backend_net_missing

    # Extract swarm routes count if present in the logs
    routes_match = re.search(r"TRAEFIK_ROUTES: (\d+) swarm-provider route", services_log)
    swarm_routes_count = int(routes_match.group(1)) if routes_match else None

    return {
        "proxy_reachable": not proxy_down,
        "swarm_routes_count": swarm_routes_count,
        "backend_net_ok": not backend_net_missing,
        "needs_redeploy": needs_redeploy
    }
def main():
    if len(sys.argv) < 6:
        print("Usage: compile_status.py <backup_log> <services_log> <hardware_log> <network_log> <output_json>")
        sys.exit(1)

    backup_log_path = sys.argv[1]
    services_log_path = sys.argv[2]
    hardware_log_path = sys.argv[3]
    network_log_path = sys.argv[4]
    output_json_path = sys.argv[5]

    backup_content, backup_status = parse_log(backup_log_path)
    services_content, services_status = parse_log(services_log_path)
    hardware_content, hardware_status = parse_log(hardware_log_path)
    network_content, network_status = parse_log(network_log_path)
    
    # Parse Swarm node statuses from services log
    nodes = parse_node_statuses(services_content)
    has_down_nodes = any(
        n["status"] != "Ready" and n["availability"] != "Drain"
        for n in nodes
    )
    if has_down_nodes and services_status != "Critical":
        services_status = "Critical"
        print(f"Escalating services status to Critical: {len([n for n in nodes if n['status'] != 'Ready'])} node(s) are Down.")

    # Parse degraded services
    degraded_services = parse_degraded_services(services_content)
    if degraded_services and services_status == "Healthy":
        services_status = "Warning"
        print(f"Escalating services status to Warning: {len(degraded_services)} degraded service(s) detected.")

    # Parse Traefik health status
    traefik_data = parse_traefik_status(services_content)
    if traefik_data["needs_redeploy"] and services_status != "Critical":
        services_status = "Critical"
        print("Escalating services status to Critical: Traefik deep-check failure detected.")
    # Determine overall status
    overall_status = "Healthy"
    statuses = [backup_status, services_status, hardware_status, network_status]
    if "Critical" in statuses:
        overall_status = "Critical"
    elif "Warning" in statuses:
        overall_status = "Warning"

    status_data = {
        "timestamp": datetime.datetime.now().isoformat(),
        "overall_status": overall_status,
        "domains": {
            "backups": {
                "status": backup_status,
                "log": backup_content
            },
            "services": {
                "status": services_status,
                "log": services_content,
                "nodes": nodes,
                "degraded_services": degraded_services,
                "traefik": traefik_data
            },
            "hardware": {
                "status": hardware_status,
                "log": hardware_content
            },
            "network": {
                "status": network_status,
                "log": network_content
            }
        }
    }

    # Make sure output directory exists
    output_dir = os.path.dirname(output_json_path)
    os.makedirs(output_dir, exist_ok=True)
    with open(output_json_path, "w", encoding="utf-8") as f:
        json.dump(status_data, f, indent=2)

    print(f"Compiled status.json successfully at: {output_json_path} (Overall: {overall_status})")
    # Maintain daily split history files (history-YYYY-MM-DD.json)
    date_str = datetime.datetime.now().strftime("%Y-%m-%d")
    history_file = os.path.join(output_dir, f"history-{date_str}.json")
    history_data = []
    if os.path.exists(history_file):
        try:
            with open(history_file, "r", encoding="utf-8") as f:
                history_data = json.load(f)
        except Exception:
            history_data = []

    history_entry = {
        "timestamp": status_data["timestamp"],
        "overall_status": overall_status,
        "domains": {
            "backups": backup_status,
            "services": services_status,
            "hardware": hardware_status,
            "network": network_status
        },
        "nodes": nodes,
        "degraded_services": degraded_services,
        # Alert-sent flags — set to False initially; llm-diagnose.py updates these
        # after successfully dispatching a Discord notification.
        "general_alert_sent": False,
        "backup_alert_sent": False
    }

    history_data.append(history_entry)

    with open(history_file, "w", encoding="utf-8") as f:
        json.dump(history_data, f, indent=2)
    print(f"Updated history-{date_str}.json ({len(history_data)} entries stored).")

if __name__ == "__main__":
    main()
