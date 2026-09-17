# =============================================================================
#  git看门狗 2.0A - install as autostart (Run key + logon task). No proxy/CA changes.
# =============================================================================
$ErrorActionPreference = 'Continue'
$BASE = $PSScriptRoot
$VBS = Join-Path $BASE 'monitor-launcher.vbs'

New-ItemProperty -Path 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Run' -Name 'GithubHostsMonitor' `
    -Value ('wscript.exe "' + $VBS + '"') -PropertyType String -Force | Out-Null
Write-Host '[OK] Run key GithubHostsMonitor registered'

try {
    $action = New-ScheduledTaskAction -Execute 'wscript.exe' -Argument ('"' + $VBS + '"')
    $trigger = New-ScheduledTaskTrigger -AtLogOn -User $env:USERNAME
    $settings = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries `
        -ExecutionTimeLimit ([TimeSpan]::Zero) -MultipleInstances IgnoreNew `
        -RestartCount 999 -RestartInterval (New-TimeSpan -Minutes 1) -StartWhenAvailable
    Register-ScheduledTask -TaskName 'GithubHostsMonitorLogon' -Action $action -Trigger $trigger -Settings $settings -Force | Out-Null
    Write-Host '[OK] logon task GithubHostsMonitorLogon registered (auto-restart on failure)'
} catch { Write-Host ('[!] logon task not registered: ' + $_.Exception.Message) }

Start-Process -FilePath 'wscript.exe' -ArgumentList ('"' + $VBS + '"') -WindowStyle Hidden
Write-Host '[OK] monitor started'
