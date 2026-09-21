# win-use-master 维护交接

更新日期：2026-09-21
公开仓库：<https://github.com/sun509549-del/win-use-master>  
上游设计：[alchaincyf/huashu-mac-use](https://github.com/alchaincyf/huashu-mac-use)

项目完成度、功能矩阵、验证状态和 v1.0 路线统一见 [`PROJECT_STATUS.md`](PROJECT_STATUS.md)，未来阶段、任务拆分、依赖和工期见 [`IMPLEMENTATION_PLAN.md`](IMPLEMENTATION_PLAN.md)；本文继续聚焦维护不变量、测试和发布交接。

## 1. 项目定位

这是一个遵循 Agent Skills 结构的 Windows 桌面自动化与取证工具。目标不是“看到按钮就点”，而是按可靠性依次选择四层控制面：

1. L0：应用 CLI、COM 对象模型、URL protocol、本地端口、CDP；
2. L1：Windows UI Automation；
3. L2：经过安全闸、短暂借前台的 `SendInput`；
4. L3：`PrintWindow`、桌面合成 `screen` 或 CDP 截图取证。

核心原则：读尽量后台，写优先结构/语义；工具返回成功不等于业务生效；结果未知时停止并保留收据，非幂等动作不自动重试。

## 2. 当前可交付状态

- 公开仓库默认分支为 `main`，Windows CI 已启用。
- `npx skills add sun509549-del/win-use-master -g` 可发现并安装根目录 Skill。
- PowerShell 7 + Node.js 24 是当前开发/CI 基线；Node.js 22+ 属支持范围。
- `scripts/HuWin.dll` 是生成物，不提交；`win.ps1` 会在缺失或源码更新时重编译。
- `win.ps1 doctor [--json|--summary]` 是 helper 加载前的只读诊断入口；它不得编译 helper、启停应用、写删文件或自动修复，输出不得含绝对用户路径、窗口标题和正文。
- `capability-cache-v1` 只提供探测顺序提示。缓存管理在 helper 加载前独立分发，`show` 零写入，`record/clear` 必须显式调用；任何 UIA/CDP/L2 写路径都不得导入缓存或据其跳过实时安全检查。
- `cleanup` 当前只能生成 dry-run 计划，生产实现不得含删除 primitive；`eligible` 不是用户授权。若未来开放 `--apply`，必须新增二次身份/路径扫描、TOCTOU 防护、逐项结果和单独授权，不能直接在现有 planner 后追加递归删除。
- `benchmark` 只做聚合性能观察：`windows` 使用摘要读取，UIA 使用合成 provider，CDP 仅连接本次自启的临时无头 Edge。不得加入真实 app 写入、延长生产超时或跳过任何安全检查；PrintWindow 与 `insert/press` 仍待独立条件。
- `THREAT_MODEL.md` 是安全评审真相源；贡献、安全披露、行为准则和 Issue/PR 模板已由 `governance-contract.ps1` 守护。仓库未开启私密漏洞报告时，公开联络 Issue 只允许类别和确认项，绝不能接收技术详情。
- `SUPPLY_CHAIN.md` 是运行时、外部 Action 和许可证清单；`repository-hygiene-contract.ps1` 扫描高置信凭据、误入库证据/二进制、包 manifest、Action 白名单和 CI 包安装命令，但不替代历史与上游人工审查。
- 最终动作文本规则仍只有 `config/risk-actions.json` 一个真相源；UIA/L2 通过 `risk-policy-core.ps1`，CDP 通过 `risk-policy.js` 解释同一规范化约定。任何规则变更都必须同时增加命中与不命中样例，并通过跨运行时契约。
- `uiaread` 的限定查询只在元数据过滤后读取当前页正文；continuation 绑定 HWND、PID/启动时间、查询、子树根和匹配树指纹，任何身份或树变化都必须退出 2 并从第一页重查。
- 机器输出成功时 stdout 只能有一个 JSON 文档；unknown 用枚举和 `null`，不能压成 false/0/空串。窗口/UIA 敏感页使用 `--json --summary`，并记住 UIA summary 只改变呈现、不改变采集。
- 收据 schema 已统一为 `win-use-master/receipt-v1`、`win-use-master/uia-map-v1`、`win-use-master/action-receipt-v1`。
- 模糊窗口/PID 或 CDP target 命中多个候选时退出 2，不再按面积或列表顺序自动选第一个；写操作应优先使用明确 HWND/target id。
- CDP `eval`/`eval-read` 已改为浏览器副作用检查；受控状态读取优先用脱敏 `inspect`。任意脚本写入只能显式使用 `eval-unsafe --allow-side-effects`，并生成不含原始表达式、`effect` 始终为 `unknown` 的动作回执。
- `open --cdp` 校验通过后签发 30 分钟 `cdp-session-v1`，绑定端口、owner PID/路径/启动时间和 page target id；底层 `cdp.js` 的每个写命令独立复核，`--dry` 不签发。
- `config/risk-actions.json` 是 UIA/CDP/L2 共用的 `risk-actions-v1`：UIA invoke 与 UIA-map 坐标点击检查控件语义，CDP click/mouse 检查文本/ARIA/id/name/表单提交，Enter/保存/关闭快捷键 fail-closed。规则命中在输入前退出 2，`--force` 不绕过。
- Excel/WPS 真实档案的证据目录必须由最外层 `finally` 清理，并同时核对 temp 根和 `win-use-master-<app>-` 叶名；WPS 第二个私有实例在重开验证失败时也要先关闭自己的工作簿并尝试 Quit。静态契约守住这两个失败路径，禁止退回“仅成功末尾清理”。
- 可重放档案有六个：计算器 11.x（UWP 宿主 + InvokePattern）、记事本 11.x（Document ValuePattern 可逆写）、WorkBuddy AI 5.4.2（CDP 零焦点 insert/撤回；需用户先以 `--cdp` 启动授权实例）、Excel 16.x（L0 COM 私有实例写表→另存→不经 Excel 验证）、WPS 表格 12.x（KET.Application 同任务 + 第二实例重开读回），以及 Windows 11 设置（AUMID 启动、ApplicationFrameHost 宿主、零写入 UIA/L3 只读回归）。另有 QQ 9.9、微信 4.1、剪映 10.4 三个只读观察档案。`config/app-profiles.json` 将 9 个样本和 1 个未安装占位编码为 6/3/1 分类，`应用能力矩阵.generated.md` 只由脚本生成；Blender 不计入样本。证据图、快照与可能含账号/设备名的 UIA map 不入库。

## 3. 代码地图

| 路径 | 职责 |
|---|---|
| `SKILL.md` | agent 必须遵守的主流程、安全闸、停手线和文档路由 |
| `PROJECT_STATUS.md` | 当前已完成工作、功能/应用/测试矩阵、缺口、优先级与 v1.0 验收标准 |
| `IMPLEMENTATION_PLAN.md` | 从当前 Beta 候选到 v1.0 的阶段、任务、依赖、质量门、风险与建议工期 |
| `THREAT_MODEL.md` | 资产、信任边界、9 类威胁、现有控制、测试映射与残余风险 |
| `CONTRIBUTING.md` / `SECURITY.md` | 安全不变量、测试要求、支持范围与私密披露流程 |
| `SUPPLY_CHAIN.md` | PowerShell/Node/Windows 运行时、固定 Action、零包依赖事实、许可证与升级规则 |
| `.github/ISSUE_TEMPLATE/` / `pull_request_template.md` | 脱敏 Bug/app 档案输入、无自由文本的私密联络请求和 PR 风险清单 |
| `scripts/win.ps1` | 用户入口；窗口解析、截图、UIA worker 调度、坐标动作、安全闸和收据 |
| `scripts/doctor.ps1` | 只读采集运行时、helper、CDP、schema、桌面、临时区和测试可运行性；输出 `doctor-report-v1` |
| `scripts/doctor-core.ps1` | 不接触系统状态的 doctor 判定与格式化核心，供生产和 fixture 共同调用 |
| `references/机器可读输出.md` | 版本化 JSON schema、unknown/null、summary 隐私与兼容规则 |
| `scripts/capability-cache.ps1` | 建议缓存的显式 show/record/clear 入口；不加载桌面 helper |
| `scripts/capability-cache-core.ps1` | 缓存白名单、路径边界、规范化、30 天/版本失效和原子写入 |
| `references/能力缓存.md` | 缓存字段、禁用方式、非授权边界、输出 schema 与精确删除说明 |
| `scripts/cleanup.ps1` / `cleanup-core.ps1` | 临时对象零写入规划入口与 namespace/manifest/到期/owner/reparse 判据 |
| `references/临时数据治理.md` | cleanup dry-run 范围、manifest v1、eligible 含义和未来 apply 前置条件 |
| `scripts/benchmark.ps1` / `benchmark-core.ps1` | windows/UIA/CDP 只读基线编排、聚合统计与临时无头 fixture 回收 |
| `scripts/benchmark-uia-fixture.ps1` | 对实际 `Get-UiaReadablePage` 运行 100/300/1000 元素合成 provider |
| `references/性能基线.md` | 测量口径、首版本机结果、隐私/副作用边界、20% p95 人工预警与延期项 |
| `references/安装升级与卸载.md` | skills CLI/Git clone 生命周期、缓存/session/evidence 数据清单和精确清理边界 |
| `scripts/HuWin.cs` | Win32/DWM/SendInput/DPI/截图看门狗/输入尾迹/HUD 底层 |
| `scripts/uia-worker.ps1` | 隔离的 UIA list/read/resolve/set/invoke worker，正文经 stdin 传递 |
| `scripts/probe.ps1` | 只读应用发现：Win32/AppX、版本、架构、runtime、端口、协议、COM、窗口、UIA、完整性 |
| `scripts/cdp.js` | CDP target、DOM ref、动作、截图、差分、脱敏收据和截止时间 |
| `config/risk-actions.json` | 跨 UIA/CDP/L2 的版本化最终动作文本、按键与 DOM 语义拒绝规则 |
| `scripts/risk-policy-core.ps1` / `risk-policy.js` | PowerShell 与 Node 的失败关闭规则解释器；规范化阶段由 JSON 声明并由同一语料核对 |
| `config/app-profiles.json` | 机器可读应用档案真相源：版本、身份、四层能力、任务、停手线、测试和复验条件 |
| `scripts/generate-app-matrix.ps1` / `references/应用能力矩阵.generated.md` | 确定性生成/校验能力矩阵；不覆盖人工 `app档案.md` |
| `tests/profile-test-template.ps1` / `references/应用档案测试模板.md` | 目录绑定、默认拒绝且零副作用的十阶段计划；真实应用命令仍由各档案单独实现 |
| `config/public-cases.json` / `scripts/generate-public-cases.ps1` / `references/脱敏真实案例.generated.md` | UIA/CDP/COM 三类公开派生案例；当前只有文字素材，视觉状态明确为未包含 |
| `assets/architecture.svg` | README 使用的仓库原生架构图；无脚本、无远程资源，含 title/desc |
| `tests/settings-profile.ps1` | Windows 11 设置隔离只读档案；拒绝复用现有实例，零写入并清理敏感临时证据 |
| `references/控制面详解.md` | 四层原理和选择依据 |
| `references/权限与故障.md` | UIPI、锁屏、虚拟桌面、截图/UIA/CDP/HUD 故障处理 |
| `references/取证规范.md` | before/action/after、哈希、隐私、归档和跑批 |
| `references/app档案.md` | 易腐的 per-app 实测模板及计算器档案 |
| `references/踩坑实录.md` | 每条闸/提示/测试断言的来历：现象→归因→落点→证据；Mac 结论在 Windows 上被推翻的记录 |
| `references/与mac版差距.md` | 已对齐能力、平台差异和待办优先级 |
| `.github/workflows/ci.yml` | 非交互 Windows CI |

根目录 `cdp.js` 只是兼容入口，真实实现只改 `scripts/cdp.js`。

## 4. 不得破坏的安全不变量

### L2 坐标输入

- Windows 没有安全可靠的通用 per-PID 后台键鼠接口。禁止用 `PostMessage` 或注入伪装成 Mac 的后台投递能力。
- 每次真实动作都重新检查：输入桌面、最小化/cloaked/hidden、UIPI、全机焦点锁、用户近 2 秒活动、前台读回和点位遮挡。hidden 窗口拒绝的原因是激活它会 `ShowWindow`，等于替用户弹出窗口。
- 最多等待用户空闲 15 秒；无法安全切前台返回 2，不强绕 Foreground Lock。
- 动作后尽力恢复鼠标和原前台；恢复失败视为 `effect=unknown`。
- `type/op` 最多 1000 个 UTF-16 字符，滚轮最多 200 步，悬停最多 8 秒。

### UIA

- 所有 provider 调用只能发生在 `uia-worker.ps1`，主进程不能直接枚举或调用 UIA。
- worker 硬截止时间 6 秒。读超时表示 L1 本轮不可用；写超时表示动作可能已发生，写 `unknown` 收据、退出 2、禁止自动重试。
- 密码/凭据字段必须拒绝；输入正文只能走 stdin，不能进入 worker 命令行或收据。
- `eN` 是短期引用；长期档案保存 AutomationId/Name/ControlType/父子关系，不保存本轮 ref。
- 敏感定向读取优先显式 `uiaread <hwnd> --id <AutomationId>`：可读类型内区分大小写、必须唯一，在正文读取与数量截断前筛选。组合查询可加精确/前缀 ID、类型、非敏感 Name、唯一子树和分页；continuation 必须绑定同一 HWND、查询和树指纹。零/多匹配、失效、树变化或内容不可读退出 2。旧位置过滤词仍是读后子串匹配，不能当隐私隔离。
- `invoke` 必须先在只读 worker 中解析当前元素并应用共享风险规则，再由 action worker 重定位与复核；无标签 Button/Hyperlink/MenuItem fail-closed。

### CDP

- 必须验证监听端口 owner PID 属于目标 exe 或进程树；端口能返回 JSON 不代表属于目标。
- 修改型 CDP 命令没有有效 `cdp-session-v1` 时必须退出 2；会话过期、owner 身份变化或 target 不在授权集合时都不能连接执行。
- target id 精确匹配优先；显式 title/URL 子串多命中或 `auto` 最高分并列时退出 2；授权集合含多个 page target 时写操作禁止 `auto`。
- HTTP/连接限 5 秒，单次协议请求限 6 秒；`auto` 只评分前 12 个候选且每个 1.5 秒；`act` 最多 200 步/120 秒。
- 修改命令必须写 `action-receipt-v1`。输入仅记录长度；CSS 和 `eval-unsafe` 表达式仅记录长度与 SHA-256；query/hash 不进入 target URL。
- 终端差分对所有承载用户文本的元素只显示字符数：采集时按 `isContentEditable`/input/textarea/`role=textbox|searchbox` 打 `editable` 标记，不能只靠 `kind` 后缀判断（Slate 的 `div/textbox` 曾因此漏脱敏）。
- `press SelectAll`（Ctrl+A）只用于撤回刚写进编辑器的内容；配 `Backspace` 走真实键事件，不用 `text` 清空 contenteditable。
- `click`/`mouse` 必须在 `withDiff` 之前做语义预检；form-submit、无标签动作目标和风险词命中都退出 2。`press Enter` 在元素聚焦前拒绝。拒绝收据写 `result.status=refused` 与 `riskGuard`。
- `eval-unsafe` 可运行任意 JavaScript，不在结构化风险检查保护面内；只能当开发/诊断逃生口，不能作为停手线绕行路径。
- 修改请求超时退出 2、`effect=unknown`。关闭 WebSocket 后让 Node 自然排空，不能恢复成强制 `process.exit(1)`，否则 Windows/libuv 可能断言崩溃。

### 截图与证据

- `PrintWindow` 有 2.5 秒看门狗，超时不得迟到覆盖目标文件。
- 账号、聊天、设备等敏感页默认从 `see/uia/uiaread --summary` 开始，只看类型统计，再按稳定 AutomationId 定向读取；摘要不脱敏截图或 `.uia.json`，两者仍按敏感证据保存与清理。
- sibling recovery 只允许几何近似且有进程血缘的窗口；收据保留请求窗口和实际渲染窗口身份。
- `shotfg` 要求两张连续非空稳定帧；它仍不是桌面合成截图。
- 判空只看裁掉边框后的内容区；内容区单色时收据另记 `frameColorBuckets`。空文档和黑壳窗口在像素上不可区分（内容区 1 桶、整帧约 20 桶），所以不得靠阈值“修好”它：`see` 用 UIA 空 Document/Edit 解释，`shotfg` 在 UIA 读到空文档且没有非空文本控件时不借前台。
- UIA 动作元素包含 Document；`first` 先 Edit，无 Edit 时兜底带 ValuePattern 的 Document。Chromium 页面 Document 会被列出，但 SetValue 会因无 ValuePattern 被拒。
- `screen` 才是桌面合成；`--window` 必须在当前桌面、可见且未最小化。裁剪后的图不得当作 `@` 坐标参考。
- `windows --all` 对不可见窗口输出 `state=hidden`；`shot` 对它们直说“不可见，空帧是预期”，`shotfg` 直接退出 2，不借前台。
- `restore`/`minimize` 是用户明确要求时才用的窗口状态命令：`SW_SHOWNOACTIVATE`/`SW_SHOWMINNOACTIVE` 不主动取得前台；只对可见（含最小化）窗口生效，隐藏窗口拒绝；打印窗口 before/after 与前台迁移。目标调用前已是前台时，最小化后仍可能保留前台 HWND；只有“其它前台 → 目标”是新激活，命令将其标为 partial 并退出 2。
- `PrintWindow` 首次直接失败（非空帧）时只重试一次（400 ms）；刚 `restore` 的窗口首帧会这样。不是循环重试。
- L0 COM：`New-Object -ComObject` 总是新起私有进程；只对新 pid 写/存/Quit，预存在的进程一律不 Quit；COM 对象不经 PowerShell 函数返回；全部 RCW 释放后再 Quit；用 Hwnd→pid→exe 核对身份（WPS 抢注了 Excel 的 ProgID/类名/Name）。`win.ps1 com` 只做“注册视图 + 身份核对 + Quit 私有实例”，不读写文档。
- `windows --all` 折叠不可见且 0 尺寸/无标题小尺寸的消息窗（Qt/CEF 动辄几百个）；`--raw` 才是完整列表。可见窗口与最小化窗口永不折叠。
- `open --background` 不得假装一定不抢前台；必须回读。禁止用 `PostMessage` 或注入去做“后台启动”。
- `scrollin --horizontal` 与纵向共用 200 步上限。
- 像素或 DOM 变化最多证明 `partial`，最终判据优先级是：业务副作用 > 状态指示器 > 控件读回 > 可见文字 > API 返回。
- 公开证据前检查账号、通知、本机路径、token、二维码、客户及未发布信息。

## 5. HUD 配置

- 默认：`corner`，鼠标穿透、不激活，并在支持的 Windows 版本上调用 `WDA_EXCLUDEFROMCAPTURE`。
- `WIN_USE_MASTER_HUD_STYLE=corner|glow|plain`：四角、整屏边框、仅标签。
- `WIN_USE_MASTER_HUD=0`：关闭 HUD。
- `WIN_USE_MASTER_HUD_CAPTURABLE=1`：只用于录制 HUD 演示；普通证据流程不要设置。
- 手动预览：`pwsh -NoProfile -File scripts/win.ps1 hud 1400 "测试" glow`。

## 6. 测试矩阵

### 2026-09-14 分层测试调度器

- 新增 `tests/run-tests.ps1`，将测试分为 `Contract`、`Desktop`、`Coordinate`、`Profiles`；默认仅运行无桌面的 Contract 层，真实应用必须显式 `-Profile`，多个名称用逗号连接。
- `-TestId` 可精确复跑当前层的一个或多个测试；`-List`/`-DryRun` 不启动应用。调度器对子测试设置总截止时间，输出 UTF-8，并保留 0/1/2 语义。
- 可选报告 schema 为 `win-use-master/test-report-v1`：记录版本、结果、耗时、输出行数和哈希，不保存原始测试日志或工作区绝对路径；已有报告默认拒绝覆盖。
- `test-runner-contract.ps1` 验证分层选择、profile 显式授权、dry-run、实际 parse 执行、报告隐私和覆盖保护；CI 增加该契约与 `uia-timeout.ps1`。
- 本地完整 Contract 层已通过 21/21，包含 release、risk policy、app profile catalog、profile template、public cases、benchmark、governance 与 repository hygiene 契约。该层仍不能替代 Desktop/Coordinate 回归；每个待发布提交还必须核对远程 CI 的目标 SHA。
- CI 已拆成单次核心契约和 Node 22/24 CDP 矩阵；`checkout`/`setup-node` 固定到已审查的完整 commit，禁用不需要的包缓存，并由 `ci-contract.ps1` 守住只读权限、矩阵和 action 身份。公开提交 `bb423a4` 的三个 job 均已通过；本地治理增量须在推送后重验目标 SHA。
- 本机可能同时解析出 Codex runtime 与 WindowsApps 两个 `pwsh.exe`。所有子进程入口必须使用 `Get-Command ... -CommandType Application | Select-Object -First 1`；静态契约会拒绝未显式选首项的 `pwsh`/`node` 解析，避免把多个路径拼成一个 FileName。

### 2026-09-21 安全与开源治理

- `THREAT_MODEL.md` 覆盖提示注入、CDP 身份、桌面/UIPI、坐标漂移、写后 unknown、证据泄露、清理越界、供应链与恶意贡献，并逐项列出残余风险和测试。
- `SECURITY.md` 不虚构邮箱或 SLA：优先使用 GitHub 私密漏洞报告；入口未启用时只创建不含细节的公开联络请求，等待私密渠道。
- Bug 与 app-profile Issue Forms 强制确认脱敏、授权和可逆任务；security-contact 表单刻意没有 input/textarea，空白 Issue 已关闭。
- PR 模板要求控制层、安全影响、测试/skip、隐私、兼容、owner 与清理说明；`governance-contract.ps1` 与 CI 同时守护这些文件。
- `SUPPLY_CHAIN.md` 与 `repository-hygiene-contract.ps1` 记录并守住当前零包管理依赖、两项固定 SHA 的 GitHub Action、MIT 许可证和禁止误入库的证据/二进制；扫描结果只报文件与规则，不输出疑似秘密内容。
- README 已增加零目标写入的五分钟体验与 English Quick Start；生命周期文档使用第三方 skills CLI 的精确 update/remove 命令，并明确缓存、session、helper、版本检查和用户 evidence 不会随卸载自动消失。没有增加 `agents/openai.yaml`：当前没有独立 UI 展示元数据需求，避免复制 `SKILL.md`。

### 2026-09-14 只读 doctor 增量

- 主入口在 `Import-HuCore` 前分发 `doctor`，所以 helper 缺失、过期或不可加载时只给建议，不触发现场编译。
- `doctor-report-v1` 区分必需核心能力与可选 CDP/桌面能力；缺 Node/Chromium 不让 UIA/截图核心整体失败，锁屏只阻断桌面相关层。
- 输出不保存绝对路径、窗口标题和正文。临时目录写权限刻意报告为 `unknown/not-probed`，因为以创建文件验证“可写”会破坏零写入承诺。
- `tests/doctor-contract.ps1` 共享同一纯判定核心，用五类 fixture 验证退出码、能力降级、隐私和历史残留只告警不删除；同名前缀与“有效 manifest”分开计数，后者也不构成删除授权。端到端检查还守住提前分发和 helper 时间戳不变。

### 2026-09-14 UIA 限定查询与安全分页

- `uiaread` 新增 `--id-prefix`、`--type`、`--name`、`--name-prefix`、`--within-id`、`--limit` 和 `--continuation`；单独 `--id` 与旧位置过滤词仍走兼容路径。
- 精确条件交给 UIA provider 求交，前缀条件在 worker 内只读元数据后过滤；只有当前页才调用 ValuePattern/TextPattern，密码正文继续不读。
- `uia-continuation-v1` 不含原始 ID/Name/Value；除 schema 外只含查询哈希、匹配树哈希和偏移。调用方必须重复完全相同的查询；HWND、PID/启动时间、子树根 RuntimeId、候选 RuntimeId 顺序或元数据变化均在页正文读取前拒绝。它是只读游标，不是鉴权或加密签名；调用方必须按不透明值处理。
- `--within-id` 必须唯一；RuntimeId 不可用时不签发后页 token。Name 查询值仍位于父命令行，因此只能用于非敏感 UI 标签。

### 2026-09-15 统一机器可读输出

- `windows`、`frontmost`、`idle`、`uia`、`uiaread` 新增 `--json`，各自使用独立 `*-result-v1` schema；默认文本输出不变。
- `--summary` 将窗口标题设为 null、将 UIA items 置为空数组，同时保留状态、计数和 ControlType；过滤词和 UIA 查询值不复制进报告。
- `frontmost` 区分 `resolved/unlisted/none`，`idle` 无法读取时使用 `unknown` 与 null 秒数，避免把未知当 false/0。
- `probe-report-v1` 不复制查询值；summary 省略 app 身份/路径、进程与窗口明细、原始能力证据和警告正文，只保留状态、计数与 L0–L3 路由。未命中为 `not-found`，动态状态使用 `unknown/null`。
- `window-state-result-v1` 覆盖 `restore/minimize` 的 `planned/completed/partial/error/refused`，记录状态回读、前台迁移和 `effect`；`--dry` 是 `planned/not-applied`。目标已改变但意外取得前台仍退出 2，不能被 JSON 包装成成功。
- CDP `list/inspect` 新增 `--json/--summary`：列表摘要清空 targets；full URL 也删除 query/fragment 且永不输出 WebSocket URL；inspect 从采集层只保留角色/状态/正文长度，不复制 target/CSS 选择器。写命令继续只认 `action-receipt-v1`。
- `tests/json-output-contract.ps1` 使用纯 fixture 与本地 HTTP fixture 检查 probe、窗口状态、五类窗口/UIA 报告和 CDP target；`cdp-action-receipt.ps1` 用无头 Edge验证 inspect full/summary 与参数误拼失败关闭。

### 2026-09-15 建议性能力缓存

- `win.ps1 cache show|record <probe-report.json>|clear <key|--all>` 在 `Import-HuCore` 前独立执行。默认 `show` 只读；probe 从不隐式写 cache，只有显式 `record` 才消费 resolved full `probe-report-v1`。
- 默认路径是 `%LOCALAPPDATA%\win-use-master\capability-cache-v1.json`。测试覆盖的自定义路径只允许系统临时目录下准确的 `win-use-master-capability-cache-test-<GUID>\capability-cache-v1.json`，并要求测试开关。
- 规范化后只留产品/版本/exe 名、窗口类、框架与 COM/CDP/UIA 观察；标题、UIA/DOM 正文、账号、命令行、路径、PID/端口和未知字段全部丢弃。30 天、未来时间、版本变化和无版本身份均失败关闭。
- `probe --no-cache` 或 `WIN_USE_MASTER_CAPABILITY_CACHE=0` 禁止读取；后者同时让 record/clear 退出 2。fresh cache 只返回 `advisoryOrder`，仍须实时核对 owner/session、UIA 元素、桌面/UIPI/前台/遮挡/用户在场和风险规则。
- `tests/capability-cache-contract.ps1` 在隔离临时目录验证字段白名单、失效、summary 隐私、show 文件哈希/时间戳不变、禁用零修改、精确清除，以及伪造 `trusted/allowWrite/L2` 不能绕过 CDP session；CI 核心 job 已加入该契约。

### 2026-09-15 临时对象治理 dry-run

- `win.ps1 cleanup [--dry-run] [--json] [--summary]` 在 helper 加载前运行；默认就是 dry-run，`--apply` 明确未开放并在扫描前退出 2。
- 生产根固定为系统临时目录，仅枚举符合 `win-use-master-*` 受限命名的直接子目录。候选需要恰好一个 `temp-artifact-v1` manifest，artifact ID 等于目录叶名，生命周期不超过 30 天且已经到期。
- owner 通过 PID + 启动时间识别；原 owner 活跃或状态未知拒绝，PID 已复用只说明原 owner 已消失。候选、manifest 或内部树出现 reparse point，目录不可读或超过 10,000 项也拒绝。
- `cleanup-plan-v1` 不输出绝对路径、payload 内容或 manifest 未知字段；summary 清空 items。生产 cleanup 两个脚本没有删除 primitive，报告副作用计数固定为 0。
- `tests/cleanup-contract.ps1` 覆盖有效过期、活动 owner、未过期、缺/错/错配 manifest 和非项目目录；对 fixture 全部文件做相对名/长度/时间戳/SHA-256 前后比对，确保所有 dry-run 与拒绝路径零修改。CI 核心 job 已加入该契约。

### 2026-09-15 只读性能基线

- `win.ps1 benchmark [--quick] [--no-cdp] [--json] [--summary]` 在 helper 自动加载前分发；helper 必须已构建，基线本身不会触发编译。
- `windows` 分别记录第一次和后续全新 PowerShell 进程，文档明确后者只可能受 OS 缓存影响，不伪称进程内 warm。UIA 通过 AST 加载实际 `Get-UiaReadablePage`，对 100/300/1000 元素合成 provider 返回前 50 项。
- 默认 CDP 只启动唯一临时 profile 的无头 Edge，对空白页执行 `inspect auto body --json --summary`；只按完整 profile 路径识别并终止本次进程，验证精确 temp 根后回收。`--no-cdp` 不创建临时目录。
- `performance-report-v1` 只有 min/p50/p95/max/mean 聚合，不保存原始样本、子命令输出、窗口数量/标题、正文、路径、selector、target、PID 或端口；副作用字段报告窗口摘要读取、浏览器启动、所见/剩余 owner 进程和 temp 目录回收。
- 本机标准档已完成：windows first 1031.350 ms，repeated p50/p95 843.120/856.627 ms；UIA 100/300/1000 p95 为 25.493/88.213/248.100 ms，均 0/5 超 6000 ms；CDP inspect p50/p95 95.233/100.076 ms。它是单机回归参考，不是 SLA。
- `tests/benchmark-contract.ps1` 守住 nearest-rank、schema/隐私、quick/no-CDP 仓库零修改、参数预拒绝，以及 UIA/CDP 生产超时常量不被放宽。PrintWindow 和 CDP 写性能未执行。

### 2026-09-10 本地精确读取增量

- 新增 `uiaread --id` 的 worker 读前精确筛选、候选唯一性、读取前身份复核；`see --summary` 正常结果不再显示窗口标题。Skill 主流程与详细说明已同步并通过 skill-creator 校验。
- 本轮通过：PowerShell 解析、构建、静态发布契约、`uia-read-contract.ps1`、CDP ownership 与 action-receipt 回归、`uia-timeout.ps1`（写 unknown 与精确读拒绝；进程端到端约 7.3s/7.2s，含启动开销）。CI 已增加无桌面的精确读取契约步骤，但本批尚未推送，不能视为远端 CI 已验证。
- 真实 WinForms 的新检查通过：精确标签读取、子串 ID 拒绝、精确摘要抑制 ID/正文，以及 `see --summary` 省略窗口标题。
- 完整 `smoke.ps1` 上轮未全绿：一次动作后状态读回失败，复测该项通过；随后发现 `restore` 断言混淆了“目标原本就持有前台 HWND”和“其它前台新切到目标”。本轮已改为比较还原前后迁移，并让命令对意外新激活报 partial/退出 2；无桌面契约已加，真实 smoke 仍需在用户空闲时复验。坐标输入上轮因用户活动而跳过，不能标成 L2 通过。
- 设置已有 `SystemSettings` 实例，本轮未运行新版设置档案，也未复用/关闭用户实例。测试生成的临时截图与收据已清理；源文件修改仅在本地。

### 2026-09-11 窗口状态回归修正

- 官方 `ShowWindow` 语义与代码复核确认：`SW_SHOWMINNOACTIVE` 不主动激活目标，但前台目标被最小化后仍可能保留前台 HWND；旧 smoke 仅检查还原后的最终 HWND，误报为 `restore` 新激活。
- 新增生产前台迁移分类：`unchanged`、`target-already`、`released-by-windows`、`changed-external`、`unexpected-target`。窗口状态命令输出 before/after；只有“其它前台 → 目标”标为 partial 并退出 2。
- `tests/window-state-contract.ps1` 无桌面覆盖五种迁移，已加入静态发布契约与 Windows CI。本轮通过该契约、PowerShell 解析、Skill 校验、静态发布契约、UIA 精确读取契约、CDP ownership 与完整 action-receipt 回归；修正后复跑 profile 数保持 6→6，没有新增临时目录。
- 上轮 InvokePattern 后状态标签曾一次立即读到旧值，复测通过；smoke 改用唯一 `fixtureStatus` AutomationId 做最多 1.25 秒的独立读回，只重读状态、不重放动作。
- CDP action-receipt 回归曾在 Edge 已终止但子进程文件锁尚未释放时静默留下 profile；finally 现按本轮唯一 profile 反复核对进程退出并重试删除，清理失败会让测试失败。历史临时目录不属于仓库，清理前仍须逐个验证路径和进程归属。
- 长时 request/act deadline 后 Edge 可能重建 CDP listener；旧 owner-bound 会话按设计失效。会话篡改断言前现显式重新绑定当前 owner/target，避免前置 owner 拒绝遮住 multi-target/target/expiry 各自要验证的规则。
- 本轮检测到用户持续操作 ChatGPT/Chrome，未启动会弹窗的真实 smoke；因此真实窗口迁移与发布级 L2 仍待用户空闲时复验。本批仍仅在本地，未提交、未推送。

### 每次提交至少运行

```powershell
pwsh -NoProfile -File tests/run-tests.ps1 -Tier Contract
```

### 有活动交互桌面的本机回归

`uia-read-contract.ps1` 不启动 app、不访问桌面：对实际生产函数使用 provider 替身，检查迟于第 300 项的目标、精确/前缀/类型组合、唯一子树、分页推进、树/窗口变化失效、重复 ID、密码、正文延迟读取与参数错误；不是实机 UIA 兼容性的替代。`smoke.ps1` 另验证真实 WinForms → CLI → 隔离 worker 的精确读取和摘要输出；新版限定查询仍待独立桌面时段复验。

```powershell
pwsh -NoProfile -File tests/run-tests.ps1 -Tier Desktop
```

发布级 L2：

```powershell
pwsh -NoProfile -File tests/run-tests.ps1 -Tier Coordinate
```

运行期间不要操作键鼠。Windows Foreground Lock 安全拒绝时退出码 2，不应改测试去绕过。

真实 app 档案回归：

```powershell
pwsh -NoProfile -File tests/calculator-profile.ps1
pwsh -NoProfile -File tests/notepad-profile.ps1
pwsh -NoProfile -File tests/settings-profile.ps1
# 需用户先：pwsh -NoProfile -File scripts/win.ps1 open "<path>\WorkBuddyAI.exe" --cdp 9333 --background
pwsh -NoProfile -File tests/workbuddy-cdp-profile.ps1 -Port 9333
# L0 COM，各自新起私有实例，不碰用户已打开的 Excel/WPS；WPS 未安装时第二个会失败
pwsh -NoProfile -File tests/excel-com-profile.ps1
pwsh -NoProfile -File tests/wps-et-com-profile.ps1
```

前三者发现目标原本已打开时会拒绝运行；不要关闭用户已有实例。计算器测试执行 `1+2=3`、恢复 0 并关闭。记事本测试还会拒绝向恢复出的会话写入（多标签、已修改或非空文档），写入后清空再关闭；记事本 11 关闭已修改标签不弹提示而是留到下次会话，因此失败路径同样先清空。设置测试不调用控件、不写搜索框，要求 `see/uia/uiaread --summary` 不输出语义明细，只做过滤后的语义读回和 PrintWindow 收据核对，随后删除含账号/设备语义的临时 map。WorkBuddy 测试相反：它从不启动、重启或关闭 app，只接受用户已授权并带 `--cdp` 启动的实例；无实例、端口归属不明或输入区有草稿时退出 2。它不按 Enter、不点发送、不碰「重启升级」。

云 CI 的核心 job 运行解析、构建、发布/CI 静态契约、跨运行时风险规则、测试调度器、UIA 读取/超时和窗口状态；CDP job 在 Node 22/24 矩阵中分别运行 owner 与无头 Edge 收据/超时测试。静态契约守住必需发布文件、架构 SVG、README 相对链接、兼容入口和 `SKILL.md ≤ 6000` 字符；风险专项守住正反例、规则 ID、规范化与失败关闭。GitHub runner 没有可信的用户交互桌面，因此不得把 L2、截图/UIA fixture 或计算器测试塞进 CI 后宣称通过。

## 7. 发布流程

1. 确认 `git status --short` 只含本轮预期文件。
2. 扫描真实密钥、本机绝对路径、账号和测试残留。
3. 运行上面的本地测试；`static-contract.ps1` 必须通过，生成的 DLL 和 `.last-update-check` 应保持 ignored。
4. 核对 `config/release.json`、`VERSION`、`CHANGELOG.md` 与 `RELEASE_NOTES.md`；运行 `scripts/release-check.ps1 -Json -Summary`。退出 2 代表发布门尚未闭合，不能发布。
5. 只有用户明确要求时，才使用描述性提交信息推送 `main`；文档完善或本地通过不是推送、tag 或 Release 授权。
6. 等待 `.github/workflows/ci.yml` 完成；远端 SHA 必须与本地一致。
7. 更新 `references/与mac版差距.md`：已编码消除的缺口移入“已经对齐”。
8. 全部门通过且仓库所有者明确授权后，才按 `references/版本与发布.md` 创建 tag、校验和与 Release；故障恢复按 `references/回滚与恢复.md`，不覆盖用户工作区。

不要提交临时证据、用户窗口截图、测试 profile、`HuWin.dll` 或任何凭据。

## 8. 当前待办

1. M0：在专用空闲桌面完成 Desktop、Coordinate、capture recovery 和 Settings 发布门；不得用云 CI 代替。
2. M4：由仓库所有者开启 GitHub 私密漏洞报告；定期人工复核固定 Action、runner 镜像、历史提交和许可证变化。
3. M2-06 第二阶段：专用空闲桌面测 PrintWindow；CDP `insert/press` 另建一次性授权、隔离且可撤回的写基线。
4. M2-05 后续评审：`--apply` 仍未授权且未实现；先设计二次扫描/TOCTOU/部分失败契约，再单独决定是否开放。
5. M3-02：剪映 CEF、QQ 可逆写、微信安全停手和 Blender L0 档案均需对应用户授权或安装条件；M3-01 机器目录/矩阵与 M3-03 测试模板首版已完成。
6. P1：三类脱敏文字案例、版本策略、Changelog、Release Notes 草案、回滚说明、英文快速开始和安装生命周期指南已完成；仍需真实截图/GIF 的人工脱敏复核，以及全部发布门通过后的 tag/校验和/Release 实证。

## 9. 常见误判

- `ApplicationFrameHost.exe` 是通用宿主，不是目标应用本体；Store app 启动优先解析精确 AUMID。
- 发现 `WebView2Loader.dll` 不等于开放了 CDP；发现 Electron 也不等于存在调试端口。
- UIA 列出 ValuePattern 不等于框架内部 state 已更新；必须读回状态或业务副作用。
- `PrintWindow` API 成功不等于图像完整、新鲜或等同用户屏幕。
- “内容区接近纯色”不等于截图失败：空文档、空画布与黑壳窗口像素上一样；看 `frameColorBuckets` 和 UIA 文本控件再下结论。
- `see --out` 在 `pwsh -File` 下会在参数绑定阶段失败（二义的 `-Out*` 前缀）；文档和脚本都用位置参数路径。
- `windows --all` 列出的窗口可能是 `state=hidden`：截图空帧、UIA 空树、`screen` 拒绝都只是“窗口没显示”，不是该 app 的能力结论。
- CDP `list` 打印的 target URL 可能带账号类 query（收据已去掉）；不要把 `list`/`snapshot` 原文贴进档案。
- `open` 对运行中的 app 不等于“显示它的窗口”：QQ 会新起实例弹登录窗，剪映启动器转交后什么都不显示。窗口层永远回读 `windows`。
- “Microsoft Excel”/`XLMAIN`/`Excel.Application.12` 在装了 WPS 的机器上可能都是 WPS；只有 exe 路径可信。
- UIA 可用性不能按框架猜：Electron 的 QQ 可读、WorkBuddy 空树；Qt 的剪映会挂死 provider（隔离 worker 6 秒终止是唯一保护）。
- HWND、端口、UIA/CDP ref、坐标和界面文案都是易腐信息，不得写成通用常量。
