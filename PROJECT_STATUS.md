# win-use-master 项目状态与完善路线

> 状态快照：2026-09-15
> 适用对象：项目维护者、贡献者、评审者，以及后续接手的开发者
> 说明：本文区分“已经实现”“本地已验证”和“远程/桌面发布门已通过”，不能把局部测试成功等同于完整发布通过。

未来 12 周的任务拆分、依赖、工期、质量门和发布节奏见 [`IMPLEMENTATION_PLAN.md`](IMPLEMENTATION_PLAN.md)。

## 1. 一页结论

`win-use-master` 已经从“Mac 工具的 Windows 移植想法”发展为一个可安装的 Windows Agent Skill：它能先只读探测应用，再在 L0 应用原生接口、L1 UI Automation、L2 安全门控的前台输入、L3 截图取证之间选择最可靠的路径，并为动作保留机器可读的验证收据。

当前更适合定义为 **Beta / 工程预览版**，而不是“支持所有 Windows 软件的通用自动化产品”。核心控制面、安全拒绝、证据链和六个可重放真实应用档案已经形成；进入 v1.0 前最重要的工作不是继续堆命令，而是完成一次不受用户键鼠干扰的发布级桌面回归、扩充真实应用样本、补齐公开项目治理材料，并把当前本地增强提交后交给远程 CI 验证。

| 方面 | 当前判断 | 依据 |
|---|---|---|
| 设计与架构 | 已成形 | L0–L3 分层、失败关闭、验证闭环已经落入代码和文档 |
| 只读探测与取证 | 可用 | `probe/windows/see/shot/screen/uia/uiaread/CDP` 已覆盖主要信息面 |
| 结构化写入 | 可用但依赖应用 | UIA、CDP、Excel/WPS COM 均有实现和真实样本 |
| 坐标输入 | 有意保持受限 | 只能短暂借前台，必须通过桌面、权限、空闲、焦点和遮挡检查 |
| 安全与隐私 | 基础较完整 | 风险规则、超时、owner 校验、脱敏收据、退出码 2 语义已经统一 |
| 自动化测试 | 大部分已覆盖 | 静态、CDP、UIA 超时/读取、窗口状态等测试存在；完整桌面 smoke 尚待本批复跑 |
| 真实应用覆盖 | 中等 | 6 个可重放档案，3 个只读观察档案；仍低于上游 Mac 版样本广度 |
| 发布成熟度 | 尚未封版 | 无桌面契约已闭环，完整 Desktop/Coordinate 发布门仍待执行 |

## 2. 项目定位与设计理念

上游 `huashu-mac-use` 最重要的价值不是某条 macOS 命令，而是一套桌面代理工程方法：先识别应用暴露的接口，再按可靠性选择控制面；能后台读就不抢焦点，能语义写就不点坐标；任何 API 返回“成功”后仍要验证业务结果。

Windows 版保留了这套方法，同时接受 Windows 的平台现实：没有安全、可靠且通用的 per-PID 后台键鼠投递能力，UIPI、UAC、输入桌面、Foreground Lock、虚拟桌面和自绘控件也会形成硬边界。因此本项目不会用 `PostMessage`、注入或关闭系统保护来伪装“后台控制”。

核心流程如下：

```text
用户目标
   │
   ├─ 只读 probe：安装、进程、窗口、架构、端口、协议、COM、UIA、完整性
   │
   ├─ L0 应用原生接口：CLI / COM / URL protocol / CDP
   ├─ L1 UI Automation：元素读取、ValuePattern 写入、InvokePattern 动作
   ├─ L2 SendInput：仅在所有安全闸通过后短暂借前台
   └─ L3 证据：PrintWindow / 桌面合成 / CDP 截图 / before-action-after 收据
                                │
                                └─ 结果验证；未知则退出 2 并停止
```

完整架构图见 [`assets/architecture.svg`](assets/architecture.svg)，控制面选择依据见 [`references/控制面详解.md`](references/控制面详解.md)。

## 3. 已经完成的工程工作

### 3.1 项目基础与分发

- 项目已经采用 Agent Skills 结构，根目录 [`SKILL.md`](SKILL.md) 是代理运行时入口，细节通过 `references/` 渐进披露。
- 项目名已经统一为 `win-use-master`，公开仓库为 [sun509549-del/win-use-master](https://github.com/sun509549-del/win-use-master)，默认分支是 `main`。
- 支持通过 `npx skills add sun509549-del/win-use-master -g` 发现和安装根目录 Skill。
- Windows CI 已建立，负责 PowerShell/JavaScript 解析、C# helper 构建、静态发布契约、UIA 契约和 Node 22/24 无头 CDP 回归；每个待发布提交仍须核对远程目标 SHA。
- `scripts/HuWin.dll` 被定义为可再生构建产物，不提交仓库；源码变更或 DLL 缺失时由脚本重编译。
- `win.ps1 doctor [--json|--summary]` 会在 helper 加载前执行零写入诊断，报告运行时、构建、CDP、schema、桌面、完整性、临时残留和测试层状态；它不构建、不启停应用、不删除或修复。
- `probe.ps1` 已提供 `probe-report-v1` 与隐私摘要；查询值永不进入 JSON，summary 只保留状态、计数和 L0–L3 路由。
- `capability-cache-v1` 已实现为建议性、显式写入的本地缓存：`cache show/record/clear` 独立于桌面 helper，`probe --no-cache` 可禁用读取；30 天、版本变化和字段白名单均为失败关闭，缓存不进入任何写授权链。
- `cleanup` 已实现零写入 dry-run 首版：只扫描系统临时根的项目直接子目录，按唯一 manifest、到期、原 owner、reparse point 和枚举上限给出 `cleanup-plan-v1`；`--apply` 尚未开放并在扫描前拒绝。
- `benchmark` 已实现聚合性能基线：明确区分首次/后续新进程，使用 100/300/1000 元素合成 UIA provider，并可在项目自有临时无头 Edge 上只读 `inspect`；报告不含原始样本、路径、标题、正文、selector、PID 或端口。
- 根目录 `cdp.js` 只保留兼容转发，真实实现集中在 `scripts/cdp.js`，减少双份实现漂移。

### 3.2 Windows 原生底层

- 用 `scripts/HuWin.cs` 封装窗口枚举、DWM 状态、DPI、前台窗口、输入桌面、空闲时间、命中测试、截图看门狗、`SendInput` 和 HUD。
- 支持普通、最小化、隐藏和 cloaked 窗口状态；默认列表会折叠 Qt/CEF 产生的大量无标题消息窗，`--raw` 才展示原始枚举。
- 模糊窗口选择命中多个候选时不再猜测，返回退出码 2，要求调用者改用明确 HWND。
- `restore`/`minimize` 使用不主动激活的窗口状态请求，并对前台迁移分类；`window-state-result-v1` 区分 dry-run、完成、partial、拒绝与未知效果，并在调用后回读请求状态。
- 支持 AUMID/Store 应用启动、普通程序后台显示请求、COM 注册视图与进程身份核对。

### 3.3 L0：应用原生接口与 CDP

- `probe.ps1` 能只读发现安装路径、进程、版本、PE 架构、Electron/CEF/WebView 线索、监听端口、URL protocol、COM 注册、窗口、UIA 概况和完整性级别。
- `probe` 不会为了探测而启动应用，不会实例化 COM，也不会修改设置。
- CDP 写操作会校验监听端口的 owner PID、可执行路径、进程树和启动时间，不允许“端口能连就控制”。
- `open --cdp` 在校验后签发 30 分钟会话清单，绑定端口、进程身份和目标页；每个写命令还会重新授权。
- 多个 page target 存在时禁止自动选择；调用者必须指定 target id。
- 已提供 `list/snapshot/find/wait/inspect/mouse/insert/press/shot/eval-read/eval-unsafe/act` 等 CDP 能力。
- CDP `list/inspect` 已提供版本化 JSON/摘要；target URL 始终移除 query/fragment，摘要不打印标题、URL、target 选择词或 CSS selector，`inspect` 从采集层只读取状态与正文长度。
- 普通 `eval`/`eval-read` 只允许受控读取；有副作用的表达式必须显式使用 `eval-unsafe --allow-side-effects`，且效果一律记为 `unknown`。
- CDP 对 HTTP、WebSocket、单次请求和动作脚本设置截止时间；写入超时后不会自动重试非幂等动作。
- DOM 动作会检查按钮文本、ARIA、id/name 和表单提交语义，发送、支付、删除等最终动作在输入前拒绝。
- 编辑器正文、选择器和脚本表达式在收据中脱敏；Slate/ProseMirror 等文本框只记录字符数量变化。

### 3.4 L1：UI Automation

- UIA 枚举、读取、解析、写入和 invoke 全部放入独立 worker；陌生 provider 挂死时，6 秒后终止 worker，不拖死整个代理。
- 支持 `uia`、`uiaread`、`uiaset`、`invoke`，并覆盖 Edit 和 Document 的 `ValuePattern`。
- UIA map 生成短引用 `eN`，动作前会用稳定语义重新定位，避免把旧坐标当成长期身份。
- `uiaread --id` 会先用 UIA `PropertyCondition` 精确筛选 AutomationId，再读取 Name/Value；匹配为零、多个、过期或 provider 异常均返回 2。
- 精确 ID 匹配区分大小写，并在最终读取前再次验证 AutomationId，降低元素树变化造成的误读。
- `uiaread` 已增加 ID/Name 精确或前缀、ControlType、唯一 `--within-id` 子树和 `--limit` 分页组合；Value/Text 只在元数据过滤后按页读取。
- `uia-continuation-v1` 除 schema 外只携带查询/树哈希和偏移，绑定 HWND、PID/启动时间、子树根、候选 RuntimeId 顺序与元数据指纹；匹配树或窗口身份变化时退出 2，不把旧 token 当持久元素引用。
- `doctor`、`probe`、`windows`、`frontmost`、`idle`、`uia`、`uiaread` 和窗口状态结果已提供版本化 JSON；摘要不复制查询值并隐去身份/窗口标题/UIA items，unknown 使用枚举与 `null` 明示。
- `--summary` 只向终端输出数量和类型统计，避免窗口标题、过滤词和控件正文直接进入会话日志。
- 密码控件不返回 Value。旧的模糊过滤接口保留兼容，但它仍会先读取最多 300 个元素，因此不应作为敏感页面的隐私隔离手段。

### 3.5 L2：安全门控的前台输入

- 坐标点击、悬停、滚动、文本输入、组合键和通用操作均通过 `SendInput`，不伪造后台窗口消息。
- 每次动作重新检查输入桌面、锁屏/UAC、窗口隐藏/最小化/cloaked、调用者与目标完整性、全机焦点锁、用户空闲、前台读回和落点遮挡。
- 用户最近 2 秒仍在操作时最多等待 15 秒；无法获得可靠前台或权限未知时返回 2。
- 动作完成后尽力恢复鼠标和原前台；恢复失败或前台状态异常时将效果标为 `unknown`。
- 自己生成的输入尾迹会从用户空闲判断中排除，避免工具把自己的动作误判为用户活动。
- 输入长度、滚轮步数和悬停时间有上限，避免失控循环。
- Enter、`Ctrl+S`、`Ctrl+Shift+S`、`Alt+F4` 以及发送/确认/支付/删除等风险语义采用统一规则并 fail-closed；`--force` 也不能绕过最终动作拒绝。
- 支持窗口像素、标准化坐标、截图缩放坐标和 UIA map 引用，但坐标始终是最后手段。

### 3.6 L3：截图、证据和效果判断

- `shot` 使用 `PrintWindow` 并设置 2.5 秒看门狗，provider 或窗口卡住时可返回未知而不是永久等待。
- sibling recovery 只接受几何关系与进程谱系均合理的同进程渲染窗口，收据同时保留请求 HWND 和实际捕获 HWND。
- 判空同时观察内容区颜色桶和整帧颜色桶，并用 UIA 的空 Document/Edit 交叉解释“空白文档”，避免把白色编辑器误判为截图失败。
- `shotfg` 只在确有必要时短暂借前台，并要求两帧稳定；`screen` 支持整屏、指定窗口裁剪和区域截图，同时记录遮挡和裁切状态。
- 截图、UIA map、动作分别使用 `receipt-v1`、`uia-map-v1`、`action-receipt-v1` schema。
- 动作收据包含目标、时间、耗时、前台变化、before/after 哈希和效果判断；文本内容默认不落入动作日志。
- HUD 提供 `corner/glow/plain` 三种样式，默认不激活并尽力排除捕获，也可通过环境变量关闭或显式允许演示捕获。

### 3.7 文档与工程经验

- README 已提供安装、命令、安全边界、目录结构和自检入口。
- [`HANDOFF.md`](HANDOFF.md) 记录维护不变量、测试矩阵、发布流程和接手顺序。
- [`references/控制面详解.md`](references/控制面详解.md) 解释 L0–L3 的选择逻辑。
- [`references/权限与故障.md`](references/权限与故障.md) 收录 UIPI、锁屏、虚拟桌面、截图/UIA/CDP/HUD 故障处理。
- [`references/取证规范.md`](references/取证规范.md) 规定 before/action/after、哈希、隐私和归档方式。
- [`references/app档案.md`](references/app档案.md) 保存真实应用版本、身份、可重放路径和限制。
- [`references/踩坑实录.md`](references/踩坑实录.md) 已沉淀 23 条可复现问题，并记录哪些 Mac 结论不能直接套到 Windows。
- [`references/与mac版差距.md`](references/与mac版差距.md) 持续跟踪功能对齐、平台差异和样本缺口。

## 4. 当前命令能力清单

| 类别 | 命令 | 主要用途 | 是否可能写入 |
|---|---|---|---|
| 窗口 | `windows`、`frontmost`、`idle` | 枚举和判断前台/用户活动 | 否 |
| 窗口状态 | `restore`、`minimize` | 请求还原或最小化并验证前台变化 | 会改变窗口状态 |
| 截图 | `shot`、`shotfg`、`screen` | 后台窗口、短借前台或桌面合成取证 | `shotfg` 可能短借前台 |
| UIA 读取 | `uia`、`uiaread` | 元素树、摘要、组合限定、子树与安全分页 | 否 |
| UIA 写入 | `uiaset`、`invoke` | ValuePattern 写入或 InvokePattern 调用 | 是，受风险规则限制 |
| 坐标输入 | `clickin`、`hoverin`、`scrollin`、`type`、`key`、`op` | UIA/CDP 不可用时的受控兜底 | 是，必须通过 L2 闸门 |
| 应用入口 | `open`、`com` | 启动、CDP 授权、COM 身份检查 | 启动会改变进程状态 |
| 能力发现 | `probe` | 只读探测应用控制面 | 否 |
| 环境诊断 | `doctor` | 脱敏文本/摘要或 `doctor-report-v1` JSON | 否；不构建、不修复 |
| 能力缓存 | `cache show/record/clear` | 查看、显式记录或精确清除低敏感探测观察 | `show` 否；其余仅改本地 cache，永不授权 app 写入 |
| 临时治理 | `cleanup [--dry-run]` | 脱敏列出可清理/拒绝候选及原因 | 否；`--apply` 未开放 |
| 性能基线 | `benchmark [--quick] [--no-cdp]` | `performance-report-v1` 聚合 windows/UIA/CDP inspect p50/p95 | 不写真实 app；默认只写并回收无头 Edge 临时 profile，`--no-cdp` 零临时目录 |
| 辅助显示 | `hud` | 展示动作状态 | 仅界面提示 |
| CDP | `list`、`snapshot`、`find`、`wait`、`inspect`、`shot` | 浏览器/Chromium 只读观察 | 否 |
| CDP 动作 | `mouse`、`insert`、`press`、`act`、`eval-unsafe` | 经 owner/session/风险校验的 DOM 操作 | 是 |

统一退出约定：`0` 表示已验证成功，`1` 表示明确失败，`2` 表示安全拒绝或结果未知。退出码 2 绝不能被上层当成成功，也不应触发非幂等自动重试。

## 5. 已验证的真实应用

### 5.1 可重放档案

| 应用 | 已验证路径 | 已验证任务 | 当前限制 |
|---|---|---|---|
| Windows 计算器 11.2607 | UWP 宿主 + UIA InvokePattern | `1 + 2 = 3`、结果读回、还原、关闭 | UI 版本变化会影响元素语义 |
| Windows 记事本 11.2607.14 | WinUI/RichEdit Document ValuePattern | 可逆写入、精确读回、状态计数、清空 | 会话恢复可能保留未保存内容，测试必须显式归零 |
| Windows 设置 10.0.26100.8875 | AUMID + ApplicationFrameHost/SystemSettings + UIA/L3 | PrintWindow、摘要读取、精确 ID 只读 | 严格零写入；最新本地档案尚待在无既有设置窗口时复跑 |
| WorkBuddy AI 5.4.2 | 已授权实例的 CDP | Slate 文本插入、SelectAll/Backspace 撤回、发送按钮禁用校验 | 不执行发送；必须由用户授权 CDP 实例 |
| Microsoft Excel 16.0.20326 | 私有 COM 实例 | 写公式、读回 3640、另存 xlsx、脱离 Excel 验证 XML | 依赖本机 Excel 和 COM 注册 |
| WPS 表格 12.1.0.23125 | `KET.Application` 私有 COM | 写入、读回、保存、第二实例重开验证 | 必须核对 WPS 身份，不能把 Excel ProgID 当成 WPS |

### 5.2 只读观察档案

| 应用 | 观察结果 | 缺少什么 |
|---|---|---|
| QQ 9.9.21 | Electron UIA 树可读 | 缺少用户指定的可逆写入目标和动作验证 |
| 微信 4.1.13 | Qt5 UIA 基本为空，未发现可用 CDP | 尚无可靠语义写路径，不应直接降级为盲点坐标 |
| 剪映 10.4 | Qt6 provider 可能挂死，隔离 worker 能保护主流程 | 主编辑器、CDP 可行性和更新弹窗尚未在用户授权重启条件下验证 |

共计 9 个应用有实测记录，其中 6 个形成可重放档案。Blender 尚未安装和验证。完整细节以 [`references/app档案.md`](references/app档案.md) 为准。

## 6. 测试与验证状态

### 6.1 已有测试资产

| 测试 | 覆盖范围 | 运行条件 |
|---|---|---|
| `tests/parse-contract.ps1` | 仓库内 PowerShell 与 JavaScript 统一语法检查 | 无桌面；JavaScript 检查需要 Node |
| `tests/doctor-contract.ps1` | 五类环境 fixture、JSON/摘要、隐私、零副作用和提前分发 | 无桌面 |
| `tests/json-output-contract.ps1` | probe/窗口状态/窗口/UIA/CDP target schema、unknown/null、URL 清理、摘要脱敏和查询值不回显 | 无桌面 + 本地 HTTP fixture |
| `tests/capability-cache-contract.ps1` | 字段白名单、TTL/版本失效、摘要隐私、show 零写入、禁用开关、精确清除与伪造缓存不能授权 | 无桌面隔离临时目录 |
| `tests/cleanup-contract.ps1` | temp namespace、manifest、到期/owner/reparse 判据、输出隐私、逐文件零修改和 apply 拒绝 | 无桌面隔离临时目录 |
| `tests/benchmark-contract.ps1` | p50/p95、windows/UIA quick、聚合隐私、仓库零修改、参数预拒绝和生产超时不变量 | 无桌面；`--no-cdp` |
| `tests/run-tests.ps1` | Contract/Desktop/Coordinate/Profiles 分层调度、截止时间和结构化报告 | 取决于所选层；默认 Contract |
| `tests/test-runner-contract.ps1` | 层选择、显式 profile、dry-run/实际执行、报告隐私和覆盖保护 | 无桌面 |
| `tests/ci-contract.ps1` | 只读权限、action 完整 SHA、Node 22/24 矩阵、禁用无用缓存 | 无桌面 |
| `tests/static-contract.ps1` | 发布文件、风险规则、README 链接、SVG 安全、Skill 体积 | 无桌面 |
| `tests/cdp-ownership.ps1` | 错误端口 owner 拒绝、正确 owner 接受 | 本地 fixture |
| `tests/cdp-action-receipt.ps1` | `inspect` JSON/摘要、动作收据、脱敏、失败、超时、会话重授权、临时进程清理 | 无头 Edge/Node |
| `tests/uia-read-contract.ps1` | 精确/前缀/类型/子树组合、正文延迟读取、分页与 continuation 失效 | 无桌面 provider fixture |
| `tests/uia-timeout.ps1` | UIA worker 卡死、终止、unknown 收据 | 无桌面 fixture |
| `tests/window-state-contract.ps1` | 前台迁移分类、“新激活”判定、窗口状态 JSON/摘要 | 无桌面 |
| `tests/capture-recovery.ps1` | sibling recovery、截图收据 | 活跃桌面/fixture |
| `tests/smoke.ps1` | 构建、窗口、截图、UIA、安全闸、可选真实坐标输入 | 活跃且空闲的交互桌面 |
| 六个 `*-profile.ps1` | 真实应用档案 | 安装对应应用并满足各自隔离条件 |

### 6.2 本批已获得的证据

- 统一调度器的完整 Contract 层已通过 14/14：parse、build、doctor、static、CI 配置、JSON output、capability cache、cleanup、benchmark、UIA read、window state、CDP ownership、CDP action receipt、UIA timeout。
- `doctor` 的干净、缺 Node、helper 过期、安全桌面和历史残留五类 fixture 已通过；端到端检查确认主入口在 helper 自动构建前分发，JSON/摘要不含绝对路径，冲突选项退出 2。
- JSON output fixture 已通过：`probe`、窗口状态、五类窗口/UIA 报告与 CDP target 均守住 schema、unknown/null、URL 清理、摘要脱敏和参数误拼失败关闭；`windows/frontmost/idle`、`probe` 未命中和 CDP list 均有端到端 JSON 解析。
- capability cache 契约已通过：缓存记录只保留低敏感白名单，30 天与版本变化失效，show 不改文件，summary 不列 entry，禁用开关阻断读写；伪造 `trusted/allowWrite/L2` 字段被丢弃且不能绕过 CDP session。
- cleanup 契约已通过：只有有效过期 manifest 且原 owner 不活跃的安全树会标为 eligible；活动 owner、未到期、缺失/错误/错配 manifest 均拒绝。full/summary/default dry-run 与 `--apply`/非法根拒绝前后，fixture 逐文件指纹一致。
- performance 契约已通过：quick/no-CDP 报告含 windows 首次/重复进程与 100/300/1000 UIA 聚合统计，stdout/privacy/副作用字段和仓库逐文件零修改均符合契约；标准档另以临时无头 Edge 完成 5 次 CDP inspect，并确认 profile 与专属 Edge 进程无残留。首版数值见 [`references/性能基线.md`](references/性能基线.md)。
- UIA 限定查询 fixture 已通过：精确条件由 provider 求交，前缀与子树只在元数据阶段筛选，页外元素不读取 Value；continuation 能稳定前进，并在树指纹或 HWND 变化时先拒绝再读正文。
- 调度器契约已验证显式 profile、`-TestId` 子集、dry-run、真实 parse 执行、报告不含绝对路径/原始输出，以及已有报告默认拒绝覆盖。
- CI 已拆为核心 job 与 Node 22/24 CDP 矩阵，第三方 action 固定到完整 commit 并关闭不需要的包缓存；本机 Node 24 与 YAML/静态契约已通过，Node 22 结论以目标提交的远程 Actions 为准。
- PowerShell 语法解析、JavaScript 语法解析和差异空白检查通过。
- 静态发布契约与 Skill quick validation 通过。
- UIA 精确读取契约通过。
- 窗口状态迁移与版本化结果契约通过；真实前台窗口的 `minimize --dry --json --summary` 返回 `planned/not-applied`，未改变窗口。
- CDP owner 校验通过。
- CDP 动作收据完整回归通过，包括 inspect full/summary、约 9 秒的写超时、超时后重新授权和临时 profile 清理断言。
- UIA 超时测试已验证读/写 provider 卡住时均在约 7 秒内退出，并把写入效果标为未知。
- 受控 WinForms smoke 的精确 AutomationId 读取断言曾通过；随后修复了 invoke 后立即读状态和 restore 判定两个不稳定假设。

### 6.3 尚不能宣称通过的部分

- 当前本批修改后的 `tests/smoke.ps1` 尚未在完全空闲桌面上端到端跑完；用户持续操作会触发安全闸，强行跑反而会污染结论。
- `smoke.ps1 -RequireCoordinate` 的发布级 L2 真实输入回归尚待专门空闲窗口执行。
- `capture-recovery.ps1` 和设置档案应在封版前与本批变更一起复跑。
- Windows 设置档案为了不复用或关闭用户现有设置窗口，本批没有在检测到既有实例时强行执行。
- UIA 读取、UIA 超时和窗口状态契约已经纳入 CI；仍不能用本地结果替代目标提交的远程 GitHub Actions 结果。

## 7. 本次候选范围与发布口径

截至本快照：

- 当前本地候选基于上一份已通过 Node 22/24 远程 CI 的公开基线，新增只读 `doctor`、UIA 限定查询/安全分页、M2-03 机器可读结果、M2-04 建议性能力缓存、M2-05 cleanup dry-run 与 M2-06 只读性能基线、对应 fixture 和文档；本批尚未提交或推送。
- 本地无桌面 Contract 层已经 14/14 通过。Desktop、Coordinate 和设置档案复验仍是独立发布门，不能由云 CI 替代。
- 对外说明应区分：“代码已经实现”“本地契约已验证”“目标提交远程 CI 已验证”“真实桌面已验证”四种状态。
- 发布状态和远程 SHA 以 Git 历史及 GitHub Actions 为准；本文不保存容易过期的“未跟踪文件数量”或“最新提交 SHA”。

## 8. 仍需完善的功能

### P0：下一次发布前必须完成

1. **完成发布级桌面回归。** 在用户停止键鼠操作、无敏感窗口暴露的测试桌面运行完整 `smoke.ps1`，再单独运行 `-RequireCoordinate`；保存测试环境、耗时和结果摘要。
2. **复跑受本批影响的专项测试。** 至少包括 `capture-recovery.ps1`、`uia-timeout.ps1`、`cdp-action-receipt.ps1`、`uia-read-contract.ps1` 和 `window-state-contract.ps1`。
3. **完成设置档案复验。** 仅在不存在用户设置窗口时运行，不关闭或复用用户实例；确认临时截图、UIA map 和收据在测试结束后删除。
4. **做发布前隐私检查。** 扫描 staged diff 中的用户名、绝对路径、窗口标题、账号/设备名、截图和 UIA 正文，确认真实证据没有误入库。
5. **治理测试遗留。** `cleanup --dry-run --json --summary` 已能给出脱敏计数；没有有效项目 manifest 的同前缀候选不能视为可删除对象。当前没有 `--apply`，实际删除能力须完成二次扫描/TOCTOU 设计并由用户另行明确授权。
6. **形成可审计提交。** 将代码、测试、文档按逻辑拆分或写清提交说明，再在用户明确要求时推送；推送后等待远程 CI 完成，不能只看本地退出码。

### P1：提高真实可用性和 OSS 可信度

1. **把可重放应用档案扩到至少 11 个。** 优先补 Blender 的原生脚本/CLI 路径、第二个 Chromium/CEF 样本，以及一个非 Office 的原生 Windows 应用。
2. **补脱敏的真实案例素材。** 为 UIA、CDP、COM 各准备一段真实 Windows 案例截图或短 GIF；不得用测试 fixture 冒充生产应用，也不得泄露账号、设备名或编辑器正文。
3. **谨慎探索 QQ、微信、剪映。** QQ 只能在用户指定可逆目标后测试写入；微信没有可靠语义层时继续保持只读；剪映的 CDP/更新弹窗测试需要用户授权重启或显示窗口。
4. **补齐开源治理文件。** 建议增加 `CONTRIBUTING.md`、`SECURITY.md`、行为准则、Issue/PR 模板、版本策略和中英文快速开始；这些会直接提高外部评审与贡献效率。
5. **加强供应链检查。** 在 CI 中加入凭据/敏感信息扫描、依赖和许可证检查，并明确第三方工具版本；不要让扫描器自动上传本地证据。

### P2：面向稳定版的工程化

1. 为应用档案设计机器可读 schema，自动生成能力矩阵，减少手工文档与实际测试漂移。
2. 建立 tag、Changelog、Release Notes 和安装升级/回滚说明；定义 Beta 到 v1.0 的兼容承诺。
3. Node.js 22/24 CDP 矩阵已在上一公开基线的远程 CI 通过；每个新候选仍需重跑。剩余工作是用真实机定期回归 Windows 10/11 差异，而不是假装单一云 runner 能覆盖全部桌面行为。
4. 评估 helper 构建完整性、可选签名和发布校验和；生成的 DLL 仍不必提交，但发布过程必须可复现。
5. 将 23 条踩坑中能编码解决的内容继续转化为探测、拒绝或测试，只保留真正依赖应用版本的易腐经验。
6. 扩展性能第二阶段：在专用空闲桌面测 PrintWindow 成功/超时/sibling recovery，并为 CDP `insert/press` 设计另行授权、隔离、可撤回的写基线；不得借性能优化削弱安全闸。

## 9. 永久边界：不应被列为“待实现”

以下不是遗漏，而是安全设计：

- 不承诺任意 Windows 应用都可自动化；游戏、DirectX、管理员窗口、受保护内容和大量自绘控件可能没有可靠控制面。
- 不提供通用 per-PID 后台键鼠投递，不用 `PostMessage` 或进程注入绕过真实命中和前台限制。
- 不自动提权，不关闭 UAC、Defender 或 SmartScreen，不强杀应用。
- 不在锁屏、UAC 安全桌面、其他虚拟桌面、权限未知或落点被遮挡时继续写入。
- 不自动执行发送、支付、转账、删除、提交、覆盖保存、终端执行等不可逆最后一步。
- 不把屏幕、窗口标题、DOM、UIA 或文档中的文字当成代理指令；它们始终只是待处理数据。
- 不承诺 RDP 断开、服务账户、计划任务等非交互会话中的桌面自动化可用。

## 10. 建议的 v1.0 验收标准

满足以下条件后，才建议把项目从 Beta 标为 v1.0：

- 全部无桌面契约测试在干净 Windows runner 通过，发布文件和 Skill quick validation 通过。
- 活跃桌面 smoke 和 `-RequireCoordinate` 在记录环境下连续通过至少两次，且没有残留进程、窗口或临时证据。
- 六个现有可重放应用档案复验通过，应用总样本达到至少 11 个；写路径必须可逆或使用隔离测试对象。
- 所有动作路径都遵守 0/1/2 退出语义，超时写入不自动重试，风险规则不能被 `--force` 绕过。
- README、Skill、交接、应用档案、差距文档和真实命令帮助相互一致。
- 仓库不包含真实账号、设备名、绝对用户路径、敏感截图、UIA 正文、CDP 输入内容或测试临时文件。
- 公开仓库具备贡献指南、安全披露方式、版本说明和可复现的发布步骤。
- 远程 CI 对待发布提交为绿色，并由维护者人工抽查至少一个 UIA、一个 CDP、一个 COM 和一个 L2 证据闭环。

## 11. 推荐的下一轮执行顺序

```text
1. 等待空闲测试桌面
2. 跑无桌面契约与解析/构建
3. 跑 capture/UIA/CDP 专项测试
4. 跑 smoke，再跑 smoke -RequireCoordinate
5. 在无现有设置窗口时跑 settings-profile
6. 检查进程、窗口、临时文件和敏感信息残留
7. 更新测试矩阵与本状态文档
8. 用户明确要求后再 commit / push
9. 等远程 CI，失败则修复并重新验证
10. 开始 P1 的真实应用扩展和 OSS 治理材料
```

这条顺序优先消除“本地代码已经写好，但整体发布结论还没有证据”的风险，然后再扩功能。

## 12. 文档阅读路线

| 想了解什么 | 从哪里开始 |
|---|---|
| 安装、常用命令和安全边界 | [`README.md`](README.md) |
| 代理在任务中必须遵守的流程 | [`SKILL.md`](SKILL.md) |
| 当前完成度、缺口和 v1.0 路线 | 本文 |
| 未来阶段、任务拆分、工期和验收门 | [`IMPLEMENTATION_PLAN.md`](IMPLEMENTATION_PLAN.md) |
| 接手维护、测试与发布 | [`HANDOFF.md`](HANDOFF.md) |
| 四层控制面如何选择 | [`references/控制面详解.md`](references/控制面详解.md) |
| 权限、锁屏、截图和 provider 故障 | [`references/权限与故障.md`](references/权限与故障.md) |
| 收据、哈希、脱敏和证据归档 | [`references/取证规范.md`](references/取证规范.md) |
| 每个真实应用的版本和可重放步骤 | [`references/app档案.md`](references/app档案.md) |
| 已踩过的坑及其代码落点 | [`references/踩坑实录.md`](references/踩坑实录.md) |
| 与 Mac 版的对齐和平台差异 | [`references/与mac版差距.md`](references/与mac版差距.md) |

## 13. 最终判断

项目最有价值的部分已经不是“Windows 上也能点按钮”，而是形成了明确的控制面优先级、安全拒绝条件和证据闭环。下一阶段应把重心从继续增加表面命令，转向发布级回归、真实应用广度、隐私审计和开源治理。完成 P0 后可以发布一个可信的 Beta；完成 P1 并满足第 10 节验收标准后，再考虑 v1.0。
