# mirror/ · Linux 版

让 `git clone/fetch/pull`（以及 Release/归档下载）**自动走最快的可用 GitHub 镜像**，`push` 仍直连 github.com。与 Windows 版 `mirror/*.ps1` 功能对齐。

## 文件

| 文件 | 作用 |
|------|------|
| `mirrors.txt` | 118 个镜像源 |
| `gh-fastest.sh` | 并行（`xargs -P16`）实测各源，按速度排序，写 `mirrors-ranked.json`（24h 缓存） |
| `gh-apply.sh` | `--apply/--refresh/--auto/--status/--off`；写 `--global` 的 `url.<m>.insteadOf` + `pushInsteadOf` + 无凭据/无代理；`--auto` 有去抖 |
| `bin/git` | git 垫片：clone/fetch/pull/submodule 触发 `gh-apply.sh --auto`（后台去抖）后再 `exec /usr/bin/git` |
| `ghdl` | 经最快镜像下载 Release/归档，并提示校验 SHA256 |
| `install.sh` / `uninstall.sh` | 装/卸（PATH 钩子 + `/usr/local/bin/git` 软链 + 每日刷新 timer） |

## 用法

```bash
gh-apply.sh --status        # 当前生效镜像
gh-apply.sh --refresh       # 全量重测并应用
gh-apply.sh --auto          # 快速复检 top 候选（垫片自动调用）
gh-apply.sh --off           # 移除改写，git 恢复直连
gh-fastest.sh --top 8       # 查看测速排名
ghdl https://github.com/OWNER/REPO/releases/download/vX/FILE
```

## 关键决策

- **作用域 `--global`**（仅 root），不污染 `--system`/其它用户；安装时会清理旧的 `--system` 单源键。
- **默认不改写 SSH**（`--include-ssh` 才改），私有库保持 SSH 直连。
- 镜像高死亡率（实测 10 个里常只剩 3 个活）——118 源的意义是**自动兜底**，不是提速。
