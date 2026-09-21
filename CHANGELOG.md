# Changelog

本项目的正式版本变化记录在这里。当前尚未创建发布 tag；以下内容属于未发布候选，不应引用为已经发布的版本。

## [Unreleased]

目标候选：`0.1.0-beta.1`。

### Added

- Windows 四层控制面、只读 doctor、机器可读结果、建议性能力缓存、临时对象 dry-run 和只读性能基线。
- 分层测试调度器、Windows CI、Node 22/24 CDP 矩阵及 UIA/CDP/窗口状态契约。
- 机器可读应用档案、确定性能力矩阵、安全档案测试模板，以及 UIA/CDP/COM 三类脱敏文字案例。
- 威胁模型、供应链清单、贡献/安全/行为规范和 GitHub Issue/PR 模板。

### Changed

- UIA、L2 和 CDP 使用同一版本化最终动作规则；Unicode、camelCase 和分隔符规范化由跨运行时契约守护。
- Excel/WPS 真实档案的证据清理进入最外层 `finally`，WPS 第二私有实例失败时尝试关闭自有工作簿并退出。

### Fixed

- 修复多个 `pwsh`/`node` PATH 结果可能被拼成单一进程路径的问题。
- 修复 UWP 宿主识别、Document ValuePattern、隐藏窗口状态、UIA provider 超时隔离和 CDP target/owner 混淆等问题。

### Security

- 最终动作、目标歧义、写后 unknown、证据隐私、清理边界和供应链漂移均改为失败关闭并加入契约。
- 原始截图、UIA/CDP 快照、账号正文、绝对用户路径和动态身份不得进入公开案例或仓库。

发布时把本节内容复制到对应版本标题并填写发布日期；在 tag、目标 commit 和远程 CI 确认前不得删除 `[Unreleased]`。
