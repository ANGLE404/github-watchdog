#requires -Version 5.1
<#
  gh-apply.ps1 - make git downloads from github.com use the fastest working mirror.

  Modes:
    (default)        pick fastest (24h cache else full test) + apply, then exit
    -Refresh         force full re-test, then apply
    -Auto            QUICK per-use refresh: re-test only the current top
                     candidates and switch if a faster one appears (used by the
                     git shim on every clone/fetch/pull; debounced)
    -Status          show current setting
    -Off             remove everything -> git direct again
    -InstallTask     (legacy) daily scheduled task
    -RemoveTask      remove that task

  Global git config applied:
    url."<mirror><https://github.com/>".insteadOf = github url forms (https/ssh/git)
    url."https://github.com/".pushInsteadOf = same forms   (push stays direct)
    credential."https://<mirror-host>".helper = ""         (no prompt)
    http."https://<mirror-host>".proxy = ""                (bypass local mitmproxy)
#>
[CmdletBinding()]
param(
  [switch]$Refresh, [switch]$Off, [switch]$Status, [switch]$Auto,
  [switch]$InstallTask, [switch]$RemoveTask,
  [int]$Quick = 6,               # candidates re-tested in -Auto
  [int]$QuickTimeout = 4,        # seconds per candidate in -Auto
  [int]$DebounceMinutes = 3      # min gap between -Auto runs
)

$ErrorActionPreference = 'Stop'
$here     = Split-Path -Parent $MyInvocation.MyCommand.Path
$tester   = Join-Path $here 'gh-fastest.ps1'
$cache    = Join-Path $here 'mirrors-ranked.json'
$state    = Join-Path $here 'applied.json'
$lockFile = Join-Path $here 'auto.lock'
$taskName = 'GhProxyFastestRefresh'
$TestUrl  = 'https://github.com/cli/cli/archive/refs/heads/trunk.zip'
$patterns = @('https://github.com/', 'git@github.com:', 'ssh://git@github.com/', 'git://github.com/')
$plainBase = 'https://github.com/'

function Get-State { if (Test-Path $state) { Get-Content $state -Raw | ConvertFrom-Json } else { $null } }

function Set-GitEmpty([string]$key) {
  $psi = New-Object System.Diagnostics.ProcessStartInfo
  $psi.FileName = 'git'
  $psi.Arguments = "config --global --replace-all `"$key`" `"`""
  $psi.UseShellExecute = $false; $psi.RedirectStandardError = $true
  $pr = [System.Diagnostics.Process]::Start($psi)
  $err = $pr.StandardError.ReadToEnd(); $pr.WaitForExit()
  if ($err) { Write-Warning $err.Trim() }
}

function Undo-Applied {
  $s = Get-State
  if ($s) {
    git config --global --unset-all "url.$($s.base).insteadOf" 2>$null | Out-Null
    git config --global --unset-all "url.$plainBase.pushInsteadOf" 2>$null | Out-Null
    foreach ($k in @($s.credKey, $s.proxyKey)) { if ($k) { git config --global --unset-all $k 2>$null | Out-Null } }
    if ($s.removed) { foreach ($p in @($s.removed)) { git config --global --add "url.$plainBase.insteadOf" $p 2>$null | Out-Null } }
  } else {
    git config --global --unset-all "url.$plainBase.pushInsteadOf" 2>$null | Out-Null
  }
  Remove-Item $state -ErrorAction SilentlyContinue
}

function Apply-Mirror([string]$fastest) {
  $base     = "$fastest" + "https://github.com/"
  $mhost    = ([Uri]$fastest).Host
  $credKey  = "credential.https://$mhost.helper"
  $proxyKey = "http.https://$mhost.proxy"

  Undo-Applied
  $removed = @()
  foreach ($p in $patterns) {
    if ($p -eq 'https://github.com/') { continue }
    if (@(git config --global --get-all "url.$plainBase.insteadOf" 2>$null) -contains $p) {
      git config --global --unset-all "url.$plainBase.insteadOf" $p 2>$null | Out-Null
      $removed += $p
    }
  }
  foreach ($p in $patterns) {
    git config --global --add "url.$base.insteadOf" $p
    git config --global --add "url.$plainBase.pushInsteadOf" $p
  }
  Set-GitEmpty $credKey
  Set-GitEmpty $proxyKey
  [pscustomobject]@{
    mirror = $fastest; base = $base; credKey = $credKey; proxyKey = $proxyKey
    removed = $removed; appliedAt = (Get-Date).ToString('o')
  } | ConvertTo-Json -Depth 5 | Set-Content $state -Encoding UTF8
}

function Get-Fastest {
  param([bool]$Force)
  if ((Test-Path $cache) -and -not $Force) {
    $c = Get-Content $cache -Raw | ConvertFrom-Json
    if ((New-TimeSpan -Start ([datetime]$c.testedAt) -End (Get-Date)).TotalHours -lt 24 -and @($c.ranked).Count -ge 1) {
      return (@($c.ranked)[0]).Trim()
    }
  }
  $top = & powershell -NoProfile -ExecutionPolicy Bypass -File $tester -Refresh -Top 1
  return (@($top)[0]).Trim()
}

function Test-Candidates([string[]]$cands) {
  $jobs = foreach ($m in $cands) {
    Start-Job -ScriptBlock {
      param($m, $t, $u)
      $out = & curl.exe --noproxy '*' --max-time $t -sS -o NUL -w '%{http_code} %{speed_download} %{size_download}' ($m + $u) 2>$null
      $p = ("$out").Trim() -split '\s+'
      [pscustomobject]@{ mirror = $m; http = [int]$p[0]; speed = [double]$p[1]; bytes = [long]$p[2] }
    } -ArgumentList $m, $QuickTimeout, $TestUrl
  }
  $res = $jobs | Wait-Job | Receive-Job
  $jobs | Remove-Job -Force
  return ($res | Where-Object { $_.http -eq 200 -and $_.bytes -gt 200000 } |
          Sort-Object -Property speed -Descending | Select-Object -First 1).mirror
}

# ---------------------------------------------------------------- modes
if ($Status) {
  $s = Get-State
  if ($s) { "Active mirror : $($s.mirror)"; "applied at    : $($s.appliedAt)" }
  else { "No mirror applied (git goes direct)." }
  return
}

if ($RemoveTask) { schtasks /Delete /TN $taskName /F 2>$null | Out-Null; "Task '$taskName' removed."; return }
if ($InstallTask) {
  $ps  = (Get-Command powershell.exe).Source
  $cmd = "`"$ps`" -NoProfile -WindowStyle Hidden -ExecutionPolicy Bypass -File `"$here\gh-apply.ps1`" -Refresh"
  schtasks /Create /TN $taskName /SC DAILY /ST 09:00 /TR $cmd /F | Out-Null
  "Task '$taskName' installed (daily 09:00)."; return
}

if ($Off) { Undo-Applied; "Mirror rewrite removed; git now goes direct."; return }

if ($Auto) {
  if ((Test-Path $lockFile) -and (((Get-Date) - (Get-Item $lockFile).LastWriteTime).TotalMinutes -lt $DebounceMinutes)) { return }
  Set-Content -Path $lockFile -Value (Get-Date).ToString('o') -Encoding UTF8

  $ranked = @()
  if (Test-Path $cache) { $ranked = @((Get-Content $cache -Raw | ConvertFrom-Json).ranked) }
  if ($ranked.Count -lt 1) {
    $fastest = Get-Fastest -Force $true
  } else {
    $fastest = Test-Candidates ($ranked | Select-Object -First $Quick)
  }
  if (-not $fastest) { return }
  $s = Get-State
  if (-not $s -or $s.mirror -ne $fastest) { Apply-Mirror $fastest }
  return
}

$fastest = Get-Fastest -Force:$Refresh
if (-not $fastest) { throw "no working mirror found (all timed out)" }
Apply-Mirror $fastest
"Applied fastest mirror : $fastest"
"  clone/fetch/pull (https/ssh/git)  ->  $fastest"
"  push (any form)                   ->  https://github.com (direct)"
"  mirror credentials + proxy        ->  disabled (direct, no prompt)"
