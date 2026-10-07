#requires -Version 5.1
# =============================================================================
#  github-watchdog :: mirror :: install
#  One-time setup that makes every `git clone/fetch/pull` from github.com use
#  the fastest working mirror automatically, while `git push` stays on the real
#  github.com. No admin required.
#
#  Usage:
#    powershell -NoProfile -ExecutionPolicy Bypass -File install-mirror.ps1
# =============================================================================
$ErrorActionPreference = 'Stop'
$here = Split-Path -Parent $MyInvocation.MyCommand.Path
$shim = Join-Path $here 'bin'

# 0) The $PROFILE hook is a .ps1; allow locally-written scripts to load.
$pol = Get-ExecutionPolicy -Scope CurrentUser
if ($pol -in @('Restricted', 'Undefined', 'AllSigned')) {
    try {
        Set-ExecutionPolicy -Scope CurrentUser RemoteSigned -Force
        Write-Host "ExecutionPolicy(CurrentUser) -> RemoteSigned"
    } catch {
        Write-Warning "Could not set ExecutionPolicy automatically: $($_.Exception.Message)"
        Write-Warning "Run manually: Set-ExecutionPolicy -Scope CurrentUser RemoteSigned"
    }
}

# 1) Prepend the shim dir to PATH for every PowerShell session (via $PROFILE),
#    so `git` — and tools launched from that shell, e.g. `npx skills` — hit it.
$markerStart = '# >>> github-watchdog mirror >>>'
$markerEnd   = '# <<< github-watchdog mirror <<<'
$profPath    = $PROFILE.CurrentUserAllHosts
$profDir     = Split-Path -Parent $profPath
if ($profDir -and -not (Test-Path $profDir)) { New-Item -ItemType Directory -Force -Path $profDir | Out-Null }
$existing = if (Test-Path $profPath) { Get-Content $profPath -Raw } else { '' }
if ($existing -notmatch [regex]::Escape($markerStart)) {
    $block = @(
        $markerStart,
        "`$ghShim = '$shim'",
        'if ((Test-Path $ghShim) -and ($env:Path -notlike "*$ghShim*")) { $env:Path = "$ghShim;" + $env:Path }',
        $markerEnd
    ) -join "`r`n"
    Add-Content -Path $profPath -Value "`r`n$block`r`n" -Encoding UTF8
    Write-Host "Profile hook added: $profPath"
} else {
    Write-Host "Profile hook already present in $profPath"
}

# 2) Pick the fastest mirror now and apply it to global git config.
& powershell -NoProfile -ExecutionPolicy Bypass -File (Join-Path $here 'gh-apply.ps1')

Write-Host ""
Write-Host "Done. Open a NEW PowerShell window so the git shim takes effect."
Write-Host "Manage:  gh-apply.ps1 -Status | -Auto | -Off    gh-fastest.ps1 -Top 8"
