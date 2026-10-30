# Git Flow

本仓库采用简化的 Git Flow，与 CI / 发布脚本一致。

## 分支

| 分支 | 用途 |
|------|------|
| `main` | 生产稳定版；仅合并已验收的发布与 hotfix |
| `develop` | 集成 / 测试（beta）；日常功能合并到此分支 |
| `feature/*` | 从 `develop` 拉出，合并回 `develop` |
| `release/*`、`hotfix/*` | 可选；也可用 `main` / `develop` 直接打标签发布 |

Flutter（`flutter_app/`）是唯一桌面客户端。发布 Windows/Linux Flutter 包与
Windows Flutter 安装包，CLI/MCP 保持独立。完成 feature 后先合入 `develop`，
再将验收后的集成版本合入 `main` 发布；发布提交同步回 `develop`。

## 发布标签

| 类型 | 分支 | `__version__` / 标签 | GitHub Release |
|------|------|----------------------|----------------|
| 稳定版 | `main` | `X.Y.Z` / `vX.Y.Z` | `prerelease: false` |
| 测试版 (beta) | `develop` | `X.Y.Z-beta.N` / `vX.Y.Z-beta.N` | `prerelease: true` |

发布脚本检查分支：稳定版使用 `main`，beta 使用 `develop`。CI 校验标签与应用版本一致。

## 命令

在 `develop` 上集成完成后发布 beta：

```bash
git checkout develop
git pull origin develop
python packaging/release.py 0.16.0-beta.1 --dry-run
python packaging/release.py 0.16.0-beta.1
```

在 `main` 上发布稳定版（与原先相同）：

```bash
git checkout main
git pull origin main
python packaging/release.py 0.16.0 --dry-run
python packaging/release.py 0.16.0
```

推送失败续传：`python packaging/release.py <version> --resume`  
查询构建：`python packaging/release.py <version> --status`

## CI 行为

- 推送到 `main` 或 `develop`：跑测试并上传 **Artifacts**（不创建 Release）。
- 推送 `v*` 标签：同上，并把所有平台产物挂到 **GitHub Release**（beta 为 prerelease）。
- **Help → Check for updates** 仍只使用 GitHub `releases/latest`（排除 prerelease），用户不会自动收到 beta。

## Hotfix

1. 从 `main` 修 bug，合并回 `main`。
2. 在 `main` 打稳定标签发布。
3. 将 `main` 合并回 `develop`，保持集成分支同步。
