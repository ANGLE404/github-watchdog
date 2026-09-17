# =============================================================================
#  git看门狗 3.0 - update-ips.ps1
#
#  Auto-discover the current GitHub IPv4 candidates from the OFFICIAL Meta API
#  (https://api.github.com/meta) and write them to dynamic-ips.json.
#
#  Discovery ONLY: this script never edits config.yaml and never restarts
#  mitmdump. It is safe to run at any time. guard.ps1 consumes dynamic-ips.json
#  as an extra failure-over pool, so the actual switch still goes through the
#  connectivity test + rollback safety net.
#
#  Fetch order (Meta API may itself be blocked): local proxy -> direct ->
#  public mirrors -> last successful cache.
# =============================================================================
param(
    [switch]$DryRun,
    [switch]$NoThirdParty
)
$ErrorActionPreference = 'Continue'
$ProgressPreference = 'SilentlyContinue'
$BASE  = $PSScriptRoot
$OUT   = Join-Path $BASE 'dynamic-ips.json'
$CACHE = Join-Path $BASE 'meta-cache.json'
$LOG   = Join-Path $BASE 'update-ips.log'
$PROXY = 'http://127.0.0.1:8180'

# Optional third-party hosts subscriptions: used ONLY as extra candidate seeds.
# They are still passed through the local TCP test before being trusted.
$THIRDPARTY = @(
    'https://raw.hellogithub.com/hosts',
    'https://raw.githubusercontent.com/521xueweihan/GitHub520/main/hosts'
)

function Write-Ulog([string]$m) {
    try {
        if ((Test-Path $LOG) -and ((Get-Item $LOG).Length -gt 1MB)) { Remove-Item $LOG -Force -ErrorAction SilentlyContinue }
        Add-Content -Path $LOG -Value ((Get-Date).ToString('yyyy-MM-dd HH:mm:ss') + '  ' + $m) -Encoding UTF8
    } catch { }
    if ($DryRun) { Write-Host $m }
}

function Test-ProxyPort {
    try {
        $c = New-Object System.Net.Sockets.TcpClient
        $ar = $c.BeginConnect('127.0.0.1', 8180, $null, $null)
        $ok = $ar.AsyncWaitHandle.WaitOne(1200, $false)
        if ($ok) { $c.EndConnect($ar) }
        $c.Close(); return $ok
    } catch { return $false }
}

function Get-Meta {
    [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
    $proxyOk = Test-ProxyPort
    $endpoints = @()
    if ($proxyOk) { $endpoints += @{ url = 'https://api.github.com/meta'; proxy = $PROXY } }
    $endpoints += @{ url = 'https://api.github.com/meta'; proxy = $null }
    $endpoints += @{ url = 'https://ghproxy.net/https://api.github.com/meta'; proxy = $null }
    $endpoints += @{ url = 'https://gh-proxy.com/https://api.github.com/meta'; proxy = $null }

    foreach ($e in $endpoints) {
        try {
            $p = @{ Uri = $e.url; Headers = @{ 'User-Agent' = 'github-watchdog'; 'Accept' = 'application/vnd.github+json' }; TimeoutSec = 30 }
            if ($e.proxy) { $p.Proxy = $e.proxy }
            $j = Invoke-RestMethod @p
            if ($j.web -or $j.api -or $j.pages) {
                $via = $(if ($e.proxy) { ' (via proxy)' } else { ' (direct)' })
                Write-Ulog ('meta OK from ' + $e.url + $via)
                return $j
            }
        } catch {
            Write-Ulog ('meta FAIL ' + $e.url + ': ' + $_.Exception.Message)
        }
    }
    if (Test-Path $CACHE) { Write-Ulog 'meta fallback: local cache'; return (Get-Content $CACHE -Raw | ConvertFrom-Json) }
    Write-Ulog 'meta unavailable (no endpoint, no cache)'
    return $null
}

function Get-Range24([string]$cidr) {
    # expand an IPv4 CIDR into its /24 base prefixes, e.g. 140.82.112.0/20 -> 140.82.112..127
    if (-not $cidr) { return @() }
    if ($cidr -match ':') { return @() }               # skip IPv6
    $p = $cidr.Split('/')
    if ($p.Count -ne 2) { return @() }
    try { $ip = [System.Net.IPAddress]::Parse($p[0]) } catch { return @() }
    $pref = [int]$p[1]
    if ($pref -gt 24) { return @() }                   # not a /24-supernet
    if ($pref -lt 16) { $pref = 16 }                   # don't enumerate huge ranges
    $b = $ip.GetAddressBytes()
    $ipInt = [int64]$b[0] * 16777216 + [int64]$b[1] * 65536 + [int64]$b[2] * 256 + [int64]$b[3]
    $mask = [int64]0xFFFFFFFF
    if ($pref -gt 0) { $mask = ([int64]0xFFFFFFFF -shl (32 - $pref)) -band [int64]0xFFFFFFFF }
    $net = $ipInt -band $mask
    $count = [int][math]::Pow(2, (24 - $pref))
    if ($count -gt 32) { $count = 32 }
    $res = @()
    for ($i = 0; $i -lt $count; $i++) {
        $n = $net + ($i * 256)
        $o1 = [int](($n -shr 24) -band 255)
        $o2 = [int](($n -shr 16) -band 255)
        $o3 = [int](($n -shr 8) -band 255)
        $res += ('{0}.{1}.{2}' -f $o1, $o2, $o3)
    }
    return $res
}

function New-Candidates($ranges, [int[]]$lastOctets, [bool]$deriveSiblings, [int]$cap) {
    # handles both supernets (/16../24 -> enumerate /24 bases + service last octet)
    # and single-host entries (/32 -> the IP itself, optionally derive .133/.154 siblings)
    $set = New-Object System.Collections.Generic.List[string]
    foreach ($r in ($ranges | Where-Object { $_ })) {
        if ($r -match ':') { continue }                 # skip IPv6
        $p = $r.Split('/')
        if ($p.Count -ne 2) { continue }
        $pref = [int]$p[1]
        if ($pref -eq 32) {
            if (-not $set.Contains($p[0])) { $set.Add($p[0]) }
            if ($deriveSiblings) {
                foreach ($lo in $lastOctets) {
                    $d = ($p[0] -replace '\.\d+$', ('.' + $lo))
                    if (-not $set.Contains($d)) { $set.Add($d) }
                }
            }
        } elseif ($pref -le 24) {
            foreach ($b in (Get-Range24 $r)) {
                foreach ($lo in $lastOctets) {
                    $ip = "$b.$lo"
                    if (-not $set.Contains($ip)) { $set.Add($ip) }
                }
            }
        }
    }
    return @($set | Select-Object -First $cap)
}

function Get-WebRanges($arr) {
    # web/api/git currently also list the Pages range and many Azure /32s;
    # drop the 185.199.* Pages range so it does not pollute the main-site pool.
    return @($arr | Where-Object { $_ -and ($_ -notmatch '^185\.199\.') })
}

function Test-Tcp([string]$ip) {
    $c = New-Object System.Net.Sockets.TcpClient
    $sw = [System.Diagnostics.Stopwatch]::StartNew()
    try {
        $ar = $c.BeginConnect($ip, 443, $null, $null)
        if ($ar.AsyncWaitHandle.WaitOne(1200, $false)) {
            $c.EndConnect($ar); $sw.Stop(); return [int]$sw.ElapsedMilliseconds
        }
        return $null
    } catch { return $null } finally { $c.Close() }
}

function Get-ThirdPartySeeds {
    # parse "IP domain" hosts files into a domain -> [IPs] map (best effort, untrusted)
    $map = @{}
    if ($NoThirdParty) { return $map }
    foreach ($url in $THIRDPARTY) {
        $txt = $null
        try {
            $p = @{ Uri = $url; Headers = @{ 'User-Agent' = 'github-watchdog' }; TimeoutSec = 25 }
            if (Test-ProxyPort) { $p.Proxy = $PROXY }
            $txt = (Invoke-WebRequest @p).Content
        } catch {
            try { $txt = (Invoke-WebRequest -Uri $url -Headers @{ 'User-Agent' = 'github-watchdog' } -TimeoutSec 25).Content } catch { }
        }
        if (-not $txt) { Write-Ulog ('thirdparty FAIL ' + $url); continue }
        $n = 0
        foreach ($line in ($txt -split "`n")) {
            $m = [regex]::Match($line, '^\s*(\d{1,3}(?:\.\d{1,3}){3})\s+(\S+)')
            if ($m.Success) {
                $ip = $m.Groups[1].Value
                $dom = $m.Groups[2].Value.ToLower()
                if (-not $map.ContainsKey($dom)) { $map[$dom] = New-Object System.Collections.Generic.List[string] }
                if (-not $map[$dom].Contains($ip)) { $map[$dom].Add($ip) }
                $n++
            }
        }
        Write-Ulog ('thirdparty ' + $url + ': ' + $n + ' host lines')
    }
    return $map
}

$meta = Get-Meta
if (-not $meta) { exit 2 }

try { $meta | ConvertTo-Json -Depth 6 | Set-Content -Path $CACHE -Encoding UTF8 } catch { Write-Ulog ('cache write failed: ' + $_.Exception.Message) }

$services = [ordered]@{
    'github.com'  = @{ ranges = (Get-WebRanges (@($meta.web) + @($meta.git))); last = @(3);        derive = $false }
    'api'         = @{ ranges = (Get-WebRanges (@($meta.api) + @($meta.web))); last = @(6);        derive = $false }
    'codeload'    = @{ ranges = (Get-WebRanges (@($meta.git) + @($meta.web))); last = @(9);        derive = $false }
    'gist'        = @{ ranges = (Get-WebRanges (@($meta.web) + @($meta.git))); last = @(4);        derive = $false }
    'assets'      = @{ ranges = @($meta.pages);                                last = @(154);      derive = $true }
    'usercontent' = @{ ranges = @($meta.pages);                                last = @(133, 154); derive = $true }
}

# which subscribed domains map to which service
$serviceDomains = @{
    'github.com'  = @('github.com')
    'api'         = @('api.github.com')
    'codeload'    = @('codeload.github.com')
    'gist'        = @('gist.github.com')
    'assets'      = @('github.githubassets.com')
    'usercontent' = @('raw.githubusercontent.com', 'avatars.githubusercontent.com', 'objects.githubusercontent.com', 'camo.githubusercontent.com', 'gist.githubusercontent.com', 'user-images.githubusercontent.com', 'media.githubusercontent.com')
}

$seeds = Get-ThirdPartySeeds

$pools = [ordered]@{}
foreach ($name in $services.Keys) {
    $cands = New-Object System.Collections.Generic.List[string]
    # third-party subscriptions first (pre-curated seeds), then official Meta ranges
    foreach ($d in $serviceDomains[$name]) {
        if ($seeds.ContainsKey($d)) { foreach ($ip in $seeds[$d]) { if (-not $cands.Contains($ip)) { $cands.Add($ip) } } }
    }
    foreach ($ip in (New-Candidates $services[$name].ranges $services[$name].last $services[$name].derive 20)) { if (-not $cands.Contains($ip)) { $cands.Add($ip) } }
    $cands = @($cands | Select-Object -First 24)

    $good = @()
    foreach ($ip in $cands) {
        $ms = Test-Tcp $ip
        if ($null -ne $ms) { $good += [pscustomobject]@{ ip = $ip; ms = $ms } }
    }
    $sorted = @($good | Sort-Object ms | ForEach-Object { $_.ip })
    $pools[$name] = $sorted
    Write-Ulog ('{0}: {1} candidates, {2} reachable -> {3}' -f $name, $cands.Count, $sorted.Count, (($sorted | Select-Object -First 6) -join ', '))
}

$result = [pscustomobject]@{
    updated = (Get-Date).ToString('s')
    source  = 'api.github.com/meta'
    pools   = $pools
}
if ($DryRun) {
    Write-Host ($result | ConvertTo-Json -Depth 4)
} else {
    $result | ConvertTo-Json -Depth 4 | Set-Content -Path $OUT -Encoding UTF8
    Write-Ulog ('wrote ' + $OUT)
}
exit 0
