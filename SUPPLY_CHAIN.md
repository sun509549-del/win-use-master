# 供应链与许可证清单

> 更新日期：2026-09-21
> 目标：让构建、CI 与发布所信任的外部组件可见，并让新增依赖必须经过显式审查。

## 当前依赖面

| 类型 | 当前依赖 | 用途 | 获取/执行方式 |
|---|---|---|---|
| 操作系统 | Windows 10/11 API、UI Automation、DWM、COM | 桌面发现、控制与取证 | 系统提供，不由仓库下载 |
| 运行时 | PowerShell 7 与其 .NET 运行时 | 主入口、测试、`Add-Type` 编译 C# helper | 用户/CI 预装；仓库不执行包恢复 |
| 可选运行时 | Node.js 22 或 24 | CDP 客户端与无头回归 | 用户预装或 CI 的 `setup-node` |
| 可选应用 | Edge/Chromium | CDP 真实集成与性能 fixture | 使用本机现有安装，不由测试下载安装 |
| GitHub Action | `actions/checkout@3d3c42e5aac5ba805825da76410c181273ba90b1` | 检出源码 | 固定完整 commit；注释版本 v7.0.1 |
| GitHub Action | `actions/setup-node@820762786026740c76f36085b0efc47a31fe5020` | 选择 Node 版本 | 固定完整 commit；注释版本 v7.0.0 |

仓库当前没有 `package.json`、lockfile、Python requirements、NuGet/csproj、Cargo、Go 或 Ruby 包清单；生产脚本和测试不运行 `npm install`、`pip install`、`Install-Module`、`dotnet restore`、Chocolatey 或 Winget。Node 代码只依赖目标 Node 版本提供的 API，C# helper 只引用 Windows/运行时程序集。

## 许可证

- 本仓库源码按根目录 [`LICENSE`](LICENSE) 中的 MIT License 发布，并保留 Huashu（花叔）署名。
- 仓库没有 vendored 第三方源码、二进制库或包管理依赖。
- GitHub Actions 不随仓库分发；升级固定 commit 前，维护者必须在其官方仓库核对来源、变更和许可证，并记录审查后的版本注释。

## 自动检查

`tests/repository-hygiene-contract.ps1` 对 tracked 与未忽略的 untracked 源文件执行：

1. 高置信私钥、GitHub/AWS/Slack/Google/OpenAI token 与常见 secret 赋值模式扫描；
2. 拒绝误入库的 DLL/EXE/PDB/archive，以及不在 `assets/public/` 的 PNG/JPEG/GIF/BMP/WebP；
3. 拒绝未登记的包管理 manifest/lockfile；
4. 将所有 workflow `uses:` 限制为本文件列出的完整 commit；
5. 拒绝 CI 内的包安装/恢复命令，并验证 MIT 许可证与本清单存在。

这是高置信、低依赖的仓库门，不是完整的秘密检测或恶意代码证明。历史提交、GitHub 仓库设置、Action 上游账户和 runner 镜像仍需维护者审查；疑似泄露时应先轮换凭据，再按 [`SECURITY.md`](SECURITY.md) 处理。

正式发布还必须对实际分发的源码归档生成 SHA-256，并把版本、tag、published commit 与校验和写入对应 Release Notes。不要把 GitHub 自动生成且内容规则可能变化的归档链接当作稳定校验对象；详细门槛见 [`references/版本与发布.md`](references/版本与发布.md)。

## 新增或升级依赖

PR 必须说明用途、为什么标准库不足、来源与许可证、固定方式、更新/撤回策略、运行时权限和网络行为，并同步本清单及测试。不得仅为方便引入会上传源码、日志、截图、UIA map、DOM 或动作收据的服务。Action 必须固定完整 commit；浮动 tag 或 branch 不可进入 CI。
