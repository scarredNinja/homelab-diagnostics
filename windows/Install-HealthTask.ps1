# automation/windows/Install-HealthTask.ps1
#
# Registers the homelab health check as a Windows Task Scheduler job.
# Run once as Administrator (or a user with Task Scheduler access).
#
# Usage:
#   powershell -ExecutionPolicy Bypass -File "...\automation\windows\Install-HealthTask.ps1"
#
# To uninstall:
#   Unregister-ScheduledTask -TaskName "HomelabHealthCheck" -Confirm:$false

#Requires -Version 5.1

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

# Verify running as Administrator
$currentPrincipal = [Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()
if (-not $currentPrincipal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
    Write-Error "This script must be run as Administrator. Right-click PowerShell and select 'Run as Administrator'."
    exit 1
}

$TaskName   = "HomelabHealthCheck"
$TaskFolder = "\Homelab"
$ScriptPath = "C:\Users\DJ\source\repos\homelab-diagnostics\windows\Invoke-HomelabHealth.ps1"

# Resolve shell path (prefer PowerShell 7, fall back to Windows PowerShell 5.1)
$pwsh7 = Get-Command pwsh -ErrorAction SilentlyContinue
if ($pwsh7) {
    $PwshPath = $pwsh7.Source
} else {
    $ps5 = Get-Command powershell -ErrorAction SilentlyContinue
    if ($ps5) {
        $PwshPath = $ps5.Source
    } else {
        Write-Error "Neither pwsh nor powershell.exe was found on PATH."
        exit 1
    }
}

Write-Host "Using shell: $PwshPath" -ForegroundColor DarkGray

# --- Trigger: every 1 hour, all day ---
$trigger = New-ScheduledTaskTrigger -RepetitionInterval (New-TimeSpan -Hours 1) -Once -At (Get-Date -Hour 0 -Minute 0 -Second 0)

# --- Action: run Invoke-HomelabHealth.ps1 non-interactively ---
$action = New-ScheduledTaskAction -Execute $PwshPath -Argument ("-NonInteractive -ExecutionPolicy Bypass -File `"" + $ScriptPath + "`"")

# --- Settings ---
$settings = New-ScheduledTaskSettingsSet -ExecutionTimeLimit (New-TimeSpan -Minutes 10) -StartWhenAvailable -RunOnlyIfNetworkAvailable -MultipleInstances IgnoreNew

# --- Principal: run as current user, only when logged in ---
$principal = New-ScheduledTaskPrincipal -UserId ([System.Security.Principal.WindowsIdentity]::GetCurrent().Name) -LogonType Interactive -RunLevel Highest

# --- Register (or update if already exists) ---
$fullPath = "$TaskFolder\$TaskName"

if (Get-ScheduledTask -TaskPath "$TaskFolder\" -TaskName $TaskName -ErrorAction SilentlyContinue) {
    Write-Host "Task '$fullPath' already exists - updating..." -ForegroundColor Yellow
    Set-ScheduledTask -TaskPath "$TaskFolder\" -TaskName $TaskName -Action $action -Trigger $trigger -Settings $settings -Principal $principal
} else {
    Write-Host "Registering new task '$fullPath'..." -ForegroundColor Cyan
    Register-ScheduledTask -TaskPath "$TaskFolder\" -TaskName $TaskName -Action $action -Trigger $trigger -Settings $settings -Principal $principal -Description "Runs homelab diagnostics via WSL2 every 1 hour and syncs status dashboard."
}

Write-Host ""
Write-Host "Task registered successfully." -ForegroundColor Green
Write-Host "  Path:    $fullPath" -ForegroundColor DarkGray
Write-Host "  Trigger: Every 1 hour" -ForegroundColor DarkGray
Write-Host "  Action:  $PwshPath -File `"$ScriptPath`"" -ForegroundColor DarkGray
Write-Host ""
Write-Host "To test immediately:" -ForegroundColor Cyan
Write-Host "  Start-ScheduledTask -TaskPath '$TaskFolder\' -TaskName '$TaskName'" -ForegroundColor White
Write-Host ""
Write-Host "To view in the UI: taskschd.msc -> Task Scheduler Library -> Homelab" -ForegroundColor DarkGray
