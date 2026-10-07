#requires -Version 5.1
<#
  gh-fastest.ps1 - speed-test all GitHub mirror prefixes in mirrors.txt and
  print the fastest ones (highest throughput first).

  Usage:
    powershell -ExecutionPolicy Bypass -File gh-fastest.ps1              # cached (24h)
    powershell -ExecutionPolicy Bypass -File gh-fastest.ps1 -Refresh     # force re-test
    powershell -ExecutionPolicy Bypass -File gh-fastest.ps1 -Top 10
    powershell -ExecutionPolicy Bypass -File gh-fastest.ps1 -Url "https://github.com/OWNER/REPO/archive/refs/heads/main.zip"

  Ranked results are cached to mirrors-ranked.json next to this script.
#>
[CmdletBinding()]
param(
  [int]$Top = 5,
  [int]$Timeout = 6,        # seconds per mirror
  [int]$Parallel = 16,      # concurrent tests
  [switch]$Refresh,         # ignore cache and re-test
  [string]$Url = 'https://github.com/cli/cli/archive/refs/heads/trunk.zip'
)

$ErrorActionPreference = 'SilentlyContinue'
$here      = Split-Path -Parent $MyInvocation.MyCommand.Path
$listFile  = Join-Path $here 'mirrors.txt'
$cacheFile = Join-Path $here 'mirrors-ranked.json'

$ranked = $null
if ((Test-Path $cacheFile) -and (-not $Refresh)) {
  try {
    $cache = Get-Content $cacheFile -Raw | ConvertFrom-Json
    if ((New-TimeSpan -Start ([datetime]$cache.testedAt) -End (Get-Date)).TotalHours -lt 24) {
      $ranked = @($cache.ranked)
    }
  } catch { $ranked = $null }
}

if (-not $ranked) {
  $mirrors = Get-Content $listFile | Where-Object { $_ -match '\S' } | ForEach-Object { $_.Trim() }
  $results = New-Object System.Collections.ArrayList
  $queue = New-Object System.Collections.Queue
  foreach ($m in $mirrors) { [void]$queue.Enqueue($m) }
  $running = @()
  while ($queue.Count -gt 0 -or $running.Count -gt 0) {
    while ($running.Count -lt $Parallel -and $queue.Count -gt 0) {
      $m = $queue.Dequeue()
      $running += Start-Job -ScriptBlock {
        param($m, $t, $u)
        $out = & curl.exe --noproxy '*' --max-time $t -sS -o NUL -w '%{http_code} %{speed_download} %{size_download}' ($m + $u) 2>$null
        $p = ("$out").Trim() -split '\s+'
        [pscustomobject]@{ mirror = $m; http = [int]$p[0]; speed = [double]$p[1]; bytes = [long]$p[2] }
      } -ArgumentList $m, $Timeout, $Url
    }
    Start-Sleep -Milliseconds 150
    foreach ($j in @($running | Where-Object { $_.State -ne 'Running' })) {
      [void]$results.Add((Receive-Job $j))
      Remove-Job $j -Force
    }
    $running = @($running | Where-Object { $_.State -eq 'Running' })
  }

  $ranked = $results |
    Where-Object { $_.http -eq 200 -and $_.bytes -gt 200000 } |
    Sort-Object -Property @{ Expression = { $_.speed }; Descending = $true } |
    ForEach-Object { $_.mirror }

  [pscustomobject]@{
    testedAt = (Get-Date).ToString('o')
    testUrl  = $Url
    ranked   = $ranked
  } | ConvertTo-Json -Depth 4 | Set-Content -Path $cacheFile -Encoding UTF8
}

$ranked | Select-Object -First $Top
