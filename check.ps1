# =============================================================================
#  git看门狗 2.0A — one-shot connectivity check (通 / 不通)
#  Usage: powershell -NoProfile -ExecutionPolicy Bypass -File check.ps1
#  No proxy / no fixed IP / no SNI changes.
# =============================================================================
$ErrorActionPreference = 'Continue'
$PROBES = @(
    @{ name = 'github.com';               url = 'https://github.com/robots.txt' },
    @{ name = 'api.github.com';           url = 'https://api.github.com/rate_limit' },
    @{ name = 'raw.githubusercontent.com'; url = 'https://raw.githubusercontent.com/cli/cli/trunk/README.md' },
    @{ name = 'github.githubassets.com';  url = 'https://github.githubassets.com/favicons/favicon.svg' }
)

foreach ($v in @('HTTP_PROXY', 'HTTPS_PROXY', 'http_proxy', 'https_proxy')) { Remove-Item "Env:$v" -ErrorAction SilentlyContinue }

Write-Output ''
Write-Output '============ git看门狗 2.0A 连通性检查 ============'
$ok = 0
foreach ($p in $PROBES) {
    $out = (curl.exe -s -o NUL --max-time 15 --connect-timeout 8 -w "%{http_code}|%{time_total}" $p.url 2>$null) -join ''
    $parts = $out -split '\|'
    $code = if ($parts.Count -ge 1 -and $parts[0]) { $parts[0] } else { '000' }
    $secs = if ($parts.Count -ge 2) { $parts[1] } else { '?' }
    $good = @('200', '301', '302') -contains $code
    if ($good) { $ok++ }
    $tag = if ($good) { '[通]' } else { '[不通]' }
    Write-Output ("{0} {1,-26} HTTP {2} ({3}s)" -f $tag, $p.name, $code, $secs)
}

# DNS sanity (informational)
try {
    $ips = (Resolve-DnsName github.com -Type A -ErrorAction Stop | Where-Object { $_.IPAddress } | Select-Object -First 3).IPAddress -join ', '
    Write-Output ("[INFO] DNS github.com -> " + $ips)
} catch { Write-Output '[INFO] DNS github.com -> 解析失败' }

try {
    $key = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Internet Settings'
    $pac = $null; $pe = (Get-ItemProperty -Path $key -Name 'ProxyEnable' -ErrorAction SilentlyContinue).ProxyEnable
    try { $pac = (Get-ItemProperty -Path $key -Name 'AutoConfigURL' -ErrorAction SilentlyContinue).AutoConfigURL } catch { }
    $sysProxy = if ($pe -eq 1) { '已启用' } elseif ($pac) { 'PAC: ' + $pac } else { '未启用（直连）' }
    Write-Output ("[INFO] 系统代理: " + $sysProxy)
} catch { }

Write-Output '--------------------------------------------------'
$verdict = if ($ok -eq $PROBES.Count) { 'GitHub 可达（通）' } elseif ($ok -gt 0) { 'GitHub 部分可达' } else { 'GitHub 不可达（不通）' }
Write-Output ("结论: {0}   ({1}/{2})" -f $verdict, $ok, $PROBES.Count)
Write-Output '=================================================='
if ($ok -eq 0) { exit 1 } else { exit 0 }
