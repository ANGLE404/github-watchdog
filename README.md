# git看门狗 2.0A — 纯连通性监测（github-watchdog 2.0A）

> 只做一件事：**如实告诉你 GitHub 通 / 不通**，并把状态记录下来。
> 不改代理、不写死 IP、不动 DNS、不做任何 TLS 规避。

本目录是 **2.0A** 版本。它与仓库 `main` 分支上的 **v1.1（完整加速版）** 是两套不同定位的东西：

| | v1.1（main） | 2.0A（本版本） |
|---|---|---|
| 目标 | 让 GitHub 在受限网络里可访问 | 只监测 GitHub 是否可达 |
| 手段 | 本地代理 + 固定上游 IP + TLS 兼容处理 | 无（用你本来的网络直连检查） |
| 是否改系统代理 | 是（PAC） | **否** |
| 是否动 DNS / SNI | 是 | **否** |
| 能否让被阻断的网络连上 | 可以 | **不能** |

---

## 它做什么

- 按固定间隔，用**你当前的网络**直连探测几个 GitHub 端点：
  `github.com` / `api.github.com` / `raw.githubusercontent.com` / `github.githubassets.com`
- 记录 HTTP 状态码与耗时，判断 **通 / 部分通 / 不通**；
- 状态写入 `status.json`，事件写入 `monitor.log`；
- 探测进程自身有自愈：异常不退出、由计划任务负责崩溃重启（见 `install-monitor.ps1`）。

## 它明确不做

- 不设置 / 不修改系统代理、PAC、环境变量；
- 不写死任何 IP，不改 hosts，不改 DNS；
- 不做 SNI 省略 / 替换等任何 TLS 层处理；
- 因此**它无法让被阻断的网络访问 GitHub**——如果探测结果是"不通"，那是网络本身的问题，它只会如实报出来。

---

## 文件

```
monitor.ps1            常驻监测循环（写 status.json / monitor.log）
check.ps1              一次性检查（打印 通/不通 结论）
monitor-launcher.vbs   隐藏窗口拉起 monitor.ps1
install-monitor.ps1    注册开机自启（Run 键 + 登录计划任务）并启动
uninstall-monitor.ps1  停止并移除自启
LICENSE                Apache-2.0
```

## 使用

```powershell
# 一次性检查
powershell -NoProfile -ExecutionPolicy Bypass -File check.ps1

# 常驻监测（前台）
powershell -NoProfile -ExecutionPolicy Bypass -File monitor.ps1

# 安装为开机自启（可选）
powershell -NoProfile -ExecutionPolicy Bypass -File install-monitor.ps1

# 卸载
powershell -NoProfile -ExecutionPolicy Bypass -File uninstall-monitor.ps1
```

## 输出示例

`status.json`：

```json
{
  "time": "2026-09-18T00:50:00",
  "githubReachable": false,
  "partial": true,
  "targets": [
    { "name": "github.com", "code": "000", "ok": false, "seconds": "15.0" },
    { "name": "api.github.com", "code": "200", "ok": true, "seconds": "1.2" }
  ],
  "systemPac": null,
  "systemProxy": null
}
```

`monitor.log`：

```
2026-09-18 00:50:00  GitHub NOT reachable (不通)
2026-09-18 00:50:00    github.com: HTTP 000 (15.0s)
2026-09-18 00:52:00  GitHub reachable (通)
```

> `status.json` 里还会顺带记录当前**系统代理状态**（PAC / 固定代理），
> 方便你确认"此刻没有别的程序在替你改代理"。

---

## 说明

- 2.0A 不包含 v1.1 的代理内核（`mitmdump` / `src/github-hosts.py` / `config.yaml`），
  也没有证书、PAC、计划任务以外的系统改动。
- 若你所在网络对 GitHub 有阻断，2.0A 只会如实报"不通"；
  能否访问取决于你的网络本身，必要时请咨询网络管理员或使用合规渠道。

## License

[Apache-2.0](LICENSE)
