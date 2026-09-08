# win-use-master 维护交接

更新日期：2026-09-08  
公开仓库：<https://github.com/sun509549-del/win-use-master>  
上游设计：[alchaincyf/huashu-mac-use](https://github.com/alchaincyf/huashu-mac-use)

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
- 收据 schema 已统一为 `win-use-master/receipt-v1`、`win-use-master/uia-map-v1`、`win-use-master/action-receipt-v1`。
- 完整可重放档案有三个：计算器 11.x（UWP 宿主 + InvokePattern）、记事本 11.x（打包桌面 app + Document ValuePattern 可逆写）、WorkBuddy AI 5.4.2（Electron + Slate，CDP 零焦点 insert/撤回，发送键作状态指示器；需用户先以 `--cdp` 启动授权实例）。剪映 10.4.0 两轮观察：启动器只拉起「环境检测」；编辑器进程起来后全部窗口隐藏，截图/UIA 皆空。Blender 未安装。证据图、快照原文不入库。

## 3. 代码地图

| 路径 | 职责 |
|---|---|
| `SKILL.md` | agent 必须遵守的主流程、安全闸、停手线和文档路由 |
| `scripts/win.ps1` | 用户入口；窗口解析、截图、UIA worker 调度、坐标动作、安全闸和收据 |
| `scripts/HuWin.cs` | Win32/DWM/SendInput/DPI/截图看门狗/输入尾迹/HUD 底层 |
| `scripts/uia-worker.ps1` | 隔离的 UIA list/read/resolve/set/invoke worker，正文经 stdin 传递 |
| `scripts/probe.ps1` | 只读应用发现：Win32/AppX、版本、架构、runtime、端口、协议、COM、窗口、UIA、完整性 |
| `scripts/cdp.js` | CDP target、DOM ref、动作、截图、差分、脱敏收据和截止时间 |
| `references/控制面详解.md` | 四层原理和选择依据 |
| `references/权限与故障.md` | UIPI、锁屏、虚拟桌面、截图/UIA/CDP/HUD 故障处理 |
| `references/取证规范.md` | before/action/after、哈希、隐私、归档和跑批 |
| `references/app档案.md` | 易腐的 per-app 实测模板及计算器档案 |
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

### CDP

- 必须验证监听端口 owner PID 属于目标 exe 或进程树；端口能返回 JSON 不代表属于目标。
- HTTP/连接限 5 秒，单次协议请求限 6 秒；`auto` 只评分前 12 个候选且每个 1.5 秒；`act` 最多 200 步/120 秒。
- 修改命令必须写 `action-receipt-v1`。输入仅记录长度；CSS 仅记录长度与 SHA-256；query/hash 不进入 target URL。
- 终端差分对所有承载用户文本的元素只显示字符数：采集时按 `isContentEditable`/input/textarea/`role=textbox|searchbox` 打 `editable` 标记，不能只靠 `kind` 后缀判断（Slate 的 `div/textbox` 曾因此漏脱敏）。
- `press SelectAll`（Ctrl+A）只用于撤回刚写进编辑器的内容；配 `Backspace` 走真实键事件，不用 `text` 清空 contenteditable。
- 修改请求超时退出 2、`effect=unknown`。关闭 WebSocket 后让 Node 自然排空，不能恢复成强制 `process.exit(1)`，否则 Windows/libuv 可能断言崩溃。

### 截图与证据

- `PrintWindow` 有 2.5 秒看门狗，超时不得迟到覆盖目标文件。
- sibling recovery 只允许几何近似且有进程血缘的窗口；收据保留请求窗口和实际渲染窗口身份。
- `shotfg` 要求两张连续非空稳定帧；它仍不是桌面合成截图。
- 判空只看裁掉边框后的内容区；内容区单色时收据另记 `frameColorBuckets`。空文档和黑壳窗口在像素上不可区分（内容区 1 桶、整帧约 20 桶），所以不得靠阈值“修好”它：`see` 用 UIA 空 Document/Edit 解释，`shotfg` 在 UIA 读到空文档且没有非空文本控件时不借前台。
- UIA 动作元素包含 Document；`first` 先 Edit，无 Edit 时兜底带 ValuePattern 的 Document。Chromium 页面 Document 会被列出，但 SetValue 会因无 ValuePattern 被拒。
- `screen` 才是桌面合成；`--window` 必须在当前桌面、可见且未最小化。裁剪后的图不得当作 `@` 坐标参考。
- `windows --all` 对不可见窗口输出 `state=hidden`；`shot` 对它们直说“不可见，空帧是预期”，`shotfg` 直接退出 2，不借前台。
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

### 每次提交至少运行

```powershell
pwsh -NoProfile -File scripts/build.ps1
pwsh -NoProfile -File tests/cdp-ownership.ps1
pwsh -NoProfile -File tests/cdp-action-receipt.ps1
```

### 有活动交互桌面的本机回归

```powershell
pwsh -NoProfile -File tests/smoke.ps1
pwsh -NoProfile -File tests/capture-recovery.ps1
pwsh -NoProfile -File tests/uia-timeout.ps1
```

发布级 L2：

```powershell
pwsh -NoProfile -File tests/smoke.ps1 -RequireCoordinate
```

运行期间不要操作键鼠。Windows Foreground Lock 安全拒绝时退出码 2，不应改测试去绕过。

真实 app 档案回归：

```powershell
pwsh -NoProfile -File tests/calculator-profile.ps1
pwsh -NoProfile -File tests/notepad-profile.ps1
# 需用户先：pwsh -NoProfile -File scripts/win.ps1 open "<path>\WorkBuddyAI.exe" --cdp 9333 --background
pwsh -NoProfile -File tests/workbuddy-cdp-profile.ps1 -Port 9333
```

前两者发现目标原本已打开时会拒绝运行；不要关闭用户已有实例。计算器测试执行 `1+2=3`、恢复 0 并关闭。记事本测试还会拒绝向恢复出的会话写入（多标签、已修改或非空文档），写入后清空再关闭；记事本 11 关闭已修改标签不弹提示而是留到下次会话，因此失败路径同样先清空。WorkBuddy 测试相反：它从不启动、重启或关闭 app，只接受用户已授权并带 `--cdp` 启动的实例；无实例、端口归属不明或输入区有草稿时退出 2。它不按 Enter、不点发送、不碰「重启升级」。

云 CI 只运行解析、构建、CDP owner 和无头 Edge 收据/超时测试。GitHub runner 没有可信的用户交互桌面，因此不得把 L2、截图/UIA fixture 或计算器测试塞进 CI 后宣称通过。

## 7. 发布流程

1. 确认 `git status --short` 只含本轮预期文件。
2. 扫描真实密钥、本机绝对路径、账号和测试残留。
3. 运行上面的本地测试；生成的 DLL 和 `.last-update-check` 应保持 ignored。
4. 使用描述性提交信息推送 `main`。
5. 等待 `.github/workflows/ci.yml` 完成；远端 SHA 必须与本地一致。
6. 更新 `references/与mac版差距.md`：已编码消除的缺口移入“已经对齐”。

不要提交临时证据、用户窗口截图、测试 profile、`HuWin.dll` 或任何凭据。

## 8. 当前待办

1. P1：再补一个非 Store 的 Win32/WPF app 只读 + 可逆写档案（记事本 11 已覆盖打包桌面 app + Document 路径，但它仍是 Store 分发）。
2. P1：剪映编辑器可见态的 PrintWindow/UIA，以及 CEF 是否接受 `--remote-debugging-port`；都需要用户显示窗口或授权重启，不得自行 ShowWindow。
3. P1：制作经脱敏的真实 Windows 案例和架构图。
4. P2：把本项目特有、可复现且不能编码消除的失败过程整理进 `踩坑实录.md`；不要复制 Mac 结论凑文档。

## 9. 常见误判

- `ApplicationFrameHost.exe` 是通用宿主，不是目标应用本体；Store app 启动优先解析精确 AUMID。
- 发现 `WebView2Loader.dll` 不等于开放了 CDP；发现 Electron 也不等于存在调试端口。
- UIA 列出 ValuePattern 不等于框架内部 state 已更新；必须读回状态或业务副作用。
- `PrintWindow` API 成功不等于图像完整、新鲜或等同用户屏幕。
- “内容区接近纯色”不等于截图失败：空文档、空画布与黑壳窗口像素上一样；看 `frameColorBuckets` 和 UIA 文本控件再下结论。
- `see --out` 在 `pwsh -File` 下会在参数绑定阶段失败（二义的 `-Out*` 前缀）；文档和脚本都用位置参数路径。
- `windows --all` 列出的窗口可能是 `state=hidden`：截图空帧、UIA 空树、`screen` 拒绝都只是“窗口没显示”，不是该 app 的能力结论。
- CDP `list` 打印的 target URL 可能带账号类 query（收据已去掉）；不要把 `list`/`snapshot` 原文贴进档案。
- HWND、端口、UIA/CDP ref、坐标和界面文案都是易腐信息，不得写成通用常量。

