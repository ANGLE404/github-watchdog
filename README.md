# git看门狗 (github-watchdog)

> 让 GitHub 访问「开机即用、断了自己爬起来」的本地代理与自愈工具。

`github-watchdog` 基于 [feng2208/github-hosts](https://github.com/feng2208/github-hosts) 的
mitmproxy 方案，补上了它在实际使用中最缺的三件事：**浏览器肯用代理**、
**上游地址不可达时会自己换**、**代理设置被清掉时会自己修**。

> **版本**
> - `main` = **v3.3**：完整加速版（v3.0 上游 IP 自动发现 + v3.1 无窗口后台任务 + v3.2 `*.github.io` 深度守卫）
>   **+ Linux 移植**（`linux/`：systemd + Python + bash，含 git 镜像模块，功能对齐 Windows 版）。
> - 分支 [`v2.0A`](../../tree/v2.0A) = **纯连通性监测**：不改代理、不写死 IP、不动 SNI，
>   只如实报告 GitHub 通 / 不通。

> **Linux 版**：仓库根目录为 Windows 版（`.ps1`/`.bat`/`.vbs` + PowerShell 版 `mirror/`）；
> **Linux 移植版全部在 [`linux/`](linux/) 目录**（systemd + Python + bash，含 git 镜像模块），
> 与 Windows 版功能对齐、并行维护。见 [linux/README.md](linux/README.md)。

---

## 特性

| 能力 | 说明 |
|---|---|
| 类 PAC 白名单代理 | 只把 GitHub 相关域名（github.com / api / codeload / gist / githubusercontent / githubassets / github.io）走本地代理，其它流量直连 |
| 固定上游地址 | 所有上游地址写死为 GitHub 官方 IP，不受本机 DNS 解析结果影响 |
| TLS 兼容处理 | 针对部分网络下 TLS 握手易被干扰的情况，按域名做 SNI 省略 / 替换，提高握手成功率 |
| 浏览器 PAC 强制刷新 | Chromium 对「值没变」的系统代理不会重读 —— 看门狗会周期性 nudge 强制它重读 |
| 开机自启（三层） | Run 键 + 启动文件夹 + 计划任务登录触发，命名互斥体保证只跑一个 |
| 看门狗自愈 | 进程挂了 / 端口不通 → 自动重启 |
| 深度守卫 + IP 自动切换 | 每 15 分钟走代理实测 6 条链路；某域名不通 → 在候选 IP 池里自动切换并验证，失败则回滚 |
| 自检脚本 | 一条命令体检 19 项：进程/端口/PAC/自启/链路/git/gh；另有 `gh-status.bat` 双击速查 |
| 一键启停 / 登录 | `start-github-hosts.bat` / `stop-github-hosts.bat` / `gh-login.bat` |
| **IP 自动发现（3.0）** | `update-ips.ps1` 调官方 Meta API（并用第三方 hosts 订阅作候选种子），本机 TCP 测速后写入 `dynamic-ips.json`；`guard.ps1` 自动采用，失败照旧回滚 |
| **解包残留清扫（2026-09-26）** | PyInstaller onefile 的 mitmdump 每次启动都会在 `%TEMP%` 解包约 45 MB；`sweep-mei.ps1` 保留最近几个 `_MEI*` 目录并给日志封顶，看门狗重启前也会先清扫，避免残留无限累积 |
| **重启节流与熔断（2026-09-26）** | 看门狗引入 `.restarting` 重启锁、冷却时间与突发熔断，避免与 `guard.ps1` 抢跑导致反复重启 |
| **下载加速（git / 文件）** | `mirror/`：把 `git clone/fetch/pull` 与 CLI 下载改写到**当前最快的第三方镜像**，**每次使用自动测速切换**；`push` 仍直连 github.com。详见 [mirror/README.md](mirror/README.md) |

---

## 2026-09-26 加固：解包残留与重启风暴

PyInstaller 打包的 `mitmdump.exe` 是 onefile 形式，**每次启动都会把自己解包到 `%TEMP%\_MEIxxxxxx`**，
进程异常退出时这些目录不会自动清理。曾有看门狗与 guard 互相抢跑反复重启，7.9 天累积
**10078 个目录 / 442.8 GB**，吃满 C 盘。本次加固：

- `sweep-mei.ps1`：只保留最近 `$KEEP` 个 `_MEI` 目录，其余清理（正在使用的因占用会跳过）；
  同时给没有自带轮转的 `mitmdump.log` 等日志封顶。由计划任务 `GithubHostsMeiSweep` 每 2 分钟兜底，
  `watchdog.ps1` / `guard.ps1` 在重启 mitmdump 前也会调用。
- `watchdog.ps1`：尊重 `guard.ps1` 的 `.restarting` 锁；加入 `COOLDOWN` 冷却、`MAXBURST` 突发熔断，
  并检测「脚本已更新但旧进程仍在跑」时自动重载。
- `guard.ps1`：换 IP 重启期间持锁，并在重启前清扫残留。

---

## 下载加速（git / 文件）

主代理解决的是**浏览器**访问 github.com；而对 **`git clone`、`npx`、Release/Archive 下载**
这类“命令行大流量”，本仓库额外带了一个独立模块 `mirror/`：

- 内置 118 个社区镜像前缀，**并行测速**取当前最快的；
- 写进 git 全局配置后，`clone/fetch/pull` 自动走镜像，**`push` 仍走官方 github.com**；
- `bin\git.cmd` 垫片让**每次 git 下载都在后台复测一次**，发现更快的镜像自动切换；
- 对镜像域名禁用凭据弹窗、绕开本地代理直连，实测可达数 MB/s。

```powershell
cd mirror
powershell -NoProfile -ExecutionPolicy Bypass -File install-mirror.ps1
```

一键还原：`mirror\uninstall-mirror.ps1`。只适用**公开仓库**（私库请先关闭，见模块文档）。

---

---

## 3.0：上游 IP 自动发现

GitHub 会不定期调整 IP，本版本让工具**自己找候选**，减少手动维护。

- `update-ips.ps1`
  1. 拉取官方 `https://api.github.com/meta`（**先走本地代理 → 再直连 → 第三方订阅 → 本地缓存** 依次回退）；
  2. 从 `web / api / git / pages` 网段按各服务的末位约定生成候选；
  3. 并入第三方 hosts 订阅（如 GitHub520 `raw.hellogithub.com/hosts`）作为**候选种子**；
  4. 对候选做**本机 TCP:443 测速**，把可达的按延迟排序写入 `dynamic-ips.json`。
  - 它**只发现、不改配置、不重启代理**，随时可安全运行。
- `guard.ps1`：某条映射不通时，候选池 = **内置静态池 + `dynamic-ips.json` 动态池**；
  逐个改配置并**端到端验证**，成功即保留，全部失败则**回滚**。
- `guard.ps1` 还会**自动注册每日更新任务** `GithubHostsUpdateIPs`（登录时 + 每天 03:00），并在动态池超过 24 小时时自动刷新。

> 安全网始终保留：**连通性测试 + SNI 策略验证（经由代理端到端）+ 失败回滚**。
> 自动发现的只是"候选"，能不能用一律以本机实测为准。

### 为什么仍然做不到"永远零维护"

- **SNI 策略会失效**：`省略 SNI / SNI 对齐` 是针对特定干扰特征的技巧；一旦对端 TLS 行为变化，换 IP 救不了。
- **可达性是动态的**：Meta 给的只是"归属网段"，今天通的 IP 明天可能被干扰 —— 实时测速与切换必须常驻。
- **证书与 IP 的对应会变**：如 `githubusercontent` 走 `SNI=github.githubassets.com` 的对齐规则，若证书不再匹配就会 TLS 失败。
- **Meta 端点本身可能不可达**：所以需要第三方订阅/缓存等备用获取渠道。

现实目标：**把"找最新 IP"完全自动化，但"测速、SNI 验证、回滚"这些安全网永远保留。**

---

## 工作原理（一句话版）

```
浏览器 --PAC(仅GitHub域名)--> 127.0.0.1:8180 (mitmdump + github-hosts.py)
                                   |
                                   | 按配置改写 SNI / 目标 IP
                                   v
                           GitHub 官方 IP（写死，不依赖本机 DNS 与默认 SNI）
```

关键设计点：

1. **写死 IP，不查 DNS**：`github.com / api / codeload / gist` 分别指向 `140.82.112~116.x`，
   `*.githubusercontent.com / githubassets` 指向 `185.199.10x.154`。
2. **SNI 省略**：部分网络中明文 SNI 会导致连接被重置；`sni: _github.com` 表示握手时不
   发送 SNI，服务端只认 HTTP 的 `Host` 头，路由依然正确。
3. **SNI 对齐**：当某 IP 的默认证书与目标域名不匹配时（例如 `185.199.111.154` 的证书是
   `*.githubassets.com`），把 SNI 设成该证书真实包含的名字，`Host` 保持不变 ——
   CDN 按 Host 返回正确内容，TLS 校验也能通过。

---

## 目录结构

```
github-watchdog/
├─ install.ps1            安装：定位 mitmdump、装 CA、设 PAC、注册自启、启动自检
├─ uninstall.ps1          卸载：清自启、停代理、清 PAC 与环境变量
├─ watchdog.ps1           看门狗：保活 + PAC 强制刷新 + 重启节流/熔断
├─ guard.ps1              深度守卫：链路实测 + IP 自动切换（含回滚）
├─ update-ips.ps1         上游 IP 自动发现（官方 Meta API + 第三方种子）
├─ sweep-mei.ps1          清理 PyInstaller _MEI 解包残留 + 日志封顶
├─ selfcheck.ps1          自检（19 项）
├─ mitmdump-run.cmd       稳定拉起 mitmdump（stdin=NUL，输出到日志）
├─ *-launcher.vbs         隐藏窗口拉起各后台脚本（watchdog/guard/update-ips/sweep）
├─ start-github-hosts.bat / stop-github-hosts.bat
├─ gh-status.bat          双击速查（进程/端口/PAC/环境变量/链路）
├─ gh-login.bat           GitHub CLI 设备码登录（可选）
├─ docs/
│  └─ git-credentials-and-ssh.md   git/gh 凭据与 SSH 的受限网络配置说明
├─ skills/
│  └─ github-access-setup/   可移植的 opencode skill：受限网络下让 git/gh/SSH 可用
├─ src/
│  ├─ github-hosts.py     mitmproxy 插件（来自上游）
│  └─ config.yaml         映射配置（本项目加固版）
├─ bin/                   放置 mitmdump.exe（不随仓库提交）
└─ mirror/                下载加速模块（git / 文件 → 最快第三方镜像），见其 README
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

:: 双击速查（进程/端口/PAC/环境变量/链路）
gh-status.bat
```

> `git` / `gh` 在受限网络下的 **凭据与 SSH 配置**（含 `git` 走代理、信任 mitmproxy 的 CA、
> `gh auth setup-git`、SSH 的可行性边界）见
> [`docs/git-credentials-and-ssh.md`](docs/git-credentials-and-ssh.md)。**该文档与本仓库均不含任何令牌或私钥。**

### 配套 opencode skill

[`skills/github-access-setup/`](skills/github-access-setup/SKILL.md) 把上面这套流程封装成一个
**可移植的 AI 技能**：自动诊断 git/gh/SSH 传输、配置代理与 CA、把 GitHub 的 SSH 地址自动
重写为 HTTPS、并在发布前扫描脱敏。复制到 `~/.config/opencode/skills/` 并重启 opencode 即可生效
（详见 [`skills/README.md`](skills/README.md)）。

改完 `src/config.yaml` 后重启代理即可生效：结束 `mitmdump` 进程，看门狗会在几秒内自动拉起。
或直接运行 `guard.ps1` 做一次深度检查。

---

## config.yaml 说明

| 域名 | SNI | 地址 | 用途 |
|---|---|---|---|
| github.com | `_github.com`（省略 SNI） | 140.82.116.3:443 | 主站 |
| *.github.com | `_github.com` | 140.82.116.3:443 | 子域兜底（uploads 等） |
| api.github.com | `_api.github.com` | 140.82.112.6:443 | REST API |
| codeload.github.com | `_codeload.github.com` | 140.82.112.9:443 | 仓库打包 |
| gist.github.com | `_github.com` | 140.82.112.4:443 | Gist |
| github.githubassets.com | `_github.githubassets.com` | 185.199.111.154:443 | 页面静态资源 |
| *.githubusercontent.com | `github.githubassets.com`（SNI 对齐） | 185.199.111.154:443 | raw / 头像 / Release 附件 |
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
GitHub 自有 CDN 段 `185.199.108~111.**.133`、`.153` 在部分网络下会整段不可达。本项目
的做法是用 `185.199.111.154` + SNI `github.githubassets.com`，`Host` 保持原样。

**Q：想确认 PAC 在系统层是否生效（不走浏览器）？**
```powershell
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
$p = [System.Net.WebRequest]::GetSystemWebProxy()
$p.GetProxy([Uri]'https://github.com/')   # 应返回 http://127.0.0.1:8180
$p.GetProxy([Uri]'https://example.com/')  # 应为直连
```

**Q：`curl` / `git` 走代理报 `schannel: server closed abruptly`？**
用 openssl 后端的 git（`http.sslBackend=openssl`）并指定 CA bundle；或加 `--ssl-no-revoke`。

**Q：`git clone/push` 用什么凭据？会不会把 token 写进仓库？**
用 HTTPS + `gh` 凭据助手：token 只存在 `gh` 的凭据存储里，git 通过
`gh auth git-credential` 取用，**配置与仓库里都不落盘任何令牌**。
`git@github.com` 的 SSH 本机直连被墙，只有存在可用 SOCKS 代理时才能走通。
详见 [`docs/git-credentials-and-ssh.md`](docs/git-credentials-and-ssh.md)。

**Q：看门狗日志里的 `PAC nudged` 是什么？**
强制浏览器重读 PAC 的动作，属于正常自愈行为。

**Q：开机自启在哪？**
1) `HKCU\...\Run\GithubHostsWatchdog`；2) 启动文件夹 `github-hosts-watchdog.vbs`；
3) 计划任务 `GithubHostsWatchdogLogon`。三者互相备份，互斥体保证只跑一个。

---

## 已知限制

- 大文件（codeload 打包、Release 附件）经浏览器 PAC 代理时速度受链路影响，可能较慢；
  命令行侧的 `git clone` / Release 下载建议走 `mirror/` 模块（第三方镜像，实测数 MB/s）。
- 上游 IP 会不定期变得不可达；`guard.ps1` 能自动切换候选 IP，但候选池也需要偶尔维护。
- 仅面向 Windows。

---

## 免责声明

本项目用于提升 GitHub 访问的稳定性与可用性，仅做本地流量代理与可用性自愈。
请遵守你所在地区的法律法规，自行评估并承担使用风险。

---

## 鸣谢

- [feng2208/github-hosts](https://github.com/feng2208/github-hosts) —— mitmproxy 代理方案与插件
- [mitmproxy](https://mitmproxy.org) —— 代理内核
- 社区 GitHub 镜像聚合站（moretools / github.akams.cn / gitwarp 等）—— `mirror/` 的候选镜像前缀来源

## License

[Apache-2.0](LICENSE)，保留上游版权与 NOTICE 声明。
