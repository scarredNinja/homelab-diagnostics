# Homelab Diagnostics

Standalone health diagnostic, monitoring, and auto-remediation tool suite for homelab services, Proxmox VE hosts, Docker Swarm clusters, hardware, backups, and network infrastructure.

## Overview

`homelab-diagnostics` decouples health checks and status reporting from infrastructure deployment repositories. It provides parallel diagnostic gathers, structured JSON telemetry compilation, LLM-assisted analysis (via Ollama), auto-remediation for known failure modes, Discord alerting, and a web-based status dashboard.

## Repository Structure

```
homelab-diagnostics/
├── config/
│   ├── config.env           # Local environment configuration (secrets, endpoints)
│   └── config.env.example   # Configuration template
├── dashboard/
│   ├── index.html           # Web dashboard user interface
│   ├── app.js               # Dashboard frontend logic
│   └── styles.css           # Modern dashboard styling
├── src/
│   ├── check-homelab-health.sh  # Orchestrator script for parallel checks & remediation
│   ├── diagnose-backups.sh      # Backup status & Restic repo lock checks
│   ├── diagnose-hardware.sh     # Proxmox / SMART / disk / temperature checks
│   ├── diagnose-network.sh      # DNS, latency, gateway reachability checks
│   ├── diagnose-services.sh     # Docker Swarm & Compose service replica checks
│   ├── diagnose-traefik-latency.sh # Traefik proxy latency & routing diagnostic
│   ├── audit-traefik-network.sh    # Network topology & Traefik audit script
│   ├── compile_status.py        # Compiles raw logs into status.json & daily history
│   └── llm-diagnose.py          # Ollama / rule-based AI diagnosis & auto-remediator
├── systemd/
│   ├── homelab-health.service   # Systemd unit file for Linux execution
│   ├── homelab-health.timer     # Systemd timer for periodic (15-min) execution
│   └── install-systemd-timer.sh # Installation script for systemd timer
├── windows/
│   ├── Invoke-HomelabHealth.ps1 # PowerShell wrapper running checks via WSL2
│   ├── Install-HealthTask.ps1   # Task Scheduler installation script for Windows
│   └── README.md                # Detailed Windows setup instructions
└── README.md
```

## Quick Start

### 1. Configuration Setup

Copy the example environment file and configure endpoints:

```bash
cp config/config.env.example config/config.env
# Edit config/config.env with your push monitor URLs, Ollama endpoint, etc.
```

### 2. Manual Execution

Run full health diagnostics with auto-remediation enabled:

```bash
bash src/check-homelab-health.sh --remediate
```

Run diagnostic without auto-remediation:

```bash
bash src/check-homelab-health.sh
```

### 3. Automated Scheduling

#### Linux (`systemd` timer)

```bash
bash systemd/install-systemd-timer.sh
```

#### Windows (Task Scheduler + WSL2)

Refer to [windows/README.md](windows/README.md) for complete instructions:

```powershell
powershell -ExecutionPolicy Bypass -File "C:\Users\DJ\source\repos\homelab-diagnostics\windows\Install-HealthTask.ps1"
```

## Dashboard Setup

The `dashboard/` directory contains static web files (`index.html`, `app.js`, `styles.css`) that render real-time and historical health data compiled into `STATUS_DATA_DIR` (e.g., `status.json` and `history-YYYY-MM-DD.json`). Point any static web server (such as Nginx, Caddy, or Python `http.server`) to serve the status data and dashboard UI.
