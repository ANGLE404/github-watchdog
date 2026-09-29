# =============================================================================
#  git看门狗 (github-watchdog) — watchdog
#  - keeps mitmdump alive: process exists AND 127.0.0.1:8180 accepts TCP
#  - 30s startup grace period so a booting mitmdump is never mistaken for a zombie
#  - keeps the PAC system proxy + CLI proxy env vars in place
#  - forces browsers to re-read the PAC (Chromium ignores same-value rewrites);
#    nudges on startup and every 5 min, and notifies on every (re)application
#  - honours the ".paused" sentinel (tear down + idle)
#  - logs: watchdog.log (rotated at 2 MB), mitmdump.log
#
#  --- 2026-09-26 修复 --------------------------------------------------------
#  故障：mitmdump 起不来时本脚本每 5 秒拉起一次。mitmdump.exe 是 PyInstaller
#        onefile 包，每次启动都往 %TEMP% 解包约 45MB（_MEIxxxxxx），退出时若
#        未正常清理就永久残留。8 天累积 10078 个目录 / 442.8 GB，吃满 C 盘。
#        另外 guard.ps1 在换 IP 时会先杀掉 mitmdump，本脚本会抢跑启动，两者打架。
#  对策：1) 尊重 guard 的 .restarting 锁，它重启期间不插手
#        2) 重启冷却 COOLDOWN，两次重启之间有最小间隔
#        3) 突发熔断 MAXBURST，窗口内重启超限则暂停 BREAKERWAIT
#        4) 每次启动前清理 %TEMP% 下陈旧的 _MEI* 残留（保留最近 MEIKEEP 个）
# =============================================================================
$ErrorActionPreference = 'Continue'
$BASE   = $PSScriptRoot
$CMDLAUNCH = Join-Path $BASE 'mitmdump-run.cmd'
$LOG    = Join-Path $BASE 'watchdog.log'
$PAUSED = Join-Path $BASE '.paused'
$LOCK   = Join-Path $BASE '.restarting'
$SWEEP  = Join-Path $BASE 'sweep-mei.ps1'
$REGKEY = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Internet Settings'
$PAC    = 'http://127.0.0.1:8180/proxy.pac'
$PORT   = 8180
$GRACE  = 30   # seconds a freshly started mitmdump is allowed to still be booting
$TICK   = 5
$NUDGE  = 300  # seconds between forced proxy re-reads (see Invoke-ProxyNudge)

# ---- 节流参数（2026-09-26 修复）----------------------------------------------
$COOLDOWN    = 120   # 两次重启之间的最小间隔（秒）
$BURSTWIN    = 900   # 突发统计窗口（秒）
$MAXBURST    = 3     # 窗口内最多允许的重启次数，超过则熔断
$BREAKERWAIT = 900   # 熔断后暂停多久（秒）
$MEIKEEP     = 2     # %TEMP% 下保留最近几个 _MEI 目录
$LOCKMAX     = 90    # .restarting 锁的最长有效时间（秒）

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

# ---- 2026-09-26 新增：清理 PyInstaller 陈旧解包残留 ---------------------------
# 只保留最近 $MEIKEEP 个 _MEI 目录；正在使用的目录会因文件被占用而删除失败，
# 由 catch 静默跳过，因此不会影响运行中的 mitmdump。
function Clear-StaleMei {
    try {
        $tmp = [System.IO.Path]::GetTempPath()
        $dirs = @(Get-ChildItem -LiteralPath $tmp -Directory -Filter '_MEI*' -ErrorAction SilentlyContinue |
                  Sort-Object LastWriteTime -Descending)
        if ($dirs.Count -le $MEIKEEP) { return }
        $removed = 0
        foreach ($d in @($dirs | Select-Object -Skip $MEIKEEP)) {
            try { Remove-Item -LiteralPath $d.FullName -Recurse -Force -ErrorAction Stop; $removed++ } catch { }
        }
        if ($removed -gt 0) { Write-Log ("pruned $removed stale _MEI dirs") }
    } catch { }
}

# ---- 2026-09-26 新增：判断 guard 是否正在重启 mitmdump -----------------------
function Test-GuardRestarting {
    try {
        if (-not (Test-Path $LOCK)) { return $false }
        $age = ((Get-Date) - (Get-Item $LOCK).LastWriteTime).TotalSeconds
        if ($age -lt $LOCKMAX) { return $true }
        Remove-Item -LiteralPath $LOCK -Force -ErrorAction SilentlyContinue
        return $false
    } catch { return $false }
}

function Start-Mitm {
    Clear-StaleMei
    # Launch through a wscript (window style 0) wrapper: starting cmd.exe or
    # powershell directly (Start-Process / Task Scheduler) can flash a console.
    try {
        Start-Process -FilePath 'wscript.exe' -ArgumentList ('"' + (Join-Path $BASE 'mitmdump-launcher.vbs') + '"') -WindowStyle Hidden
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
$lastNudge = (Get-Date).AddSeconds(-$NUDGE)      # nudge once right after startup
$lastStart = (Get-Date).AddSeconds(-$COOLDOWN)   # allow the first start immediately
$startHist = @()                                 # restart timestamps (burst window)
$breakerUntil = (Get-Date).AddSeconds(-1)

while ($true) {
    if (Test-Path $PAUSED) { Set-ProxyOff; Start-Sleep -Seconds 10; continue }

    # guard 正在换 IP 重启 mitmdump —— 别插手，否则两个看门狗会互相打架
    if (Test-GuardRestarting) {
        Set-ProxyOn
        Start-Sleep -Seconds $TICK
        continue
    }

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

            # ---- 2026-09-26 修复：重启节流 + 突发熔断 ----
            $now = Get-Date
            $startHist = @($startHist | Where-Object { ($now - $_).TotalSeconds -lt $BURSTWIN })

            if ($now -lt $breakerUntil) {
                Write-Log ('restart suppressed by circuit breaker ({0:N0}s left)' -f ($breakerUntil - $now).TotalSeconds)
            }
            elseif (($now - $lastStart).TotalSeconds -lt $COOLDOWN) {
                Write-Log ('restart throttled, cooldown {0:N0}s left' -f ($COOLDOWN - ($now - $lastStart).TotalSeconds))
            }
            elseif ($startHist.Count -ge $MAXBURST) {
                $breakerUntil = $now.AddSeconds($BREAKERWAIT)
                Write-Log ("CIRCUIT BREAKER tripped: $($startHist.Count) restarts within ${BURSTWIN}s -> pausing ${BREAKERWAIT}s")
            }
            else {
                if (Start-Mitm) {
                    $lastStart = Get-Date
                    $startHist += $lastStart
                    Start-Sleep -Seconds 5
                    if (Test-ProxyPort) { Write-Log 'OK: mitmdump up, 127.0.0.1:8180 listening' }
                    else { Write-Log 'WARN: mitmdump started but port 8180 not listening yet' }
                }
            }
        }
    } else {
        if ($misses -gt 0) { Write-Log 'health restored'; $misses = 0 }
    }

    Set-ProxyOn
    if (((Get-Date) - $lastNudge).TotalSeconds -ge $NUDGE) { Invoke-ProxyNudge; $lastNudge = Get-Date }
    Start-Sleep -Seconds $TICK
}
