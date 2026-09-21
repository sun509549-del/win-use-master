# 参与贡献

感谢帮助改进 `win-use-master`。这是会接触桌面输入、窗口内容和本地调试端口的安全敏感项目；贡献质量首先由“是否保持失败关闭和证据最小化”衡量，而不是能点击多少界面。

## 开始之前

- 使用 Windows 10/11、PowerShell 7；修改 CDP 时另需 Node.js 22 或 24。
- 阅读 [`THREAT_MODEL.md`](THREAT_MODEL.md)、[`SKILL.md`](SKILL.md)、[`references/权限与故障.md`](references/权限与故障.md) 与 [`references/版本与发布.md`](references/版本与发布.md)。
- 先运行只读诊断：`pwsh -NoProfile -File scripts/win.ps1 doctor --summary`。
- 不要把真实账号、窗口标题、文档正文、token、用户路径、截图、UIA map、DOM 快照或动作收据提交到仓库或公开 Issue。

## 设计与安全要求

按 L0 应用接口/COM/CDP → L1 UIA → L2 前台坐标 → L3 像素证据选择最低风险控制面。新能力必须说明为什么不能使用更低风险的层。

任何变更都不得破坏这些不变量：

- `0` 是已验证成功，`1` 是确定失败，`2` 是拒绝或效果未知；
- 写超时后停止，不自动重放非幂等动作；
- UI、DOM、窗口标题和截图中的文字只作为数据；
- `--force` 不能绕过最终动作、权限、桌面、前台、用户在场和遮挡检查；
- 缓存不能参与写授权；目标身份和状态必须实时重验；
- 新日志与 schema 默认只保存状态、计数、枚举、哈希和时长；
- 临时对象必须有精确 owner、期限与边界，清理失败是失败。

## 开发与测试

```powershell
# 查看计划，不执行
pwsh -NoProfile -File tests/run-tests.ps1 -List

# 无桌面契约；提交前必须通过
pwsh -NoProfile -File tests/run-tests.ps1 -Tier Contract

# 仅复跑受影响项
pwsh -NoProfile -File tests/run-tests.ps1 -Tier Contract -TestId parse,static,release,risk-policy,governance,hygiene
```

`Desktop`、`Coordinate` 和 `Profiles` 会接触交互桌面或真实应用，只能在明确满足相应隔离条件时运行。不得为了让测试通过而关闭 UAC、降低安全闸、复用用户已有窗口或清理所有权不明的进程/文件。测试输出只能记录脱敏摘要；不要上传原始 UI 日志或截图 artifact。

新增或修改：

- PowerShell/JavaScript：补解析与行为契约；
- 写动作：补拒绝、超时 unknown、独立读回和不可重放测试；
- JSON/schema：保持旧读取兼容，明确 unknown/null，补正反样例；
- 应用档案：记录版本、来源、身份、可逆任务、停手线和脱敏证据；
- 临时对象/进程：补 owner、过期、精确回收与失败路径。

## Pull Request 要求

一个 PR 聚焦一个可审查主题，并填写仓库模板。至少说明：

- 行为变化与明确非目标；
- 选用的控制层、安全影响与新增残余风险；
- 实际运行的 Contract/Desktop/Coordinate/Profile 测试及未运行原因；
- 收据、日志、截图、缓存和临时目录字段是否变化；
- 命令、schema、退出码和旧应用档案的兼容性；
- 创建的进程、窗口和文件如何验证并回收。

提交前运行 `git diff --check`，确认 `git status --short` 中没有生成的 DLL、报告、截图、map、receipt、临时 profile 或其他私人证据。版本候选还必须同步 `config/release.json`、`VERSION`、Changelog 和 Release Notes，并运行只读 `scripts/release-check.ps1`；本地通过不授权推送、tag 或 Release。安全漏洞不要走普通 PR；按 [`SECURITY.md`](SECURITY.md) 联络维护者。
