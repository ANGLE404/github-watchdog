# =============================================================================
#  git看门狗 (github-watchdog) - installer
#  Usage (normal user, no admin needed):
#     powershell -NoProfile -ExecutionPolicy Bypass -File install.ps1
# =============================================================================
$ErrorActionPreference = 'Continue'
$BASE = $PSScriptRoot
$LAUNCH = Join-Path $BASE 'mitmdump-run.cmd'
$VBS = Join-Path $BASE 'watchdog-launcher.vbs'
$GUARD = Join-Path $BASE 'guard.ps1'
$SELF = Join-Path $BASE 'selfcheck.ps1'
$REGKEY = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Internet Settings'
$PAC = 'http://127.0.0.1:8180/proxy.pac'
$SU = Join-Path $env:APPDATA 'Microsoft\Windows\Start Menu\Programs\Startup'

function Info($m) { Write-Host "[*] $m" -ForegroundColor Cyan }
function Ok($m)   { Write-Host "[OK] $m" -ForegroundColor Green }
function Warn($m) { Write-Host "[!] $m" -ForegroundColor Yellow }
function Err($m)  { Write-Host "[X] $m" -ForegroundColor Red }

function Test-Port {
    try {
        $c = New-Object System.Net.Sockets.TcpClient
        $ar = $c.BeginConnect('127.0.0.1', 8180, $null, $null)
        $ok = $ar.AsyncWaitHandle.WaitOne(1500, $false)
        if ($ok) { $c.EndConnect($ar) }
        $c.Close(); return $ok
    } catch { return $false }
}

Write-Host ''
Write-Host '==============================================' -ForegroundColor White
Write-Host '   git-watchdog installer' -ForegroundColor White
Write-Host '==============================================' -ForegroundColor White

Info '1/6 locating mitmdump'
$exe = Join-Path $BASE 'bin\mitmdump.exe'
if (Test-Path $exe) {
    Ok "using bundled $exe"
} elseif (Get-Command mitmdump -ErrorAction SilentlyContinue) {
    Ok 'mitmdump found on PATH'
} else {
    Warn 'mitmdump not found - trying: pip install mitmproxy'
    $pip = Get-Command pip -ErrorAction SilentlyContinue
    $py  = Get-Command python -ErrorAction SilentlyContinue
    if ($pip) { & pip install --user mitmproxy }
    elseif ($py) { & python -m pip install --user mitmproxy }
    else { Err 'neither pip nor python is available.' }
    if (Get-Command mitmdump -ErrorAction SilentlyContinue) { Ok 'mitmdump is now available' }
    else {
        Err 'Could not obtain mitmdump automatically.'
        Write-Host '      a) pip install mitmproxy      (then re-run this installer)'
        Write-Host "      b) put a mitmdump.exe at: $exe"
        exit 1
    }
}

Info '2/6 preparing CA certificate'
$cer = Join-Path $HOME '.mitmproxy\mitmproxy-ca-cert.cer'
if (-not (Test-Path $cer)) {
    Start-Process -FilePath 'cmd.exe' -ArgumentList '/c', $LAUNCH -WindowStyle Hidden
    $deadline = (Get-Date).AddSeconds(30)
    while ((Get-Date) -lt $deadline -and -not (Test-Path $cer)) { Start-Sleep -Seconds 1 }
}
if (Test-Path $cer) {
    $x = New-Object System.Security.Cryptography.X509Certificates.X509Certificate2($cer)
    $tp = $x.Thumbprint
    if (Test-Path "Cert:\CurrentUser\Root\$tp") {
        Ok 'mitmproxy CA already trusted'
    } else {
        $store = New-Object System.Security.Cryptography.X509Certificates.X509Store('Root', 'CurrentUser')
        $store.Open('ReadWrite')
        $store.Add($x)
        $store.Close()
        if (Test-Path "Cert:\CurrentUser\Root\$tp") { Ok 'mitmproxy CA installed into CurrentUser\Root' }
        else { Warn 'could not verify CA install - browsers may warn; see README' }
    }
} else {
    Warn 'CA cert not generated yet (mitmdump may still be starting)'
}

Info '3/6 setting PAC system proxy'
New-ItemProperty -Path $REGKEY -Name 'AutoConfigURL' -Value $PAC -PropertyType String -Force | Out-Null
New-ItemProperty -Path $REGKEY -Name 'ProxyEnable' -Value 0 -PropertyType DWord -Force | Out-Null
foreach ($v in @('HTTP_PROXY', 'HTTPS_PROXY', 'http_proxy', 'https_proxy')) {
    [Environment]::SetEnvironmentVariable($v, 'http://127.0.0.1:8180', 'User')
}
Ok "AutoConfigURL = $PAC"

Info '4/6 registering autostart (3 layers)'
New-ItemProperty -Path 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Run' -Name 'GithubHostsWatchdog' -Value ('wscript.exe "' + $VBS + '"') -PropertyType String -Force | Out-Null
Ok 'Run key registered'

$suVbs = Join-Path $SU 'github-hosts-watchdog.vbs'
$vbsText = "' git-watchdog autostart" + "`r`n" + 'Set shell = CreateObject("WScript.Shell")' + "`r`n" + 'shell.Run "wscript.exe ""' + $VBS + '""", 0, False' + "`r`n"
Set-Content -Path $suVbs -Value $vbsText -Encoding ASCII
Ok "Startup folder entry: $suVbs"

try {
    $action = New-ScheduledTaskAction -Execute 'wscript.exe' -Argument ('"' + $VBS + '"')
    $trigger = New-ScheduledTaskTrigger -AtLogOn -User $env:USERNAME
    $settings = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries -ExecutionTimeLimit ([TimeSpan]::Zero) -MultipleInstances IgnoreNew
    Register-ScheduledTask -TaskName 'GithubHostsWatchdogLogon' -Action $action -Trigger $trigger -Settings $settings -Force | Out-Null
    Ok 'logon task registered'
} catch { Warn "logon task not registered: $($_.Exception.Message)" }

Info '5/6 registering deep guard (every 15 min)'
try {
    $gAction = New-ScheduledTaskAction -Execute 'powershell.exe' -Argument ('-NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File "' + $GUARD + '"')
    $gSet = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries -MultipleInstances IgnoreNew -ExecutionTimeLimit (New-TimeSpan -Minutes 15) -StartWhenAvailable
    $gLogon = New-ScheduledTaskTrigger -AtLogOn -User $env:USERNAME
    $gRep = New-ScheduledTaskTrigger -Once -At (Get-Date).AddMinutes(2) -RepetitionInterval (New-TimeSpan -Minutes 15) -RepetitionDuration (New-TimeSpan -Days 3650)
    Register-ScheduledTask -TaskName 'GithubHostsGuard' -Action $gAction -Trigger @($gLogon, $gRep) -Settings $gSet -Force | Out-Null
    Ok 'guard task registered'
} catch { Warn "guard task not registered: $($_.Exception.Message)" }

Info '6/6 starting watchdog'
Start-Process -FilePath 'wscript.exe' -ArgumentList ('"' + $VBS + '"') -WindowStyle Hidden
Start-Sleep -Seconds 8
if (Test-Port) { Ok 'mitmdump is listening on 127.0.0.1:8180' } else { Warn 'port 8180 not listening yet' }

Write-Host ''
Write-Host 'Done. Running self-check...' -ForegroundColor White
& powershell -NoProfile -ExecutionPolicy Bypass -File $SELF