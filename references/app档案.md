# Windows per-app 操控档案

> 🔴 **易腐声明**：这里记录的版本、exe 路径、进程名、窗口类、端口、UIA 属性、按钮文案与坐标都会随升级、安装渠道、显示器和账号状态变化。
>
> **档案用来形成假设，不用来跳过现场探测。** 每次先 `probe.ps1`、`windows`、`see`，再拿本文件对照。坐标对不上就视为已失效，绝不凭旧数字点击。

当前仓库不内置未经本机实测的 app 结论。Windows 同名 app 可能同时存在 Win32、Microsoft Store、企业封装和自动更新版本；把另一个人的观察冒充本机事实，比空档案更危险。

## 一、维护规则

1. 每个 app 只保留一个当前条目；历史版本移入该条目的“已失效记录”，不要堆多个互相矛盾的结论。
2. 标题写 `显示名 · 版本 · 实测 YYYY-MM-DD`。每个易腐字段行尾也写核对日期。
3. 版本、exe 路径、包标识或主窗口类任一变化，L0–L3 全部重测。
4. 动态端口、PID、HWND 不存为常量，只记录发现方法和本次收据。HWND 关闭后会失效，也可能被复用。
5. 坐标只存“归一化坐标 + 可见锚点 + 实测窗口尺寸 + DPI/显示器”，不存裸全局坐标。
6. UIA ref、CDP `ref=eN` 都是会话内引用，档案存重新定位规则，不存 ref 本身。
7. “调用成功”不能写成“能力可用”；必须附读回、状态指示器或业务副作用。
8. 单个 app 的观察留在这里；至少两个不同实现复现、且能稳定解释，才提炼到控制面正文。
9. 先问“能否变成工具的探测、拒绝或自诊断”。能，就改脚本并为档案保留证据，不把人工口诀当永久方案。

## 二、新增 app 的现场流程

```powershell
# 1. 纯只读能力探测；不会启动、关闭或重启 app
pwsh -NoProfile -File "$SKILL_DIR/scripts/probe.ps1" "显示名或 exe 路径"

# 2. 枚举真实窗口，拿到当前 HWND/PID/状态
pwsh -NoProfile -File "$SKILL_DIR/scripts/win.ps1" windows "关键词"

# 3. 读取窗口图、收据与当次 UIA map
pwsh -NoProfile -File "$SKILL_DIR/scripts/win.ps1" see <hwnd> --out .\evidence\raw\app-see.png

# 4. 必要时单独复核 UIA
pwsh -NoProfile -File "$SKILL_DIR/scripts/win.ps1" uia <hwnd>

# 5. 读取 Text/Document/Edit/Status/Header 的可见语义文本
pwsh -NoProfile -File "$SKILL_DIR/scripts/win.ps1" uiaread <hwnd> [名称或 AutomationId]
```

再按优先级实测：

1. L0 CLI / protocol / app 自有端口；
2. 若确认有 CDP，读 `list` / `snapshot`，不要先写；
3. L1 UIA 的 `ValuePattern` / action pattern；
4. L2 坐标只做可逆动作，先 `--dry`；
5. L3 分别验证后台 `shot` 与必要时的 `shotfg`；
6. 为每一项写“成功判据”和失败证据。

`probe.ps1` 未运行目标 app 时，窗口、动态进程树、端口、CDP 和 UIA 为空是正常的。不要为了补全档案擅自启动或重启 app。特别是 `open --cdp --relaunch` 会影响未保存内容，必须获得用户同意。

## 三、条目模板

复制下面整段；未知写 `未测`，不要猜。

```yaml
显示名: <用户看到的名称>
实测日期: YYYY-MM-DD
版本: <文件版本/产品版本/包版本>          # 核对 YYYY-MM-DD
安装形态: <Win32 exe | MSIX/AppX | Store | portable | 企业封装>
exe: <绝对路径；对外文档需脱敏>           # 核对 YYYY-MM-DD
包标识/AUMID: <如适用>
架构: <x64 | x86 | arm64 | 混合/未知>
进程:
  主进程: <name.exe>
  渲染/子进程判据: <命令行、父子关系；不要只看名字>
窗口:
  owner: <ProcessName>
  title 规则: <稳定部分，不存账号/文档名>
  class: <窗口类>
  主窗口识别: <面积/类/标题/子进程组合>
  完整性: <Low | Medium | High | System | 未知>

L0:
  CLI: <命令与只读/写能力，或无>
  URL protocol: <scheme、注册来源、已验证路由；不要猜路由>
  本地端口: <发现方法、协议、认证；端口号按动态值处理>
  CDP: <默认开放 | 需 --remote-debugging-port | 被禁 | 未测>
  CDP target: <按 title/url/type 重新寻找的规则>
  COM: <ProgID / TypeLib 有无；是否实测只读连接；New-Object 会不会新起实例>
  启动/重启风险: <是否会丢状态、是否有 launcher 吞参数；`--background` 是否被忽略>

L1_UIA:
  总体: <可用 | 部分 | 不可用 | 未测>
  树唤醒/延迟: <是否需要等待；只写实测>
  输入定位: <AutomationId + ControlType + Name/父子关系>
  输入 pattern: <ValuePattern 等>
  动作定位: <同上>
  动作 pattern: <Invoke/Toggle/Selection/ExpandCollapse>
  实测判据: <读回 + 状态指示器/副作用>
  暗拒: <调用成功但 app 不认的路径>

L2_SendInput:
  总体: <可用 | 受限 | 不可用 | 未测>
  输入: <Unicode SendInput 是否完整；是否需 --replace>
  Enter 语义: <发送 | 换行 | 确认 | 未测>
  前台激活: <自动成功率与明确失败条件；不写“保证”>
  模态框: <已知行为>
  坐标:
    - 控件: <名称>
      normalized: [0.0000, 0.0000]
      anchor: <截图上如何辨认>
      tested_window: <宽x高 px, DPI/缩放, 显示器>
      checked: YYYY-MM-DD

L3_capture:
  PrintWindow_后台: <完整 | 缺硬件层 | 黑/空 | 旧帧 | 未测>
  PrintWindow_前台后重试: <改善 | 无改善 | 未测>
  screen_合成: <窗口在当前桌面时是否与 PrintWindow 一致；遮挡情况>
  CDP_shot: <可用范围；是否只含 web 内容>
  壳窗口/渲染窗口: <如何区分>
  受保护内容: <如有，写明不可捕获>

验证:
  输入生效: <最强判据>
  动作生效: <最强判据>
  最终副作用: <文件/列表/状态等>

安全:
  风险类别: <普通 | 终端/IDE | 高风险数据 | 管理员 | 系统安全 UI>
  停手点: <发布/提交/付款/删除/授权等>
  敏感像素: <账号、侧栏、路径、通知等>

已知坑:
  - <现象 → 归因 → 安全替代路线>       # 核对 YYYY-MM-DD
```

条目后附最小证据索引，不把大量日志塞进档案：

```text
证据批次：evidence/20260907-appname/
probe：raw/probe.txt
窗口收据：raw/app-see.png.receipt.json
UIA map：raw/app-see.png.uia.json
成功路径：recipes/smoke.ps1 或 recipes/smoke.cdp.txt
失败路径：ledger.md#...
```

## 四、已实测 app

### Windows 计算器 · 11.2607.0.0 · 实测 2026-09-08

```yaml
显示名: 计算器
实测日期: 2026-09-08
版本: 11.2607.0.0                         # 核对 2026-09-08
安装形态: Microsoft Store / MSIX-AppX
exe: C:\Program Files\WindowsApps\Microsoft.WindowsCalculator_11.2607.0.0_x64__8wekyb3d8bbwe\CalculatorApp.exe  # 核对 2026-09-08
包标识/AUMID: Microsoft.WindowsCalculator_8wekyb3d8bbwe!App
架构: x64
进程:
  主进程: CalculatorApp.exe（Low integrity）
  窗口宿主: ApplicationFrameHost.exe（Medium integrity）
窗口:
  owner: ApplicationFrameHost
  title 规则: 精确匹配“计算器”
  class: ApplicationFrameWindow
  主窗口识别: 可见、非 cloaked、标题精确匹配；不要仅凭 ApplicationFrameHost PID
  完整性: 窗口宿主 Medium；应用进程 Low

L0:
  CLI: 未发现
  URL protocol: calculator://、ms-calculator://（仅确认 manifest 注册；路由未调用）
  本地端口: 无
  CDP: 未发现；包内出现 WebView2Loader.dll 只是静态信号，不足以证明可连接
  COM: 未测
  启动/重启风险: 本轮由工具启动空白计算器；未测试有历史/内存状态时重启

L1_UIA:
  总体: 可用
  只读: uiaread 可按 AutomationId=CalculatorResults 读取结果；初始“显示为 0”
  输入定位: 无 Edit 控件；数字与运算符是 Button
  动作定位: AutomationId=num1Button/plusButton/num2Button/equalButton
  动作 pattern: InvokePattern
  实测判据: 依次清除、1、加、2、等于后，uiaread 回读 CalculatorResults 为“显示为 3”
  实测焦点: 5 个 InvokePattern 动作均未借前台
  隔离: 2026-09-08 后枚举、读取与动作统一走 6 秒 uia-worker；计算器正常路径已回归

L2_SendInput:
  总体: 未测；L1 已覆盖本轮目标，不应降级走坐标

L3_capture:
  PrintWindow_后台: 完整；实测 502x810、颜色桶 27
  PrintWindow_前台后重试: 未触发
  CDP_shot: 不适用/未发现 CDP
  壳窗口/渲染窗口: 可直接从 ApplicationFrameWindow 捕获；未触发 sibling recovery

验证:
  动作生效: CalculatorResults 的独立 UIA 文本回读
  最终副作用: 显示值从 0 变为 3

安全:
  风险类别: 普通
  停手点: 无外部副作用；若未来用于货币换算等联网功能仍需重新判断

已知坑:
  - UWP 顶层窗口属于 ApplicationFrameHost；旧探针会把 System32 宿主误报为 app 本体。2026-09-08 已编码修复：静态身份改取匹配的 AppX 包，窗口仍按标题关联。
  - 旧 open 逻辑在窗口已运行时也可能启动 ApplicationFrameHost.exe；2026-09-08 已修复为显示名优先走 AUMID，并由 calculator-profile.ps1 真实回归。
  - 一个 ApplicationFrameHost PID 可承载别的 UWP 窗口；相关窗口必须再次按标题过滤。
  - UIA eN 会随枚举变化；档案只存 AutomationId，不存本轮 e14/e25 等短 ref。
```

本轮证据只保留在受控临时目录并在收尾清理；可复现路径是 `tests/calculator-profile.ps1`，内部执行 `open(AUMID) → see → 从 map 按 AutomationId 取 ref → invoke → uiaread CalculatorResults → 恢复/关闭`。结论不依赖 HWND、PID 或短 ref。

### Microsoft Excel · 16.0.20326.20132 · 只读探测 2026-09-08

> 本条只来自 `probe.ps1 "Excel"`，**未启动、未实例化 COM、未截图、未写入**。不能据此点击或改用户工作簿。

```yaml
显示名: Excel
实测日期: 2026-09-08
版本: 16.0.20326.20132                     # 核对 2026-09-08
安装形态: Win32 Click-to-Run（Office16）
exe: C:\Program Files\Microsoft Office\root\Office16\EXCEL.EXE  # 核对 2026-09-08
包标识/AUMID: Microsoft.Office.EXCEL.EXE.15
架构: x64
进程:
  主进程: 本轮未运行 EXCEL.EXE
  渲染/子进程判据: 安装目录下的 SDXHelper.exe 会被目录前缀算进“相关 PID”，不是 Excel 本体
窗口: 本轮无 Excel 顶层窗口

L0:
  CLI: 未测（probe 不执行 --help）
  URL protocol: 注册表出现 ms-excel:// → protocolhandler.exe；同目录还会列出 ms-word/ms-powerpoint/OneNote 等，因为匹配的是安装根而不是单 exe。未调用任何路由。
  本地端口: 无（Excel 未运行）
  CDP: 未发现；目录内有 WebView2Loader.dll，只是静态信号
  COM: 有。Excel.Application / Excel.Application.16 → LocalServer32 `EXCEL.EXE /automation`；另有 Excel.Sheet.*、Excel.Chart.*。类型库 “Microsoft Excel 16.0 Object Library”。未执行 New-Object（会新起实例）。
  启动/重启风险: `--background` 未测；COM 实例化可能弹出或隐藏启动 Excel，未授权前禁止

L1_UIA: 未运行，未测
L2_SendInput: 未测
L3_capture: 未测

验证:
  本轮只验证“注册表能指向该 exe 的 COM 服务器”；不验证对象模型可写或能连上用户已打开的簿

安全:
  风险类别: 普通办公；用户工作簿可能含他人/未发布数据
  停手点: 保存、另存为、发送、共享、宏

已知坑:
  - 2026-09-08 probe 把 Office16 目录下的 SDXHelper 算进相关进程，并扫到 Word/PowerPoint 的 protocol 与 typelib。选层时以 Excel.Application 为准，不要把同套件其它 ProgID 当成已验证的 Excel 接口。
  - New-Object -ComObject Excel.Application 不是“连接当前窗口”；在用户已打开工作簿时尤其危险。
```

### WorkBuddy AI · 5.4.2 · 只读窗口实测 2026-09-08

> `open --background` 启动后只做 probe / shot / see / uia / screen。**未输入、未发送、未 `--relaunch`、未开 CDP。** 截图留在本机临时目录，不入库。

```yaml
显示名: WorkBuddy AI
实测日期: 2026-09-08
版本: 5.4.2 / 文件 5.4.2.0                  # 核对 2026-09-08
安装形态: 便携/本地安装 Electron
exe: D:\ruanjian\WorkBuddyAI\WorkBuddyAI.exe  # 核对 2026-09-08；对外文档脱敏
包标识/AUMID: WorkBuddy.WorkBuddyAI
架构: x64
进程:
  主进程: WorkBuddyAI.exe Medium
  渲染/子进程判据: 多个 WorkBuddyAI.exe + `--type=gpu-process|utility`；另有 editor_sdk.exe、用户目录 node。probe 会把 git/cmd 子孙算进相关 PID，选 CDP 端口时必须再核 exe。
窗口:
  owner: WorkBuddyAI
  title 规则: 精确 “WorkBuddy AI”
  class: Chrome_WidgetWin_1
  主窗口识别: 可见、面积最大的 WidgetWin_1；另有无标题 WidgetWin_0
  完整性: Medium
  `--background`: 生效（foreground=kept）

L0:
  CLI: 未测
  URL protocol: workbuddy-ai:// → WorkBuddyAI.exe "%1"；未调用
  本地端口: 127.0.0.1 上多个监听，对本机 /json/version 均 HTTP 404，不是 CDP
  CDP: 命令行无 --remote-debugging-port。Electron 静态信号明确。未授权 `--relaunch`，本轮无 CDP
  COM: 无
  启动/重启风险: 普通 open 会进用户会话；托盘进程 CloseMainWindow 后仍可能残留

L1_UIA:
  总体: 不可用（主窗口）
  树: probe 统计 Pane=2 Window=1，可编辑/可操作 0
  see/uia: 0 个可操作元素；uiaread 无 Text/Edit
  暗拒: 不要在空树上 uiaset

L2_SendInput: 未测（无必要的可逆写目标，且会看到用户会话）

L3_capture:
  PrintWindow_后台: 主窗口首次 1815x1203、颜色桶 67，与窗口 1:1
  screen_合成: 同几何 1815x1203、颜色桶 67，遮挡采样 5/5 命中目标
  see 降采样: 随后一张收据 colorBuckets=1（暗色 UI 或瞬时空帧）；不能单次判黑
  CDP_shot: 无端口
  壳窗口/渲染窗口: 主窗 WidgetWin_1 可直接 PrintWindow，未走 sibling

验证:
  本轮最强证据: 窗口类 + 后台截图有内容 + 本地端口非 CDP + UIA 空树
  未验证: 输入框写入、发送键、CDP insert

安全:
  风险类别: 办公客户端
  停手点: 发送、分享、删除会话
  敏感像素: 侧栏会话、账号、本地项目路径；证据不入库

已知坑:
  - 开始菜单 “WorkBuddy AI” vs exe WorkBuddyAI；不要启动 updater。
  - 有本地端口 ≠ CDP。
  - `win.ps1 see --out` 经 `pwsh -File` 时 `--out` 会撞 PowerShell 公共参数，需 `pwsh -Command` 或把路径当位置参数。
```

### 剪映专业版 · 10.4.0.13957 · 启动器 + 环境检测弹窗 2026-09-08

> `open --background` 启动根目录启动器。8 秒内没有编辑器主窗，只出现版本目录里的 `VEDetector.exe`「环境检测」。**未点确定、未开草稿、未导出。** 弹窗用 CloseMainWindow 关掉。

```yaml
显示名: 剪映专业版
实测日期: 2026-09-08
版本: 启动器/产品 10.4.0.13957；VEDetector 文件版本 10.4.0.f23c7304ec7  # 核对 2026-09-08
安装形态: Win32 多版本并列 + 根目录启动器
exe: D:\ruanjian\jianying\JianyingPro\JianyingPro.exe  # 启动器
版本目录 exe: D:\ruanjian\jianying\JianyingPro\10.4.0.13957\  # 含 JianyingPro.exe 与 VEDetector.exe
包标识/AUMID: Bytedance.JianyingPro
架构: x64
进程:
  启动器: `open --background` 报 pid 后退出；foreground=kept，但 8s 内无主窗
  本轮实际窗口进程: VEDetector.exe Medium
窗口:
  编辑器主窗: 未出现
  弹窗 owner: VEDetector
  title 规则: “环境检测”
  class: Qt622QWindowIcon
  尺寸: 615x462

L0:
  CLI: 未测
  URL protocol: vega://、videocut://（启动器）；未调用
  本地端口: VEDetector 无监听
  CDP: 启动器与 VEDetector 命令行均无 remote-debugging-port。版本目录有 libcef，CEF ≠ 已开放 CDP
  COM: 旧 9.x 的 AppNotificationActivated，不是对象模型
  启动/重启风险: 根启动器会拉起检测弹窗，不保证进入编辑器；不要对「确定」invoke

L1_UIA:
  总体: 弹窗部分可用，编辑器未测
  弹窗 see: e1 无 Name 的 VETitleBarButton；e2 Name=确定 QPushButton，均 InvokePattern
  probe 统计: 14 元素 / 可编辑 11 / 可操作 14（含 Group/Text）
  停手: 本轮不 invoke「确定」

L2_SendInput: 未测

L3_capture:
  PrintWindow_后台: 弹窗 615x462、颜色桶 66，内容完整
  screen_合成: 同几何颜色桶 71，但遮挡采样 5/5 落在其它窗口（本机是 QQ）；合成图不能当弹窗内容
  与 Mac 档案对照: “主窗能后台截、更新弹窗截不到”在本轮不成立——弹窗 PrintWindow 能截到，合成图却被遮挡。不能抄 Mac 结论。
  编辑器主窗: 未出现，未测

验证:
  本轮最强证据: 启动器 ≠ 编辑器；环境检测是独立 Qt 进程；PrintWindow vs screen 对弹窗结论相反
  未验证: 时间线、导出、CEF 主画布截图、CDP

安全:
  风险类别: 媒体工程
  停手点: 导出、发布、删除草稿、覆盖工程、点检测弹窗的确定（可能继续启动/更新）

已知坑:
  - 根目录启动器与 `10.4.0.13957\JianyingPro.exe` 不是同一个文件。
  - `open --background` 成功只保证启动器进程起来，不保证编辑器窗口。
  - 弹窗 UIA 的「确定」是高风险默认按钮，先读完整文案。
```

### Blender · 本机未安装 · 2026-09-08

开始菜单、`Get-Command blender`、`C:\Program Files\Blender Foundation`、`D:\ruanjian` 均无安装。不编造 Windows 版 Python/`--background --python` 结论。用户自行安装并授权独立测试实例后，再按模板从 `probe.ps1` 重测。

## 五、如何写“可用”

### L0/CDP

合格结论：

> 通过 `probe.ps1` 在目标相关 PID 上发现监听端口；`/json/version` 返回 `webSocketDebuggerUrl`；`cdp.js list` 能列出主页面；`snapshot auto` 可重新找到输入区；`insert` 后发送按钮状态变化。窗口遮挡时复验通过。

不合格结论：

> 是 Electron，所以肯定能用 CDP。

Electron/CEF 可能没开调试端口、被企业策略禁用、由 launcher 吞掉参数，或主 UI 不在第一个 target。

### L1/UIA

合格结论：

> Edit 元素按 `AutomationId + ControlType` 唯一定位，支持 `ValuePattern`；设置后读回一致，依赖按钮由 disabled 变 enabled；随后用独立只读状态确认。

不合格结论：

> UIA 列出了 87 个元素，所以 UIA 可用。

数量不说明目标控件可写。很多 app 只暴露标题栏、菜单或空 Pane；虚拟化列表还会随滚动复用节点。

### L2/坐标

合格结论：

> 在版本 X、窗口 1280×800、缩放 125% 下，按锚点重新定位到归一化 `(0.7132, 0.8841)`；`--dry` 通过；点击后目标状态变化。窗口移动后重新 `see` 复验。

不合格结论：

> 发送按钮在 `(913, 707)`。

裸坐标没有窗口原点、尺寸、DPI、版本和锚点，无法安全复用。

### L3/截图

合格结论要拆开写：后台 `PrintWindow`、借前台后重试 `PrintWindow`、CDP 页面截图分别覆盖哪些内容。不能把“文件生成成功”写成“后台截图完整”。

## 六、按实现类型形成假设，但不把假设当结论

| 信号 | 优先试 | 常见误判 |
|---|---|---|
| Electron / CEF 子进程、`--type=renderer` | CDP、本地端口 | Electron 不等于默认开放 CDP |
| WebView2 runtime / `msedgewebview2.exe` | app 自有 API、CDP（若明确开放）、UIA | WebView2 进程存在不等于能从外部连接 |
| 标准 Win32 控件 | UIA Value/Invoke | 窗口类像标准控件也可能被自绘替换 |
| WPF / WinUI / UWP | UIA，再看 app protocol | 虚拟化与 Custom/Pane 会断掉细粒度语义 |
| Qt / Java / Canvas / 游戏引擎 | app CLI/plugin，最后坐标 | UIA 偶尔有节点，但不代表真实编辑区可写 |
| 管理员/受保护进程 | 只读探测并报告边界 | 自动提权不是推荐路线 |

这些只决定“先试什么”，不允许跳过验证。

## 七、失效与证伪

发现档案不符时：

1. 立即停用旧坐标/ref/选择器；
2. 保存本次 `probe`、`see`、版本与失败收据；
3. 判断是版本漂移、安装形态不同、窗口选错、权限/桌面状态还是旧结论本身错误；
4. 就地改当前条目并更新核对日期；
5. 将被推翻的结论简短移入“已失效记录”，说明为何不能再用；
6. 若能编码成探测或安全拒绝，优先改工具并补回归测试。

证伪比新增更重要。特别是“某架构一定支持 UIA/PrintWindow/CDP”这类绝对句，一次反例就应降级成条件化描述。

## 八、已失效记录模板

```markdown
### 已失效：<旧结论摘要>

- 原核对：YYYY-MM-DD，版本 X
- 证伪：YYYY-MM-DD，版本 Y / 安装形态 Z
- 现象：<可复现事实>
- 原因：<已证实原因；未知就写未知>
- 替代路线：<L0/L1/L2/L3>
- 证据：<相对路径>
```

不要为了显得完整填造一个“可能原因”。未知本身是有效档案状态。
