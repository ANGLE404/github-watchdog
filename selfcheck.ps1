# =============================================================================
#  git看门狗 (github-watchdog) — self-check
#  Usage:  powershell -NoProfile -ExecutionPolicy Bypass -File selfcheck.ps1
#  Exit 0 = all critical checks passed, 1 = one or more failed.
# =============================================================================
$ErrorActionPreference = 'Continue'
$PROXY  = 'http://127.0.0.1:8180'
$PACURL = 'http://127.0.0.1:8180/proxy.pac'
$REGKEY = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Internet Settings'
$SU     = Join-Path $env:APPDATA 'Microsoft\Windows\Start Menu\Programs\Startup'

function Resolve-Gh {
    $c = Get-Command gh -ErrorAction SilentlyContinue
    if ($c) { return $c.Source }
    $p = Join-Path $env:LOCALAPPDATA 'Programs\GitHubCLI\bin\gh.exe'
    if (Test-Path $p) { return $p }
    return $null
}
function Resolve-Git {
    $c = Get-Command git -ErrorAction SilentlyContinue
    if ($c) { return $c.Source }
    $p = Join-Path $env:ProgramFiles 'Git\cmd\git.exe'
    if (Test-Path $p) { return $p }
    return $null
}
$GHEXE  = Resolve-Gh
$GITEXE = Resolve-Git

$rows = New-Object System.Collections.ArrayList
function Add-Check([string]$name, [bool]$ok, [string]$detail) {
    [void]$rows.Add([pscustomobject]@{ Name = $name; OK = $ok; Detail = $detail })
}

# --- 1. mitmdump process ------------------------------------------------------
$procs = @(Get-Process mitmdump -ErrorAction SilentlyContinue)
Add-Check 'mitmdump process' ($procs.Count -gt 0) ("count=" + $procs.Count)

# --- 2. port 8180 -------------------------------------------------------------
$portOpen = $false
try {
    $c = New-Object System.Net.Sockets.TcpClient
    $ar = $c.BeginConnect('127.0.0.1', 8180, $null, $null)
    $portOpen = $ar.AsyncWaitHandle.WaitOne(1500, $false)
    if ($portOpen) { $c.EndConnect($ar) }
    $c.Close()
} catch { $portOpen = $false }
Add-Check 'port 8180 listening' $portOpen ''

# --- 3. PAC registry ----------------------------------------------------------
$pac = $null
try { $pac = (Get-ItemProperty -Path $REGKEY -Name 'AutoConfigURL' -ErrorAction Stop).AutoConfigURL } catch { }
Add-Check 'PAC AutoConfigURL' ($pac -eq $PACURL) "$pac"
$pe = $null
try { $pe = (Get-ItemProperty -Path $REGKEY -Name 'ProxyEnable' -ErrorAction Stop).ProxyEnable } catch { }
Add-Check 'ProxyEnable = 0' ($pe -eq 0) "$pe"

# --- 4. watchdog process ------------------------------------------------------
$wd = @(Get-CimInstance Win32_Process -Filter "Name='powershell.exe'" |
        Where-Object { $_.CommandLine -like '*watchdog.ps1*' -and $_.ProcessId -ne $PID })
Add-Check 'watchdog running' ($wd.Count -ge 1) ("count=" + $wd.Count)

# --- 5. autostart (3 layers) --------------------------------------------------
$run = $null
try { $run = (Get-ItemProperty -Path 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Run' -Name 'GithubHostsWatchdog' -ErrorAction Stop).GithubHostsWatchdog } catch { }
Add-Check 'autostart: Run key' ($run -like '*watchdog-launcher.vbs*') "$run"
Add-Check 'autostart: Startup folder' (Test-Path (Join-Path $SU 'github-hosts-watchdog.vbs')) ''
$null = schtasks /Query /TN GithubHostsWatchdogLogon 2>&1
Add-Check 'autostart: logon task' ($LASTEXITCODE -eq 0) ''
$null = schtasks /Query /TN GithubHostsGuard 2>&1
Add-Check 'autostart: guard task' ($LASTEXITCODE -eq 0) ''

# --- 6. proxy chain -----------------------------------------------------------
$targets = @(
    @('github.com',      'https://github.com/robots.txt'),
    @('api.github.com',  'https://api.github.com/rate_limit'),
    @('raw githubusercontent', 'https://raw.githubusercontent.com/cli/cli/trunk/README.md'),
    @('avatars',         'https://avatars.githubusercontent.com/u/2?v=4'),
    @('githubassets',    'https://github.githubassets.com/favicons/favicon.svg'),
    @('codeload',        'https://codeload.github.com/cli/cli/tar.gz/refs/heads/trunk'),
    @('github.io pages', 'https://jquery.github.io/'),
    @('octocaptcha',     'https://octocaptcha.com/')
)
foreach ($t in $targets) {
    $o = (curl.exe -s -o NUL --max-time 30 -x $PROXY -w "%{http_code}|%{size_download}" $t[1] 2>&1) -join ''
    $parts = $o -split '\|'
    $code = if ($parts.Count -ge 1) { $parts[0] } else { '?' }
    $size = if ($parts.Count -ge 2) { $parts[1] } else { '?' }
    $ok = @('200', '301', '302') -contains $code
    Add-Check ("proxy: " + $t[0]) $ok ("HTTP $code, $size bytes")
}

# --- 7. git -------------------------------------------------------------------
if ($GITEXE) {
    $g = (& $GITEXE ls-remote https://github.com/cli/cli HEAD 2>&1) -join ' '
    Add-Check 'git ls-remote' ($g -match 'HEAD') ($g.Trim().Substring(0, [Math]::Min(60, $g.Trim().Length)))
} else {
    Add-Check 'git ls-remote' $false 'git.exe not found'
}

# --- 8. gh cli ----------------------------------------------------------------
Add-Check 'gh.exe installed' ([bool]$GHEXE) ''

# --- report -------------------------------------------------------------------
$pass = @($rows | Where-Object { $_.OK }).Count
$fail = @($rows | Where-Object { -not $_.OK }).Count
Write-Output ''
Write-Output '================ git看门狗 self-check ================'
foreach ($r in $rows) {
    $tag = if ($r.OK) { '[ OK ]' } else { '[FAIL]' }
    Write-Output ("{0} {1,-28} {2}" -f $tag, $r.Name, $r.Detail)
}
Write-Output '------------------------------------------------------'
Write-Output ("TOTAL: {0} passed, {1} failed" -f $pass, $fail)

# --- informational: GitHub CLI login (needs user action, not counted) ---------
if ($GHEXE) {
    $env:HTTP_PROXY = $PROXY
    $env:HTTPS_PROXY = $PROXY
    $authOut = ((& $GHEXE auth status 2>&1) -join ' ')
    $authMsg = if ($authOut -match 'Logged in to') { 'logged in' } else { 'NOT logged in - run gh-login.bat to authorize' }
    Write-Output ("[INFO] gh auth status: " + $authMsg)
}
Write-Output '======================================================'
if ($fail -gt 0) { exit 1 } else { exit 0 }
