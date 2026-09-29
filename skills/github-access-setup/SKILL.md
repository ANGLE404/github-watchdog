---
name: github-access-setup
description: Diagnose and fix GitHub access on restricted/blocked networks (Windows): configure git/gh credentials, HTTPS via a local proxy, SSH proxy/fallback, and de-identify repos before publishing. Use when git clone/push or gh fails with timeouts, "Connection timed out during banner exchange", "Unable to connect to relay host", "schannel: server closed abruptly", permission denied on publickey, or when setting up git/SSH credentials to GitHub.
---

# GitHub access setup (restricted network)

A repeatable workflow to get `git` and `gh` working against GitHub on a
network where GitHub is partially blocked, then publish/de-identify a repo.
Written for Windows + PowerShell 5.1, but the diagnosis generalizes.

## Golden rules

- **Never hardcode or commit secrets.** Tokens live only in `gh`'s credential
  store (`keyring`/manager). git should delegate to `gh auth git-credential`.
- **De-identify before publishing**: no personal paths, real names/emails,
  device names, or private IPs in tracked files. See "De-identify a repo".
- **Diagnose the transport before configuring.** Decide HTTPS vs SSH from
  actual probes, don't assume.
- Report results with evidence (exit codes, HTTP codes, banners).

## Step 1 — inventory the environment

Run these in parallel and read the output:

```powershell
git --version
gh --version; gh auth status                 # logged in? which scopes?
git config --global --list                    # proxy / ssl / credential helpers
Get-ChildItem "$env:USERPROFILE\.ssh"         # keys, config, known_hosts
```

Check for an existing proxy and which ports actually listen:

```powershell
Get-NetTCPConnection -State Listen -ErrorAction SilentlyContinue |
  Where-Object { $_.LocalPort -in 8180,8080,3128,1080,1081,7890,7891,10808,10809 } |
  ForEach-Object { $p = Get-Process -Id $_.OwningProcess -ErrorAction SilentlyContinue; "$($_.LocalAddress):$($_.LocalPort) -> $($p.ProcessName)" }
```

A local MITM proxy (e.g. `mitmdump` on 8180) usually only carries **HTTP/TLS**,
not raw TCP — it cannot proxy SSH by itself.

## Step 2 — probe the transport

**HTTPS** (does the proxy path work?):

```powershell
git ls-remote https://github.com/cli/cli.git HEAD
```

**SSH direct** (often blocked on 22 and 443):

```powershell
ssh -o BatchMode=yes -o ConnectTimeout=10 -T git@github.com
ssh -o BatchMode=yes -o ConnectTimeout=10 -T -p 443 git@ssh.github.com
```

Interpretation:

| Symptom | Meaning |
|---|---|
| `Connection timed out` / `banner exchange` | TCP/SSH blocked; SSH won't work directly |
| `Permission denied (publickey)` | Transport OK, key not on the account — still usable once key is added |
| `Hi <user>! You've successfully authenticated` | SSH fully working — use it |
| `Unable to connect to relay host, errno=10061` | `~/.ssh/config` points at a dead proxy port |

**Critical lesson:** a stale `ProxyCommand` in `~/.ssh/config` can *break* SSH
that would otherwise work. If direct SSH succeeds after removing it, keep it
removed. Only add `ProxyCommand` when a real SOCKS proxy is listening.

## Step 3 — configure HTTPS (the reliable path)

```powershell
$proxy = 'http://127.0.0.1:8180'                     # your local proxy
$ca    = Join-Path $HOME '.mitmproxy\git-ca-bundle.crt'

# route only GitHub through the proxy
git config --global http.https://github.com.proxy      $proxy
git config --global http.https://gist.github.com.proxy $proxy

# trust the MITM CA (avoid schannel: server closed abruptly)
if (Test-Path $ca) {
  git config --global http.sslBackend openssl
  git config --global http.sslcainfo   $ca
}

gh auth setup-git          # git credential helper -> gh auth git-credential
```

**Make every tool work, regardless of URL style.** Other AI agents, IDEs, and
scripts may still use SSH-style URLs (`git@github.com:owner/repo.git`). On a
network where SSH is flaky, rewrite those to HTTPS transparently so *any*
consumer of `git` succeeds:

```powershell
git config --global --add url."https://github.com/".insteadOf "git@github.com:"
git config --global --add url."https://github.com/".insteadOf "ssh://git@github.com/"
git config --global --add url."https://github.com/".insteadOf "git://github.com/"
```

Note: plain `git config --global url.X.insteadOf Y` **overwrites** the list —
always use `--add` when defining multiple `insteadOf` values for the same key.
Verify: `git ls-remote git@github.com:OWNER/REPO.git HEAD` should now return a
commit SHA even while raw SSH is down.

For GUI/AI tools that read env vars instead of git config, also persist:

```powershell
[Environment]::SetEnvironmentVariable('HTTP_PROXY',  $proxy, 'User')
[Environment]::SetEnvironmentVariable('HTTPS_PROXY', $proxy, 'User')
[Environment]::SetEnvironmentVariable('http_proxy',  $proxy, 'User')
[Environment]::SetEnvironmentVariable('https_proxy', $proxy, 'User')
# if the proxy MITMs TLS, help Node/Python trust it:
[Environment]::SetEnvironmentVariable('NODE_EXTRA_CA_CERTS', (Join-Path $HOME '.mitmproxy\mitmproxy-ca-cert.pem'), 'User')
```

Login (device flow; run with proxy env vars set so it can reach GitHub):

```powershell
$env:HTTP_PROXY=$proxy; $env:HTTPS_PROXY=$proxy
gh auth login --hostname github.com --git-protocol https --web
```

Identity (use the GitHub noreply address for privacy;
it appears in GitHub → Settings → Emails as `<id>+<user>@users.noreply.github.com`):

```powershell
git config --global user.name  "Your Name"
git config --global user.email "<id>+<user>@users.noreply.github.com"
```

Verify: `git ls-remote https://github.com/OWNER/REPO.git HEAD`

## Step 4 — SSH (only when a real proxy exists)

If direct 22/443 is blocked **and** you have a SOCKS proxy (e.g. `ssh -D 1080`),
`connect.exe` ships with Git for Windows and can tunnel SSH over SOCKS.
Add to `~/.ssh/config`:

```
Host github.com
    HostName github.com
    User git
    IdentityFile ~/.ssh/id_ed25519
    IdentitiesOnly yes
    ProxyCommand "C:\Program Files\Git\mingw64\bin\connect.exe" -S 127.0.0.1:1080 %h %p
```

Add the public key (web UI, or CLI which needs the `admin:public_key` scope):

```powershell
gh auth refresh -h github.com -s admin:public_key   # then authorize in browser
gh ssh-key add "$env:USERPROFILE\.ssh\id_ed25519.pub" --title "my-machine"
```

No proxy available? **Don't configure a dead `ProxyCommand`** — leave a comment
explaining HTTPS is required, so SSH fails with a clear message instead of a
confusing relay error.

## Step 5 — de-identify a repo before publishing

Scan tracked files for anything personal:

```powershell
Get-ChildItem -Recurse -File | Where-Object { $_.FullName -notmatch '\\\.git\\' } |
  ForEach-Object {
    $m = Select-String -Path $_.FullName -Pattern 'C:\\Users\\[^\\]+|/home/[^/]+|gho_|ghp_|github_pat_|BEGIN (RSA|OPENSSH|PRIVATE)|password|secret|token\s*[:=]' -ErrorAction SilentlyContinue
    if ($m) { "== $($_.Name) =="; $m | ForEach-Object { "  L$($_.LineNumber): $($_.Line.Trim())" } }
  }
```

Fix by replacing absolute paths with script-relative ones:
- PowerShell: `$PSScriptRoot`
- `.bat`/`.cmd`: `%~dp0`
- `.vbs`: `fso.GetParentFolderName(WScript.ScriptFullName)`

Also add runtime artifacts to `.gitignore` (`*.log`, `*.bak`, `*.cer`, `*.pem`,
state/IP cache files). Keep license/NOTICE copyright intact.

## Step 6 — verify and publish

```powershell
git status -sb
git add <intended files>       # never `git add -A` blindly
git diff --cached --stat
git commit -m "..."            # matching repo style
git push origin main
gh api "repos/OWNER/REPO/git/trees/main?recursive=1" --jq ".tree[].path"
```

Only commit/push when the user asked. Confirm the pushed commit SHA from the
remote afterward.

## Troubleshooting quick table

| Error | Cause / fix |
|---|---|
| `schannel: server closed abruptly` | Use openssl backend + `http.sslcainfo` pointing at the MITM CA |
| `Permission denied (publickey)` | Key not on GitHub, or SSH died mid-way; prefer HTTPS |
| `Unable to connect to relay host` | Dead `ProxyCommand` port; remove or start the SOCKS proxy |
| `gh` 404 on `/user/keys` | Token lacks `admin:public_key`; run `gh auth refresh -s admin:public_key` |
| HTTPS fine, SSH times out | Normal on blocked networks; stay on HTTPS |
| `git` works after deleting `ProxyCommand` | Direct SSH became available; keep it simple |
