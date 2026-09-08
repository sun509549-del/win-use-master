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
pwsh -NoProfile -File "$SKILL_DIR/scripts/win.ps1" see <hwnd> .\evidence\raw\app-see.png

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

### 记事本 · 11.2607.14.0 · 实测 2026-09-08

> 第二个完整可重放档案：`tests/notepad-profile.ps1`。覆盖 **Document（非 Edit）控件的 L1 可逆写**、两种应用状态指示器的读回，以及“空白文档不是黑帧”的截图诊断。测试拒绝复用运行中的记事本，也拒绝向恢复出来的会话写入。

```yaml
显示名: 记事本
实测日期: 2026-09-08
版本: 11.2607.14.0                          # 核对 2026-09-08
安装形态: Microsoft Store / MSIX（打包桌面 app，不经 ApplicationFrameHost）
exe: C:\Program Files\WindowsApps\Microsoft.WindowsNotepad_11.2607.14.0_x64__8wekyb3d8bbwe\Notepad\Notepad.exe  # 核对 2026-09-08
包标识/AUMID: Microsoft.WindowsNotepad_8wekyb3d8bbwe!App
架构: x64
进程:
  主进程: Notepad.exe Medium；同 PID 另有 0x0 的 IME / MSCTFIME UI / GDI+ Hook 辅助窗口，windows 默认过滤
  旧版: System32\notepad.exe 10.0.26100 仍存在；本轮未测它是否转交 Store 版
窗口:
  owner: Notepad
  title 规则: “<标签名> - Notepad”（界面中文，标题用英文产品名；启动动画期短暂为“记事本”）
  class: Notepad
  主窗口识别: owner=Notepad + class=Notepad + state=current；不要用标题里的中文名
  完整性: Medium
  --background: 未测（open 走 AUMID/shell，不支持该开关）

L0:
  CLI: 未测
  URL protocol: ms-notepad://（AppxManifest；未调用）
  本地端口: 无
  CDP: 无；probe 无任何 Chromium/WebView2 信号（WinUI 原生）
  COM: 无
  启动/重启风险: 见“会话持久化”——关闭不提示，内容留到下次

L1_UIA:
  总体: 可用（完整写链路已回归）
  文本区: ControlType=Document Name=“文本编辑器” ClassName=RichEditD2DPT AutomationId 为空；patterns=ValuePattern,TextPattern
  输入定位: 唯一的 Document(ValuePattern)；worker 的 `first` 在无 Edit 时兜底选它（2026-09-08 编码）
  输入 pattern: ValuePattern.SetValue；读回逐字一致（41/30 字符两次）
  状态指示器 1: 状态栏 Text AutomationId=ContentTextBlock value=“N 个字符” 随内容变化（0→41→0）
  状态指示器 2: TabItem Name=“<前约 35 字>. 已修改。” ↔ “无标题. 未修改。”；写空串后回到未修改
  动作定位: MenuItem File/Edit/View；Button CloseButton/AddButton/FREButton/SettingsButton；格式工具栏按钮（标题/列表/加粗…）为 TogglePattern，无 AutomationId
  实测判据: uiaread Document value + “N 个字符” + 标签状态三者一致
  暗拒: 未遇到；像素差分对“清空”一步报 suspected_noop，以语义读回为准

L2_SendInput: 未测；L1 已覆盖，不降级

L3_capture:
  PrintWindow_后台: 完整（1512x1022 @144DPI，标签/工具栏/状态栏俱在）
  判空启发式: 空文档时内容区 1 桶、整帧 37 桶；2026-09-08 起收据写 frameColorBuckets，see 用 UIA 空 Document 说明“不是截图失败”，shotfg 不再为空文档借前台
  screen_合成: 未测
  CDP_shot: 不适用

验证:
  输入生效: uiaread Document value 逐字一致 + 状态栏字符数
  动作生效: 标签“已修改/未修改”
  最终副作用: 本档案只做可逆写，不落文件

安全:
  风险类别: 普通
  停手点: 保存/另存为/覆盖；关闭含用户内容的标签
  会话持久化: 关闭已修改标签**不弹提示**，下次启动原样恢复。任何写入必须自己还原；测试失败路径先清空再关窗。
  敏感像素: 用户恢复出的标签内容

已知坑:
  - 文本区是 Document 不是 Edit，旧 worker 列不到、`first` 找不到 → 2026-09-08 已编码：动作元素纳入 Document，first 兜底 Document(ValuePattern)。
  - 空白文档触发“接近纯色”并会误导去 shotfg/CDP → 已编码：整帧桶数 + UIA 空 Document 交叉验证。
  - 一次失败运行把测试文本留进了会话，下次启动被自己的“拒绝写入恢复会话”闸拦住 → 测试 finally 现在会先清空。
  - Document 铺满窗口，像素差分若取控件中心会落在空白处 → uiaset 对 Document 改取首行附近。
  - 标题是英文“Notepad”，显示名/开始菜单是“记事本”；probe/open 用显示名，窗口定位用 owner/class。
```

可复现路径 `tests/notepad-profile.ps1`：`open(AUMID) → see（位置参数路径）→ 校验唯一 Document(ValuePattern)、单标签未修改、文档为空 → uiaset first → uiaread/uia 读回三指示器 → uiaset first '' → 读回归零 → CloseMainWindow`。

### Microsoft Excel · 16.0.20326.20132 · L0 COM 真实任务 2026-09-08

> 第四个可重放档案：`tests/excel-com-profile.ps1`。任务是“新建工作簿，写 3 行采购数据，金额公式与合计，另存 xlsx”，全程零焦点。`New-Object -ComObject Excel.Application` 起的是**私有 `/automation -Embedding` 进程**，与用户正在用的 Excel 无关；只写、只存、只退出这个私有实例。结果不经 Excel、直接从 xlsx 的 XML 里核对。

```yaml
显示名: Excel
实测日期: 2026-09-08
版本: 16.0.20326.20132                     # 核对 2026-09-08
安装形态: Win32 Click-to-Run（Office16）
exe: C:\Program Files\Microsoft Office\root\Office16\EXCEL.EXE  # 核对 2026-09-08
包标识/AUMID: Microsoft.Office.EXCEL.EXE.15
架构: x64
进程:
  自动化实例: EXCEL.EXE /automation -Embedding，Medium，启动约 4.5–5.7 秒；Quit 后进程自己退出（前提见已知坑）
  渲染/子进程判据: 安装目录下的 SDXHelper.exe 会被目录前缀算进“相关 PID”，不是 Excel 本体；自动化实例还会派生一个 0 线程的 EXCEL.EXE 子进程，随父进程消失
窗口:
  owner: EXCEL
  class: XLMAIN
  title 规则: “<工作簿名> - Excel”
  主窗口识别: Application.Hwnd；注意 Workbooks.Add 之后 Hwnd 会换成新的 XLMAIN，旧句柄保持隐藏
  完整性: Medium

L0:
  CLI: 未测
  URL protocol: ms-excel:// → protocolhandler.exe；同目录列出的 ms-word/ms-powerpoint/OneNote 属于套件，不是 Excel 接口。未调用。
  本地端口: 无
  CDP: 无；WebView2Loader.dll 只是静态信号
  COM: Excel.Application（=Excel.Application.16）。实测可用：Workbooks.Add、Range.Value2/Formula、Calculate、Worksheet.Name、SaveAs(path, 51=xlsx)、Close(false)、Quit
  COM 身份核对: 用 Application.Hwnd → pid → exe 路径必须是 EXCEL.EXE。WPS 在 32 位注册表视图把 Excel.Application.12 指向自己的 et.exe；64 位 pwsh 拿到微软 Excel，32 位宿主可能拿到 WPS
  启动/重启风险: CoCreate 永远新起私有进程；不要对它之外的 Excel 调 Quit

L1_UIA:
  总体: 部分可用（窗口可见后）
  uiaread: 状态栏 StatusBar、Text“单元格模式 就绪”、Edit AutomationId=FormulaBar value=“=SUM(D2:D4)”、Edit 字体/字号、Edit TellMeTextBoxAutomationId
  uia: 180 个动作元素（到上限）；功能区 Button/TabItem 带 AutomationId（FileSave、AutoSaveSwitch、TabHome、TabFormulas…）；账户菜单 MeControlWidget 的 Name 是用户姓名，不入档案
  名称框: 不在 uiaread 的可读类型里；未按 Edit value=“D5” 暴露
  网格: 180 上限内没到单元格；有 COM 就不需要

L2_SendInput: 未测；有 COM 不降级

L3_capture:
  PrintWindow_后台: 窗口可见后 1920x1117、颜色桶 46，完整
  screen_合成: 5/5 采样未遮挡（自动化窗口新出现时在前）
  窗口未显示时: 整帧 1 桶、UIA 空——那是 Visible 没生效，不是 Excel 的能力

验证:
  输入生效: COM 读回 D5=3640；UIA 编辑栏读到同一公式
  最终副作用: 另存的 xlsx 里 sheet1.xml `<c r="D5"><f>SUM(D2:D4)</f><v>3640</v>`，workbook.xml 含重命名的工作表——不经 Excel 直接验证
  私有实例退出: Quit 后 30 秒内进程消失

安全:
  风险类别: 普通办公；用户工作簿可能含他人/未发布数据
  停手点: 对用户已打开工作簿的保存/另存/发送/共享/宏；本档案只碰临时目录的新文件
  会话隔离: 私有实例的 Workbooks.Count 归零后才 Quit；预存在的 EXCEL pid 一律不动

已知坑:
  - Application.Visible=True 在没有工作簿窗口时被忽略（5.1 与 7 一样）；先 Workbooks.Add() 再设，否则 XLMAIN 隐藏、UIA/PrintWindow 全空。
  - pwsh 7 的 COM 绑定拒绝 Int32 写入 Range.Value2（“cannot cast Int32 to String”）；写 [double]。
  - COM 对象不能从 PowerShell 函数 return：集合会被展开（空 Workbooks 变 $null）；`Write-Output -NoEnumerate` 又会让属性写入失败。赋值后再登记引用。
  - Range/Worksheet/Workbook 的 RCW 不释放就 Quit，/automation 进程会挂到 DCOM ping 超时（约 6 分钟）才退。全部 FinalReleaseComObject 后 30 秒内正常退出。
  - probe 会把 Office16 目录下的 SDXHelper 算进相关进程，并扫到 Word/PowerPoint 的 protocol 与 typelib；选层以 Excel.Application 为准。
```

### WPS 表格 · 12.1.0.23125 · L0 COM 真实任务 2026-09-08

> 第五个可重放档案：`tests/wps-et-com-profile.ps1`，任务与 Excel 相同，外加“第二个私有实例重新打开文件读回合计”。用户的 WPS 当时正在后台运行（8 个 wps.exe），`KET.Application` 仍新起了私有 `wps.exe /prometheus /et /Automation` 进程，没有碰用户实例。

```yaml
显示名: WPS Office / WPS 表格
实测日期: 2026-09-08
版本: 12.1.0.23125                          # 核对 2026-09-08
安装形态: Win32，x86
exe: D:\ruanjian\wps\WPS Office\12.1.0.23125\office6\wps.exe  # 核对 2026-09-08；表格组件 et.exe 同目录；对外文档脱敏
包标识/AUMID: Kingsoft.Office.KPrometheus
架构: x86 (0x014C)；64 位 pwsh 可 CoCreate 其 out-of-proc COM 服务器
进程:
  自动化实例: 新 pid（wps.exe /prometheus /et /Automation），启动 1.3–2.1 秒；Quit 后 20 秒内退出
  用户实例: 常驻 wps.exe + promecefpluginhost.exe（CEF）+ wpscloudsvr.exe；首页是 CEF（Kingsoft.Office.cefhomepage）
窗口:
  owner: wps
  class: XLMAIN（伪装成 Excel 的类名）；标题 “WPS Office”，保存后 “<文件名> - WPS 表格”
  主窗口识别: 新 pid + class=XLMAIN + 可见；同 pid 更大的 KLiteMainWindowShadowBorder 是阴影窗，不是目标
  Application.Hwnd: 不是顶层窗口，不能用它定位
  完整性: Medium

L0:
  CLI: 未测
  URL protocol: 未发现指向 wps.exe 的注册项
  本地端口: wpscloudsvr 监听 4709 等，非 CDP
  CDP: 无；CEF 首页进程无 remote-debugging 参数
  COM: KET.Application（表格）可用：Workbooks.Add/Open、Range.Value2/Formula、Calculate、SaveAs(path, 51) 产出可被 Excel 结构解析的 xlsx、Close、Quit。Application.Name 报 “Microsoft Excel”、Version “12.0”。另有 KWPS.Application（文字）、KWPP.Application（演示）未测
  ProgID 抢注: 32 位视图 Excel.Application.12 → et.exe；要 WPS 就用 KET.Application，要微软 Excel 用 64 位宿主并核对 exe 路径
  启动/重启风险: CoCreate 新起私有进程；用户 WPS 在后台时也不复用

L1_UIA:
  总体: 部分——可操作 55 个 Button（工具栏），可读文本 0；编辑栏没有作为 Edit 暴露
  暗拒: 不要期待 uiaread 读到公式；读值走 COM

L2_SendInput: 未测；有 COM 不降级

L3_capture:
  PrintWindow_后台: 867x536、颜色桶 115，完整
  screen_合成: 私有窗口出现在 Cursor 之后，5/5 被遮挡——合成图拍不到它，PrintWindow 才是它的内容
  UIA/截图目标: 必须是 XLMAIN；对阴影窗 KLiteMainWindowShadowBorder 截图是 1 桶、UIA 为空

验证:
  输入生效: COM 读回 D5=3640
  最终副作用: xlsx sheet1.xml `SUM(D2:D4)`/3640（不经 WPS）；第二个私有实例 Workbooks.Open 读回 3640 且工作表名一致

安全:
  风险类别: 普通办公；用户文档在另一个进程里
  停手点: 对用户实例的 Quit/保存/云同步；本档案只碰临时目录新文件
  残留: 结束后新出现的 wps.exe 多为用户实例派生的 CEF 助手（命令行含 CefRenderEntryPoint），不是我们的

已知坑:
  - `Application.Hwnd` 与 “最大的窗口” 都会选错目标，按 class=XLMAIN 选。
  - 名字“Microsoft Excel”、类名 XLMAIN、ProgID Excel.Application.12 全是 WPS 的兼容伪装；任何按名字判断“是不是 Excel”的逻辑在装了 WPS 的机器上都不可信。
```

### QQ · 9.9.21（QQ NT，Electron）· 只读窗口实测 2026-09-08

> 用户已登录的 QQ 在托盘/最小化态。只做 probe / see / uia / uiaread / shot / screen 和端口探测；**未输入、未发送、未重启**。为了观察把最小化的主窗还原，结束后按原样最小化回去。截图、UIA 里的昵称/会话文字只留本机。

```yaml
显示名: QQ
实测日期: 2026-09-08
版本: 启动器 QQ.exe 9.9.21.39038；协议处理器指向 versions\9.9.32-50776\resources\app\timwp.exe  # 核对 2026-09-08
安装形态: 便携目录 Electron；QQ.exe 是启动器，真实应用在 versions\<ver>\
exe: D:\ruanjian\qq\QQ.exe                 # 对外文档脱敏
包标识/AUMID: QQ（开始菜单 AppID 就是 “QQ”）
架构: x64
进程:
  主进程: QQ.exe Medium + 十余个子进程（renderer 为 Low 或完整性不可读）+ crashpad_handler
  多实例: 允许多账号并行——再启动一次不会激活已登录窗口，而是新起进程弹登录窗
窗口:
  owner: QQ
  class: Chrome_WidgetWin_1（主窗、聊天窗、登录窗都是）；Chrome_WidgetWin_0 是隐藏的渲染宿主
  主窗口识别: 已登录实例里 title=“QQ” 且尺寸最大的可见/最小化 WidgetWin_1（本轮 1734x1461）；“QQ(窗口)” 是独立聊天窗
  托盘态: 主窗 state=min，其余若干 1081x961/1200x900 的 WidgetWin_1 state=hidden
  完整性: 主进程 Medium

L0:
  CLI: 未测
  URL protocol: tencent://、mqqapi://、ntqq-notification://、guild-notification:// → timwp.exe；未调用
  本地端口: 主进程监听 4001/4301（非 HTTP）、5284（HTTP 400）、4310/9210（HTTP 200，不是 CDP）
  CDP: 无 remote-debugging 参数；未授权 --relaunch，未测能否接受
  COM: 无（probe 早先把 QQ 音乐算进来是安装根前缀 bug，已修）
  启动/重启风险: `open QQ` = 新登录窗，不是显示已登录窗口；--relaunch 会关掉登录会话

L1_UIA:
  总体: 可用（Chromium 无障碍树对 UIA 开放）
  see/uia: 49 个动作元素——Button=47（InvokePattern 43，如 消息/联系人/空间/频道/游戏、在线状态、切换为经典模式、最小化/最大化/关闭）、Edit=1（顶部搜索框，ValuePattern+TextPattern）、Document=1（AutomationId=RootWebArea）
  uiaread: 300 个（到上限）：Text=298、Edit=1、Document=1——会话列表文字可读，含隐私
  与 Mac 对照: Mac 档案写 “AX 树断在 AXWebArea”；Windows 上 UIA 能进到页面内元素，不能照抄
  未验证: 聊天输入框写入（未做，停手线附近）

L2_SendInput: 未测；闸预检 desktop=pass/UIPI=pass

L3_capture:
  PrintWindow_后台: 1734x1461、颜色桶 232，完整；刚还原的第一帧曾失败一次，几百毫秒后成功 → 工具已加一次 400ms 重试
  screen_合成: 5/5 被前台 Cursor 遮挡（还原不激活，窗口在后面）；合成图不是 QQ 内容
  隐藏/最小化态: 截图不可用，须先 restore

验证:
  本轮最强证据: UIA 树可读 + PrintWindow 完整 + 端口非 CDP

安全:
  风险类别: 高敏感私人通信
  停手点: 发送、转发、删除会话、登录/切换账号、任何对聊天输入框的写入
  敏感像素/文本: 全部会话、昵称、头像、未读数；快照与截图不入库
  布局: 观察完成后 minimize 回原状

已知坑:
  - `open QQ` 会起第二个实例弹登录窗；已登录窗口只能 restore（最小化态）或由用户点托盘。
  - probe 的安装根 `D:\ruanjian\qq` 曾前缀匹配到 `D:\ruanjian\qqyinyue`，把 QQ 音乐的 COM 算进 QQ → 2026-09-08 已编码为目录级匹配。
```

### WorkBuddy AI · 5.4.2 · CDP 可逆写实测 2026-09-08

> 第三个可重放档案，也是第一个 Chromium/CDP 写档案：`tests/workbuddy-cdp-profile.ps1`。用户授权后，在 app **未运行**时以 `open <exe> --cdp 9333 --background` 全新启动（无需 `--relaunch`），CDP 端口归属校验通过、前台未被打扰。写路径全程零焦点：`insert` 进 Slate 输入区 → 发送键 `disabled→enabled` → `press SelectAll` + `press Backspace` 撤回 → 发送键回到 `disabled`。**未按 Enter、未点发送、未碰「重启升级」。** 快照含用户会话标题与账号，只留本机，不入库。

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
  本地端口: 默认启动时 127.0.0.1 上多个监听，对 /json/version 均 HTTP 404，不是 CDP
  CDP: 默认关闭；`--remote-debugging-port=<port>` 被接受。`open <exe> --cdp 9333 --background` → 端口归属新实例、foreground=kept
  CDP target: 只有一个 page，url 为 file:///…/resources/app.asar/renderer/index.html（带 query，含账号参数；收据已去 query，`list` 原文不要贴进文档）。没有独立 iframe target（与 Mac 档案的 page+iframe 结构不同）
  COM: 无
  启动/重启风险: app 未运行时直接带端口启动即可；运行中需 `--relaunch`，会关掉用户会话；托盘态 CloseMainWindow 关不掉

L0_CDP_写路径:
  输入区定位: `[data-slate-editor="true"]`（div role=textbox，Slate；class 是哈希 CSS module，不能存）
  空态判据: 输入区内有 `[data-slate-placeholder]`；发送键 `button "发送"` 为 [disabled]
  写: `insert '[data-slate-editor="true"]' "<文本>"` → 输入区 text 变、发送键 disabled true→false、多出「增强提示词」按钮（两个状态指示器）
  撤回: `press SelectAll` + `press Backspace`（真实键事件，Slate state 一致）→ 占位符回来、发送键 false→true、「增强提示词」消失
  收据: action-receipt-v1，输入只记长度，target url 去 query；act 6 步 events=3，insert/Backspace 均 effect=partial，SelectAll 为 suspected_noop（选区不进交互树，属预期）
  其它元素: 模型选择 button/combobox；工作空间/权限 combobox；窗口控制按钮的可见文本是 i18n key（menu.minimize / window.maximize / common.close）；本构建顶部有「更新日志」「重启升级」

L1_UIA:
  总体: 不可用（主窗口）
  树: probe 统计 Pane=2 Window=1，可编辑/可操作 0
  see/uia: 0 个可操作元素；uiaread 无 Text/Edit
  暗拒: 不要在空树上 uiaset；有 CDP 就不需要 L1

L2_SendInput: 未测；有 CDP 不降级

L3_capture:
  PrintWindow_后台: 主窗口 1815x1203、颜色桶 67，与窗口 1:1
  screen_合成: 同几何、颜色桶 67，遮挡采样 5/5 命中目标
  see 降采样: 曾有一张收据 colorBuckets=1（暗色 UI 或瞬时空帧）；不能单次判黑
  CDP_shot: 可用，198KB 整页；不含原生标题栏
  壳窗口/渲染窗口: 主窗 WidgetWin_1 可直接 PrintWindow，未走 sibling

验证:
  输入生效: 发送键 disabled→enabled + 输入区 text 长度变化（终端只显示字符数）
  撤回生效: 占位符回来 + 发送键回到 disabled
  最终副作用: 本档案不发送，不产生会话

安全:
  风险类别: 办公 AI 客户端
  停手点: 发送（按钮与 Enter）、分享、删除会话、「重启升级」、上传（系统文件框，CDP 够不着）
  敏感像素/文本: 侧栏会话标题、账号邮箱、target url 的 query；snapshot 输出与截图不入库
  草稿保护: 输入区无占位符 = 用户有草稿，档案回归拒绝写入

已知坑:
  - 开始菜单 “WorkBuddy AI” vs exe WorkBuddyAI；不要启动 updater。
  - 有本地端口 ≠ CDP。
  - `win.ps1 see --out` 经 `pwsh -File` 时 `--out` 被宿主当成二义公共参数前缀（-OutVariable/-OutBuffer）→ 2026-09-08 已编码：`see <target> <path>` 位置参数；`--out` 只在进程内 `&` 调用可用。
  - role=textbox 的 contenteditable 在终端差分里原本按普通元素打印全文 → 2026-09-08 已编码：采集时标记 editable，差分只显示字符数；回归里用 role=textbox fixture 守住。
  - `text`（el.textContent=）对 Slate 不可信，Mac 档案已记；Windows 直接用 `insert` + 键事件撤回，未走 `text`。
```

可复现路径 `tests/workbuddy-cdp-profile.ps1 [-Port 9333]`：前置是用户已用 `open <exe> --cdp <port> --background` 启动授权实例；测试只校验端口归属、输入区为空、发送键 disabled，然后跑上面的 act 配方并核对收据与脱敏。它不启动、不重启、不关闭 app；无实例或有草稿时退出 2。

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
  PrintWindow_后台: 环境检测弹窗 615x462、颜色桶 66，内容完整
  screen_合成: 同几何颜色桶 71，但遮挡采样 5/5 落在其它窗口（本机是 QQ）；合成图不能当弹窗内容
  与 Mac 档案对照: “主窗能后台截、更新弹窗截不到”——可见的环境检测弹窗 PrintWindow 能截到；隐藏态下主窗与更新弹窗都截不到（见下）。两轮都不支持照抄 Mac 结论
  编辑器主窗（隐藏态）: 见 2026-09-08 第二次观察

2026-09-08 第二次观察（编辑器进程已起、全部窗口隐藏）:
  进程: 版本目录 JianyingPro.exe 主进程 + gpu-process/renderer/utility 子进程（CEF 已起）
  窗口: 主窗 Qt622QWindowIcon title=JianyingPro 1558x1255、「版本更新」Qt 弹窗 507x519、CEF Chrome_WidgetWin_0 1920x1117 无标题、一个 528x237 的 JianyingPro 小窗——全部 visible=False；只有 237x39 的「剪映专业版」是最小化态
  PrintWindow: 四个隐藏窗口全部整帧 1 桶（没渲染，不是拒绝渲染）；`shot` 现在会直接说明“窗口不可见”
  screen: 对不可见窗口正确拒绝
  UIA: 四个隐藏窗口全部 0 元素；probe 统计 Window=1
  L2: 隐藏窗口被闸拒绝（BLOCK(hidden)）；显示它属于替用户改状态，交还用户
  CDP: 命令行无 remote-debugging-port；CEF 是否接受该参数未测（需用户授权重启剪映）

2026-09-08 第三次观察（用户要求跑任务，把最小化的「剪映专业版」主窗 restore 后只读）:
  再启动根启动器: 转交给已运行实例后退出，没有把任何窗口显示出来
  主窗: 0x2C104C “剪映专业版” Qt622QWindowIcon，还原后 1752x1170，首页（登录入口、模板、我的云空间、功能入口、本地草稿区）
  PrintWindow: 1752x1170、颜色桶 404，完整——Mac 档案“主窗能后台截”在 Windows 可见态成立
  screen: 404/415 桶，5/5 未遮挡（restore 把它带到了前面）
  UIA: `uia` 与 `uiaread` 都超过 6 秒被隔离 worker 终止——Qt 的 UIA provider 在这个窗口上挂住；L1 不可用，且不能直接在 agent 进程里调 UIA
  版本更新弹窗: 仍隐藏，无法复验 Mac 的“更新弹窗截不到”
  结束: minimize 回原状；未点任何按钮、未开草稿

验证:
  本轮最强证据: 启动器 ≠ 编辑器；环境检测是独立 Qt 进程；隐藏态下截图/UIA 全部为空是窗口状态问题；可见态 PrintWindow 完整而 UIA 挂起
  未验证: 时间线、导出、CDP、更新弹窗截图

安全:
  风险类别: 媒体工程
  停手点: 导出、发布、删除草稿、覆盖工程、点检测弹窗的确定、「版本更新」弹窗的任何按钮

已知坑:
  - 根目录启动器与 `10.4.0.13957\JianyingPro.exe` 不是同一个文件。
  - `open --background` 成功只保证启动器进程起来，不保证编辑器窗口。
  - 弹窗 UIA 的「确定」是高风险默认按钮，先读完整文案。
  - `windows --all` 里的隐藏窗口过去也显示 state=current → 2026-09-08 已编码为 state=hidden，`shot` 空帧时直说不可见，L2/shotfg 拒绝。
```

### 微信 · 4.1.13.12 · 只读窗口实测 2026-09-08

> 用户已登录的微信在托盘（主窗最小化）。用 `restore` 放回原位、只读 shot / screen / uia / uiaread，再 `minimize` 还原；前台始终未变。**未输入、未发送、未重启。** 截图只留本机。

```yaml
显示名: 微信
实测日期: 2026-09-08
版本: 4.1.13.12                             # 核对 2026-09-08
安装形态: Win32（新版 Weixin，Qt 5.15）+ WeChatAppEx（Chromium 小程序/网页运行时，独立目录 %APPDATA%\Tencent\xwechat\xplugin）
exe: D:\ruanjian\wechat\Weixin\Weixin.exe   # 对外文档脱敏
包标识/AUMID: 开始菜单 AppID 就是 exe 路径
架构: x64
进程:
  主进程: Weixin.exe Medium + 若干 Weixin.exe 子进程 + crashpad_handler
  运行时: WeChatAppEx.exe ×8（Medium / Low / 不可读），Chromium 信号 18 条，无 remote-debugging 参数
窗口:
  owner: Weixin
  class: Qt51514QWindowIcon；title “微信”
  主窗口识别: owner=Weixin + 该 class + 尺寸最大（还原后 1830x1127）；托盘态是 state=min
  其它: WxTrayIconMessageWindow 1920x1117 hidden；WeChatAppEx 的 Chrome_WidgetWin_0 hidden
  完整性: Medium

L0:
  CLI: 未测
  URL protocol: weixin://、xweixin:// → Weixin.exe "%1"；未调用
  本地端口: 主进程 14013/14016/14019/14022/14023，/json/version 无响应，不是 CDP
  CDP: 无；WeChatAppEx 也无调试参数；未授权 --relaunch
  COM: 无

L1_UIA:
  总体: 不可用——`uia`/`uiaread` 1–2 秒返回 0 个元素（Qt 5.15 没有暴露树，与 Qt6 剪映的挂死不同）
  暗拒: 不要在空树上 uiaset

L2_SendInput: 未测；闸预检 desktop=pass/UIPI=pass；本轮用户在场（idle=0s）

L3_capture:
  PrintWindow_后台: 1830x1127、颜色桶 230，完整
  screen_合成: 5/5 被前台 Cursor 遮挡（restore 不激活，窗口在后面）
  restore/minimize: 均 ok，前台未变

验证:
  本轮最强证据: PrintWindow 完整 + UIA 空 + 端口非 CDP

安全:
  风险类别: 高敏感私人通信
  停手点: 发送、转发、删除、切换账号、任何输入框写入
  敏感像素: 会话列表、聊天内容、联系人；截图不入库
  布局: 观察后 minimize 回原状

已知坑:
  - 与 QQ 同为 IM、同为托盘态，但 L1 完全相反：QQ（Electron）UIA 可读，微信（Qt5）空树。没有 UIA、没有 CDP 的微信在 Windows 上只剩 L2，且每一步都要借前台。
```

### Blender · 本机未安装 · 2026-09-08

开始菜单、`Get-Command blender`、`C:\Program Files\Blender Foundation`、`D:\ruanjian` 均无安装。不编造 Windows 版 Python/`--background --python` 结论。用户自行安装并授权独立测试实例后，再按模板从 `probe.ps1` 重测。

## 四·五、跨 app 的共性结论（2026-09-08，样本：计算器、记事本、WorkBuddy、Excel、WPS 表格、QQ、剪映、微信）

每条至少两个不同实现复现；坐标、端口、HWND 一律不在此处。

1. **起始状态多半是“没有可见窗口”。** QQ、微信、WPS、剪映、WorkBuddy 都在托盘/最小化态运行，Excel 自动化实例默认隐藏。`windows` 默认列不到它们，`--all` 里是 `state=hidden|min`；此时截图整帧 1 桶、UIA 空树、`screen` 拒绝——这是窗口状态，不是 app 能力。先分清状态再下结论；最小化的用 `restore`（不激活），隐藏的交给用户。
2. **“再启动一次”不等于“显示已运行的窗口”。** QQ 会新起实例弹登录窗；剪映启动器转交后什么都不显示；Excel/WPS 的 COM 永远新起私有进程。`open` 对运行中的 app 只保证进程层的动作，窗口层必须回读 `windows`。
3. **UIA 可用性不能按框架猜。** 同为 Electron：QQ 的 Chromium 树对 UIA 完整可读（Button/Edit/Document + 300 条文本），WorkBuddy 是空树。同为 Qt：微信（Qt5）秒回空树，剪映（Qt6）provider 挂死 6 秒。记事本（WinUI）Document 可写；WPS 自绘只露 55 个 Button；Excel 编辑栏可读而网格到不了。现场 `uia`/`uiaread` 各试一次，而且只能在隔离 worker 里试——剪映证明了为什么。
4. **COM 是 Windows 的 AppleScript 字典，但要核对身份。** Excel 与 WPS 共用 ProgID（Excel.Application.12）、窗口类名（XLMAIN）甚至 Application.Name（“Microsoft Excel”）；32/64 位注册表视图决定谁应答。exe 路径是唯一可信身份；用 KET.Application 明确指 WPS。COM 对象不能穿过 PowerShell 函数返回，RCW 不释放会让进程挂到 DCOM 超时。
5. **可见窗口的 PrintWindow 基本可靠；空帧几乎都是状态问题。** 八个可见窗口全部截到（46–404 桶）。复现的三种空帧：窗口隐藏（剪映、未显示的 Excel）、空白文档（记事本）、刚还原的首帧（QQ，已加一次 400ms 重试）。“app 拒绝后台渲染”本轮一次都没遇到——别把它当默认解释。
6. **`screen` 拍到的常常是别的窗口。** 新出现的私有窗口（WPS、Excel 自动化）和 `restore` 回来的窗口（QQ）都排在前台 IDE 后面，5/5 采样被遮；剪映环境检测被 QQ 挡住。合成图只做交叉验证，不做内容证据。
7. **本地端口 ≠ CDP。** WorkBuddy 多个端口 404，QQ 两个 HTTP 200，微信五个无响应，剪映 7264 无响应，WPS 云服务 4709——全都不是 CDP。只有 `/json/version` 返回 `webSocketDebuggerUrl` 且 owner 属于目标进程树才算。
8. **状态指示器比像素可信。** WorkBuddy 发送键 disabled↔enabled、记事本“N 个字符”与标签“已修改”、Excel 编辑栏公式、计算器结果文本、WPS/Excel 另存文件里的缓存值——每个档案的“最强证据”都不是截图。

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
