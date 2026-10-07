#requires -Version 5.1
# =============================================================================
#  github-watchdog :: mirror :: uninstall
#  Removes the $PROFILE hook and the global git config rewrite (git goes direct).
#
#  Usage:
#    powershell -NoProfile -ExecutionPolicy Bypass -File uninstall-mirror.ps1
# =============================================================================
$ErrorActionPreference = 'Stop'
$here = Split-Path -Parent $MyInvocation.MyCommand.Path

# 1) Remove the marked block from $PROFILE
$markerStart = '# >>> github-watchdog mirror >>>'
$markerEnd   = '# <<< github-watchdog mirror <<<'
$profPath    = $PROFILE.CurrentUserAllHosts
if (Test-Path $profPath) {
    $text = Get-Content $profPath -Raw
    $pattern = '(?ms)^[ \t]*' + [regex]::Escape($markerStart) + '.*?' + [regex]::Escape($markerEnd) + '[ \t]*\r?\n?'
    $new = [regex]::Replace($text, $pattern, '')
    if ($new -ne $text) {
        Set-Content -Path $profPath -Value $new -Encoding UTF8
        Write-Host "Profile hook removed from $profPath"
    } else {
        Write-Host "No profile hook found."
    }
}

# 2) Undo the global git config rewrite
& powershell -NoProfile -ExecutionPolicy Bypass -File (Join-Path $here 'gh-apply.ps1') -Off

Write-Host "Done. Open a new PowerShell window for PATH to revert."
