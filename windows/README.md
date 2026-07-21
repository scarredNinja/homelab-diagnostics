# Windows Setup — Homelab Health Service

Runs the homelab health check suite on a 15-minute schedule using **WSL2** and **Windows Task Scheduler**, replacing the Linux `systemd` timer.

## Architecture

```
Task Scheduler (every 15 min)
  └─ Invoke-HomelabHealth.ps1        # PowerShell wrapper (this machine)
       └─ wsl.exe bash check-homelab-health.sh --remediate
            ├─ diagnose-*.sh         # SSH → Proxmox / Swarm manager
            ├─ compile_status.py     # Writes status.json + history.json
            ├─ llm-diagnose.py       # Hits Ollama on Windows host
            └─ status dashboard data output
```

## One-Time Setup

### 1. Copy SSH key into WSL

The bash scripts need `~/.ssh/homelab_ed25519` inside WSL. Copy it from Windows:

```bash
# In WSL terminal
mkdir -p ~/.ssh
cp /mnt/c/Users/DJ/.ssh/homelab_ed25519 ~/.ssh/homelab_ed25519
cp /mnt/c/Users/DJ/.ssh/homelab_ed25519.pub ~/.ssh/homelab_ed25519.pub
chmod 600 ~/.ssh/homelab_ed25519
chmod 644 ~/.ssh/homelab_ed25519.pub
```

### 2. Install Python dependencies in WSL

```bash
# In WSL terminal
pip3 install requests
# Or if pip is not available:
sudo apt install python3-requests
```

### 3. Verify Ollama is reachable from WSL

`config/config.env` sets `OLLAMA_URL=http://host.docker.internal:11434` which points to the Windows Ollama instance.

```bash
# Test from WSL
curl http://host.docker.internal:11434/api/tags
```

If that fails, find the Windows host IP from WSL with:
```bash
cat /etc/resolv.conf | grep nameserver
```
And update `OLLAMA_URL` in `config/config.env` accordingly.

### 4. Test the wrapper manually

```powershell
# In a PowerShell terminal (no admin needed for manual runs)
powershell -ExecutionPolicy Bypass -File "C:\Users\DJ\source\repos\homelab-diagnostics\windows\Invoke-HomelabHealth.ps1"
```

Check `logs/` for the timestamped log output.

### 5. Register the Task Scheduler job

```powershell
# Run PowerShell as Administrator
powershell -ExecutionPolicy Bypass -File "C:\Users\DJ\source\repos\homelab-diagnostics\windows\Install-HealthTask.ps1"
```

The task appears at: **Task Scheduler Library → Homelab → HomelabHealthCheck**

### 6. Trigger a test run via Task Scheduler

```powershell
Start-ScheduledTask -TaskPath "\Homelab\" -TaskName "HomelabHealthCheck"
```

Then verify `status.home.purvishome.com` updates.

## Log Files

Logs are written to `logs/homelab-health-<timestamp>.log` and rotated after 14 days.

## Uninstall

```powershell
Unregister-ScheduledTask -TaskPath "\Homelab\" -TaskName "HomelabHealthCheck" -Confirm:$false
```

