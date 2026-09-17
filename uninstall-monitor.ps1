# =============================================================================
#  git看门狗 2.0A - stop and remove autostart.
# =============================================================================
$ErrorActionPreference = 'Continue'
Get-CimInstance Win32_Process -Filter "Name='powershell.exe'" |
    Where-Object { $_.CommandLine -like '*-File*monitor.ps1*' -and $_.CommandLine -notlike '*-Command*' } |
    ForEach-Object { Stop-Process -Id $_.ProcessId -Force -ErrorAction SilentlyContinue }
Remove-ItemProperty -Path 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Run' -Name 'GithubHostsMonitor' -ErrorAction SilentlyContinue
schtasks /Delete /TN GithubHostsMonitorLogon /F 2>&1 | Out-Null
Write-Host '[OK] monitor stopped and autostart removed'
