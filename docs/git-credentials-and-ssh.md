# git / gh 凭据与 SSH 设置（受限网络）

本机网络下 `github.com` 的 **SNI 被阻断**，网页/HTTPS 需借助本地 8180 代理。
`git@github.com`（SSH）的可用性随网络状态变化 —— **先直连探测，再决定是否加代理**。
本文说明如何让 `git` / `gh` 正常认证、克隆、推送，以及 SSH 的正确配置姿势。
**全文不含任何令牌、私钥或个人信息**。

---

## 一、结论先行

| 用途 | 本机可行方案 |
|---|---|
| `git clone/push`（HTTPS） | ✅ 推荐：HTTPS + `gh` 凭据助手，流量走 8180 |
| `gh` 命令 | ✅ 设备码登录时即走 8180（见 `gh-login.bat`） |
| SSH（`git@github.com`） | 先 `ssh -T git@github.com` 实测：**直连通了就直接用**；不通且没有 SOCKS 代理时改用 HTTPS（见第三节） |

> 凭据始终存放在 **`gh` 的凭据存储**（keyring / manager）里，git 只是通过
> `gh auth git-credential` 去取——**仓库里不会、也不应该出现任何 token**。

> **关键教训**：`~/.ssh/config` 里若为 `github.com` 写了一个 `ProxyCommand`（指向某个
> 当时可用、后来关掉的 SOCKS 端口），会让本可直连的 SSH 反而失败，报
> `Unable to connect to relay host, errno=10061`。**加代理前务必先测直连**。

---

## 二、HTTPS + gh（推荐）

### 1. 登录 gh（自动经 8180）
直接双击 `gh-login.bat`，或：

```bat
set HTTP_PROXY=http://127.0.0.1:8180
set HTTPS_PROXY=http://127.0.0.1:8180
gh auth login --hostname github.com --git-protocol https --web
gh auth setup-git
```

`--git-protocol https` 让 gh 用 HTTPS 参与 git 操作；`gh auth setup-git` 会把
git 的 credential helper 指向 `gh auth git-credential`。

### 2. 让 git 走代理 + 信任 mitmproxy 的 CA

```powershell
$proxy    = 'http://127.0.0.1:8180'
$caBundle = Join-Path $HOME '.mitmproxy\git-ca-bundle.crt'

# 只给 GitHub 相关域名挂代理，其它流量直连
git config --global http.https://github.com.proxy      $proxy
git config --global http.https://gist.github.com.proxy $proxy

# git 在 Windows 上改用 openssl 后端，并指定 mitmproxy 的 CA
git config --global http.sslBackend openssl
git config --global http.sslcainfo   $caBundle
```

> `git-ca-bundle.crt` 由 mitmproxy 首次运行时生成；若不存在，先启动一次代理
> （`start-github-hosts.bat`）再运行上面的命令。

### 3. 身份（示例值，改成你自己的）

```powershell
git config --global user.name  "Your Name"
git config --global user.email "you@users.noreply.github.com"
```

GitHub 的隐私邮箱形如 `<数字ID>+<用户名>@users.noreply.github.com`，
可在 GitHub Settings → Emails 里查到，避免公开真实邮箱。

### 4. 验证

```powershell
git ls-remote https://github.com/OWNER/REPO.git HEAD
```

---

## 三、SSH（先测直连，再决定是否加代理）

**第一步，永远先测直连**（网络状态会变，别凭旧印象配置）：

```powershell
ssh -o BatchMode=yes -o ConnectTimeout=10 -T git@github.com
```

- 若返回 `Hi <user>! You've successfully authenticated...` → **直连可用，直接用**，
  不要加任何 `ProxyCommand`。此时 `git ls-remote git@github.com:OWNER/REPO.git HEAD` 也应正常。
- 若 `Connection timed out`（TCP/SSH 被阻断）→ 进入第二步。

注意：mitmproxy 只处理 **HTTP/TLS**，**不透传裸 TCP**，所以 SSH **不能**借用 8180。

**第二步，只有在另有一个可用的 SOCKS 代理时**（例如 `ssh -D 1080` 或本地翻墙工具的
SOCKS 端口），才通过 `connect.exe` 把 SSH 塞进 SOCKS。`connect.exe` 随 Git for Windows 自带：
`C:\Program Files\Git\mingw64\bin\connect.exe`。

> ⚠️ 若直连已通，却仍保留下面这段 `ProxyCommand`，而那个 SOCKS 端口**已经没在监听**，
> SSH 会报 `Unable to connect to relay host, errno=10061` —— **这时删掉 `ProxyCommand`
> 反而立刻恢复**。建议以注释形式保留，需要时再启用。

`~/.ssh/config` 片段（把 `127.0.0.1:1080` 换成你自己的 SOCKS 端口）：

```
Host github.com
    HostName github.com
    User git
    IdentityFile ~/.ssh/id_ed25519
    IdentitiesOnly yes
    ProxyCommand "C:\Program Files\Git\mingw64\bin\connect.exe" -S 127.0.0.1:1080 %h %p
    ServerAliveInterval 30
    ServerAliveCountMax 3
```

若直连被墙又没有代理，就把该 `Host github.com` 段整体注释掉，并在注释里写明
「本网络 SSH 不可用，请改用 HTTPS」，这样将来报错信息清晰，而不是费解的 relay 错误。

### 添加公钥
- 网页：GitHub → Settings → SSH and GPG keys → New SSH key，粘贴 `~/.ssh/id_ed25519.pub` 内容。
- 命令行：`gh ssh-key add ~/.ssh/id_ed25519.pub --title "my-machine"`
  —— 需要 token 具备 `admin:public_key` 权限；
  当前 gh 默认 scope 不含它，需先执行一次
  `gh auth refresh -h github.com -s admin:public_key` 完成授权。

### 验证

```powershell
ssh -T git@github.com                                   # "Hi <user>! ..."
git ls-remote git@github.com:OWNER/REPO.git HEAD        # 返回 commit SHA 即 git over SSH 可用
```

---

## 四、排错速查

| 现象 | 原因 / 处理 |
|---|---|
| `schannel: server closed abruptly` | HTTPS 未走 openssl + CA：确认 `http.sslBackend=openssl`、`http.sslcainfo` 指向 bundle |
| `Permission denied (publickey)` | 公钥没加到 GitHub；加上即可，或改用 HTTPS |
| `Unable to connect to relay host, errno=10061` | `~/.ssh/config` 的 `ProxyCommand` 指向的端口没人监听；**删掉该段先测直连** |
| SSH 直连成功却仍配了代理 | 多余且脆弱，直接删除 `ProxyCommand`，走直连 |
| `gh` 报 404 on `/user/keys` | token 缺 `admin:public_key` scope |
| push 慢/断 | 走 8180 的带宽有限，大对象建议分块或改用 release 附件 |
