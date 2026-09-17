# =============================================================================
#  git看门狗 (github-watchdog) — deep guard
#  - verifies the *whole proxy chain* (not just "is mitmdump alive")
#  - when a mapped host stops responding, fails over to the next candidate IP
#    by rewriting src\config.yaml, restarting mitmdump and re-verifying
#  - only keeps a change that is proven to work; otherwise restores the backup
#  - honours the ".paused" sentinel
#  Run:  powershell -NoProfile -ExecutionPolicy Bypass -File guard.ps1
# =============================================================================
$ErrorActionPreference = 'Continue'
$BASE   = $PSScriptRoot
$CONFIG = Join-Path $BASE 'src\config.yaml'
$BAK    = Join-Path $BASE 'src\config.yaml.bak'
$LAUNCH = Join-Path $BASE 'mitmdump-run.cmd'
$LOG    = Join-Path $BASE 'guard.log'
$PAUSED = Join-Path $BASE '.paused'
$DYN    = Join-Path $BASE 'dynamic-ips.json'   # produced by update-ips.ps1 (Meta API)
$PROXY  = 'http://127.0.0.1:8180'
$UTF8   = New-Object System.Text.UTF8Encoding($false)   # config.yaml has no BOM, LF endings

function Write-GLog([string]$msg) {
    try {
        if ((Test-Path $LOG) -and ((Get-Item $LOG).Length -gt 2MB)) { Remove-Item $LOG -Force -ErrorAction SilentlyContinue }
        Add-Content -Path $LOG -Value ((Get-Date).ToString('yyyy-MM-dd HH:mm:ss') + '  ' + $msg) -Encoding UTF8
    } catch { }
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
        $a = New-ScheduledTaskAction -Execute 'powershell.exe' -Argument ('-NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File "' + $UPD + '"')
        $t1 = New-ScheduledTaskTrigger -AtLogOn -User $env:USERNAME
        $t2 = New-ScheduledTaskTrigger -Daily -At 3am
        $s = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries -MultipleInstances IgnoreNew -ExecutionTimeLimit (New-TimeSpan -Minutes 10) -StartWhenAvailable
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
    [pscustomobject]@{ Name = 'usercontent'; Host = '*.githubusercontent.com'; Url = 'https://raw.githubusercontent.com/cli/cli/trunk/README.md'; Ips = @('185.199.111.154', '185.199.110.154', '185.199.109.154', '185.199.108.154') }
)

if (Test-Path $PAUSED) { Write-GLog 'paused (.paused present) - nothing to do'; exit 0 }

# keep the Meta-API discovery running even if install.ps1 did not register it
Ensure-UpdateTask
Refresh-DynamicIpsIfStale

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
