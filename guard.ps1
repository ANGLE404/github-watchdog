# =============================================================================
#  git看门狗 (github-watchdog) — deep guard
#  - verifies the *whole proxy chain* (not just "is mitmdump alive")
#  - when a mapped host stops responding, fails over to the next candidate IP
#    by rewriting src\config.yaml, restarting mitmdump and re-verifying
#  - only keeps a change that is proven to work; otherwise restores the backup
#  - honours the ".paused" sentinel
#  Run:  powershell -NoProfile -ExecutionPolicy Bypass -File guard.ps1
#
#  --- 2026-09-26 修复 A (sweep-mei) ------------------------------------------
#  故障：Restart-Mitm 是「杀掉 mitmdump -> 等 -> 再启动」，而它在 failover 循环
#        里对每个候选 IP 都调用一次；watchdog.ps1 又会在进程消失的瞬间抢跑启动。
#        两者互相打架，每次重启都让 mitmdump.exe 向 %TEMP% 解包约 45 MB 的
#        _MEI 目录且永不回收 —— 7.9 天累积 10078 个 / 442.8 GB。
#  对策：1) 重启期间建 .restarting 锁，watchdog 尊重它，不再抢跑
#        2) 重启前 & 脚本启动时清理陈旧 _MEI（保留最近 $MEIKEEP 个）
#        3) 自注册 GithubHostsMeiSweep 计划任务（每 2 分钟清扫，终极兜底）
#        4) 检测到 watchdog.ps1 已更新而进程还是旧版 -> 自动重启它加载新补丁
# =============================================================================
$ErrorActionPreference = 'Continue'
$BASE   = $PSScriptRoot
$CONFIG = Join-Path $BASE 'src\config.yaml'
$BAK    = Join-Path $BASE 'src\config.yaml.bak'
$LAUNCH = Join-Path $BASE 'mitmdump-run.cmd'
$LOG    = Join-Path $BASE 'guard.log'
$PAUSED = Join-Path $BASE '.paused'
$LOCK   = Join-Path $BASE '.restarting'
$SWEEP  = Join-Path $BASE 'sweep-mei.ps1'
$DYN    = Join-Path $BASE 'dynamic-ips.json'   # produced by update-ips.ps1 (Meta API)
$PROXY  = 'http://127.0.0.1:8180'
$UTF8   = New-Object System.Text.UTF8Encoding($false)   # config.yaml has no BOM, LF endings
$MEIKEEP = 3

function Write-GLog([string]$msg) {
    try {
        if ((Test-Path $LOG) -and ((Get-Item $LOG).Length -gt 2MB)) { Remove-Item $LOG -Force -ErrorAction SilentlyContinue }
        Add-Content -Path $LOG -Value ((Get-Date).ToString('yyyy-MM-dd HH:mm:ss') + '  ' + $msg) -Encoding UTF8
    } catch { }
}

# ---- 2026-09-26 新增：清理 PyInstaller 解包残留 -------------------------------
# 只保留最近 $MEIKEEP 个 _MEI 目录；正在使用的会因文件占用删除失败，静默跳过。
function Clear-StaleMei {
    try {
        $tmp  = [System.IO.Path]::GetTempPath()
        $dirs = @(Get-ChildItem -LiteralPath $tmp -Directory -Filter '_MEI*' -ErrorAction SilentlyContinue |
                  Sort-Object LastWriteTime -Descending)
        if ($dirs.Count -le $MEIKEEP) { return }
        $n = 0
        foreach ($d in @($dirs | Select-Object -Skip $MEIKEEP)) {
            try { Remove-Item -LiteralPath $d.FullName -Recurse -Force -ErrorAction Stop; $n++ } catch { }
        }
        if ($n -gt 0) { Write-GLog "swept $n stale _MEI dirs (kept $MEIKEEP)" }
    } catch { }
}

# ---- 2026-09-26 新增：确保高频清扫任务存在（终极兜底）------------------------
function Ensure-MeiSweepTask {
    if (-not (Test-Path $SWEEP)) { return }
    try {
        if (Get-ScheduledTask -TaskName 'GithubHostsMeiSweep' -ErrorAction SilentlyContinue) { return }
        $vbs = Join-Path $BASE 'sweep-launcher.vbs'
        if (Test-Path $vbs) { $a = New-ScheduledTaskAction -Execute 'wscript.exe' -Argument ('"' + $vbs + '"') }
        else { $a = New-ScheduledTaskAction -Execute 'powershell.exe' -Argument ('-NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File "' + $SWEEP + '"') }
        $t = New-ScheduledTaskTrigger -Once -At ((Get-Date).AddMinutes(1)) -RepetitionInterval (New-TimeSpan -Minutes 2)
        $s = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries -MultipleInstances IgnoreNew -ExecutionTimeLimit (New-TimeSpan -Minutes 5) -StartWhenAvailable -Hidden
        Register-ScheduledTask -TaskName 'GithubHostsMeiSweep' -Action $a -Trigger $t -Settings $s -Force | Out-Null
        Write-GLog 'registered GithubHostsMeiSweep task (every 2 min)'
    } catch { Write-GLog ('failed to register mei-sweep task: ' + $_.Exception.Message) }
}

# ---- 2026-09-26 新增：看门狗存在性与版本自愈 ---------------------------------
# watchdog.ps1 改了但进程还是旧版时，主动重启它（否则补丁永远不生效）。
function Ensure-Watchdog {
    $script = Join-Path $BASE 'watchdog.ps1'
    if (-not (Test-Path $script)) { return }
    $scriptTime = (Get-Item $script).LastWriteTime
    $vbs = Join-Path $BASE 'watchdog-launcher.vbs'
    try {
        $ws = @(Get-CimInstance Win32_Process -Filter "Name='powershell.exe'" -ErrorAction SilentlyContinue |
                Where-Object { $_.CommandLine -like '*watchdog.ps1*' })
        if ($ws.Count -eq 0) {
            Start-Process -FilePath 'wscript.exe' -ArgumentList ('"' + $vbs + '"') -WindowStyle Hidden
            Write-GLog 'watchdog not running -> started'
            return
        }
        foreach ($p in $ws) {
            try {
                $started = [datetime]$p.CreationDate
                if ($started -lt $scriptTime.AddSeconds(-5)) {
                    Write-GLog "watchdog pid $($p.ProcessId) predates current script -> reloading"
                    Stop-Process -Id $p.ProcessId -Force -ErrorAction SilentlyContinue
                    Start-Sleep -Seconds 3
                    Start-Process -FilePath 'wscript.exe' -ArgumentList ('"' + $vbs + '"') -WindowStyle Hidden
                    break
                }
            } catch { }
        }
    } catch { Write-GLog ('Ensure-Watchdog failed: ' + $_.Exception.Message) }
}

function Test-ProxyPort {
    try {
        $c = New-Object System.Net.Sockets.TcpClient
        $ar = $c.BeginConnect('127.0.0.1', 8180, $null, $null)
        $ok = $ar.AsyncWaitHandle.WaitOne(1500, $false)
        if ($ok) { $c.EndConnect($ar) }
        $c.Close(); return $ok
    } catch { return $false }
}

function Test-Chain([string]$url) {
    try {
        $code = (curl.exe -s -o NUL --max-time 25 -x $PROXY -w "%{http_code}" $url 2>$null) -join ''
        return @('200', '301', '302') -contains $code
    } catch { return $false }
}

function Restart-Mitm {
    # 2026-09-26：重启期间上锁，让 watchdog 不要抢跑；并在启动前清理旧解包残留
    try { Set-Content -LiteralPath $LOCK -Value ([DateTime]::Now.ToString('o')) -Encoding ASCII -Force } catch { }
    try {
        Clear-StaleMei
        Get-Process mitmdump -ErrorAction SilentlyContinue | Stop-Process -Force -ErrorAction SilentlyContinue
        $deadline = (Get-Date).AddSeconds(30)
        while ((Get-Date) -lt $deadline) {
            Start-Sleep -Seconds 2
            if (Test-ProxyPort) { return $true }
        }
        try { Start-Process -FilePath 'cmd.exe' -ArgumentList '/c', $LAUNCH -WindowStyle Hidden } catch { }
        $deadline = (Get-Date).AddSeconds(30)
        while ((Get-Date) -lt $deadline) {
            Start-Sleep -Seconds 2
            if (Test-ProxyPort) { return $true }
        }
        return $false
    } finally {
        try { Remove-Item -LiteralPath $LOCK -Force -ErrorAction SilentlyContinue } catch { }
    }
}

function Set-MappingAddress {
    param([string]$Text, [string]$HostName, [string]$Address)
    $nl = "`n"
    $lines = $Text -split "`r?`n"
    $pattern = '^\s*-\s*"?\s*' + [regex]::Escape($HostName) + '\s*"?\s*$'
    $idx = -1
    for ($i = 0; $i -lt $lines.Count; $i++) {
        if ($lines[$i] -match $pattern) {
            $j = $i - 1
            while ($j -ge 0 -and $lines[$j].Trim() -eq '') { $j-- }
            if ($j -ge 0 -and $lines[$j].Trim() -eq '- hosts:') { $idx = $i; break }
        }
    }
    if ($idx -lt 0) { return $null }
    for ($k = $idx + 1; $k -lt $lines.Count; $k++) {
        if ($lines[$k] -match '^\s*address:\s*') {
            $indent = ($lines[$k] -replace 'address:.*$', '')
            $lines[$k] = $indent + 'address: ' + $Address
            return ($lines -join $nl)
        }
    }
    return $null
}

$UPD = Join-Path $BASE 'update-ips.ps1'

function Get-DynamicCandidates([string]$name) {
    # extra failover pool discovered from the official Meta API (update-ips.ps1)
    if (-not (Test-Path $DYN)) { return @() }
    try {
        $j = Get-Content $DYN -Raw | ConvertFrom-Json
        $pool = $j.pools.$name
        if ($pool) { return @($pool) }
    } catch { }
    return @()
}

function Ensure-UpdateTask {
    # self-register the daily Meta-API IP refresh task (so install.ps1 need not know)
    if (-not (Test-Path $UPD)) { return }
    $null = schtasks /Query /TN GithubHostsUpdateIPs 2>&1
    if ($LASTEXITCODE -eq 0) { return }
    try {
        $vbs = Join-Path $BASE 'update-ips-launcher.vbs'
        if (Test-Path $vbs) { $a = New-ScheduledTaskAction -Execute 'wscript.exe' -Argument ('"' + $vbs + '"') }
        else { $a = New-ScheduledTaskAction -Execute 'powershell.exe' -Argument ('-NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File "' + $UPD + '"') }
        $t1 = New-ScheduledTaskTrigger -AtLogOn -User $env:USERNAME
        $t2 = New-ScheduledTaskTrigger -Daily -At 3am
        $s = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries -MultipleInstances IgnoreNew -ExecutionTimeLimit (New-TimeSpan -Minutes 10) -StartWhenAvailable -Hidden
        Register-ScheduledTask -TaskName 'GithubHostsUpdateIPs' -Action $a -Trigger @($t1, $t2) -Settings $s -Force | Out-Null
        Write-GLog 'registered daily GithubHostsUpdateIPs task'
    } catch { Write-GLog ('failed to register update task: ' + $_.Exception.Message) }
}

function Refresh-DynamicIpsIfStale {
    # keep dynamic-ips.json fresh (<=24h) using the official Meta API
    if (-not (Test-Path $UPD)) { return }
    if (Test-Path $DYN) {
        try {
            $j = Get-Content $DYN -Raw | ConvertFrom-Json
            if ($j.updated) { $age = (Get-Date) - [datetime]$j.updated; if ($age.TotalHours -lt 24) { return } }
        } catch { }
    }
    Write-GLog 'dynamic-ips stale -> refreshing from Meta API'
    try { & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $UPD 2>&1 | Out-Null } catch { Write-GLog ('update-ips failed: ' + $_.Exception.Message) }
}

$targets = @(
    [pscustomobject]@{ Name = 'github.com';  Host = 'github.com';               Url = 'https://github.com/robots.txt';                           Ips = @('140.82.116.3', '140.82.112.3', '140.82.113.3', '140.82.114.3') },
    [pscustomobject]@{ Name = 'api';         Host = 'api.github.com';           Url = 'https://api.github.com/rate_limit';                       Ips = @('140.82.112.6', '140.82.113.6', '140.82.114.6', '140.82.116.6') },
    [pscustomobject]@{ Name = 'codeload';    Host = 'codeload.github.com';      Url = 'https://codeload.github.com/feng2208/github-hosts/zip/refs/heads/main'; Ips = @('140.82.112.9', '140.82.113.9', '140.82.114.9', '140.82.116.9') },
    [pscustomobject]@{ Name = 'gist';        Host = 'gist.github.com';          Url = 'https://gist.github.com/';                                Ips = @('140.82.112.4', '140.82.113.4', '140.82.114.4', '140.82.116.4') },
    [pscustomobject]@{ Name = 'assets';      Host = 'github.githubassets.com';  Url = 'https://github.githubassets.com/favicons/favicon.svg';    Ips = @('185.199.111.154', '185.199.110.154', '185.199.109.154', '185.199.108.154') },
    [pscustomobject]@{ Name = 'usercontent'; Host = '*.githubusercontent.com'; Url = 'https://raw.githubusercontent.com/cli/cli/trunk/README.md'; Ips = @('185.199.111.154', '185.199.110.154', '185.199.109.154', '185.199.108.154') },
    [pscustomobject]@{ Name = 'github.io';   Host = '*.github.io';             Url = 'https://jquery.github.io/';                               Ips = @('185.199.111.153', '185.199.110.153', '185.199.109.153', '185.199.108.153') }
)

# ---- 2026-09-26：无条件先扫一遍残留（即便处于 paused 也清）-------------------
Clear-StaleMei

if (Test-Path $PAUSED) { Write-GLog 'paused (.paused present) - nothing to do'; exit 0 }

# keep the Meta-API discovery running even if install.ps1 did not register it
Ensure-UpdateTask
Refresh-DynamicIpsIfStale

# 2026-09-26：兜底清扫任务 + 看门狗版本自愈
Ensure-MeiSweepTask
Ensure-Watchdog

if (-not (Test-ProxyPort)) {
    Write-GLog 'proxy port 8180 down -> restarting mitmdump'
    if (-not (Restart-Mitm)) { Write-GLog 'ERROR: could not bring mitmdump up'; exit 2 }
    Start-Sleep -Seconds 1
}

$failed = 0
foreach ($t in $targets) {
    if (Test-Chain $t.Url) { continue }

    Write-GLog ("$($t.Name) FAILED via proxy -> trying IP failover")
    $failed++
    $orig = [IO.File]::ReadAllText($CONFIG)
    Copy-Item $CONFIG $BAK -Force -ErrorAction SilentlyContinue
    $fixed = $false

    $candidates = @($t.Ips) + @(Get-DynamicCandidates $t.Name)
    $candidates = @($candidates | Where-Object { $_ } | Select-Object -Unique)
    foreach ($ip in $candidates) {
        $new = Set-MappingAddress -Text $orig -HostName $t.Host -Address ($ip + ':443')
        if ($null -eq $new) { Write-GLog "  cannot locate mapping for $($t.Host)"; break }
        if ($new -eq $orig) { continue }
        [IO.File]::WriteAllText($CONFIG, $new, $UTF8)
        [void](Restart-Mitm)
        Start-Sleep -Seconds 2
        if (Test-Chain $t.Url) {
            Write-GLog "  $($t.Name) FIXED with new address $ip"
            $fixed = $true
            break
        }
        Write-GLog "  candidate $ip did not work"
    }

    if (-not $fixed) {
        [IO.File]::WriteAllText($CONFIG, $orig, $UTF8)
        [void](Restart-Mitm)
        Write-GLog "  $($t.Name) no candidate worked - config restored to original"
    }
}

Write-GLog ("guard done: targets tested = $($targets.Count), failures repaired attempted = $failed")
exit 0
