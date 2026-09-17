# git看门狗 (github-watchdog)

> 让 GitHub 在受限网络里「开机即用、断了自己爬起来」的本地加速代理。

`github-watchdog` 基于 [feng2208/github-hosts](https://github.com/feng2208/github-hosts) 的
mitmproxy 域名前置思路，补上了它在真实网络里最缺的三件事：**浏览器肯用代理**、
**IP 被封了会自己换**、**被谁清掉代理了会自己修**。

---

## 特性

| 能力 | 说明 |
|---|---|
| 类 PAC 白名单代理 | 只把 GitHub 相关域名（github.com / api / codeload / gist / githubusercontent / githubassets / github.io）走本地代理，其它流量直连 |
| 抗 DNS 污染 | 所有上游地址写死真实 IP，不依赖本机 DNS |
| 抗 SNI 阻断 | 对 github.com / api / codeload / gist 采用**不发 SNI**；对 CDN 采用**域前置** |
| 浏览器 PAC 强制刷新 | Chromium 对「值没变」的系统代理不会重读 —— 看门狗会周期性 nudge 强制它重读 |
| 开机自启（三层） | Run 键 + 启动文件夹 + 计划任务登录触发，命名互斥体保证只跑一个 |
| 看门狗自愈 | 进程挂了 / 端口不通 → 自动重启 |
| 深度守卫 + IP 自动切换 | 每 15 分钟走代理实测 6 条链路；某域名不通 → 在候选 IP 池里自动切换并验证，失败则回滚 |
| 自检脚本 | 一条命令体检 19 项：进程/端口/PAC/自启/链路/git/gh |
| 一键启停 / 登录 | `start-github-hosts.bat` / `stop-github-hosts.bat` / `gh-login.bat` |

---

## 工作原理（一句话版）

```
浏览器 --PAC(仅GitHub域名)--> 127.0.0.1:8180 (mitmdump + github-hosts.py)
                                   |
                                   | 按 hosts 规则改写 SNI / 目标 IP
                                   v
                           GitHub 真实 IP（写死，绕过 DNS 污染与 SNI 阻断）
```

关键设计点：

1. **写死 IP，不查 DNS**：`github.com / api / codeload / gist` 分别指向 `140.82.112~116.x`，
   `*.githubusercontent.com / githubassets` 指向 `185.199.10x.154`。
2. **不发 SNI**：GFW 靠 TLS 明文里的 SNI 做阻断，`sni: _github.com` 表示握手时不发送 SNI，
   服务端只认 HTTP 的 `Host` 头，路由依然正确。
3. **域前置**：当某 IP 的默认证书与目标域名不匹配时（例如 `185.199.111.154` 的证书是
   `*.githubassets.com`），就把 SNI 设成该证书真实包含的名字，`Host` 保持不变 ——
   CDN 按 Host 返回正确内容，证书校验也能通过。

---

## 目录结构

```
github-watchdog/
├─ install.ps1            安装：定位 mitmdump、装 CA、设 PAC、注册自启、启动自检
├─ uninstall.ps1          卸载：清自启、停代理、清 PAC 与环境变量
├─ watchdog.ps1           看门狗：保活 + PAC 强制刷新
├─ guard.ps1              深度守卫：链路实测 + IP 自动切换（含回滚）
├─ selfcheck.ps1          自检（19 项）
├─ mitmdump-run.cmd       稳定拉起 mitmdump（stdin=NUL，输出到日志）
├─ watchdog-launcher.vbs  隐藏窗口拉起看门狗
├─ start-github-hosts.bat / stop-github-hosts.bat
├─ gh-login.bat           GitHub CLI 设备码登录（可选）
├─ src/
│  ├─ github-hosts.py     mitmproxy 插件（来自上游）
│  └─ config.yaml         映射配置（本项目加固版）
└─ bin/                   放置 mitmdump.exe（不随仓库提交）
```

---

## 安装

### 前置

- Windows 10 / 11，PowerShell 5.1（系统自带）
- **mitmdump**：任选其一
  - `pip install mitmproxy`（需要 Python / pip），或
  - 把官方 `mitmdump.exe` 放到 `bin\mitmdump.exe`
- 可选：`git`、`GitHub CLI (gh)`

### 一键安装

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File install.ps1
```

`install.ps1` 会自动：

1. 定位 mitmdump（`bin\` → PATH → `pip install mitmproxy`）；
2. 首次运行生成 mitmproxy CA，并装入 `Cert:\CurrentUser\Root`（**无需管理员**）；
3. 写入 PAC 系统代理 `http://127.0.0.1:8180/proxy.pac`；
4. 注册三层开机自启；
5. 注册深度守卫计划任务（每 15 分钟）；
6. 启动看门狗并跑一次自检。

> CA 证书只装到「当前用户」，不碰系统级证书；卸载时可用
> `certutil -user -delstore Root <指纹>` 移除。

### 手动安装 mitmdump（备选）

若自动获取失败，可下载 mitmproxy 的 Windows 版，将其 `mitmdump.exe`
（以及同目录依赖，若为 onefile 版则单个文件即可）放到本目录 `bin\` 下。

---

## 使用

```bat
:: 暂停（写 .paused，看门狗休眠，清除 PAC 与环境变量）
stop-github-hosts.bat

:: 恢复
start-github-hosts.bat

:: 体检
powershell -NoProfile -ExecutionPolicy Bypass -File selfcheck.ps1

:: GitHub CLI 登录（可选）
gh-login.bat
```

改完 `src/config.yaml` 后重启代理即可生效：结束 `mitmdump` 进程，看门狗会在几秒内自动拉起。
或直接运行 `guard.ps1` 做一次深度检查。

---

## config.yaml 说明

| 域名 | SNI | 地址 | 用途 |
|---|---|---|---|
| github.com | `_github.com`（不发 SNI） | 140.82.116.3:443 | 主站 |
| *.github.com | `_github.com` | 140.82.116.3:443 | 子域兜底（uploads 等） |
| api.github.com | `_api.github.com` | 140.82.112.6:443 | REST API |
| codeload.github.com | `_codeload.github.com` | 140.82.112.9:443 | 仓库打包 |
| gist.github.com | `_github.com` | 140.82.112.4:443 | Gist |
| github.githubassets.com | `_github.githubassets.com` | 185.199.111.154:443 | 页面静态资源 |
| *.githubusercontent.com | `github.githubassets.com`（域前置） | 185.199.111.154:443 | raw / 头像 / Release 附件 |
| *.github.io | `_github.io` | 185.199.111.153:443 | GitHub Pages |

未映射的域名默认 TCP 直通（不影响其它网站）。

`guard.ps1` 里为每条映射维护了**候选 IP 池**，某条不通时会自动换下一个可用 IP。

---

## 常见问题（都是踩过的坑）

**Q：代理明明在跑，浏览器却打不开 GitHub / 表现为直连超时？**
Chromium 只在系统代理「字符串发生变化」时才重读。看门狗已内置强制刷新（周期性改写
`AutoConfigURL` 的 `#片段`，片段不会发给服务器，路径仍是 `/proxy.pac`）。若手动调试，
记得用「改变量 + 通知」，只调 `InternetSetOption` 是不够的。

**Q：`raw.githubusercontent.com` / 头像打不开？**
GitHub 自有 CDN 段 `185.199.108~111.**.133`、`.153` 会整段被封。本项目的做法是用
`185.199.111.154` + 域前置 SNI `github.githubassets.com`，`Host` 保持原样。

**Q：想确认 PAC 在系统层是否生效（不走浏览器）？**
```powershell
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
$p = [System.Net.WebRequest]::GetSystemWebProxy()
$p.GetProxy([Uri]'https://github.com/')   # 应返回 http://127.0.0.1:8180
$p.GetProxy([Uri]'https://example.com/')  # 应为直连
```

**Q：`curl` / `git` 走代理报 `schannel: server closed abruptly`？**
用 openssl 后端的 git（`http.sslBackend=openssl`）并指定 CA bundle；或加 `--ssl-no-revoke`。

**Q：看门狗日志里的 `PAC nudged` 是什么？**
强制浏览器重读 PAC 的动作，属于正常自愈行为。

**Q：开机自启在哪？**
1) `HKCU\...\Run\GithubHostsWatchdog`；2) 启动文件夹 `github-hosts-watchdog.vbs`；
3) 计划任务 `GithubHostsWatchdogLogon`。三者互相备份，互斥体保证只跑一个。

---

## 已知限制

- 大文件（codeload 打包、Release 附件）速度受链路影响，可能较慢。
- 上游 IP 会不定期被封；`guard.ps1` 能自动切换候选 IP，但候选池也需要偶尔维护。
- 仅面向 Windows。

---

## 免责声明

本项目用于在受限网络环境下访问 GitHub，仅做本地流量代理与可用性自愈。
请遵守你所在地区的法律法规，自行评估并承担使用风险。

---

## 鸣谢

- [feng2208/github-hosts](https://github.com/feng2208/github-hosts) —— mitmproxy 域名前置思路与插件
- [mitmproxy](https://mitmproxy.org) —— 代理内核

## License

[Apache-2.0](LICENSE)，保留上游版权与 NOTICE 声明。
