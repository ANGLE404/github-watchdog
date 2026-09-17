# =============================================================================
#  git看门狗 (github-watchdog) — watchdog
#  - keeps mitmdump alive: process exists AND 127.0.0.1:8180 accepts TCP
#  - 30s startup grace period so a booting mitmdump is never mistaken for a zombie
#  - keeps the PAC system proxy + CLI proxy env vars in place
#  - forces browsers to re-read the PAC (Chromium ignores same-value rewrites);
#    nudges on startup and every 5 min, and notifies on every (re)application
#  - honours the ".paused" sentinel (tear down + idle)
#  - logs: watchdog.log (rotated at 2 MB), mitmdump.log
# =============================================================================
$ErrorActionPreference = 'Continue'
$BASE   = $PSScriptRoot
$CMDLAUNCH = Join-Path $BASE 'mitmdump-run.cmd'
$LOG    = Join-Path $BASE 'watchdog.log'
$PAUSED = Join-Path $BASE '.paused'
$REGKEY = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Internet Settings'
$PAC    = 'http://127.0.0.1:8180/proxy.pac'
$PORT   = 8180
$GRACE  = 30   # seconds a freshly started mitmdump is allowed to still be booting
$TICK   = 5
$NUDGE  = 300  # seconds between forced proxy re-reads (see Invoke-ProxyNudge)

# ---- single-instance guard ---------------------------------------------------
$mutex = New-Object System.Threading.Mutex($false, 'Local\GithubHostsWatchdog')
$acquired = $false
try { $acquired = $mutex.WaitOne(0) }
catch [System.Threading.AbandonedMutexException] { $acquired = $true }
if (-not $acquired) { exit }

# ---- WinINET notification (no admin needed) ----------------------------------
# Chromium only re-reads the system proxy when the AutoConfigURL string actually
# changes; InternetSetOption alone is not enough. Some processes also clear the
# key behind our back. Nudging (a fragment-only change, invisible to the PAC
# server) forces every running browser to refetch and re-apply the PAC.
Add-Type -TypeDefinition @'
using System;
using System.Runtime.InteropServices;
public static class WinInetNotify {
    [DllImport("wininet.dll", SetLastError=true, CharSet=CharSet.Auto)]
    public static extern bool InternetSetOption(IntPtr hInternet, int dwOption, IntPtr lpBuffer, int dwBufferLength);
}
'@ -ErrorAction SilentlyContinue

function Invoke-ProxyNotify {
    try {
        [WinInetNotify]::InternetSetOption([IntPtr]::Zero, 39, [IntPtr]::Zero, 0) | Out-Null
        [WinInetNotify]::InternetSetOption([IntPtr]::Zero, 37, [IntPtr]::Zero, 0) | Out-Null
    } catch { }
}

function Get-CurrentPac {
    try { return (Get-ItemProperty -Path $REGKEY -Name 'AutoConfigURL' -ErrorAction Stop).AutoConfigURL }
    catch { return $null }
}

function Invoke-ProxyNudge {
    # fragment-only change: the PAC server still sees path /proxy.pac
    try {
        $gen = [DateTimeOffset]::Now.ToUnixTimeSeconds()
        New-ItemProperty -Path $REGKEY -Name 'AutoConfigURL' -Value ($PAC + '#n' + $gen) -PropertyType String -Force | Out-Null
        Invoke-ProxyNotify
        Start-Sleep -Milliseconds 400
        New-ItemProperty -Path $REGKEY -Name 'AutoConfigURL' -Value $PAC -PropertyType String -Force | Out-Null
        Invoke-ProxyNotify
        Write-Log 'PAC nudged (forced proxy re-read)'
    } catch { }
}

function Write-Log([string]$msg) {
    try {
        if ((Test-Path $LOG) -and ((Get-Item $LOG).Length -gt 2MB)) { Remove-Item $LOG -Force -ErrorAction SilentlyContinue }
        Add-Content -Path $LOG -Value ((Get-Date).ToString('yyyy-MM-dd HH:mm:ss') + '  ' + $msg) -Encoding UTF8
    } catch { }
}

function Test-ProxyPort {
    try {
        $client = New-Object System.Net.Sockets.TcpClient
        $async  = $client.BeginConnect('127.0.0.1', $PORT, $null, $null)
        $ok     = $async.AsyncWaitHandle.WaitOne(1200, $false)
        if ($ok) { $client.EndConnect($async) } else { $ok = $false }
        $client.Close()
        return $ok
    } catch { return $false }
}

function Start-Mitm {
    # Launching mitmdump.exe *directly* via Start-Process makes it exit within a
    # few seconds on some systems; going through the cmd launcher (which binds
    # stdin to NUL) is reliable, so use that.
    try {
        Start-Process -FilePath 'cmd.exe' -ArgumentList '/c', $CMDLAUNCH -WindowStyle Hidden
        return $true
    } catch {
        Write-Log ('ERROR starting mitmdump: ' + $_.Exception.Message)
        return $false
    }
}

function Set-ProxyOn {
    try {
        if ((Get-CurrentPac) -ne $PAC) {
            New-ItemProperty -Path $REGKEY -Name 'AutoConfigURL' -Value $PAC -PropertyType String -Force | Out-Null
            Invoke-ProxyNotify
            Write-Log 'PAC (re)applied + notified'
        }
        New-ItemProperty -Path $REGKEY -Name 'ProxyEnable' -Value 0 -PropertyType DWord -Force | Out-Null
    } catch { }
    try {
        foreach ($v in @('HTTP_PROXY', 'HTTPS_PROXY', 'http_proxy', 'https_proxy')) {
            [Environment]::SetEnvironmentVariable($v, 'http://127.0.0.1:8180', 'User')
        }
    } catch { }
}

function Set-ProxyOff {
    try {
        Remove-ItemProperty -Path $REGKEY -Name 'AutoConfigURL' -ErrorAction SilentlyContinue
        New-ItemProperty -Path $REGKEY -Name 'ProxyEnable' -Value 0 -PropertyType DWord -Force | Out-Null
    } catch { }
}

Write-Log ('=== watchdog started (pid ' + $PID + ') ===')
$misses = 0
$lastNudge = (Get-Date).AddSeconds(-$NUDGE)   # nudge once right after startup

while ($true) {
    if (Test-Path $PAUSED) { Set-ProxyOff; Start-Sleep -Seconds 10; continue }

    $procs   = @(Get-Process -Name 'mitmdump' -ErrorAction SilentlyContinue)
    $alive   = ($procs.Count -gt 0)
    $healthy = $false
    $age     = 999
    if ($alive) {
        $healthy = Test-ProxyPort
        try { $age = ((Get-Date) - $procs[0].StartTime).TotalSeconds } catch { $age = 999 }
    }

    if (-not $healthy) {
        if ($alive -and $age -lt $GRACE) {
            # still booting - leave it alone
        } else {
            if ($alive) {
                Write-Log ('mitmdump unhealthy (age {0:N0}s, port not listening) -> restarting' -f $age)
                $procs | Stop-Process -Force -ErrorAction SilentlyContinue
                Start-Sleep -Seconds 1
            } else {
                $misses++
                Write-Log ("mitmdump not running (consecutive misses = $misses) -> starting")
            }
            if (Start-Mitm) {
                Start-Sleep -Seconds 5
                if (Test-ProxyPort) { Write-Log 'OK: mitmdump up, 127.0.0.1:8180 listening' }
                else { Write-Log 'WARN: mitmdump started but port 8180 not listening yet' }
            }
        }
    } else {
        if ($misses -gt 0) { Write-Log 'health restored'; $misses = 0 }
    }

    Set-ProxyOn
    if (((Get-Date) - $lastNudge).TotalSeconds -ge $NUDGE) { Invoke-ProxyNudge; $lastNudge = Get-Date }
    Start-Sleep -Seconds $TICK
}
