# automation/windows/Invoke-HomelabHealth.ps1
#
# Runs the homelab health check orchestrator inside WSL2.
# Called by the Windows Task Scheduler every 15 minutes.
#
# Usage (manual run):
#   powershell -NonInteractive -ExecutionPolicy Bypass -File "C:\Users\DJ\source\repos\docker-swarm-home\automation\windows\Invoke-HomelabHealth.ps1"

param(
    [switch]$NoRemediate
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

# --- Config ---
$RepoRoot    = "C:\Users\DJ\source\repos\homelab-diagnostics"
$LogDir      = Join-Path $RepoRoot "logs"
$Timestamp   = Get-Date -Format "yyyy-MM-dd_HH-mm"
$LogFile     = Join-Path $LogDir "homelab-health-$Timestamp.log"

# WSL path to the repo (via /mnt/c mount)
$WslRepoRoot = "/mnt/c/Users/DJ/source/repos/homelab-diagnostics"
$WslScript   = "$WslRepoRoot/src/check-homelab-health.sh"

# --- Ensure log directory exists ---
if (-not (Test-Path $LogDir)) {
    New-Item -ItemType Directory -Path $LogDir -Force | Out-Null
}

# --- Build remediate flag ---
$RemediateArg = if ($NoRemediate) { "" } else { "--remediate" }

Write-Host "[$Timestamp] Starting homelab health check via WSL2..." -ForegroundColor Cyan
Write-Host "Log: $LogFile" -ForegroundColor DarkGray

# --- Check WSL is available ---
$wslExe = Get-Command wsl.exe -ErrorAction SilentlyContinue
if (-not $wslExe) {
    Write-Error "wsl.exe not found. Please enable WSL2 on this machine."
    exit 1
}

# --- Run in WSL ---
# We explicitly override HOME to prevent Windows environment pollution (WSL inherits Windows environment variables like HOME).
$WslCommand = 'export HOME=$(getent passwd $(whoami) | cut -d: -f6); cd "' + $WslRepoRoot + '" && bash "' + $WslScript + '" ' + $RemediateArg
$WslCommand = $WslCommand.Trim()

$output = wsl.exe bash -c $WslCommand 2>&1

# --- Write to log ---
$header = @"
=======================================================
 Homelab Health Check — $Timestamp
 Command: $WslCommand
=======================================================

"@

$logContent = $header + ($output -join "`n")
$logContent | Out-File -FilePath $LogFile -Encoding UTF8

# --- Print to console ---
$output | ForEach-Object { Write-Host $_ }

# --- Rotate old logs (keep last 14 days) ---
Get-ChildItem -Path $LogDir -Filter "homelab-health-*.log" -ErrorAction SilentlyContinue |
    Where-Object { $_.LastWriteTime -lt (Get-Date).AddDays(-14) } |
    Remove-Item -Force

Write-Host ""
Write-Host "[$Timestamp] Health check complete. Log: $LogFile" -ForegroundColor Green
