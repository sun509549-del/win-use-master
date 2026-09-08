# 与 huashu-mac-use 的功能差距

> 基线：上游 [huashu-mac-use](https://github.com/alchaincyf/huashu-mac-use) 的 README/SKILL 所表达的设计，以及用户提供的[相关文章](https://mp.weixin.qq.com/s/pgvLMG7pg_1lpPLMN8zbhg)。本表记录 Windows 版本的工程差距，不把操作系统做不到的能力伪装成待实现功能。更新日期：2026-09-08。

## 已经对齐

| 设计能力 | Windows 落点 |
|---|---|
| 先探测、再按 L0–L3 选控制面 | `probe.ps1` + `win.ps1` + `cdp.js` |
| 读操作尽量不借焦点 | `windows/shot/see/uia/uiaread/CDP` |
| 写优先结构接口和语义层 | CDP `insert/mouse`、UIA `uiaset/invoke` |
| 坐标写前检查用户在场、遮挡和前台 | 全机锁、idle 等待、前台读回、点位遮挡、光标/前台还原 |
| 跨桌面/锁屏/权限不明时安全拒绝 | DWM cloaked、输入桌面、UIPI 完整性检查，退出码 2 |
| 后台截图、判空、必要时短借前台 | `PrintWindow` 看门狗、严格 sibling recovery、`shotfg` 稳定双帧 |
| 图上坐标到窗口坐标换算 | `@截图` + receipt 中 `imageToWindowScale` |
| 动作后验证而非相信 API 返回值 | 像素差分、UIA 读回、CDP 交互树摘要与 effect |
| 每一步机器可读取证 | 截图 receipt；L1/L2 after action 链；CDP `action-receipt-v1` |
| 陌生 provider 不能卡死 agent | UIA 全部放入 6 秒隔离 worker，写超时标 `unknown` |
| CDP 不能无限等待 | HTTP/连接 5 秒、请求 6 秒、auto 候选限额、act 200 步/120 秒；写超时标 `unknown` |
| 一键安装与干净环境回归 | 公开 GitHub 仓库可被 `npx skills add` 识别；Windows CI 负责解析、构建和无头 CDP 集成测试 |
| HUD 可配置性 | `corner/glow/plain` 三种样式、关闭开关、显式可捕获演示开关；默认仍不激活且尽力排除捕获 |
| 不激活启动 | `open --background`：`SW_SHOWNOACTIVATE` 请求 + 前台回读/尽力归还；UWP/.lnk 拒绝该开关 |
| 桌面合成交叉验证 | `screen`：全屏 / `--window` 裁剪 / `--region`；收据含 occlusion 采样与 clipped |
| 横向滚动 | `scrollin --horizontal` → `MOUSEEVENTF_HWHEEL`，仍受 200 步限制 |
| COM 作为 L0 | `probe.ps1` 只读 LocalServer32/TypeLib，不实例化；路径建议写入 L0 |
| SKILL 正文体积 | 压到 ≤6k 字符；细则整段落入 references |
| 空图判定不能只靠像素 | 内容区/整帧两个桶数进收据；`see` 用 UIA 空 Document/Edit 解释空白文档；`shotfg` 不为空文档借前台 |
| RichEdit/Document 类编辑器的 L1 写 | worker 动作元素含 Document，`first` 兜底 Document(ValuePattern)；记事本 11 全链路回归 |
| CDP 零焦点可逆写与撤回 | `insert` + `press SelectAll`/`Backspace` 真实键事件；WorkBuddy 上以发送键 disabled 状态为指示器全链路回归 |
| 编辑器正文不进日志 | 采集时打 `editable` 标记，`role=textbox` 的 Slate/ProseMirror 差分只显示字符数；无头 Edge 回归守住 |
| 隐藏窗口不误判 | `windows --all` 标 `state=hidden`；`shot` 直说不可见、`screen`/L2/`shotfg` 拒绝 |
| 用户要求时还原/最小化窗口 | `restore`/`minimize`：`SW_SHOW*NOACTIVE` 不改前台，隐藏窗口拒绝，打印前后状态（Mac 靠 `mac open` 激活） |
| COM 作为 L0 的真实写路径 | Excel/WPS 两个私有实例档案：身份核对、Visible 时机、RCW 释放、不经宿主验证文件 |
| app 经验回流与版本自检 | `app档案.md`、30 天静默版本检查 |

## 仍缺少或样本不足

| 优先级 | 差距 | 当前状态 / 完成标准 |
|---|---|---|
| P1 | 真实 app 档案广度 | 完整可重放档案五个：计算器（Invoke）、记事本（Document ValuePattern）、WorkBuddy（CDP 零焦点写/撤回）、Excel（COM 私有实例写表另存并不经 Excel 验证）、WPS 表格（KET.Application 同任务 + 二次打开）。只读档案：QQ（UIA 可读、PrintWindow 完整、无 CDP）、剪映（可见态截图完整、UIA 挂死）。Mac 有 11 个 app；Windows 7 个，且 Blender、微信、系统设置类样本仍缺。 |
| P1 | 跨 app 共性结论 | 已有 8 条（`app档案.md` 四·五节），每条 ≥2 个实现复现；比 Mac 的 9 条少一轮验证周期。 |
| P1 | 面向用户的真实案例与视觉素材不足 | Mac 版有 Blender/桌面客户端案例、GIF 和架构图；Windows 版目前重工程验证、轻展示。需要经脱敏的 Windows 原生/UIA/CDP 案例与架构图，但不能拿测试 fixture 冒充生产案例。 |
| P1 | 单 app 经验的广度不足 | Mac 档案覆盖多个 Electron 和原生 app；Windows 需要随真实任务渐进积累，不能凭框架名称推断 UIA/CDP/截图一定可用。 |
| P2 | 翻车过程文档尚未独立沉淀 | 原理、故障、证据、app 档案已拆分，但没有对应 `踩坑实录.md`。只有出现可复现且不能编码消除的教训时再补，避免复制 Mac 结论。 |

## 不应照搬的“差距”

Mac 版可以先尝试向指定 PID 投递合成事件，失败后再借焦点。Windows 对任意现代桌面 app 没有同等可靠、安全、通用的 per-PID 后台键鼠接口；`PostMessage`、窗口消息伪造和注入都不能等价替代 `SendInput`，还会绕过真实命中测试或扩大权限风险。因此 Windows 版把所有 L2 坐标输入设计为“短暂借前台 + 完整安全闸”，这是平台适配，不是待补 bug。

同理，macOS 的 AppleScript 字典、TCC、Space 和 CGWindow 能力，在 Windows 分别对应 app 自有 CLI/COM/协议、UIPI/UAC、虚拟桌面 cloaking 和 `PrintWindow`/DWM；只能保持设计原则一致，不能追求命令逐字一致。

## 下一步顺序

1. 剪映 CEF `--remote-debugging-port` 与更新弹窗（需用户授权重启/显示）作为第二个 Chromium 实现。
2. 微信、系统设置、Blender 等补样本；QQ 输入框写路径需用户指定可逆目标。
3. 案例素材与 `踩坑实录.md`。
