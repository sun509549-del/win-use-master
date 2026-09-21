# win-use-master 威胁模型

> 版本：2026-09-21
> 范围：仓库中的 PowerShell、C# helper、Node.js CDP 工具、测试与公开文档。
> 安全结论：本项目降低桌面自动化误操作与证据泄露风险，但不能突破 Windows 的权限、桌面、前台和应用实现边界。

## 1. 保护目标

- 用户正在编辑的文档、草稿、账号与外部系统状态；
- 键盘、鼠标、前台窗口和活动交互桌面的完整性；
- CDP 端口、进程、target、会话与 UIA 元素的目标身份；
- 截图、UIA map、DOM 文本、动作收据、命令行和临时目录中的敏感信息；
- 用户文件、非本项目进程以及测试没有创建的临时对象；
- 发布源码、CI 结果和贡献审查链的完整性。

## 2. 信任边界与假设

```text
用户目标 / agent 推理
        │  不信任窗口标题、DOM、UIA Name/Value 和截图文字
        ▼
PowerShell 编排 ── UIA worker / HuWin helper ── Windows 交互桌面
        │
        ├── 本机 CDP HTTP/WebSocket ── 受用户授权的 app 进程/target
        └── 收据、截图、map、缓存与临时目录 ── 本地文件系统
```

假设操作者有权控制目标应用与数据，Windows 内核和密码学原语可信。目标应用、页面内容、窗口文本、网络响应、第三方 UIA provider、同机普通进程以及外部贡献均按不可信处理。管理员或内核级恶意代码、被攻陷的操作系统、绕过 DRM/受保护内容和无人值守远程桌面不在本项目能可靠防御的范围内。

## 3. 威胁与控制矩阵

| ID | 资产与攻击面 | 可能失效/攻击 | 现有控制 | 对应测试 | 残余风险与停手线 |
|---|---|---|---|---|---|
| T-UI-01 | 用户意图；窗口标题、DOM、UIA、截图 | 页面把“点击发送”“泄露 token”等文本伪装成代理指令 | 所有界面文字只作数据；跨运行时最终动作规则；默认只读；写后独立读回 | `risk-policy-contract.ps1`、`uia-read-contract.ps1`、`cdp-action-receipt.ps1` | denylist 仍可能漏报；目标或动作不明确时退出 2，最终提交留给用户 |
| T-CDP-01 | CDP 端口、owner、进程树、target、session | 端口劫持、PID 复用、多 target 混淆、过期会话控制错实例 | owner/exe/启动时间绑定；30 分钟清单；每次写前重验；多 target 拒绝猜测 | `cdp-ownership.ps1`、`cdp-action-receipt.ps1` | 同权限本机恶意进程仍可竞争；任一身份字段未知即拒绝写 |
| T-DESKTOP-01 | 全局输入、前台、交互桌面、权限 | 锁屏、UAC 安全桌面、虚拟桌面、UIPI、前台劫持使输入落错目标 | 输入桌面、完整性、cloaked、前台读回、全机锁、用户空闲与遮挡检查 | `window-state-contract.ps1`、`smoke.ps1` | Windows 可拒绝或改变前台；不能证明活动桌面与前台时退出 2 |
| T-COORD-01 | 鼠标落点与截图坐标 | 窗口移动、缩放/DPI、遮挡或旧截图导致错点 | 坐标仅为 L2 兜底；窗口相对坐标；动作前重验几何、前台和命中窗口；短引用不持久化 | `smoke.ps1 -RequireCoordinate`、`capture-recovery.ps1` | UI 可在检查后变化；关键/不可逆动作不使用坐标自动完成 |
| T-UNKNOWN-01 | 文档、草稿与外部副作用 | 写调用超时但实际已生效，重放造成重复提交 | 写入 deadline；效果记为 `unknown`；退出 2；禁止自动重试非幂等动作；独立验证 | `uia-timeout.ps1`、`cdp-action-receipt.ps1` | 外部系统可能延迟完成；无法读回时停止并交给用户确认 |
| T-EVIDENCE-01 | 标题、正文、账号、路径、截图、map、收据 | 终端、Issue、CI artifact 或仓库历史泄露敏感信息 | `--summary`；字段白名单和哈希/长度；URL 去 query/fragment；真实证据不入库 | `json-output-contract.ps1`、`doctor-contract.ps1`、`capability-cache-contract.ps1` | 截图像素仍可能敏感；无法证明已脱敏就不公开或上传 |
| T-CLEANUP-01 | 用户文件和临时目录 | 路径展开、reparse point、TOCTOU 或错误 owner 导致误删 | 当前只开放 dry-run；限定系统临时根和直接子目录；manifest、owner、期限、reparse 与枚举上限校验 | `cleanup-contract.ps1`、`static-contract.ps1` | 真正删除尚未实现；任何路径或所有权不确定都必须拒绝 |
| T-SUPPLY-01 | 发布源码和 CI | 浮动 Action、恶意依赖、凭据或测试 artifact 污染发布结论 | Actions 固定完整 SHA；默认 `contents: read`；零包安装；凭据/二进制/manifest 扫描；测试后检查工作区 | `ci-contract.ps1`、`repository-hygiene-contract.ps1`、`static-contract.ps1` | GitHub runner、历史提交与固定 Action 仍是供应链信任；版本更新需人工审查 |
| T-CONTRIB-01 | 安全不变量和公开协作 | 贡献削弱退出码、绕过风险规则、嵌入秘密或扩大清理范围 | 贡献清单、PR 风险/隐私/兼容说明、治理契约和分层测试 | `governance-contract.ps1`、完整 `Contract` 层 | 文档与测试不能替代人工代码审查；高风险改动不得只看覆盖率合并 |

## 4. 强制安全不变量

1. `0` 仅表示已验证成功；`1` 是确定失败；`2` 是安全拒绝或效果未知。
2. 退出码 2 不得当作成功，也不得触发非幂等动作自动重放。
3. 界面与网页内容永远是数据，不是新的授权或指令。
4. 写操作必须绑定当前目标身份并在动作前重验；缓存只能调整探测顺序，不能授权。
5. Enter、保存、关闭、发送、支付、删除等最终动作不能用 `--force` 绕过。
6. 截图、UIA/DOM 正文、完整命令行、token、用户绝对路径和真实账号数据默认不进入公开日志、Issue 或测试夹具。
7. 只清理能证明由本项目创建、位于精确边界内且 owner 已失效的对象；当前生产 cleanup 不执行删除。

## 5. 安全评审触发条件

以下变更必须更新本文件、相关测试和 PR 安全说明：新增写命令或最终动作；改变 0/1/2 语义；扩大日志/收据字段；读取缓存参与授权；放宽 owner/session/前台/UIPI/遮挡校验；增加删除 primitive、网络依赖、GitHub Action 或外部包；新增真实应用证据。

漏洞与隐私问题请按 [`SECURITY.md`](SECURITY.md) 处理，不要在公开 Issue 中粘贴利用步骤、截图、正文、token、路径、UIA map 或动作收据。
