# github-watchdog · Linux 版

在受限/被污染的网络上稳定访问 GitHub 的**自愈式加速器**。这是 Windows 版（仓库根目录的 `.ps1`/`.bat` + `mirror/`）的 Linux 移植，与 Windows 版并行维护。

面向 Debian/Ubuntu（已在 Ubuntu 26.04 + Python 3.12 上实测）。以 root 运行，部署到 `/opt/github-hosts`。

## 三层结构

| 层 | 作用 | 组件 |
|----|------|------|
| **hosts 核心** | mitmproxy 域前置：把 github.com / api / codeload 的 TLS 连接改写到直连可达的 IP，`*.githubusercontent.com` 走域前置 | `core/github-hosts.py` + `src/config.yaml` + `github-hosts.service` |
| **自愈守卫** | 定期经代理实测各链路，坏了就用候选池换 IP、重启、验证，全失败则回滚 | `ghcommon.py` / `update_ips.py` / `guard.py` / `selfcheck.sh` |
| **git 镜像** | git 大流量（clone/fetch/pull）自动走最快的第三方镜像；push 仍直连 github.com | `mirror/`（见下） |

除此之外：
- `profile.d/github-proxy.sh` —— 登录 shell 里给**非 git 工具**（curl/wget 等）设本地代理，同时把国内源（pip/apt/HF/镜像站）和 LAN 放进 `no_proxy` 直连。
- `profile.d/github-mirror.sh` —— 把 `mirror/bin` 前插到 PATH，使 `git` 命中垫片。

## 目录

```
linux/
  install.sh / uninstall.sh     # 顶层安装/卸载
  start.sh stop.sh status.sh    # 启停与总览
  selfcheck.sh                  # ~19 项体检（失败自动重刷 IP+重启）
  ghcommon.py                   # 公共库：配置读写、代理探活、TCP 测速、候选池
  update_ips.py                 # 每日：Meta API→第三方 seeds→doh.pub 发现候选→测速→应用(验证+回滚)
  guard.py                      # 每 15min：逐链路探活→换 IP→验证→回滚
  core/
    github-hosts.py             # mitmproxy 插件
    config.yaml                 # 映射模板（运行时会按 IP 重写）
  systemd/                      # 9 个 unit（service + timer）
  profile.d/                    # 两个 profile 片段
  mirror/                       # git 加速模块（见 mirror/README）
  tools/gh-release-upload.py    # Release 附件上传绕过（见下）
```

## 安装

```bash
sudo bash install.sh
```

安装脚本会：建 venv 装 `mitmproxy==10.4.2`、装插件与脚本、落 systemd unit、首次启动生成 CA 并入系统信任库、启用三个 timer（update 每日 / health 5min / guard 15min）、写 profile.d、装 git 镜像模块。

## 运维

```bash
gh-status                      # 服务/定时器/当前 IP/镜像/候选池/最近日志 总览
sudo bash /opt/github-hosts/selfcheck.sh   # 完整体检
sudo bash /opt/github-hosts/update_ips.py  # 立即重发现（验证+回滚）
sudo bash /opt/github-hosts/guard.py       # 立即逐链路守卫
gh-start / gh-stop             # 启停
```

## 原理速记

- **连通**：直连 github.com 被 SNI 重置时，经 mitmproxy 把连接指向 Meta API 公布的可用 IP，并置空上游 SNI（`sni: "_github.com"`）。`*.githubusercontent.com` 用域前置（`sni: www.yelp.com`）。
- **自愈**：`update_ips.py` 用官方 `api.github.com/meta` + GitHub520 seeds + `doh.pub` 兜底生成候选池（TCP:443 测速排序，写 `dynamic-ips.json`），逐个经代理验证后写 `config.yaml` 并重启；`guard.py` 每 15min 复检并换 IP，**任何候选失败都回滚**。
- **大流量**：代理只擅长小请求（实测 ~10 KB/s），clone/fetch 走镜像（实测 ~1.7 MB/s）。
- **私有库安全**：默认**只改写 `https://`**，`git@github.com:` / `ssh://` 形式不动 → 私有库保持 SSH 直连，绝不经第三方镜像（避免 token 泄露）。HTTPS 私有库会被镜像，**不要这样用**。

## Release 附件上传（`uploads.github.com` 特殊处理）

`gh release upload` / REST 的附件上传走 **`uploads.github.com`**，它有两个坑：

1. 不在 `*.github.com` 通配 IP 上 —— 用通配 IP（`140.82.116.3`）会返回 **404**；真实前端在 Azure 段 `20.205.243.161`。
2. 该 IP **发 TLS SNI 会被重置**，必须省略 SNI。

`config.yaml` 已加入显式映射：

```yaml
- hosts: [uploads.github.com]
  sni: "_github.com"          # 省略 SNI
  address: 20.205.243.161:443
```

即便如此，`gh release upload` 经 mitmproxy 仍可能 `unexpected EOF`（代理层二次 TLS 处理所致）。**可靠兜底**是 `tools/gh-release-upload.py`：绕开代理，直接向 Azure 前端建 **无 SNI** 的原始 TLS 连接并 POST：

```bash
# 解析 release id 用 gh（需代理环境），上传本体直连
HTTPS_PROXY=http://127.0.0.1:8180 \
  python3 /opt/github-hosts/tools/gh-release-upload.py OWNER/REPO TAG FILE [FILE ...]
```

失败会自动在 `.161/.162/.165/.167` 间轮换。token 取自 `$GH_TOKEN` 或 `gh auth token`。

## 安全 / 边界

- 第三方镜像能看到你 clone 的公开仓库流量；**私有仓库一律用 SSH**。
- `profile.d/github-proxy.sh` 只对登录 shell 生效；`no_proxy` 已排除国内源与 LAN。
- 运行时状态（`dynamic-ips.json` / `meta-cache.json` / `*.log` / `*.pem`）已在 `.gitignore` 中，不会入库。
