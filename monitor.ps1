# =============================================================================
#  git看门狗 2.0A (github-watchdog 2.0A) — pure connectivity monitor
#
#  Design guarantees:
#    * does NOT change the system proxy / PAC
#    * does NOT hardcode any IP
#    * does NOT touch DNS or TLS SNI
#    * only checks, with the network exactly as-is, whether GitHub is reachable,
#      writes a status file + log, and keeps itself running (monitor self-heal)
#
#  It therefore cannot make a blocked network reach GitHub. It just tells the
#  truth: 通 / 不通, and why (HTTP code / timing / DNS failure).
# =============================================================================
$ErrorActionPreference = 'Continue'
$BASE     = $PSScriptRoot
$LOG      = Join-Path $BASE 'monitor.log'
$STATUS   = Join-Path $BASE 'status.json'
$INTERVAL = 120   # seconds between checks

$PROBES = @(
    @{ name = 'github.com';              url = 'https://github.com/robots.txt' },
    @{ name = 'api.github.com';          url = 'https://api.github.com/rate_limit' },
    @{ name = 'raw.githubusercontent.com'; url = 'https://raw.githubusercontent.com/cli/cli/trunk/README.md' },
    @{ name = 'github.githubassets.com'; url = 'https://github.githubassets.com/favicons/favicon.svg' }
)

function Write-Log([string]$m) {
    try {
        if ((Test-Path $LOG) -and ((Get-Item $LOG).Length -gt 2MB)) { Remove-Item $LOG -Force -ErrorAction SilentlyContinue }
        Add-Content -Path $LOG -Value ((Get-Date).ToString('yyyy-MM-dd HH:mm:ss') + '  ' + $m) -Encoding UTF8
    } catch { }
}

function Probe([string]$url) {
    # plain request, no proxy flag, no --resolve, no SNI tricks
    $out = (curl.exe -s -o NUL --max-time 15 --connect-timeout 8 -w "%{http_code}|%{time_total}" $url 2>$null) -join ''
    $p = $out -split '\|'
    $code = if ($p.Count -ge 1 -and $p[0]) { $p[0] } else { '000' }
    $secs = if ($p.Count -ge 2) { $p[1] } else { '' }
    return [pscustomobject]@{ code = $code; ok = (@('200', '301', '302') -contains $code); seconds = $secs }
}

function Get-SystemProxyInfo {
    $key = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Internet Settings'
    $pac = $null; $proxy = $null
    try { $pac = (Get-ItemProperty -Path $key -Name 'AutoConfigURL' -ErrorAction Stop).AutoConfigURL } catch { }
    try {
        $pe = (Get-ItemProperty -Path $key -Name 'ProxyEnable' -ErrorAction Stop).ProxyEnable
        if ($pe -eq 1) { $proxy = (Get-ItemProperty -Path $key -Name 'ProxyServer' -ErrorAction SilentlyContinue).ProxyServer }
    } catch { }
    return [pscustomobject]@{ pac = $pac; proxy = $proxy }
}

# This monitor must observe the network as-is: drop any proxy env vars for itself.
foreach ($v in @('HTTP_PROXY', 'HTTPS_PROXY', 'http_proxy', 'https_proxy')) {
    Remove-Item "Env:$v" -ErrorAction SilentlyContinue
}

Write-Log ('=== monitor 2.0A started (pid ' + $PID + ', interval ' + $INTERVAL + 's) ===')
$lastOverall = $null

while ($true) {
    try {
        $results = foreach ($pr in $PROBES) {
            $r = Probe $pr.url
            [pscustomobject]@{ name = $pr.name; url = $pr.url; code = $r.code; ok = $r.ok; seconds = $r.seconds }
        }
        $okCount = @($results | Where-Object { $_.ok }).Count
        $overall = ($okCount -eq $results.Count)
        $partial = ($okCount -gt 0 -and -not $overall)
        $sp = Get-SystemProxyInfo

        $status = [pscustomobject]@{
            time             = (Get-Date).ToString('s')
            githubReachable  = $overall
            partial          = $partial
            targets          = $results
            systemPac        = $sp.pac
            systemProxy      = $sp.proxy
        }
        $status | ConvertTo-Json -Depth 4 | Set-Content -Path $STATUS -Encoding UTF8

        if ($lastOverall -ne $overall) {
            if ($overall) { Write-Log 'GitHub reachable (通)' }
            elseif ($partial) { Write-Log 'GitHub partially reachable (部分通)' }
            else { Write-Log 'GitHub NOT reachable (不通)' }
            foreach ($r in $results) { Write-Log ('  ' + $r.name + ': HTTP ' + $r.code + ' (' + $r.seconds + 's)') }
            $lastOverall = $overall
        }
    } catch {
        Write-Log ('probe error: ' + $_.Exception.Message)
    }
    Start-Sleep -Seconds $INTERVAL
}
