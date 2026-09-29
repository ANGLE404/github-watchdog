# =============================================================================
#  PyInstaller 解包残留清扫器  (github-watchdog - mei sweep)
#
#  背景：bin\mitmdump.exe 是 PyInstaller onefile 包，每次启动都会把自己解包成
#        约 45 MB / 183 个文件放进 %TEMP%\_MEIxxxxxx。若进程异常退出，这些残留
#        不会自动清除。2026-09-26 曾因看门狗重启循环累积 10078 个目录 / 442.8GB。
#
#  作用：1) 只保留最近 $KEEP 个 _MEI 目录，其余删除。正在使用的目录会因文件被
#           占用而删除失败，由 catch 静默跳过 —— 绝不影响运行中的 mitmdump。
#        2) 给没有自带轮转的 mitmdump.log 做体积封顶。
#
#  运行：计划任务 GithubHostsMeiSweep 每 2 分钟调用一次（终极兜底，不依赖任何
#        常驻进程存活）；watchdog.ps1 / guard.ps1 在重启 mitmdump 前也会调用。
# =============================================================================
$ErrorActionPreference = 'Continue'
$BASE    = $PSScriptRoot
$LOGFILE = Join-Path $BASE 'mei-sweep.log'
$KEEP    = 3
$LOGKEEP = 2000

function Write-SLog([string]$msg) {
    try {
        if ((Test-Path $LOGFILE) -and ((Get-Item $LOGFILE).Length -gt 512KB)) {
            Remove-Item $LOGFILE -Force -ErrorAction SilentlyContinue
        }
        Add-Content -Path $LOGFILE -Value ((Get-Date).ToString('yyyy-MM-dd HH:mm:ss') + '  ' + $msg) -Encoding UTF8
    } catch { }
}

# ---- 1. 清理 _MEI 残留 -------------------------------------------------------
$removed = 0
try {
    $tmp  = [System.IO.Path]::GetTempPath()
    $dirs = @(Get-ChildItem -LiteralPath $tmp -Directory -Filter '_MEI*' -ErrorAction SilentlyContinue |
              Sort-Object LastWriteTime -Descending)
    if ($dirs.Count -gt $KEEP) {
        foreach ($d in @($dirs | Select-Object -Skip $KEEP)) {
            try {
                Remove-Item -LiteralPath $d.FullName -Recurse -Force -ErrorAction Stop
                $removed++
            } catch { }
        }
    }
    if ($removed -gt 0) { Write-SLog ("swept $removed stale _MEI dirs (kept $KEEP)") }
} catch { }

# ---- 2. 日志封顶 -------------------------------------------------------------
# 名 -> 上限。watchdog.ps1 / guard.ps1 自身还有 2MB 的「整文件删除式」轮转，
# 这里做更温和的截断：长期稳定运行时不会把几万行历史堆在一个文件里。
$caps = @{
    'mitmdump.log'   = 5MB
    'watchdog.log'   = 1MB
    'guard.log'      = 1MB
    'update-ips.log' = 512KB
}
foreach ($name in @($caps.Keys)) {
    $p = Join-Path $BASE $name
    if (-not (Test-Path $p)) { continue }
    try {
        if ((Get-Item $p).Length -gt $caps[$name]) {
            $tail = @(Get-Content -LiteralPath $p -Tail $LOGKEEP -ErrorAction SilentlyContinue)
            $head = @('# --- truncated by sweep-mei.ps1 at ' + (Get-Date).ToString('yyyy-MM-dd HH:mm:ss') + ', kept last ' + $LOGKEEP + ' lines ---')
            Set-Content -LiteralPath $p -Value ($head + $tail) -Encoding UTF8
            Write-SLog ("truncated $name to last $LOGKEEP lines")
        }
    } catch { }
}

exit 0
