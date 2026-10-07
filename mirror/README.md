# 下载加速模块（mirror）

给 **git / CLI 下载** 单独加的加速层，与主项目的“浏览器 PAC 代理”互补：

- 主代理（`install.ps1` + mitmproxy）解决**浏览器访问 github.com**；
- 本模块解决 **`git clone/fetch/pull`、`npx`、Release/Archive 下载**——它不去改本机
  hosts/代理，而是把 GitHub 请求**改写到当前最快的第三方镜像前缀**，并在**每次 git 下载
  时自动重新测速、择优切换**。

> 只适用**公开仓库**。镜像是第三方只读中转，绝不能用来推代码或拉私有库（那样会失败）。

---

## 特性

| 能力 | 说明 |
|---|---|
| 全量候选池 | `mirrors.txt` 内置 118 个社区镜像前缀（来自 moretools / github.akams.cn / gitwarp 等聚合站） |
| 自动测速 | `gh-fastest.ps1` 并行实测全部候选，按吞吐排序并缓存 24h |
| 每次自动换 | `bin\git.cmd` 垫片：`clone/fetch/pull/submodule` 时后台**去抖**复测当前最快若干候选，发现更快才切换，不阻塞当次命令 |
| 写入 git 配置 | `gh-apply.ps1` 把 `url.<镜像>.insteadOf` 写进全局配置：clone/fetch/pull 走镜像，**push 仍直连 github.com** |
| 无弹窗 / 不卡代理 | 对镜像域名自动禁用凭据助手与本地代理，直连镜像（MB/s 级） |
| 可一键还原 | `gh-apply.ps1 -Off` + `uninstall-mirror.ps1` 完全恢复 |

实测（本机直连 16 MB 文件）：`gh-proxy.com` ~4.9 MB/s，`gh.padao.fun` ~3.9 MB/s，
`ghproxy.sakuramoe.dev` ~3.7 MB/s。

---

## 目录结构

```
mirror/
├─ README.md              本文档
├─ install-mirror.ps1     一键安装：profile 钩子 + 选最快镜像写入 git 配置
├─ uninstall-mirror.ps1   卸载：移除 profile 钩子 + 还原 git 配置
├─ gh-apply.ps1           核心：测速结果写入/撤销全局 git 配置（支持 -Auto/-Off/-Status）
├─ gh-fastest.ps1         并行测速全部镜像，输出最快列表（缓存 mirrors-ranked.json）
├─ mirrors.txt            候选镜像前缀（每行一个 https://xxx/ ）
└─ bin/
   └─ git.cmd             git 透传垫片（每次下载自动复测）
```

运行期文件（`mirrors-ranked.json`、`auto.lock`、`applied.json`）已加入 `.gitignore`。

---

## 安装

```powershell
# 在 mirror\ 目录下
powershell -NoProfile -ExecutionPolicy Bypass -File install-mirror.ps1
```

它会：

1. 如执行策略为 `Restricted`，把**当前用户**策略设为 `RemoteSigned`（无需管理员，可随时改回）；
2. 把一个带标记的代码块追加到 `$PROFILE`，让新开的 PowerShell 会话里 `git`（以及从该
   shell 启动的 `npx` 等）优先命中 `bin\git.cmd` 垫片；
3. 跑一次 `gh-fastest.ps1` 选最快镜像，并写入全局 git 配置。

装完**新开一个 PowerShell 窗口**生效。

### 手动设置（不想用 profile 钩子）

只想让 git 用镜像、不需要“每次自动换”时，直接：

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File gh-apply.ps1
```

---

## 使用 / 管理

```powershell
$s = "路径\github-watchdog\mirror"

powershell -File "$s\gh-apply.ps1"            # 选最快镜像并应用
powershell -File "$s\gh-apply.ps1" -Auto      # 快速复选（复测当前最快的若干候选）
powershell -File "$s\gh-apply.ps1" -Refresh   # 全量重测后应用
powershell -File "$s\gh-apply.ps1" -Status    # 查看当前使用的镜像
powershell -File "$s\gh-apply.ps1" -Off        # 撤销，git 恢复直连

powershell -File "$s\gh-fastest.ps1" -Top 10   # 只测速、不出排名缓存以外的改动
```

参数：`gh-apply.ps1 -Auto` 支持 `-Quick 6 -QuickTimeout 4 -DebounceMinutes 3`。

还原：`uninstall-mirror.ps1`。

> 拉私有库前先 `-Off`（镜像无法认证），或参考“已知限制”给单个仓库加直连例外。

---

## 工作原理

1. **前缀改写**：镜像 URL = `<前缀>` + `<原始 GitHub URL>`，例如
   `https://gh-proxy.com/https://github.com/OWNER/REPO.git`。
2. **写进 git 配置**（仅这些键，均可还原）：

   ```
   url."<镜像><https://github.com/>".insteadOf = https://github.com/ / git@github.com: / ssh://git@github.com/ / git://github.com/
   url."https://github.com/".pushInsteadOf     = 同上各种形式        # push 直连
   credential."https://<镜像域名>".helper = ""                       # 不弹凭据窗
   http."https://<镜像域名>".proxy        = ""                       # 直连镜像，绕开本地 mitmproxy
   ```

3. **测速**：`gh-fastest.ps1` 对每个前缀请求一个固定 16 MB 的归档文件（`curl --max-time`），
   按 `%{speed_download}` 排序；`-Auto` 只复测当前最快的少数候选（快、够用）。
4. **每次自动换**：`git.cmd` 在下载类子命令上以后台方式触发一次 `gh-apply.ps1 -Auto`
   （3 分钟去抖），当前命令立刻用“上次的最快”，后台测完若发现更快就更新配置，下次生效。

---

## 镜像来源与安全

- 候选前缀来自公开聚合站（moretools、github.akams.cn、gitwarp 等），均为**第三方**服务，
  会缓存/中转公开内容。请仅用于拉公开仓库；**不要在镜像站点登录 GitHub 账号**。
- 测速只比较吞吐，不代表内容可信。重要文件建议对照官方 SHA256 校验后再使用。
- 本项目只做“把请求指向更快的公开中转”，不修改官方仓库内容，也不涉及任何账号凭据。

---

## 已知限制

- **仅公开仓库**：私有库需 `-Off` 后直连；或给该仓库加更长的 `insteadOf` 例外以绕过镜像。
- 每次自动换依赖 `$PROFILE` 钩子（PowerShell）。在 cmd / 其它 shell 中，git 仍会走“上次选出的
  最快镜像”，但不会自动复测；可手动跑 `gh-apply.ps1 -Auto`。
- 镜像可用性会波动；`gh-fastest.ps1` 会自动过滤失败项，必要时用聚合站刷新 `mirrors.txt`。
- 仅面向 Windows。
