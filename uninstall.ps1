# =============================================================================
#  git看门狗 (github-watchdog) — uninstaller
#  Removes autostart, stops the proxy, clears the PAC + proxy env vars.
#  Usage:  powershell -NoProfile -ExecutionPolicy Bypass -File uninstall.ps1
# =============================================================================
$ErrorActionPreference = 'Continue'
$BASE = $PSScriptRoot
$REGKEY = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Internet Settings'
$SU = Join-Path $env:APPDATA 'Microsoft\Windows\Start Menu\Programs\Startup'

Write-Host '[*] stopping watchdog + mitmdump' -ForegroundColor Cyan
Get-CimInstance Win32_Process -Filter "Name='powershell.exe'" |
    Where-Object { $_.CommandLine -like '*watchdog.ps1*' } |
    ForEach-Object { Stop-Process -Id $_.ProcessId -Force -ErrorAction SilentlyContinue }
Get-Process mitmdump -ErrorAction SilentlyContinue | Stop-Process -Force -ErrorAction SilentlyContinue

Write-Host '[*] removing autostart' -ForegroundColor Cyan
Remove-ItemProperty -Path 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Run' -Name 'GithubHostsWatchdog' -ErrorAction SilentlyContinue
Remove-Item (Join-Path $SU 'github-hosts-watchdog.vbs') -Force -ErrorAction SilentlyContinue
schtasks /Delete /TN GithubHostsWatchdogLogon /F 2>&1 | Out-Null
schtasks /Delete /TN GithubHostsGuard /F 2>&1 | Out-Null
schtasks /Delete /TN GithubHostsMeiSweep /F 2>&1 | Out-Null
schtasks /Delete /TN GithubHostsUpdateIPs /F 2>&1 | Out-Null

Write-Host '[*] clearing PAC + proxy env vars' -ForegroundColor Cyan
Remove-ItemProperty -Path $REGKEY -Name 'AutoConfigURL' -ErrorAction SilentlyContinue
New-ItemProperty -Path $REGKEY -Name 'ProxyEnable' -Value 0 -PropertyType DWord -Force | Out-Null
foreach ($v in @('HTTP_PROXY', 'HTTPS_PROXY', 'http_proxy', 'https_proxy')) {
    [Environment]::SetEnvironmentVariable($v, $null, 'User')
}
Remove-Item (Join-Path $BASE '.paused') -Force -ErrorAction SilentlyContinue
Remove-Item (Join-Path $BASE '.restarting') -Force -ErrorAction SilentlyContinue

Write-Host ''
Write-Host 'Done. The mitmproxy CA is still trusted (remove it manually if you want):' -ForegroundColor Gray
Write-Host '  certutil -user -delstore Root <thumbprint>   (see ~\.mitmproxy\mitmproxy-ca-cert.cer)' -ForegroundColor Gray
Write-Host 'Git global http.proxy (if set by you) can be removed with:' -ForegroundColor Gray
Write-Host '  git config --global --unset http.proxy' -ForegroundColor Gray
