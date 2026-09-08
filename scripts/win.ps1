# win-use-master main entrypoint.
# Read operations stay in the background. Any coordinate input goes through a
# focus lock, user-presence gate, foreground verification, UIPI check, and
# screenshot verification before focus and cursor are restored.

param(
    [Parameter(Position = 0)]
    [string] $Command = 'help',
    [Parameter(Position = 1, ValueFromRemainingArguments = $true)]
    [string[]] $Rest = @()
)

$CommandArgs = @($Rest | ForEach-Object { [string]$_ })
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version 2.0

$script:ToolName = 'win-use-master'
$script:IdleThresholdSeconds = 2.0
$script:IdleWaitSeconds = 15.0
$script:CaptureTimeoutMilliseconds = 2500
$script:UiaTimeoutMilliseconds = 6000
$script:Force = $CommandArgs -contains '--force'
$script:Dry = $CommandArgs -contains '--dry'
$script:ProcessParentCache = @{}
$CommandArgs = @($CommandArgs | Where-Object { $_ -notin @('--force', '--dry') })

function Stop-Hu {
    param([string] $Message, [int] $Code = 1)
    [Console]::Error.WriteLine($Message)
    exit $Code
}

function Write-HuWarning([string] $Message) {
    [Console]::Error.WriteLine($Message)
}

function Show-HuHud([int] $Milliseconds, [string] $Text, [string] $Style = '') {
    $enabled = [Environment]::GetEnvironmentVariable('WIN_USE_MASTER_HUD') -ne '0'
    $resolvedStyle = if ($Style) { $Style } else { [Environment]::GetEnvironmentVariable('WIN_USE_MASTER_HUD_STYLE') }
    if (-not $resolvedStyle) { $resolvedStyle = 'corner' }
    $resolvedStyle = $resolvedStyle.ToLowerInvariant()
    if ($resolvedStyle -notin @('corner','glow','plain')) {
        Write-HuWarning "HUD 样式 '$resolvedStyle' 无效，改用 corner（可选 corner/glow/plain）。"
        $resolvedStyle = 'corner'
    }
    $captureSetting = [Environment]::GetEnvironmentVariable('WIN_USE_MASTER_HUD_CAPTURABLE')
    $capturable = $captureSetting -match '^(1|true|yes)$'
    if ($enabled) { [HuWin]::ShowHud($Milliseconds, $Text, $resolvedStyle, $capturable) }
    return [pscustomobject]@{ Shown = $enabled; Style = $resolvedStyle; Capturable = $capturable }
}

function Get-AbsolutePath([string] $Path) {
    if ([IO.Path]::IsPathRooted($Path)) { return [IO.Path]::GetFullPath($Path) }
    return [IO.Path]::GetFullPath((Join-Path (Get-Location).Path $Path))
}

function Ensure-Parent([string] $Path) {
    $parent = [IO.Path]::GetDirectoryName((Get-AbsolutePath $Path))
    if ($parent -and -not [IO.Directory]::Exists($parent)) {
        [IO.Directory]::CreateDirectory($parent) | Out-Null
    }
}

function Import-HuCore {
    if ('HuWin' -as [type]) { return }
    $dll = Join-Path $PSScriptRoot 'HuWin.dll'
    $source = Join-Path $PSScriptRoot 'HuWin.cs'
    if (-not (Test-Path -LiteralPath $source)) { Stop-Hu "找不到底层源码: $source" }

    # A stale DLL is worse than a short one-time compile: it silently runs old
    # safety gates. Prefer source whenever it is newer.
    if ((Test-Path -LiteralPath $dll) -and
        (Get-Item -LiteralPath $dll).LastWriteTimeUtc -ge (Get-Item -LiteralPath $source).LastWriteTimeUtc) {
        try { Add-Type -Path $dll; return } catch {
            Write-HuWarning "预编译内核加载失败，改为现场编译: $($_.Exception.Message)"
        }
    }

    try {
        Add-Type -AssemblyName System.Drawing.Common -ErrorAction SilentlyContinue
        Add-Type -AssemblyName System.Drawing -ErrorAction SilentlyContinue
        Add-Type -AssemblyName System.Windows.Forms -ErrorAction SilentlyContinue
        # Add-Type's -ReferencedAssemblies replaces its defaults. PowerShell 7
        # ships compile-time reference assemblies under $PSHOME/ref; include the
        # complete set, then add WindowsDesktop implementation assemblies that
        # are intentionally absent from that ref pack.
        $refs = @()
        $refDir = Join-Path $PSHOME 'ref'
        if (Test-Path -LiteralPath $refDir) {
            $refs += @(Get-ChildItem -LiteralPath $refDir -Filter '*.dll' | Select-Object -ExpandProperty FullName)
        }
        foreach ($candidate in @(
            (Join-Path $PSHOME 'System.Drawing.Common.dll'),
            (Join-Path $PSHOME 'System.Windows.Forms.dll'),
            (Join-Path $PSHOME 'System.Windows.Forms.Primitives.dll'),
            (Join-Path $PSHOME 'System.Private.Windows.Core.dll'),
            (Join-Path $PSHOME 'System.Private.Windows.GdiPlus.dll')
        )) { if (Test-Path -LiteralPath $candidate) { $refs += $candidate } }
        if (-not $refs.Count -and $PSVersionTable.PSEdition -eq 'Desktop') {
            $refs = @('mscorlib.dll', 'System.dll', 'System.Core.dll', 'System.Drawing.dll', 'System.Windows.Forms.dll')
        }
        if ($refs.Count) { Add-Type -Path $source -ReferencedAssemblies $refs }
        else { Add-Type -Path $source }
    } catch {
        Stop-Hu "HuWin.cs 编译失败。先运行 scripts/build.ps1。`n$($_.Exception.Message)"
    }
}

function Invoke-UiaWorker {
    param(
        $Window,
        [Parameter(Mandatory = $true)][string] $Mode,
        [string] $Reference,
        $Spec = $null,
        [string] $Text,
        [int] $Limit = 300
    )
    $worker = Join-Path $PSScriptRoot 'uia-worker.ps1'
    if (-not (Test-Path -LiteralPath $worker -PathType Leaf)) { Stop-Hu "找不到 UIA worker: $worker" }
    $request = [ordered]@{
        mode = $Mode; hwnd = [long]$Window.Hwnd; limit = $Limit
        window = [ordered]@{ l = $Window.L; t = $Window.T; r = $Window.R; b = $Window.B }
    }
    if ($Reference) { $request['reference'] = $Reference }
    if ($null -ne $Spec) { $request['spec'] = $Spec }
    if ($Mode -eq 'set') { $request['text'] = $Text }

    $start = [Diagnostics.ProcessStartInfo]::new()
    $start.FileName = (Get-Process -Id $PID).Path
    $start.UseShellExecute = $false
    $start.CreateNoWindow = $true
    $start.RedirectStandardInput = $true
    $start.RedirectStandardOutput = $true
    $start.RedirectStandardError = $true
    $utf8 = [Text.UTF8Encoding]::new($false)
    $start.StandardInputEncoding = $utf8
    $start.StandardOutputEncoding = $utf8
    $start.StandardErrorEncoding = $utf8
    [void]$start.ArgumentList.Add('-NoProfile')
    [void]$start.ArgumentList.Add('-File')
    [void]$start.ArgumentList.Add($worker)
    $process = [Diagnostics.Process]::new()
    $process.StartInfo = $start
    try {
        if (-not $process.Start()) { return [pscustomobject]@{ TimedOut = $false; ExitCode = 1; Result = $null; Error = 'UIA worker 未启动' } }
        $stdoutTask = $process.StandardOutput.ReadToEndAsync()
        $stderrTask = $process.StandardError.ReadToEndAsync()
        $process.StandardInput.Write(($request | ConvertTo-Json -Depth 8 -Compress))
        $process.StandardInput.Close()
        if (-not $process.WaitForExit($script:UiaTimeoutMilliseconds)) {
            try { $process.Kill($true) } catch { try { $process.Kill() } catch { } }
            try { $process.WaitForExit(1000) | Out-Null } catch { }
            return [pscustomobject]@{ TimedOut = $true; ExitCode = 2; Result = $null; Error = "UIA worker 超过 $($script:UiaTimeoutMilliseconds)ms" }
        }
        $stdout = $stdoutTask.Result
        $stderr = $stderrTask.Result
        $result = $null
        if (-not [string]::IsNullOrWhiteSpace($stdout)) {
            try { $result = $stdout.Trim() | ConvertFrom-Json }
            catch { return [pscustomobject]@{ TimedOut = $false; ExitCode = 1; Result = $null; Error = "UIA worker 返回无效 JSON: $stdout" } }
        }
        $hasError = $result -and ($result.PSObject.Properties.Name -contains 'error') -and $result.error
        $errorText = if ($hasError) { [string]$result.error } elseif ($stderr) { $stderr.Trim() } else { '' }
        return [pscustomobject]@{ TimedOut = $false; ExitCode = $process.ExitCode; Result = $result; Error = $errorText }
    } catch {
        return [pscustomobject]@{ TimedOut = $false; ExitCode = 1; Result = $null; Error = $_.Exception.Message }
    } finally {
        $process.Dispose()
    }
}

Import-HuCore
[HuWin]::SetProcessDPIAware() | Out-Null

function ConvertTo-Hwnd([string] $Text) {
    if ($Text -match '^0x[0-9a-fA-F]+$') { return [Convert]::ToInt64($Text.Substring(2), 16) }
    $n = 0L
    if ([long]::TryParse($Text, [ref]$n)) { return $n }
    return $null
}

function Get-HuWindows {
    return @([HuWin]::AllWindows())
}

function Test-JunkWindow($Window) {
    if (-not $Window.Visible -or $Window.Tool -or $Window.W -lt 60 -or $Window.H -lt 40) { return $true }
    if ([string]::IsNullOrWhiteSpace($Window.Title) -and $Window.W -lt 240 -and $Window.H -lt 180) { return $true }
    if ($Window.Owner -match '^(Idle|Registry|smss|csrss|wininit|services|lsass|dwm|fontdrvhost)$') { return $true }
    return $false
}

function Format-Hwnd([long] $Hwnd) { return ('0x{0:X}' -f $Hwnd) }

function Format-Window($Window) {
    # Hidden windows (tray state, not-yet-shown editors, background dialogs) are
    # only listed with --all; calling them "current" would invite shot/screen/L2.
    $state = if ($Window.Iconic) { 'min' } elseif ($Window.Cloaked) { 'other-desktop/cloaked' } elseif (-not $Window.Visible) { 'hidden' } else { 'current' }
    $title = ([string]$Window.Title).Replace('"', '\"')
    return ('id={0} pid={1} owner="{2}" state={3} rect={4},{5} {6}x{7} class="{8}" title="{9}"' -f
        (Format-Hwnd $Window.Hwnd), $Window.Pid, $Window.Owner, $state,
        $Window.L, $Window.T, $Window.W, $Window.H, $Window.Cls, $title)
}

function Resolve-HuWindow([string] $Selector) {
    $wins = Get-HuWindows
    $numeric = ConvertTo-Hwnd $Selector
    if ($null -ne $numeric) {
        $byHwnd = @($wins | Where-Object { $_.Hwnd -eq $numeric })
        if ($byHwnd.Count) { return $byHwnd[0] }
        $byPid = @($wins | Where-Object { $_.Pid -eq $numeric -and -not (Test-JunkWindow $_) } |
            Sort-Object @{ Expression = { $_.W * $_.H }; Descending = $true })
        if ($byPid.Count) { return $byPid[0] }
        Stop-Hu "找不到窗口/进程 $Selector。先运行 win.ps1 windows。"
    }

    $matches = @($wins | Where-Object {
        -not (Test-JunkWindow $_) -and
        ($_.Owner.IndexOf($Selector, [StringComparison]::OrdinalIgnoreCase) -ge 0 -or
         $_.Title.IndexOf($Selector, [StringComparison]::OrdinalIgnoreCase) -ge 0)
    } | Sort-Object @{ Expression = { $_.W * $_.H }; Descending = $true })
    if (-not $matches.Count) { Stop-Hu "没有 owner/title 含「$Selector」的窗口。先运行 win.ps1 windows。" }
    return $matches[0]
}

function Get-HuParentPid([uint32] $ProcessId) {
    $key = [string]$ProcessId
    if ($script:ProcessParentCache.ContainsKey($key)) { return [uint32]$script:ProcessParentCache[$key] }
    $parent = 0
    try {
        $row = Get-CimInstance -ClassName Win32_Process -Filter "ProcessId=$ProcessId" -ErrorAction Stop
        if ($row) { $parent = [uint32]$row.ParentProcessId }
    } catch { $parent = 0 }
    $script:ProcessParentCache[$key] = $parent
    return [uint32]$parent
}

function Test-HuProcessLineage([uint32] $First, [uint32] $Second) {
    if ($First -eq $Second) { return $true }
    foreach ($pair in @(@($First,$Second), @($Second,$First))) {
        $current = [uint32]$pair[0]; $needle = [uint32]$pair[1]
        $seen = [Collections.Generic.HashSet[uint32]]::new()
        for ($depth = 0; $depth -lt 16 -and $current -gt 4 -and $seen.Add($current); $depth++) {
            $current = Get-HuParentPid $current
            if ($current -eq $needle) { return $true }
        }
    }
    return $false
}

function Get-HuSiblingWindows($Window) {
    return @((Get-HuWindows) | Where-Object {
        $_.Hwnd -ne $Window.Hwnd -and $_.Visible -and -not $_.Iconic -and
        [Math]::Abs($_.L - $Window.L) -le 4 -and [Math]::Abs($_.T - $Window.T) -le 4 -and
        [Math]::Abs($_.W - $Window.W) -le 4 -and [Math]::Abs($_.H - $Window.H) -le 4 -and
        (Test-HuProcessLineage ([uint32]$Window.Pid) ([uint32]$_.Pid))
    } | Sort-Object @{ Expression = { if ($_.Pid -eq $Window.Pid) { 0 } else { 1 } } },
        @{ Expression = { $_.Hwnd } })
}

function Get-HuProcessFamilyIds([uint32] $RootPid) {
    $ids = [Collections.Generic.HashSet[uint32]]::new()
    [void]$ids.Add($RootPid)
    # -NoEnumerate keeps the HashSet intact; a plain return unrolls it, and a
    # single-PID family would then arrive as a bare uint32 without .Contains().
    try { $rows = @(Get-CimInstance -ClassName Win32_Process -ErrorAction Stop) } catch { Write-Output -NoEnumerate $ids; return }
    $changed = $true
    while ($changed) {
        $changed = $false
        foreach ($row in $rows) {
            $pidValue = [uint32]$row.ProcessId; $parentValue = [uint32]$row.ParentProcessId
            if (-not $ids.Contains($pidValue) -and $ids.Contains($parentValue)) {
                [void]$ids.Add($pidValue); $changed = $true
            }
        }
    }
    Write-Output -NoEnumerate $ids
}

function Find-HuCdpPort($Window) {
    try {
        $family = Get-HuProcessFamilyIds ([uint32]$Window.Pid)
        $listeners = @(Get-NetTCPConnection -State Listen -ErrorAction Stop | Where-Object {
            $family.Contains([uint32]$_.OwningProcess) -and $_.LocalAddress -in @('127.0.0.1','::1','0.0.0.0','::')
        } | Sort-Object LocalPort -Unique)
        foreach ($listener in $listeners) {
            try {
                $info = Invoke-RestMethod -Uri "http://127.0.0.1:$([int]$listener.LocalPort)/json/version" -TimeoutSec 2 -Proxy $null
                if ($info.webSocketDebuggerUrl) { return [int]$listener.LocalPort }
            } catch { }
        }
    } catch { }
    return $null
}

function New-TempPng([string] $Prefix = 'win-use-master') {
    return Join-Path ([IO.Path]::GetTempPath()) ("$Prefix-$([Guid]::NewGuid().ToString('N')).png")
}

function New-Receipt($Window, [string] $Path, [int] $Width, [int] $Height, [int] $Colors, [string] $Method) {
    $full = Get-AbsolutePath $Path
    $hash = if (Test-Path -LiteralPath $full) { (Get-FileHash -LiteralPath $full -Algorithm SHA256).Hash.ToLowerInvariant() } else { $null }
    return [ordered]@{
        schema = 'win-use-master/receipt-v1'
        capturedAt = [DateTimeOffset]::Now.ToString('o')
        method = $Method
        image = $full
        sha256 = $hash
        imageSize = @{ width = $Width; height = $Height }
        imageToWindowScale = @{
            x = if ($Width -gt 0) { [Math]::Round($Window.W / [double]$Width, 6) } else { $null }
            y = if ($Height -gt 0) { [Math]::Round($Window.H / [double]$Height, 6) } else { $null }
        }
        dpi = @{
            window = [HuWin]::WindowDpi([long]$Window.Hwnd)
            monitor = [HuWin]::MonitorDpi([long]$Window.Hwnd)
            printWindowScale = [Math]::Round([HuWin]::PrintWindowScale([long]$Window.Hwnd), 6)
        }
        window = @{
            hwnd = Format-Hwnd $Window.Hwnd; pid = $Window.Pid; owner = $Window.Owner
            title = $Window.Title; class = $Window.Cls
            rect = @{ x = $Window.L; y = $Window.T; width = $Window.W; height = $Window.H }
            minimized = $Window.Iconic; cloaked = $Window.Cloaked
        }
        colorBuckets = $Colors
    }
}

function Save-Receipt($Receipt, [string] $ImagePath) {
    $sidecar = (Get-AbsolutePath $ImagePath) + '.receipt.json'
    $Receipt | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath $sidecar -Encoding utf8
    return $sidecar
}

function Get-EffectCode([string] $Report) {
    if ($Report -match 'effect=(confirmed|partial|suspected_noop|unverifiable|unknown)') { return $Matches[1] }
    return 'unverifiable'
}

function Add-ActionEvidenceToReceipt($Receipt, [string] $BeforePath, [string] $PixelReport, $ActionEvidence, [string] $EffectOverride = '') {
    if ($null -eq $Receipt -or $null -eq $ActionEvidence) { return }
    $beforeFull = if ($BeforePath) { Get-AbsolutePath $BeforePath } else { $null }
    $beforeHash = if ($beforeFull -and (Test-Path -LiteralPath $beforeFull -PathType Leaf)) {
        (Get-FileHash -LiteralPath $beforeFull -Algorithm SHA256).Hash.ToLowerInvariant()
    } else { $null }
    $Receipt['action'] = $ActionEvidence
    $Receipt['verification'] = [ordered]@{
        effect = if ($EffectOverride) { $EffectOverride } else { Get-EffectCode $PixelReport }
        before = if ($beforeHash) { [ordered]@{ sha256 = $beforeHash; retained = $false } } else { $null }
        after = [ordered]@{ sha256 = $Receipt.sha256; retained = $true }
        pixelReport = if ($PixelReport) { $PixelReport.Trim() } else { 'effect=unverifiable no before/after pixel comparison' }
    }
}

function Invoke-BackgroundShot($Window, [string] $Path, [switch] $NoReceipt, [switch] $AfterAction) {
    if ([HuWin]::ScreenLocked()) { Stop-Hu 'refused: 当前是锁屏/安全桌面，窗口截图不可信；CDP 仍可用。' 2 }
    if ($Window.Iconic) {
        Stop-Hu "窗口 $(Format-Hwnd $Window.Hwnd) 已最小化。PrintWindow 对最小化窗口通常只返回空帧；恢复窗口或改用 CDP shot。" 2
    }
    $full = Get-AbsolutePath $Path
    Ensure-Parent $full
    if (Test-Path -LiteralPath $full) { [IO.File]::Delete($full) }
    $selectedWindow = $Window
    $recoveredFrom = $null
    $method = 'PrintWindow(PW_RENDERFULLCONTENT)'
    $size = [HuWin]::ShotWindowTimed([long]$Window.Hwnd, $full, $script:CaptureTimeoutMilliseconds)
    $colors = if ($null -ne $size -and (Test-Path -LiteralPath $full)) { [HuWin]::ColorCount($full, 160) } else { -1 }

    # Some Chromium/CEF shells expose one blank owner window and a same-geometry
    # renderer window in the same process lineage. Try only that narrow relation;
    # never use owner-name similarity alone because it can cross app boundaries.
    if ($null -eq $size -or $colors -lt 6) {
        foreach ($sibling in @(Get-HuSiblingWindows $Window)) {
            $candidatePath = New-TempPng 'shot-sibling'
            try {
                $candidateSize = [HuWin]::ShotWindowTimed([long]$sibling.Hwnd, $candidatePath, $script:CaptureTimeoutMilliseconds)
                if ($null -eq $candidateSize -or -not (Test-Path -LiteralPath $candidatePath)) { continue }
                $candidateColors = [HuWin]::ColorCount($candidatePath, 160)
                if ($null -eq $size -or $candidateColors -ge [Math]::Max(6, $colors + 3)) {
                    [IO.File]::Copy($candidatePath, $full, $true)
                    $size = $candidateSize; $colors = $candidateColors
                    $selectedWindow = $sibling; $recoveredFrom = $Window
                    $method = 'PrintWindow sibling-renderer recovery'
                    break
                }
            } finally {
                if (Test-Path -LiteralPath $candidatePath) { [IO.File]::Delete($candidatePath) }
            }
        }
    }
    if ($null -eq $size -or -not (Test-Path -LiteralPath $full) -or (Get-Item -LiteralPath $full).Length -eq 0) {
        if ($AfterAction) {
            Stop-Hu "effect=unknown: 动作已经发出，但动作后截图失败。不要自动重试；先读取目标状态或最终副作用。目标 $(Format-Hwnd $Window.Hwnd)。" 2
        }
        $cdpPort = Find-HuCdpPort $Window
        $cdpHint = if ($null -ne $cdpPort) { " 已发现目标进程树的 CDP 端口 $cdpPort；改用: node `"$PSScriptRoot\cdp.js`" $cdpPort shot auto <路径>。" } else { '' }
        Stop-Hu "后台截图失败：窗口可能已关闭、进入安全桌面，或拒绝/超时 PrintWindow。目标 $(Format-Hwnd $Window.Hwnd)。$cdpHint$(Get-ScreenCrossCheckHint $Window)" 1
    }
    if ($colors -lt 0) { $colors = [HuWin]::ColorCount($full, 160) }
    # The interior count ignores title/tool bars. When it is near-uniform, also
    # measure the whole frame: an empty editor and a dead client area look the
    # same inside, but a frame that rendered nothing at all is a different fault.
    $frameColors = if ($colors -lt 6) { [HuWin]::ColorCount($full, 160, $false) } else { $null }
    $receipt = New-Receipt $selectedWindow $full $size.Width $size.Height $colors $method
    if ($null -ne $frameColors) { $receipt['frameColorBuckets'] = $frameColors }
    if ($null -ne $recoveredFrom) {
        $receipt['recoveredFrom'] = @{ hwnd = Format-Hwnd $recoveredFrom.Hwnd; pid = $recoveredFrom.Pid; owner = $recoveredFrom.Owner }
    }
    $sidecar = $null
    if (-not $NoReceipt) { $sidecar = Save-Receipt $receipt $full }
    $cdpPort = if ($colors -lt 6) { Find-HuCdpPort $selectedWindow } else { $null }
    return [pscustomobject]@{ Window = $selectedWindow; RecoveredFrom = $recoveredFrom; CdpPort = $cdpPort; Path = $full; Width = $size.Width; Height = $size.Height; Colors = $colors; FrameColors = $frameColors; Receipt = $receipt; Sidecar = $sidecar }
}

# Pixels cannot tell an empty document from a shell whose client area never
# rendered: both are a uniform interior under a rendered frame. Report which shape
# was seen and point at semantic cross-checks instead of implying a capture fault.
function Get-BlankFrameHint($Result, $Window, $Elements = $null) {
    $cdpRoute = if ($null -ne $Result.CdpPort) { "已发现目标 CDP 端口 $($Result.CdpPort)：node `"$PSScriptRoot\cdp.js`" $($Result.CdpPort) shot auto <路径>。" } else { '' }
    $frame = $Result.FrameColors
    if ($null -ne $Window -and -not $Window.Visible -and -not $Window.Iconic) {
        return "effect=unverifiable ⚠️ 目标窗口当前不可见（未显示/托盘态，state=hidden），PrintWindow 返回空帧是预期，不是渲染拒绝。请用户显示该窗口后再截；${cdpRoute}借前台的 shotfg 对隐藏窗口同样无效。"
    }
    if ($null -eq $frame -or $frame -lt 6) {
        return "effect=unverifiable ⚠️ 整帧接近纯色（内容区 $($Result.Colors) 桶，整帧 $frame 桶）：应用可能拒绝后台渲染，也可能窗口本来就是空白。${cdpRoute}可改 shotfg；Chromium 系先用 probe 查 CDP。$(Get-ScreenCrossCheckHint $Window)"
    }
    $semantic = ''
    if ($null -ne $Elements) {
        $texts = @($Elements | Where-Object { [string]$_.ControlType -in @('Document', 'Edit') })
        $filled = @($texts | Where-Object { -not [string]::IsNullOrEmpty([string]$_.Value) })
        $empty = @($texts | Where-Object { [string]::IsNullOrEmpty([string]$_.Value) })
        if ($filled.Count) { $semantic = " UIA 却读到 $($filled.Count) 个非空 Document/Edit：像素与语义不一致，内容层可能未渲染，用 screen --window 交叉验证。" }
        elseif ($empty.Count) { $semantic = " UIA 读到空的 $($empty[0].ControlType)「$($empty[0].Name)」，与单色内容区一致：多半是空文档，不是截图失败。" }
    }
    return "⚠️ 内容区接近单色但窗口框/工具栏已渲染（内容区 $($Result.Colors) 桶，整帧 $frame 桶）：可能是空白文档/画布，也可能是壳窗口或内容层未渲染。${semantic}${cdpRoute}$(if (-not $semantic) { ' 先 uiaread 看 Document/Edit 是否为空，或 screen --window 交叉验证；都判断不了再 shotfg。' })"
}

# PrintWindow asks the app to paint itself; it can hand back a stale or black
# surface while the user sees a live window. When the window is actually on the
# current desktop, the desktop composition is the only independent cross-check.
function Get-ScreenCrossCheckHint($Window) {
    if ($null -eq $Window -or $Window.Iconic -or $Window.Cloaked -or -not $Window.Visible) { return '' }
    return " 窗口在当前桌面且可见时，可用 win.ps1 screen <路径> --window $(Format-Hwnd $Window.Hwnd) 做桌面合成交叉验证（含遮挡物）。"
}

function Get-ScreenOcclusion($Window) {
    # Center plus four inner quadrant points. WindowAtPoint returns the root
    # window under each screen point; anything but the target is an occluder.
    $samples = @(@(0.5, 0.5), @(0.25, 0.25), @(0.75, 0.25), @(0.25, 0.75), @(0.75, 0.75))
    $blocked = 0
    $blockers = [Collections.Generic.List[string]]::new()
    foreach ($sample in $samples) {
        $sx = [int]($Window.L + $sample[0] * $Window.W); $sy = [int]($Window.T + $sample[1] * $Window.H)
        $top = [HuWin]::WindowAtPoint($sx, $sy)
        if ($null -eq $top) { $blocked++; continue }
        if ($top.Hwnd -ne $Window.Hwnd) {
            $blocked++
            $label = "$($top.Owner) $(Format-Hwnd $top.Hwnd)"
            if (-not $blockers.Contains($label)) { $blockers.Add($label) }
        }
    }
    return [ordered]@{ samples = $samples.Count; blocked = $blocked; blockers = @($blockers) }
}

# Desktop composition capture (BitBlt via CopyFromScreen). Unlike PrintWindow it
# shows what the user sees, including occluders, notifications and any HUD that
# was made capturable. Region is clipped to the virtual screen; never activates.
function Invoke-ScreenShot([string] $Path, $Window, $Region) {
    if ([HuWin]::ScreenLocked()) { Stop-Hu 'refused: 当前是锁屏/安全桌面，桌面合成截图不可信；CDP 仍可用。' 2 }
    $virtual = [HuWin]::GetVirtualScreen()
    $occlusion = $null
    if ($null -ne $Window) {
        if ($Window.Iconic) { Stop-Hu "refused: 目标窗口 $(Format-Hwnd $Window.Hwnd) 已最小化，屏幕上没有它的像素；改 shot/CDP，或请用户恢复窗口。" 2 }
        if ($Window.Cloaked) { Stop-Hu "refused: 目标窗口 $(Format-Hwnd $Window.Hwnd) 在其它虚拟桌面或被 DWM cloaked；桌面合成截图只会拍到当前桌面。" 2 }
        if (-not $Window.Visible) { Stop-Hu "refused: 目标窗口 $(Format-Hwnd $Window.Hwnd) 不可见。" 2 }
        $Region = [ordered]@{ X = $Window.L; Y = $Window.T; W = $Window.W; H = $Window.H }
        $occlusion = Get-ScreenOcclusion $Window
    } elseif ($null -eq $Region) {
        $Region = [ordered]@{ X = $virtual.X; Y = $virtual.Y; W = $virtual.W; H = $virtual.H }
    }
    if ($Region.W -le 0 -or $Region.H -le 0) { Stop-Hu 'refused: 截图区域宽高必须大于 0。' 2 }
    $left = [Math]::Max([int]$Region.X, $virtual.L); $top = [Math]::Max([int]$Region.Y, $virtual.T)
    $right = [Math]::Min([int]$Region.X + [int]$Region.W, $virtual.R); $bottom = [Math]::Min([int]$Region.Y + [int]$Region.H, $virtual.B)
    if ($right -le $left -or $bottom -le $top) {
        Stop-Hu "refused: 区域 $($Region.X),$($Region.Y) $($Region.W)x$($Region.H) 完全在虚拟屏幕 $($virtual.X),$($virtual.Y) $($virtual.W)x$($virtual.H) 之外。" 2
    }
    $clipped = ($left -ne [int]$Region.X) -or ($top -ne [int]$Region.Y) -or (($right - $left) -ne [int]$Region.W) -or (($bottom - $top) -ne [int]$Region.H)
    $full = Get-AbsolutePath $Path
    Ensure-Parent $full
    if (Test-Path -LiteralPath $full) { [IO.File]::Delete($full) }
    $size = [HuWin]::ShotScreen($full, $left, $top, $right - $left, $bottom - $top)
    if ($null -eq $size -or -not (Test-Path -LiteralPath $full) -or (Get-Item -LiteralPath $full).Length -eq 0) {
        Stop-Hu '桌面合成截图失败：CopyFromScreen 没有产出文件；可能是远程会话断开或显示驱动拒绝。' 1
    }
    $colors = [HuWin]::ColorCount($full, 160)
    $receipt = [ordered]@{
        schema = 'win-use-master/receipt-v1'
        capturedAt = [DateTimeOffset]::Now.ToString('o')
        method = 'BitBlt desktop composition (CopyFromScreen)'
        composition = $true
        image = $full
        sha256 = (Get-FileHash -LiteralPath $full -Algorithm SHA256).Hash.ToLowerInvariant()
        imageSize = @{ width = $size.Width; height = $size.Height }
        region = [ordered]@{ x = $left; y = $top; width = $right - $left; height = $bottom - $top; requested = [ordered]@{ x = [int]$Region.X; y = [int]$Region.Y; width = [int]$Region.W; height = [int]$Region.H }; clipped = $clipped }
        virtualScreen = @{ x = $virtual.X; y = $virtual.Y; width = $virtual.W; height = $virtual.H }
        screens = @([HuWin]::AllScreens() | ForEach-Object { [ordered]@{ x = $_.X; y = $_.Y; width = $_.W; height = $_.H; primary = $_.Primary } })
        colorBuckets = $colors
    }
    if ($null -ne $Window) {
        $receipt['window'] = @{
            hwnd = Format-Hwnd $Window.Hwnd; pid = $Window.Pid; owner = $Window.Owner
            title = $Window.Title; class = $Window.Cls
            rect = @{ x = $Window.L; y = $Window.T; width = $Window.W; height = $Window.H }
            minimized = $Window.Iconic; cloaked = $Window.Cloaked
        }
        $receipt['occlusion'] = $occlusion
        # Only an unclipped window crop is 1:1 with the window; a clipped image
        # must not be reused as an @reference for coordinates.
        $receipt['imageToWindowScale'] = if ($clipped) { $null } else { @{ x = 1.0; y = 1.0 } }
    }
    $sidecar = Save-Receipt $receipt $full
    return [pscustomobject]@{ Path = $full; Width = $size.Width; Height = $size.Height; Colors = $colors; Clipped = $clipped; Occlusion = $occlusion; Left = $left; Top = $top; Receipt = $receipt; Sidecar = $sidecar }
}

# Launch helper. -NoActivate asks the first window not to take activation; that is
# advisory, so open reads the foreground back through Get-HuLaunchReport.
function Start-HuProcess([string] $Path, [string] $Arguments, [switch] $NoActivate) {
    if ($NoActivate) {
        $newPid = [HuWin]::StartProcessNoActivate($Path, $Arguments, '', $false)
        if ($newPid -le 0) { Stop-Hu "启动失败: $Path（CreateProcess 未成功，请检查路径与权限）" 1 }
        try { return Get-Process -Id $newPid -ErrorAction Stop }
        catch { return [pscustomobject]@{ Id = $newPid; HasExited = $true; Path = $Path } }
    }
    if ($Arguments) { return Start-Process -FilePath $Path -ArgumentList $Arguments -PassThru }
    return Start-Process -FilePath $Path -PassThru
}

# Watches a freshly launched process. STARTF_USESHOWWINDOW is advisory, so the
# report says whether the app took the foreground anyway; if it did, the user's
# previous window is handed back within one poll (~100 ms) rather than after the
# app finishes loading. The hand-back never injects the Alt unlock while the
# user is typing; a plain SetForegroundWindow that fails is reported as such.
function Get-HuLaunchReport([string] $Path, [int] $LaunchedPid, [IntPtr] $PreviousForeground, [int] $WaitSeconds = 8) {
    $deadline = [DateTime]::UtcNow.AddSeconds($WaitSeconds)
    $window = $null
    $family = [Collections.Generic.HashSet[uint32]]::new()
    [void]$family.Add([uint32]$LaunchedPid)
    $stolen = $false; $restored = $null; $restoreAttempts = 0
    $stableHits = 0
    $nextFamilyRefresh = [DateTime]::MinValue
    $previousValid = ($PreviousForeground -ne [IntPtr]::Zero) -and [HuWin]::IsWindow($PreviousForeground)
    while ([DateTime]::UtcNow -lt $deadline) {
        if ([DateTime]::UtcNow -ge $nextFamilyRefresh) {
            # Single-instance apps hand off to an existing process and exit, and
            # Squirrel/Store launchers spawn the real exe; match by exe path too.
            $familyNow = Get-HuProcessFamilyIds ([uint32]$LaunchedPid)
            foreach ($id in $familyNow) { [void]$family.Add([uint32]$id) }
            foreach ($proc in @(Get-Process -ErrorAction SilentlyContinue)) {
                try { if ($proc.Path -and $proc.Path -ieq $Path) { [void]$family.Add([uint32]$proc.Id) } } catch { }
            }
            $nextFamilyRefresh = [DateTime]::UtcNow.AddMilliseconds(700)
        }
        $windows = Get-HuWindows
        $foreground = [HuWin]::ForegroundWindow().ToInt64()
        $foregroundInfo = @($windows | Where-Object { $_.Hwnd -eq $foreground } | Select-Object -First 1)
        if ($foregroundInfo.Count -and $family.Contains([uint32]$foregroundInfo[0].Pid)) {
            $stolen = $true
            if ($previousValid -and $restoreAttempts -lt 3) {
                $restoreAttempts++
                $userIdle = [HuWin]::UserIdleSeconds() -ge $script:IdleThresholdSeconds
                $restored = [HuWin]::ActivateWindow($PreviousForeground.ToInt64(), 400, $userIdle)
            } elseif ($null -eq $restored) { $restored = $false }
        }
        $candidates = @($windows | Where-Object { $family.Contains([uint32]$_.Pid) -and -not (Test-JunkWindow $_) } |
            Sort-Object @{ Expression = { $_.W * $_.H }; Descending = $true })
        if ($candidates.Count) {
            $window = $candidates[0]
            # Two consecutive sightings catch splash → main window transitions
            # that activate twice; then stop watching.
            $stableHits++
            if ($stableHits -ge 2 -and (-not $stolen -or $restored)) { break }
        } else { $stableHits = 0 }
        Start-Sleep -Milliseconds 100
    }
    $state = if (-not $stolen) { 'kept' } elseif ($restored) { 'stolen-restored' } else { 'stolen-unrestored' }
    return [pscustomobject]@{ Window = $window; ForegroundStolen = $stolen; Restored = $restored; RestoreAttempts = $restoreAttempts; Foreground = $state; FamilyCount = $family.Count }
}

# Verification should never turn a completed semantic action into a reported
# hard failure. This lower-level capture returns false instead of exiting, so
# callers can honestly report effect=unverifiable.
function Try-VerificationShot($Window, [string] $Path) {
    if ($Window.Iconic -or [HuWin]::ScreenLocked()) { return $false }
    try {
        $full = Get-AbsolutePath $Path
        Ensure-Parent $full
        $size = [HuWin]::ShotWindowTimed([long]$Window.Hwnd, $full, $script:CaptureTimeoutMilliseconds)
        return $null -ne $size -and (Test-Path -LiteralPath $full) -and (Get-Item -LiteralPath $full).Length -gt 0
    } catch { return $false }
}

function Write-VerificationReport {
    param(
        $Window,
        [string] $Before,
        [string] $After,
        [double] $Nx = 0.5,
        [double] $Ny = 0.5,
        [switch] $Semantic,
        $ActionEvidence = $null,
        [string] $EffectOverride = ''
    )
    if ((Test-Path -LiteralPath $Before) -and (Test-Path -LiteralPath $After)) {
        $report = [HuWin]::DiffReport($Before, $After, $Nx, $Ny)
        if ($Semantic -and $report -match 'effect=suspected_noop 落点几乎没变') {
            $report = $report -replace 'effect=suspected_noop 落点几乎没变', 'effect=partial 语义动作使窗口其它区域变化、控件附近几乎没变' -replace '，多半是 app 自己的动画', '；可能是预期副作用，也可能是动画，需读回确认'
        }
        Write-Output $report
        $img = [Drawing.Image]::FromFile($After)
        try { $iw = $img.Width; $ih = $img.Height } finally { $img.Dispose() }
        $receipt = New-Receipt $Window $After $iw $ih ([HuWin]::ColorCount($After,160)) 'PrintWindow verification'
        Add-ActionEvidenceToReceipt $receipt $Before $report $ActionEvidence $EffectOverride
        $sidecar = Save-Receipt $receipt $After
        Write-Output "verification: $After receipt=$sidecar"
    } else {
        Write-Output 'effect=unverifiable：动作后的窗口帧无法获取；必须改用 UIA/CDP 读回或检查最终副作用。'
    }
}

function Save-UiaMap($Window, $Elements, [string] $Path, [string] $Screenshot) {
    $map = [ordered]@{
        schema = 'win-use-master/uia-map-v1'
        createdAt = [DateTimeOffset]::Now.ToString('o')
        screenshot = $Screenshot
        window = @{ hwnd = Format-Hwnd $Window.Hwnd; pid = $Window.Pid; owner = $Window.Owner; width = $Window.W; height = $Window.H }
        elements = @($Elements | ForEach-Object {
            [ordered]@{ ref = $_.Ref; name = $_.Name; controlType = $_.ControlType; automationId = $_.AutomationId; className = $_.ClassName
                cx = $_.Cx; cy = $_.Cy; width = $_.Width; height = $_.Height
                enabled = $_.Enabled; offscreen = $_.Offscreen; isPassword = $_.IsPassword; patterns = @($_.Patterns) }
        })
    }
    $map | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath $Path -Encoding utf8
}

function Format-UiaElement($Element) {
    $disabled = if (-not $Element.Enabled) { ' [disabled]' } else { '' }
    $off = if ($Element.Offscreen) { ' [offscreen]' } else { '' }
    $password = if ($Element.IsPassword) { ' [password-redacted]' } else { '' }
    $name = ([string]$Element.Name).Replace('"', '\"')
    $value = if ($Element.Value) { ' value="' + ([string]$Element.Value).Replace('"','\"').Replace("`r",' ').Replace("`n",' ') + '"' } else { '' }
    return ('{0} {1} "{2}" ({3},{4}) id="{5}" patterns={6}{7}{8}{9}{10}' -f
        $Element.Ref, $Element.ControlType, $name, [int]$Element.Cx, [int]$Element.Cy,
        $Element.AutomationId, ($Element.Patterns -join ','), $disabled, $off, $password, $value)
}

function Format-UiaReadableElement($Element) {
    $name = ([string]$Element.Name).Replace('"', '\"').Replace("`r", ' ').Replace("`n", ' ')
    $value = ([string]$Element.Value).Replace('"', '\"').Replace("`r", ' ').Replace("`n", ' ')
    $shown = if ($Element.IsPassword) { ' value="[password-redacted]"' } elseif ($value) { ' value="' + $value + '"' } else { '' }
    $off = if ($Element.Offscreen) { ' [offscreen]' } else { '' }
    return ('{0} name="{1}" id="{2}"{3}{4}' -f $Element.ControlType,$name,$Element.AutomationId,$shown,$off)
}

# Public UIA reads always cross a process boundary. A provider that blocks
# FindAll/GetCurrentPattern is terminated at the parent deadline instead of
# freezing the agent process.
function Get-UiaElements($Window, [int] $Limit = 180) {
    $reply = Invoke-UiaWorker $Window -Mode list -Limit $Limit
    if ($reply.TimedOut) { Stop-Hu 'UIA 枚举超过 6 秒，已终止辅助进程；改用截图/CDP，不要立即重复撞同一 provider。' 2 }
    if ($reply.ExitCode -ne 0 -or $null -eq $reply.Result -or -not $reply.Result.ok) {
        Stop-Hu ("UIA 枚举失败: " + $(if ($reply.Error) { $reply.Error } else { 'worker 无结果' })) $(if($reply.ExitCode -eq 2){2}else{1})
    }
    return @($reply.Result.items)
}

function Get-UiaReadableElements($Window, [int] $Limit = 300) {
    $reply = Invoke-UiaWorker $Window -Mode read -Limit $Limit
    if ($reply.TimedOut) { Stop-Hu 'UIA 读取超过 6 秒，已终止辅助进程；改用截图/CDP。' 2 }
    if ($reply.ExitCode -ne 0 -or $null -eq $reply.Result -or -not $reply.Result.ok) {
        Stop-Hu ("UIA 读取失败: " + $(if ($reply.Error) { $reply.Error } else { 'worker 无结果' })) $(if($reply.ExitCode -eq 2){2}else{1})
    }
    return @($reply.Result.items)
}

function Get-UiaReferenceSpec([string] $Reference, [string] $MapPath) {
    if ($Reference -ne 'first' -and $Reference -notmatch '^e\d+$') { Stop-Hu "UIA ref 应为 eN 或 first，收到: $Reference" }
    if (-not $MapPath) { return $null }
    $fullMap = Get-AbsolutePath ($MapPath.TrimStart('@'))
    if (-not (Test-Path -LiteralPath $fullMap)) { Stop-Hu "UIA map 不存在: $fullMap" }
    $saved = Get-Content -Raw -LiteralPath $fullMap | ConvertFrom-Json
    $match = @($saved.elements | Where-Object { $_.ref -eq $Reference })
    if (-not $match.Count) { Stop-Hu "$fullMap 里没有 $Reference" }
    return $match[0]
}

function Resolve-UiaReference($Window, [string] $Reference, [string] $MapPath) {
    $spec = Get-UiaReferenceSpec $Reference $MapPath
    $reply = Invoke-UiaWorker $Window -Mode resolve -Reference $Reference -Spec $spec -Limit 300
    if ($reply.TimedOut) { Stop-Hu 'UIA 引用解析超过 6 秒，已终止辅助进程；没有点击或写入。' 2 }
    if ($reply.ExitCode -ne 0 -or $null -eq $reply.Result -or -not $reply.Result.ok) {
        Stop-Hu ("UIA 引用已失效: " + $(if ($reply.Error) { $reply.Error } else { '重新运行 see/uia' })) 2
    }
    return $reply.Result.item
}

function Resolve-Point($Window, [string] $XText, [string] $YText, [string] $ReferencePath) {
    if ($XText -match '^(e\d+)@(.+)$') {
        $el = Resolve-UiaReference $Window $Matches[1] $Matches[2]
        $inkX = $el.Cx - $el.Width / 2 + [Math]::Min(40, $el.Width / 4)
        return [pscustomobject]@{ X = [int]$el.Cx; Y = [int]$el.Cy; VerifyX = [int]$inkX; VerifyY = [int]$el.Cy; ScreenX = [int]($Window.L + $el.Cx); ScreenY = [int]($Window.T + $el.Cy); Note = "$($Matches[1]) from UIA map" }
    }
    $x = 0.0; $y = 0.0
    if (-not [double]::TryParse($XText, [Globalization.NumberStyles]::Float, [Globalization.CultureInfo]::InvariantCulture, [ref]$x) -or
        -not [double]::TryParse($YText, [Globalization.NumberStyles]::Float, [Globalization.CultureInfo]::InvariantCulture, [ref]$y)) {
        Stop-Hu "坐标必须是数字、归一化小数，或 eN@uia.json。收到: $XText $YText"
    }
    if ($ReferencePath) {
        $imgPath = Get-AbsolutePath ($ReferencePath.TrimStart('@'))
        if (-not (Test-Path -LiteralPath $imgPath)) { Stop-Hu "参考截图不存在: $imgPath" }
        $img = [Drawing.Image]::FromFile($imgPath)
        try { $rx = $x * $Window.W / $img.Width; $ry = $y * $Window.H / $img.Height; $note = "图上像素($x,$y)@$($img.Width)x$($img.Height)" }
        finally { $img.Dispose() }
    } elseif ([Math]::Abs($x) -le 1 -and [Math]::Abs($y) -le 1) {
        $rx = $x * $Window.W; $ry = $y * $Window.H; $note = "归一化($x,$y)"
    } else {
        $rx = $x; $ry = $y; $note = "窗口内像素($x,$y)"
    }
    if ($rx -lt 0 -or $ry -lt 0 -or $rx -gt $Window.W -or $ry -gt $Window.H) {
        Stop-Hu "refused: 坐标换算后 ($([int]$rx),$([int]$ry)) 超出窗口 $($Window.W)x$($Window.H)。" 2
    }
    return [pscustomobject]@{ X = [int][Math]::Round($rx); Y = [int][Math]::Round($ry); VerifyX = [int][Math]::Round($rx); VerifyY = [int][Math]::Round($ry); ScreenX = [int][Math]::Round($Window.L + $rx); ScreenY = [int][Math]::Round($Window.T + $ry); Note = $note }
}

function Get-ReferenceToken([string[]] $Items) {
    if (-not $Items) { return $null }
    $hit = @($Items | Where-Object { $_ -and $_.StartsWith('@') })
    if ($hit.Count) { return $hit[0] }
    return $null
}

function Get-FocusLock {
    $path = Join-Path ([IO.Path]::GetTempPath()) 'win-use-master.focus.lock'
    try {
        $stream = [IO.File]::Open($path, [IO.FileMode]::OpenOrCreate, [IO.FileAccess]::ReadWrite, [IO.FileShare]::None)
        $stream.SetLength(0)
        $bytes = [Text.Encoding]::UTF8.GetBytes("pid=$PID acquired=$([DateTimeOffset]::Now.ToString('o'))")
        $stream.Write($bytes, 0, $bytes.Length); $stream.Flush()
        return $stream
    } catch { Stop-Hu 'refused: 另一个 win-use-master 进程正持有借焦点锁。等它结束，或改走 CDP/UIA。' 2 }
}

function Wait-ForUserIdle {
    $started = [Diagnostics.Stopwatch]::StartNew()
    while ($started.Elapsed.TotalSeconds -lt $script:IdleWaitSeconds) {
        $idle = [HuWin]::UserIdleSeconds()
        if ($idle -ge $script:IdleThresholdSeconds) { return $started.Elapsed.TotalSeconds }
        Start-Sleep -Milliseconds 100
    }
    $last = [HuWin]::UserIdleSeconds()
    Stop-Hu ("refused: 用户正在使用电脑（键鼠仅空闲 {0:F1}s），等了 {1:F0}s 仍未停手。改走 CDP/UIA，或等用户停手后再试；--force 不绕过在场闸。" -f $last, $script:IdleWaitSeconds) 2
}

function Test-ShellWindow($Window) {
    return $Window.Owner -match '^(WindowsTerminal|wt|cmd|powershell|pwsh|ConEmu|Code|Cursor|devenv|idea64|pycharm64|rider64)$'
}

function Get-GatePreview($Window, $Point) {
    $self = [HuWin]::SelfIntegrity(); $target = [HuWin]::IntegrityLevel([uint32]$Window.Pid)
    $uipi = if ($self -eq 0 -or $target -eq 0) { "BLOCK(unknown self=$self target=$target)" } elseif ($self -lt $target) { "BLOCK(self=$self target=$target)" } else { "pass(self=$self target=$target)" }
    $desktop = if ($Window.Cloaked) { 'BLOCK(other-desktop/cloaked)' } elseif ($Window.Iconic) { 'BLOCK(minimized)' } elseif (-not $Window.Visible) { 'BLOCK(hidden)' } else { 'pass' }
    $idle = [HuWin]::UserIdleSeconds()
    $presence = if ($idle -ge $script:IdleThresholdSeconds) { "pass(idle=$([Math]::Round($idle,1))s)" } else { "WAIT(idle=$([Math]::Round($idle,1))s)" }
    $pointText = if ($null -ne $Point) { " point=$($Point.ScreenX),$($Point.ScreenY)" } else { '' }
    return "闸预检: desktop=$desktop UIPI=$uipi presence=$presence focus-lock=runtime-check$pointText"
}

function Test-TargetForeground($Window) {
    $foreground = [HuWin]::ForegroundWindow()
    if ($foreground -eq [IntPtr]::Zero) { return $false }
    $target = [IntPtr]$Window.Hwnd
    if ($foreground -eq $target) { return $true }
    $foregroundRoot = [HuWin]::GetAncestor($foreground, [uint32]2)
    $targetRoot = [HuWin]::GetAncestor($target, [uint32]2)
    if ($targetRoot -eq [IntPtr]::Zero) { $targetRoot = $target }
    return $foregroundRoot -eq $targetRoot
}

function Invoke-WithBorrowedFocus($Window, [scriptblock] $Action, [switch] $KeepCursor, [string] $HudText = '') {
    if ([HuWin]::ScreenLocked()) { Stop-Hu 'refused: 当前是锁屏/安全桌面，不能发送输入。' 2 }
    if ($Window.Iconic) { Stop-Hu 'refused: 目标窗口已最小化。先由用户恢复窗口，或改走 CDP/UIA。' 2 }
    if ($Window.Cloaked) { Stop-Hu 'refused: 目标窗口在其它虚拟桌面或被 DWM cloaked。坐标输入可能切桌面；改走 CDP/UIA，或请用户把窗口移来。--force 也不会自动切桌面。' 2 }
    # Activating a hidden window would ShowWindow it: that changes what the user
    # sees on their behalf, the same class of side effect as switching desktops.
    if (-not $Window.Visible) { Stop-Hu 'refused: 目标窗口当前不可见（未显示/托盘态）。坐标输入必须先把它显示出来，这会改变用户可见状态；请用户自己打开窗口，或改走 CDP/UIA。--force 不绕过。' 2 }
    $selfLevel = [HuWin]::SelfIntegrity(); $targetLevel = [HuWin]::IntegrityLevel([uint32]$Window.Pid)
    if (-not $selfLevel -or -not $targetLevel) {
        Stop-Hu "refused: 无法确认 UIPI 完整性级别（self=$selfLevel target=$targetLevel）。未知不等于安全；改走 CDP/UIA。--force 也不绕过。" 2
    }
    if ($selfLevel -lt $targetLevel) {
        Stop-Hu "refused: UIPI 完整性级别不足（self=$selfLevel < target=$targetLevel）。请在相同权限级别运行 agent；--force 也无法绕过。" 2
    }

    $lock = Get-FocusLock
    $previous = [IntPtr]::Zero
    $cursor = [HuWin+POINT]::new()
    $focusClock = [Diagnostics.Stopwatch]::new()
    $actionClock = [Diagnostics.Stopwatch]::new()
    $waited = 0.0
    $borrowed = $false
    $actionCompleted = $false
    $cursorRestored = $true
    $foregroundRestored = $true
    try {
        $waited = Wait-ForUserIdle
        if ($waited -gt 0.5) { Write-HuWarning ("用户刚在动键鼠，等他停手 {0:F1}s 后才动手。" -f $waited) }
        # Capture the user's current context only after the idle wait. They may
        # legitimately switch windows while we are waiting; restoring an older
        # foreground HWND would be an unexpected second focus steal.
        $previous = [HuWin]::ForegroundWindow()
        [HuWin]::GetCursorPos([ref]$cursor) | Out-Null
        $borrowed = -not (Test-TargetForeground $Window)
        if (-not $HudText) { $HudText = "$script:ToolName 正在操作「$($Window.Owner)」" }
        try { [void](Show-HuHud 1200 $HudText) } catch { }
        if ($borrowed) { $focusClock.Start() }
        if (-not [HuWin]::ActivateWindow([long]$Window.Hwnd)) { Stop-Hu "refused: Windows 不允许把目标窗口切到前台。请手动点一下目标窗口后重试。" 2 }
        $deadline = [DateTime]::UtcNow.AddSeconds(2)
        while (-not (Test-TargetForeground $Window) -and [DateTime]::UtcNow -lt $deadline) { Start-Sleep -Milliseconds 25 }
        if (-not (Test-TargetForeground $Window)) { Stop-Hu 'refused: 前台验证失败，没有发送任何输入。请手动把目标窗口置前。' 2 }
        $actionClock.Start()
        & $Action
        $actionClock.Stop()
        $actionCompleted = $true
    } finally {
        if ($actionClock.IsRunning) { $actionClock.Stop() }
        if (-not $KeepCursor) { $cursorRestored = [HuWin]::SetCursorPos($cursor.X, $cursor.Y) }
        if ($borrowed -and $previous -ne [IntPtr]::Zero -and $previous.ToInt64() -ne $Window.Hwnd) {
            $foregroundRestored = [HuWin]::ActivateWindow($previous.ToInt64())
        }
        if ($focusClock.IsRunning) { $focusClock.Stop() }
        if ($null -ne $lock) { $lock.Dispose() }
    }
    if ($actionCompleted -and (-not $cursorRestored -or -not $foregroundRestored)) {
        Stop-Hu "effect=unknown: 动作可能已完成，但现场还原不完整（cursor=$cursorRestored foreground=$foregroundRestored）。不要自动重试；先检查目标状态并由用户恢复现场。" 2
    }
    return [pscustomobject]@{
        Borrowed = $borrowed
        WaitedSeconds = $waited
        FocusSeconds = $focusClock.Elapsed.TotalSeconds
        ActionSeconds = $actionClock.Elapsed.TotalSeconds
    }
}

function Format-FocusSummary($Timing) {
    if ($Timing.Borrowed) { return ("借焦点 {0:F2}s 后已还原" -f $Timing.FocusSeconds) }
    return ("目标本就在前台，未切换焦点（动作 {0:F2}s）" -f $Timing.ActionSeconds)
}

function Assert-PointTargetsWindow($Window, $Point) {
    $top = [HuWin]::WindowAtPoint($Point.ScreenX, $Point.ScreenY)
    if ($null -eq $top) { Stop-Hu "refused: 落点 $($Point.ScreenX),$($Point.ScreenY) 没有窗口。" 2 }
    if ($top.Hwnd -ne $Window.Hwnd) {
        Stop-Hu "refused: occluded 落点上层是「$($top.Owner)」$(Format-Hwnd $top.Hwnd)，不是目标 $(Format-Hwnd $Window.Hwnd)。没有点击。" 2
    }
}

function Parse-KeyChord([string] $Chord) {
    $parts = @($Chord.Split('+', [StringSplitOptions]::RemoveEmptyEntries))
    $ctrl = $parts -contains 'Ctrl'; $alt = $parts -contains 'Alt'; $shift = $parts -contains 'Shift'; $win = $parts -contains 'Win'
    $main = @($parts | Where-Object { $_ -notin @('Ctrl','Alt','Shift','Win') })
    if ($main.Count -ne 1) { Stop-Hu "按键格式示例: Enter / Ctrl+A / Ctrl+Shift+S。收到: $Chord" }
    $name = $main[0]
    $map = @{ Enter=0x0D; Escape=0x1B; Esc=0x1B; Tab=0x09; Backspace=0x08; Delete=0x2E; Space=0x20
        Left=0x25; Up=0x26; Right=0x27; Down=0x28; Home=0x24; End=0x23; PageUp=0x21; PageDown=0x22
        F1=0x70; F2=0x71; F3=0x72; F4=0x73; F5=0x74; F6=0x75; F7=0x76; F8=0x77; F9=0x78; F10=0x79; F11=0x7A; F12=0x7B }
    if ($map.ContainsKey($name)) { $vk = $map[$name] }
    elseif ($name.Length -eq 1) { $vk = [int][char]$name.ToUpperInvariant() }
    else { Stop-Hu "未知按键: $name" }
    return [pscustomobject]@{ Vk = [uint16]$vk; Ctrl = $ctrl; Alt = $alt; Shift = $shift; Win = $win; Name = $name }
}

function Show-Usage {
@'
win-use-master — Windows 原生 app 的分层操控与可复现取证

读取（不抢焦点）:
  win.ps1 windows [关键词] [--all]
  win.ps1 see <hwnd|pid|owner> [path]          # 也接受 --out path，但 pwsh -File 下只能用位置参数
  win.ps1 shot <hwnd|owner> <path>
  win.ps1 shotfg <hwnd|owner> <path>          # 后台空图才短暂借焦点
  win.ps1 screen <path> [--window <target>] [--region x y w h]   # 桌面合成截图，交叉验证 PrintWindow
  win.ps1 uia <hwnd|pid|owner>
  win.ps1 uiaread <hwnd|pid|owner> [名称或 AutomationId 过滤]
  win.ps1 idle | frontmost

语义写入（通常不抢焦点）:
  win.ps1 uiaset <target> <eN|first> <text> [@uia.json]
  win.ps1 invoke <target> <eN> [@uia.json]

坐标写入（会短暂借焦点，默认先等用户空闲）:
  win.ps1 clickin <target> <x> <y> [@shot.png] [shot out.png] [--dry]
  win.ps1 hoverin <target> <x> <y> [@shot.png] [holdms] [shot out.png]
  win.ps1 scrollin <target> <x> <y> <delta> [steps] [--horizontal]
  win.ps1 type <target> <text> [--replace]
  win.ps1 key <target> <Enter|Ctrl+A|Ctrl+Shift+S> [--force]
  win.ps1 op <target> <x> <y> <text> [@shot.png] [--replace] [shot out.png]

应用与状态:
  win.ps1 open <显示名|进程名|exe路径> [--cdp port] [--relaunch] [--background] [--dry]
  win.ps1 hud [毫秒] [文案] [corner|glow|plain]
  probe.ps1 <显示名|进程名|exe路径>
  node cdp.js <port> list|snapshot|find|wait|mouse|insert|press|shot|eval|act

坐标：≤1 是归一化；>1 是窗口内物理像素；追加 @截图 使用图上像素；也可 eN@uia.json。
screen 是桌面合成截图（含遮挡物/通知），只用于交叉验证与全屏取证；--region 用虚拟屏幕物理像素。
open --background 请求首个窗口不激活（best effort），并回读前台是否被抢。
退出码：0 成功；1 失败；2 被安全闸拒绝或结果未知。退出码 2 绝不能当成功。
'@
}

try {
switch ($Command.ToLowerInvariant()) {
    { $_ -in @('help', '-h', '--help') } { Show-Usage; break }

    'windows' {
        $all = $CommandArgs -contains '--all'
        $filter = @($CommandArgs | Where-Object { $_ -ne '--all' } | Select-Object -First 1)
        $hidden = 0
        foreach ($w in (Get-HuWindows | Sort-Object Owner, Hwnd)) {
            if ($filter.Count -and
                $w.Owner.IndexOf($filter[0], [StringComparison]::OrdinalIgnoreCase) -lt 0 -and
                $w.Title.IndexOf($filter[0], [StringComparison]::OrdinalIgnoreCase) -lt 0) { continue }
            if (-not $all -and (Test-JunkWindow $w)) { $hidden++; continue }
            Write-Output (Format-Window $w)
        }
        if ($hidden) { Write-Output "（已隐藏 $hidden 个系统残留/浮层窗口；加 --all 显示）" }
        break
    }

    'shot' {
        if ($CommandArgs.Count -lt 2) { Stop-Hu '用法: win.ps1 shot <hwnd|owner> <路径>' }
        $w = Resolve-HuWindow $CommandArgs[0]
        $result = Invoke-BackgroundShot $w $CommandArgs[1]
        $recovery = if ($null -ne $result.RecoveredFrom) { " recovered-from=$(Format-Hwnd $result.RecoveredFrom.Hwnd)" } else { '' }
        Write-Output ("shot {0} -> {1} {2}x{3}px colors={4}{5} receipt={6}" -f (Format-Hwnd $result.Window.Hwnd), $result.Path, $result.Width, $result.Height, $result.Colors, $recovery, $result.Sidecar)
        if ($result.Colors -lt 6) { Write-Output (Get-BlankFrameHint $result $result.Window) }
        break
    }

    'screen' {
        if (-not $CommandArgs.Count -or $CommandArgs[0].StartsWith('--')) { Stop-Hu '用法: win.ps1 screen <路径> [--window <hwnd|owner>] [--region <x> <y> <w> <h>]' }
        $windowIndex = [Array]::IndexOf($CommandArgs, '--window')
        $regionIndex = [Array]::IndexOf($CommandArgs, '--region')
        if ($windowIndex -ge 0 -and $regionIndex -ge 0) { Stop-Hu '--window 与 --region 只能选一个。' }
        $w = $null; $region = $null
        if ($windowIndex -ge 0) {
            if ($windowIndex + 1 -ge $CommandArgs.Count) { Stop-Hu '--window 需要 <hwnd|owner>。' }
            $w = Resolve-HuWindow $CommandArgs[$windowIndex + 1]
        } elseif ($regionIndex -ge 0) {
            if ($regionIndex + 4 -ge $CommandArgs.Count) { Stop-Hu '--region 需要 <x> <y> <w> <h>，单位是虚拟屏幕物理像素。' }
            $numbers = foreach ($offset in 1..4) {
                $v = 0
                if (-not [int]::TryParse($CommandArgs[$regionIndex + $offset], [ref]$v)) { Stop-Hu "--region 参数必须是整数，收到: $($CommandArgs[$regionIndex + $offset])" }
                $v
            }
            $region = [ordered]@{ X = $numbers[0]; Y = $numbers[1]; W = $numbers[2]; H = $numbers[3] }
        }
        $result = Invoke-ScreenShot $CommandArgs[0] $w $region
        $clipNote = if ($result.Clipped) { ' clipped=true（区域超出屏幕已裁剪，不要用作 @坐标参考）' } else { '' }
        Write-Output ("screen -> {0} {1}x{2}px colors={3} region={4},{5} {1}x{2}{6} receipt={7}" -f $result.Path, $result.Width, $result.Height, $result.Colors, $result.Left, $result.Top, $clipNote, $result.Sidecar)
        if ($null -ne $w) {
            $occ = $result.Occlusion
            Write-Output "窗口: $(Format-Window $w)"
            if ($occ.blocked -gt 0) {
                Write-Output "⚠️ 目标有 $($occ.blocked)/$($occ.samples) 个采样点被「$($occ.blockers -join '」「')」盖住；图中这些区域是遮挡物，不是目标内容。"
            } else { Write-Output "遮挡采样 $($occ.samples)/$($occ.samples) 全部命中目标；此图可作为 PrintWindow 结果是否陈旧的交叉验证基准。" }
        }
        if ($result.Colors -lt 6) { Write-Output 'effect=unverifiable ⚠️ 图像接近纯色；可能是受保护内容、独占全屏或远程会话断开。' }
        Write-Output '说明: 桌面合成截图包含区域内一切可见内容（通知、其它窗口、可捕获的 HUD），公开前先脱敏。'
        break
    }

    'see' {
        if (-not $CommandArgs.Count) { Stop-Hu '用法: win.ps1 see <hwnd|pid|owner> [路径 | --out 路径]' }
        $w = Resolve-HuWindow $CommandArgs[0]
        # Positional path is the portable form. `--out` only works for in-process
        # `& win.ps1` calls: under `pwsh -File` the host binds `--out` as the
        # ambiguous common parameter prefix -Out(Variable|Buffer) before the
        # script runs, so it cannot be repaired here.
        $outIndex = [Array]::IndexOf($CommandArgs, '--out')
        $out = if ($outIndex -ge 0 -and $outIndex + 1 -lt $CommandArgs.Count) { Get-AbsolutePath $CommandArgs[$outIndex + 1] }
               elseif ($CommandArgs.Count -ge 2 -and -not $CommandArgs[1].StartsWith('--')) { Get-AbsolutePath $CommandArgs[1] }
               else { New-TempPng "see-$($w.Pid)" }
        $raw = New-TempPng "see-raw-$($w.Pid)"
        try {
            $shot = Invoke-BackgroundShot $w $raw -NoReceipt
            $w = $shot.Window
            Ensure-Parent $out
            [HuWin]::ResizePng($raw, $out, 1400) | Out-Null
            $img = [Drawing.Image]::FromFile($out)
            try { $ow = $img.Width; $oh = $img.Height } finally { $img.Dispose() }
            $receipt = New-Receipt $w $out $ow $oh ([HuWin]::ColorCount($out,160)) ($shot.Receipt.method + '+downsample')
            if ($null -ne $shot.FrameColors) { $receipt['frameColorBuckets'] = $shot.FrameColors }
            if ($null -ne $shot.RecoveredFrom) {
                $receipt['recoveredFrom'] = @{ hwnd = Format-Hwnd $shot.RecoveredFrom.Hwnd; pid = $shot.RecoveredFrom.Pid; owner = $shot.RecoveredFrom.Owner }
            }
            $sidecar = Save-Receipt $receipt $out
            $elements = @(Get-UiaElements $w)
            $mapPath = $out + '.uia.json'
            Save-UiaMap $w $elements $mapPath $out
            Write-Output "截图: $out ${ow}x${oh}px（图上坐标可直接配 @$out 使用）"
            Write-Output "窗口: $(Format-Window $w) receipt=$sidecar"
            if ($shot.Colors -lt 6) { Write-Output (Get-BlankFrameHint $shot $w $elements) }
            if (-not $elements.Count) { Write-Output 'UIA 元素表: 无。可能 app 不暴露、窗口在其它虚拟桌面，或 Chromium 树断开；改 CDP/坐标。' }
            else {
                Write-Output "UIA 元素表 $($elements.Count) 个，map=$mapPath（引用示例: $($elements[0].Ref)@$mapPath）："
                $elements | ForEach-Object { Write-Output ('  ' + (Format-UiaElement $_)) }
            }
        } finally {
            if (Test-Path -LiteralPath $raw) { [IO.File]::Delete($raw) }
        }
        break
    }

    'uia' {
        if (-not $CommandArgs.Count) { Stop-Hu '用法: win.ps1 uia <hwnd|pid|owner>' }
        $w = Resolve-HuWindow $CommandArgs[0]
        $first = @(Get-UiaElements $w)
        Start-Sleep -Milliseconds 250
        $elements = @(Get-UiaElements $w)
        Write-Output "UIA window=$(Format-Hwnd $w.Hwnd) pid=$($w.Pid) elements=$($elements.Count) first-pass=$($first.Count)"
        $elements | ForEach-Object { Write-Output (Format-UiaElement $_) }
        if (-not $elements.Count) { Write-Output '→ L1 暂不可用：Chromium 系走 CDP，其它走 L2 坐标。' }
        else { Write-Output '→ L1 有希望，但 SetValue/Invoke 返回成功仍须截图或副作用验证。' }
        break
    }

    'uiaread' {
        if (-not $CommandArgs.Count) { Stop-Hu '用法: win.ps1 uiaread <hwnd|pid|owner> [名称或 AutomationId 过滤]' }
        $w = Resolve-HuWindow $CommandArgs[0]
        $filter = if ($CommandArgs.Count -gt 1) { [string]$CommandArgs[1] } else { '' }
        $elements = @(Get-UiaReadableElements $w)
        if ($filter) {
            $elements = @($elements | Where-Object {
                $_.Name.IndexOf($filter, [StringComparison]::OrdinalIgnoreCase) -ge 0 -or
                $_.AutomationId.IndexOf($filter, [StringComparison]::OrdinalIgnoreCase) -ge 0 -or
                $_.Value.IndexOf($filter, [StringComparison]::OrdinalIgnoreCase) -ge 0
            })
        }
        Write-Output "UIA read window=$(Format-Hwnd $w.Hwnd) pid=$($w.Pid) elements=$($elements.Count) filter=$(if($filter){'"'+$filter+'"'}else{'<none>'})"
        $elements | ForEach-Object { Write-Output (Format-UiaReadableElement $_) }
        if (-not $elements.Count) { Write-Output '→ 没有读到匹配的 Text/Document/Edit/Status/Header；改用截图或 app 自有接口。' }
        break
    }

    'uiaset' {
        if ($CommandArgs.Count -lt 3) { Stop-Hu '用法: win.ps1 uiaset <target> <eN|first> <文本> [@uia.json]' }
        $w = Resolve-HuWindow $CommandArgs[0]
        $map = Get-ReferenceToken ($CommandArgs | Select-Object -Skip 3)
        $spec = Get-UiaReferenceSpec $CommandArgs[1] $map
        $beforeShot = New-TempPng 'uiaset-before'; $afterShot = New-TempPng 'uiaset-after'
        try {
            $null = Try-VerificationShot $w $beforeShot
            $reply = Invoke-UiaWorker $w -Mode set -Reference $CommandArgs[1] -Spec $spec -Text $CommandArgs[2] -Limit 300
            if ($reply.TimedOut) {
                $null = Try-VerificationShot $w $afterShot
                $actionEvidence = [ordered]@{
                    layer = 'L1'; kind = 'uiaset'; pattern = 'unknown-timeout'; recordedAt = [DateTimeOffset]::Now.ToString('o')
                    target = [ordered]@{ ref = $CommandArgs[1]; automationId = $(if($spec){$spec.automationId}else{''}); controlType = $(if($spec){$spec.controlType}else{''}) }
                    request = [ordered]@{ textLength = $CommandArgs[2].Length }
                    worker = [ordered]@{ timedOut = $true; deadlineMilliseconds = $script:UiaTimeoutMilliseconds }
                    focus = [ordered]@{ borrowed = $false; seconds = 0 }
                }
                Write-VerificationReport $w $beforeShot $afterShot 0.5 0.5 -ActionEvidence $actionEvidence -EffectOverride unknown
                Stop-Hu 'effect=unknown: UIA SetValue 超时，辅助进程已终止；动作可能已发生。不要自动重试，先用 uiaread 或最终副作用核对。' 2
            }
            if ($reply.ExitCode -ne 0 -or $null -eq $reply.Result -or -not $reply.Result.ok) {
                if ($reply.Result -and ($reply.Result.PSObject.Properties.Name -contains 'refused') -and $reply.Result.refused) {
                    Stop-Hu ("refused: UIA 没有写入（" + $reply.Error + '）。') 2
                }
                Stop-Hu ("effect=unknown: UIA worker 异常（" + $reply.Error + '）；动作可能已发生，不要自动重试。') 2
            }
            $item = $reply.Result.item
            $null = Try-VerificationShot $w $afterShot
            Write-Output "uiaset $($item.ref) len=$($CommandArgs[2].Length) readback-len=$($reply.Result.afterLength)（隔离 worker，未借焦点）"
            if ($reply.Result.matchesRequest -and $reply.Result.changed) { $readback = 'matched-changed'; Write-Output 'effect=partial UIA 已读回新值；仍要检查应用状态指示器或最终副作用。' }
            elseif (-not $reply.Result.changed) { $readback = 'unchanged'; Write-Output 'effect=suspected_noop UIA 返回但读回没变；改 CDP insert 或 op。' }
            else { $readback = 'changed-not-equal'; Write-Output 'effect=unverifiable 值发生变化但与目标不完全一致；截图复核。' }
            $textInkX = [double]$item.cx - [double]$item.width / 2 + [Math]::Min(40, [double]$item.width / 4)
            # A Document fills the window; its first line sits near the top, so the
            # pixel check must look there rather than at the (usually empty) centre.
            $textInkY = if ([string]$item.controlType -eq 'Document') { [double]$item.cy - [double]$item.height / 2 + [Math]::Min(40, [double]$item.height / 4) } else { [double]$item.cy }
            $actionEvidence = [ordered]@{
                layer = 'L1'; kind = 'uiaset'; pattern = 'ValuePattern'; recordedAt = [DateTimeOffset]::Now.ToString('o')
                target = [ordered]@{ ref = $item.ref; automationId = $item.automationId; controlType = $item.controlType }
                request = [ordered]@{ textLength = $CommandArgs[2].Length }
                semanticReadback = $readback
                worker = [ordered]@{ isolated = $true; deadlineMilliseconds = $script:UiaTimeoutMilliseconds }
                focus = [ordered]@{ borrowed = $false; seconds = 0 }
            }
            Write-VerificationReport $w $beforeShot $afterShot ($textInkX/[double]$w.W) ($textInkY/[double]$w.H) -ActionEvidence $actionEvidence
            if (-not (Test-Path -LiteralPath $afterShot)) { Stop-Hu 'effect=unknown: UIA 值可能已写入，但动作后截图失败。不要自动重试；先检查读回与最终副作用。' 2 }
        } finally {
            if (Test-Path -LiteralPath $beforeShot) { [IO.File]::Delete($beforeShot) }
        }
        break
    }

    'invoke' {
        if ($CommandArgs.Count -lt 2) { Stop-Hu '用法: win.ps1 invoke <target> <eN> [@uia.json]' }
        $w = Resolve-HuWindow $CommandArgs[0]
        $map = Get-ReferenceToken ($CommandArgs | Select-Object -Skip 2)
        $spec = Get-UiaReferenceSpec $CommandArgs[1] $map
        $beforeShot = New-TempPng 'invoke-before'; $afterShot = New-TempPng 'invoke-after'
        try {
            $null = Try-VerificationShot $w $beforeShot
            $reply = Invoke-UiaWorker $w -Mode invoke -Reference $CommandArgs[1] -Spec $spec -Limit 300
            if ($reply.TimedOut) {
                $null = Try-VerificationShot $w $afterShot
                $actionEvidence = [ordered]@{
                    layer = 'L1'; kind = 'invoke'; pattern = 'unknown-timeout'; recordedAt = [DateTimeOffset]::Now.ToString('o')
                    target = [ordered]@{ ref = $CommandArgs[1]; automationId = $(if($spec){$spec.automationId}else{''}); controlType = $(if($spec){$spec.controlType}else{''}) }
                    worker = [ordered]@{ timedOut = $true; deadlineMilliseconds = $script:UiaTimeoutMilliseconds }
                    focus = [ordered]@{ borrowed = $false; seconds = 0 }
                }
                Write-VerificationReport $w $beforeShot $afterShot 0.5 0.5 -Semantic -ActionEvidence $actionEvidence -EffectOverride unknown
                Stop-Hu 'effect=unknown: UIA action 超时，辅助进程已终止；动作可能已发生。不要自动重试，先读取最终副作用。' 2
            }
            if ($reply.ExitCode -ne 0 -or $null -eq $reply.Result -or -not $reply.Result.ok) {
                if ($reply.Result -and ($reply.Result.PSObject.Properties.Name -contains 'refused') -and $reply.Result.refused) {
                    Stop-Hu ("refused: UIA 没有执行（" + $reply.Error + '）。') 2
                }
                Stop-Hu ("effect=unknown: UIA worker 异常（" + $reply.Error + '）；动作可能已发生，不要自动重试。') 2
            }
            $item = $reply.Result.item; $used = [string]$reply.Result.pattern
            Start-Sleep -Milliseconds 300
            $null = Try-VerificationShot $w $afterShot
            Write-Output "invoke $($item.ref) via $used（隔离 worker，未借焦点）"
            $actionEvidence = [ordered]@{
                layer = 'L1'; kind = 'invoke'; pattern = $used; recordedAt = [DateTimeOffset]::Now.ToString('o')
                target = [ordered]@{ ref = $item.ref; automationId = $item.automationId; controlType = $item.controlType }
                worker = [ordered]@{ isolated = $true; deadlineMilliseconds = $script:UiaTimeoutMilliseconds }
                focus = [ordered]@{ borrowed = $false; seconds = 0 }
            }
            Write-VerificationReport $w $beforeShot $afterShot ([double]$item.cx/[double]$w.W) ([double]$item.cy/[double]$w.H) -Semantic -ActionEvidence $actionEvidence
            Write-Output 'pattern 返回成功不等于业务状态已生效；继续读取最终副作用。'
            if (-not (Test-Path -LiteralPath $afterShot)) { Stop-Hu 'effect=unknown: UIA action 可能已执行，但动作后截图失败。不要自动重试；先检查最终副作用。' 2 }
        } finally {
            if (Test-Path -LiteralPath $beforeShot) { [IO.File]::Delete($beforeShot) }
        }
        break
    }

    'shotfg' {
        if ($CommandArgs.Count -lt 2) { Stop-Hu '用法: win.ps1 shotfg <target> <路径>' }
        $w = Resolve-HuWindow $CommandArgs[0]
        $first = Invoke-BackgroundShot $w $CommandArgs[1]
        if ($first.Colors -ge 6) {
            Write-Output "截图: $($first.Path)；后台直接截到，未动焦点。receipt=$($first.Sidecar)"
            break
        }
        # A hidden window has no surface to refresh; activating it would ShowWindow
        # on the user's behalf, which the focus gate refuses anyway.
        if (-not $w.Visible) { Stop-Hu (Get-BlankFrameHint $first $w) 2 }
        # Borrowing focus cannot add content to an empty editor. When the frame
        # rendered and UIA reads an empty Document/Edit with no non-empty sibling,
        # the uniform interior is the app's real state; keep the background image.
        if ($null -ne $first.FrameColors -and $first.FrameColors -ge 6) {
            $reply = Invoke-UiaWorker $w -Mode list -Limit 180
            if (-not $reply.TimedOut -and $reply.ExitCode -eq 0 -and $null -ne $reply.Result -and $reply.Result.ok) {
                $texts = @(@($reply.Result.items) | Where-Object { [string]$_.controlType -in @('Document', 'Edit') })
                $filled = @($texts | Where-Object { -not [string]::IsNullOrEmpty([string]$_.value) })
                if ($texts.Count -and -not $filled.Count) {
                    Write-Output "截图: $($first.Path)；内容区单色但窗口框已渲染（整帧 $($first.FrameColors) 桶），UIA 读到空的 $($texts[0].controlType)「$($texts[0].name)」。空文档借前台也不会有内容，未动焦点。receipt=$($first.Sidecar)"
                    break
                }
            }
        }
        if ($script:Dry) { Write-Output "dry: 后台图 colors=$($first.Colors) frame=$($first.FrameColors)，下一档会短暂借焦点。$(Get-GatePreview $w $null)"; break }
        $captureState = [pscustomobject]@{ Settled = $false }
        $timing = Invoke-WithBorrowedFocus $w {
            for ($attempt = 0; $attempt -lt 12; $attempt++) {
                Start-Sleep -Milliseconds 60
                $frameA = Invoke-BackgroundShot $w $CommandArgs[1]
                if ($frameA.Colors -lt 6) { continue }
                Start-Sleep -Milliseconds 60
                $frameB = Invoke-BackgroundShot $w $CommandArgs[1]
                if ($frameB.Colors -ge 6) { $captureState.Settled = $true; break }
            }
        } -HudText "$script:ToolName 正在截取「$($w.Owner)」"
        $colors = [HuWin]::ColorCount((Get-AbsolutePath $CommandArgs[1]),160)
        Write-Output ("后台近空图，{0}；stable={1} colors={2} path={3}" -f (Format-FocusSummary $timing),$captureState.Settled,$colors,(Get-AbsolutePath $CommandArgs[1]))
        if ($colors -lt 6) {
            $cdpPort = Find-HuCdpPort $w
            $route = if ($null -ne $cdpPort) { "已发现 CDP $cdpPort：node `"$PSScriptRoot\cdp.js`" $cdpPort shot auto <路径>" } else { 'Chromium 系先用 probe 查 CDP' }
            Write-Output "effect=unverifiable 借焦点后仍接近纯色；可能禁止捕获/硬件表面。$route。"
        }
        break
    }

    'clickin' {
        if ($CommandArgs.Count -lt 3) { Stop-Hu '用法: win.ps1 clickin <target> <x> <y> [@截图] [shot 路径] [--dry]' }
        $w = Resolve-HuWindow $CommandArgs[0]
        $ref = Get-ReferenceToken ($CommandArgs | Select-Object -Skip 3)
        $point = Resolve-Point $w $CommandArgs[1] $CommandArgs[2] $ref
        if ($script:Dry) { Write-Output "dry: clickin $(Format-Hwnd $w.Hwnd) $($point.Note) -> $($point.ScreenX),$($point.ScreenY)"; Write-Output (Get-GatePreview $w $point); break }
        $shotIndex = [Array]::IndexOf($CommandArgs, 'shot')
        $out = if ($shotIndex -ge 0 -and $shotIndex + 1 -lt $CommandArgs.Count) { $CommandArgs[$shotIndex + 1] } else { New-TempPng 'click-after' }
        $before = New-TempPng 'click-before'
        try {
            $null = Invoke-BackgroundShot $w $before -NoReceipt
            $timing = Invoke-WithBorrowedFocus $w {
                Assert-PointTargetsWindow $w $point
                if ([HuWin]::MouseClick($point.ScreenX, $point.ScreenY, $false) -lt 2) { Stop-Hu 'effect=unknown: SendInput 没有完整发送鼠标按下/抬起。不要自动重试。' 2 }
            }
            Start-Sleep -Milliseconds 300
            $capture = Invoke-BackgroundShot $w $out -AfterAction
            Write-Output "clicked $($point.Note)；$(Format-FocusSummary $timing)。"
            $report = [HuWin]::DiffReport($before, (Get-AbsolutePath $out), $point.X / [double]$w.W, $point.Y / [double]$w.H)
            Write-Output $report
            $actionEvidence = [ordered]@{
                layer = 'L2'; kind = 'click'; recordedAt = [DateTimeOffset]::Now.ToString('o')
                target = [ordered]@{ windowX = $point.X; windowY = $point.Y; normalizedX = [Math]::Round($point.X/[double]$w.W,6); normalizedY = [Math]::Round($point.Y/[double]$w.H,6) }
                focus = [ordered]@{ borrowed = $timing.Borrowed; seconds = [Math]::Round($timing.FocusSeconds,3); actionSeconds = [Math]::Round($timing.ActionSeconds,3); waitedForUserSeconds = [Math]::Round($timing.WaitedSeconds,3) }
            }
            Add-ActionEvidenceToReceipt $capture.Receipt $before $report $actionEvidence
            $sidecar = Save-Receipt $capture.Receipt $capture.Path
            Write-Output "after: $(Get-AbsolutePath $out) receipt=$sidecar"
        } finally { if (Test-Path -LiteralPath $before) { [IO.File]::Delete($before) } }
        break
    }

    'hoverin' {
        if ($CommandArgs.Count -lt 3) { Stop-Hu '用法: win.ps1 hoverin <target> <x> <y> [@截图] [holdms] [shot 路径]' }
        $w = Resolve-HuWindow $CommandArgs[0]
        $ref = Get-ReferenceToken ($CommandArgs | Select-Object -Skip 3)
        $point = Resolve-Point $w $CommandArgs[1] $CommandArgs[2] $ref
        $hold = 700
        foreach ($token in ($CommandArgs | Select-Object -Skip 3)) { $v=0; if ([int]::TryParse($token,[ref]$v)) { $hold=$v; break } }
        if ($hold -lt 0 -or $hold -gt 8000) { Stop-Hu 'holdms 必须在 0..8000；单次借焦点不能长时间占用用户屏幕。' 2 }
        $shotIndex = [Array]::IndexOf($CommandArgs, 'shot')
        $out = if ($shotIndex -ge 0 -and $shotIndex + 1 -lt $CommandArgs.Count) { $CommandArgs[$shotIndex + 1] } else { New-TempPng 'hover' }
        if ($script:Dry) { Write-Output "dry: hoverin $($point.Note) hold=${hold}ms shot=$(Get-AbsolutePath $out)"; Write-Output (Get-GatePreview $w $point); break }
        $captureState = [pscustomobject]@{ Result = $null }
        $timing = Invoke-WithBorrowedFocus $w {
            Assert-PointTargetsWindow $w $point
            if (-not [HuWin]::MouseMove($point.ScreenX,$point.ScreenY)) { Stop-Hu '无法移动鼠标；没有继续等待或截图。' 1 }
            Start-Sleep -Milliseconds $hold
            $captureState.Result = Invoke-BackgroundShot $w $out -AfterAction
        }
        $actionEvidence = [ordered]@{
            layer = 'L2'; kind = 'hover'; recordedAt = [DateTimeOffset]::Now.ToString('o')
            target = [ordered]@{ windowX = $point.X; windowY = $point.Y; normalizedX = [Math]::Round($point.X/[double]$w.W,6); normalizedY = [Math]::Round($point.Y/[double]$w.H,6) }
            request = [ordered]@{ holdMilliseconds = $hold }
            focus = [ordered]@{ borrowed = $timing.Borrowed; seconds = [Math]::Round($timing.FocusSeconds,3); actionSeconds = [Math]::Round($timing.ActionSeconds,3); waitedForUserSeconds = [Math]::Round($timing.WaitedSeconds,3) }
        }
        Add-ActionEvidenceToReceipt $captureState.Result.Receipt $null 'effect=unverifiable hover evidence has no before frame' $actionEvidence
        $sidecar = Save-Receipt $captureState.Result.Receipt $captureState.Result.Path
        Write-Output "hovered $($point.Note) hold=${hold}ms；$(Format-FocusSummary $timing)。证据: $(Get-AbsolutePath $out) receipt=$sidecar"
        break
    }

    'scrollin' {
        $horizontal = ($CommandArgs -contains '--horizontal') -or ($CommandArgs -contains '--dx')
        $scrollArgs = @($CommandArgs | Where-Object { $_ -notin @('--horizontal', '--dx') })
        if ($scrollArgs.Count -lt 4) { Stop-Hu '用法: win.ps1 scrollin <target> <x> <y> <delta> [steps] [--horizontal] [@截图]' }
        $w = Resolve-HuWindow $scrollArgs[0]
        $ref = Get-ReferenceToken ($scrollArgs | Select-Object -Skip 4)
        $point = Resolve-Point $w $scrollArgs[1] $scrollArgs[2] $ref
        $delta = [int]$scrollArgs[3]; $steps = if ($scrollArgs.Count -gt 4 -and $scrollArgs[4] -match '^-?\d+$') { [int]$scrollArgs[4] } else { 3 }
        $axis = if ($horizontal) { 'horizontal' } else { 'vertical' }
        if ($steps -eq 0) { Stop-Hu 'steps 不能为 0；没有滚动。' }
        if ([Math]::Abs([long]$steps) -gt 200) { Stop-Hu 'steps 绝对值不能超过 200；拆成多次并在每次之间验证状态。' 2 }
        if ($script:Dry) { Write-Output "dry: scrollin $($point.Note) axis=$axis delta=$delta x$steps"; Write-Output (Get-GatePreview $w $point); break }
        $before = New-TempPng 'scroll-before'; $after = New-TempPng 'scroll-after'
        try {
            $null = Try-VerificationShot $w $before
            $timing = Invoke-WithBorrowedFocus $w {
                Assert-PointTargetsWindow $w $point
                $expected = [Math]::Min([Math]::Abs([long]$steps), 1000)
                $sent = [HuWin]::MouseWheel($point.ScreenX,$point.ScreenY,$delta,$steps,$horizontal)
                if ($sent -lt $expected) { Stop-Hu "effect=unknown: 只发送了 $sent/$expected 个滚轮事件。不要自动重试。" 2 }
            }
            Start-Sleep -Milliseconds 300
            $null = Try-VerificationShot $w $after
            Write-Output "scrolled $($point.Note) axis=$axis delta=$delta x$steps；$(Format-FocusSummary $timing)。"
            $actionEvidence = [ordered]@{
                layer = 'L2'; kind = 'scroll'; recordedAt = [DateTimeOffset]::Now.ToString('o')
                target = [ordered]@{ windowX = $point.X; windowY = $point.Y; normalizedX = [Math]::Round($point.X/[double]$w.W,6); normalizedY = [Math]::Round($point.Y/[double]$w.H,6) }
                request = [ordered]@{ delta = $delta; steps = $steps; axis = $axis }
                focus = [ordered]@{ borrowed = $timing.Borrowed; seconds = [Math]::Round($timing.FocusSeconds,3); actionSeconds = [Math]::Round($timing.ActionSeconds,3); waitedForUserSeconds = [Math]::Round($timing.WaitedSeconds,3) }
            }
            Write-VerificationReport $w $before $after ($point.X/[double]$w.W) ($point.Y/[double]$w.H) -ActionEvidence $actionEvidence
            if (-not (Test-Path -LiteralPath $after)) { Stop-Hu 'effect=unknown: 滚动已发出，但动作后截图失败。不要自动重试。' 2 }
        } finally { if (Test-Path -LiteralPath $before) { [IO.File]::Delete($before) } }
        break
    }

    'type' {
        if ($CommandArgs.Count -lt 2) { Stop-Hu '用法: win.ps1 type <target> <文本> [--replace] [--dry]' }
        if ($CommandArgs[1].Length -gt 1000) { Stop-Hu 'L2 单次输入最多 1000 个 UTF-16 字符；长文本改用 CDP/UIA 或拆分并逐段验证。' 2 }
        $w = Resolve-HuWindow $CommandArgs[0]; $replace = $CommandArgs -contains '--replace'
        if ($script:Dry) { Write-Output "dry: type len=$($CommandArgs[1].Length) replace=$replace -> $(Format-Hwnd $w.Hwnd)"; Write-Output (Get-GatePreview $w $null); break }
        $before = New-TempPng 'type-before'; $after = New-TempPng 'type-after'
        try {
            $null = Try-VerificationShot $w $before
            $timing = Invoke-WithBorrowedFocus $w {
                if ($replace -and [HuWin]::SendKey(0x41,$true,$false,$false,$false) -lt 2) { Stop-Hu 'effect=unknown: Ctrl+A 未完整发送。不要自动重试。' 2 }
                $sent = [HuWin]::TypeUnicode($CommandArgs[1])
                if ($sent -lt $CommandArgs[1].Length * 2) { Stop-Hu "effect=unknown: SendInput 只发送了 $sent/$($CommandArgs[1].Length * 2) 个键盘事件。不要自动重试。" 2 }
            }
            Start-Sleep -Milliseconds 300
            $null = Try-VerificationShot $w $after
            Write-Output "typed $($CommandArgs[1].Length) chars；$(Format-FocusSummary $timing)。"
            $actionEvidence = [ordered]@{
                layer = 'L2'; kind = 'type'; recordedAt = [DateTimeOffset]::Now.ToString('o')
                request = [ordered]@{ textLength = $CommandArgs[1].Length; replace = $replace }
                focus = [ordered]@{ borrowed = $timing.Borrowed; seconds = [Math]::Round($timing.FocusSeconds,3); actionSeconds = [Math]::Round($timing.ActionSeconds,3); waitedForUserSeconds = [Math]::Round($timing.WaitedSeconds,3) }
            }
            Write-VerificationReport $w $before $after 0.5 0.5 -ActionEvidence $actionEvidence
            if (-not (Test-Path -LiteralPath $after)) { Stop-Hu 'effect=unknown: 输入已发出，但动作后截图失败。不要自动重试。' 2 }
        } finally { if (Test-Path -LiteralPath $before) { [IO.File]::Delete($before) } }
        break
    }

    'key' {
        if ($CommandArgs.Count -lt 2) { Stop-Hu '用法: win.ps1 key <target> <Enter|Ctrl+A|Ctrl+Shift+S> [--dry]' }
        $w = Resolve-HuWindow $CommandArgs[0]; $key = Parse-KeyChord $CommandArgs[1]
        if ((Test-ShellWindow $w) -and $key.Name -eq 'Enter' -and -not $script:Force) { Stop-Hu "refused: $($w.Owner) 是终端/IDE，Enter 等于执行命令。需用户明确授权后加 --force。" 2 }
        if ($script:Dry) { Write-Output "dry: key $($CommandArgs[1]) -> $(Format-Hwnd $w.Hwnd)"; Write-Output (Get-GatePreview $w $null); break }
        $before = New-TempPng 'key-before'; $after = New-TempPng 'key-after'
        try {
            $null = Try-VerificationShot $w $before
            $timing = Invoke-WithBorrowedFocus $w {
                if ([HuWin]::SendKey($key.Vk,$key.Ctrl,$key.Alt,$key.Shift,$key.Win) -lt 2) { Stop-Hu 'effect=unknown: 按键没有完整发送。不要自动重试。' 2 }
            }
            Start-Sleep -Milliseconds 300
            $null = Try-VerificationShot $w $after
            Write-Output "key $($CommandArgs[1])；$(Format-FocusSummary $timing)。"
            $actionEvidence = [ordered]@{
                layer = 'L2'; kind = 'key'; recordedAt = [DateTimeOffset]::Now.ToString('o')
                request = [ordered]@{ chord = $CommandArgs[1]; forceApproved = $script:Force }
                focus = [ordered]@{ borrowed = $timing.Borrowed; seconds = [Math]::Round($timing.FocusSeconds,3); actionSeconds = [Math]::Round($timing.ActionSeconds,3); waitedForUserSeconds = [Math]::Round($timing.WaitedSeconds,3) }
            }
            Write-VerificationReport $w $before $after 0.5 0.5 -ActionEvidence $actionEvidence
            if (-not (Test-Path -LiteralPath $after)) { Stop-Hu 'effect=unknown: 按键已发出，但动作后截图失败。不要自动重试。' 2 }
        } finally { if (Test-Path -LiteralPath $before) { [IO.File]::Delete($before) } }
        break
    }

    'op' {
        if ($CommandArgs.Count -lt 4) { Stop-Hu '用法: win.ps1 op <target> <x> <y> <文本> [@截图] [--replace] [shot 路径] [--dry]' }
        if ($CommandArgs[3].Length -gt 1000) { Stop-Hu 'L2 单次输入最多 1000 个 UTF-16 字符；长文本改用 CDP/UIA 或拆分并逐段验证。' 2 }
        $w = Resolve-HuWindow $CommandArgs[0]; $replace = $CommandArgs -contains '--replace'
        $ref = Get-ReferenceToken ($CommandArgs | Select-Object -Skip 4)
        $point = Resolve-Point $w $CommandArgs[1] $CommandArgs[2] $ref
        $sendIndex = [Array]::IndexOf($CommandArgs, 'send'); $sendPoint = $null
        if ($sendIndex -ge 0) {
            Stop-Hu 'refused: op 不执行发送/提交的最终点击；内容可填好，但按钮留给用户。--force 不绕过。' 2
        }
        $shotIndex = [Array]::IndexOf($CommandArgs, 'shot')
        $out = if ($shotIndex -ge 0 -and $shotIndex + 1 -lt $CommandArgs.Count) { $CommandArgs[$shotIndex+1] } else { New-TempPng 'op-after' }
        if ($script:Dry) {
            Write-Output "dry: op $(Format-Hwnd $w.Hwnd) click=$($point.Note) input-len=$($CommandArgs[3].Length) replace=$replace shot=$(Get-AbsolutePath $out)"
            Write-Output (Get-GatePreview $w $point); break
        }
        $before = New-TempPng 'op-before'
        try {
            $null = Invoke-BackgroundShot $w $before -NoReceipt
            $timing = Invoke-WithBorrowedFocus $w {
                Assert-PointTargetsWindow $w $point
                if ([HuWin]::MouseClick($point.ScreenX,$point.ScreenY,$false) -lt 2) { Stop-Hu 'effect=unknown: 输入区点击没有完整发送。不要自动重试。' 2 }
                Start-Sleep -Milliseconds 100
                if ($replace -and [HuWin]::SendKey(0x41,$true,$false,$false,$false) -lt 2) { Stop-Hu 'effect=unknown: Ctrl+A 未完整发送。不要自动重试。' 2 }
                $typed = [HuWin]::TypeUnicode($CommandArgs[3])
                if ($typed -lt $CommandArgs[3].Length * 2) { Stop-Hu "effect=unknown: 文本只发送了 $typed/$($CommandArgs[3].Length * 2) 个键盘事件。不要自动重试。" 2 }
                if ($null -ne $sendPoint) {
                    Start-Sleep -Milliseconds 120
                    Assert-PointTargetsWindow $w $sendPoint
                    if ([HuWin]::MouseClick($sendPoint.ScreenX,$sendPoint.ScreenY,$false) -lt 2) { Stop-Hu 'effect=unknown: 最终点击没有完整发送。不要自动重试。' 2 }
                }
            }
            Start-Sleep -Milliseconds 350
            $capture = Invoke-BackgroundShot $w $out -AfterAction
            Write-Output "op finished；$(Format-FocusSummary $timing)。"
            $report = [HuWin]::DiffReport($before,(Get-AbsolutePath $out),$point.VerifyX/[double]$w.W,$point.VerifyY/[double]$w.H)
            Write-Output $report
            $actionEvidence = [ordered]@{
                layer = 'L2'; kind = 'op'; recordedAt = [DateTimeOffset]::Now.ToString('o')
                target = [ordered]@{ windowX = $point.X; windowY = $point.Y; normalizedX = [Math]::Round($point.X/[double]$w.W,6); normalizedY = [Math]::Round($point.Y/[double]$w.H,6) }
                request = [ordered]@{ textLength = $CommandArgs[3].Length; replace = $replace; finalSubmit = $false }
                focus = [ordered]@{ borrowed = $timing.Borrowed; seconds = [Math]::Round($timing.FocusSeconds,3); actionSeconds = [Math]::Round($timing.ActionSeconds,3); waitedForUserSeconds = [Math]::Round($timing.WaitedSeconds,3) }
            }
            Add-ActionEvidenceToReceipt $capture.Receipt $before $report $actionEvidence
            $sidecar = Save-Receipt $capture.Receipt $capture.Path
            Write-Output "after: $(Get-AbsolutePath $out) receipt=$sidecar（差分只证明像素变化；最终仍看应用状态指示器/副作用）"
        } finally { if (Test-Path -LiteralPath $before) { [IO.File]::Delete($before) } }
        break
    }

    'idle' {
        $idle = [HuWin]::UserIdleSeconds(); $rawIdle = [HuWin]::IdleSeconds(); $fg = [HuWin]::ForegroundWindow().ToInt64(); $front = @((Get-HuWindows) | Where-Object { $_.Hwnd -eq $fg })
        $frontText = if ($front.Count) { "$($front[0].Owner) $(Format-Hwnd $fg) `"$($front[0].Title)`"" } else { Format-Hwnd $fg }
        $verdict = if ($idle -lt $script:IdleThresholdSeconds) { '🔴 用户在场；坐标写会先等，最多 15 秒' } else { '🟢 用户空闲；坐标写可进入借焦点流程' }
        $trail = if ($idle -ge 3599 -and $rawIdle -lt 10) { "；最近一次输入为本工具合成事件，原始空闲 $([Math]::Round($rawIdle,1))s" } else { '' }
        Write-Output ("用户键鼠空闲 {0:F1}s（阈值 {1:F0}s）{2} 前台: {3}`n{4}`n注：windows/shot/see/uia/CDP 等读操作不受此闸影响。" -f $idle,$script:IdleThresholdSeconds,$trail,$frontText,$verdict)
        break
    }

    'frontmost' {
        $fg = [HuWin]::ForegroundWindow().ToInt64(); $front = @((Get-HuWindows) | Where-Object { $_.Hwnd -eq $fg })
        if ($front.Count) { Write-Output (Format-Window $front[0]) } else { Write-Output (Format-Hwnd $fg) }
        break
    }

    'hud' {
        $ms = if ($CommandArgs.Count -and $CommandArgs[0] -match '^\d+$') { [int]$CommandArgs[0] } else { 1400 }
        $text = if ($CommandArgs.Count -gt 1) { $CommandArgs[1] } else { "$script:ToolName 正在接管屏幕" }
        $style = if ($CommandArgs.Count -gt 2) { $CommandArgs[2] } else { '' }
        $hud = Show-HuHud $ms $text $style
        if ($hud.Shown) {
            Write-Output "HUD displayed ${ms}ms style=$($hud.Style) capturable=$($hud.Capturable)"
        } else { Write-Output 'HUD disabled by WIN_USE_MASTER_HUD=0' }
        break
    }

    'open' {
        if (-not $CommandArgs.Count -or $CommandArgs[0].StartsWith('--')) { Stop-Hu '用法: win.ps1 open <显示名|进程名|exe路径> [--cdp 端口] [--relaunch] [--background] [--dry]' }
        $name = $CommandArgs[0]; $cdpIndex = [Array]::IndexOf($CommandArgs,'--cdp'); $port = $null
        if ($cdpIndex -ge 0 -and $cdpIndex + 1 -lt $CommandArgs.Count) { $port = [int]$CommandArgs[$cdpIndex+1] }
        $relaunch = $CommandArgs -contains '--relaunch'
        $background = ($CommandArgs -contains '--background') -or ($CommandArgs -contains '--bg')
        $path = $null; $appId = $null
        if (Test-Path -LiteralPath $name) { $path = (Get-Item -LiteralPath $name).FullName }
        if (-not $path) {
            $cmd = Get-Command $name,$("$name.exe") -CommandType Application -ErrorAction SilentlyContinue | Select-Object -First 1
            if ($cmd) { $path = $cmd.Source }
        }
        # Localized Store/UWP display names must resolve through their AUMID.
        # A visible UWP window is often owned by the generic
        # ApplicationFrameHost.exe; launching that host path is the wrong app.
        if (-not $path) {
            try {
                $startMatches = @(Get-StartApps | Where-Object { $_.Name -eq $name -or $_.Name -like "*$name*" })
                $exactStart = @($startMatches | Where-Object Name -EQ $name)
                if ($exactStart.Count -eq 1) { $appId = [string]$exactStart[0].AppID }
                elseif ($exactStart.Count -gt 1) { Stop-Hu "开始菜单里有多个同名 app「$name」；请提供 exe 路径或更精确名称。" 2 }
                elseif ($startMatches.Count -eq 1) { $appId = [string]$startMatches[0].AppID }
                elseif ($startMatches.Count -gt 1) { Stop-Hu "开始菜单名称「$name」匹配多个 app；请使用完整显示名。" 2 }
            } catch {
                if ($_.Exception -is [Management.Automation.ExitException]) { throw }
            }
        }
        $running = @(Get-Process -ErrorAction SilentlyContinue | Where-Object {
            $_.ProcessName -eq [IO.Path]::GetFileNameWithoutExtension($name) -or $_.MainWindowTitle -like "*$name*"
        } | Sort-Object @{Expression={ $_.MainWindowHandle -ne 0 };Descending=$true})
        if (-not $path -and -not $appId -and $running.Count) {
            $specificRunning = @($running | Where-Object { $_.ProcessName -notin @('ApplicationFrameHost','explorer','ShellExperienceHost','StartMenuExperienceHost') })
            if ($specificRunning.Count) { try { $path = $specificRunning[0].Path } catch {} }
        }
        if ($path) {
            $running = @($running | Where-Object {
                try { $_.Path -and $_.Path -ieq $path } catch { $false }
            })
        }
        if (-not $path -and -not $appId) { Stop-Hu "找不到 app「$name」。请给 exe/lnk 绝对路径、进程名或开始菜单显示名。" }

        function Get-CdpInfo([int]$Port) {
            try {
                $r = Invoke-RestMethod -Uri "http://127.0.0.1:$Port/json/version" -TimeoutSec 2 -Proxy $null
                if ($r.webSocketDebuggerUrl) { return $r }
            } catch { }
            return $null
        }
        function Get-CdpPortOwnership([int]$Port, [string]$ExePath, [object[]]$KnownProcesses) {
            try {
                $owners = @(Get-NetTCPConnection -State Listen -LocalPort $Port -ErrorAction Stop |
                    Select-Object -ExpandProperty OwningProcess -Unique | ForEach-Object { [int]$_ })
            } catch {
                return [pscustomobject]@{ Known = $false; Owned = $false; Owners = @(); Reason = $_.Exception.Message }
            }
            if (-not $owners.Count) {
                return [pscustomobject]@{ Known = $false; Owned = $false; Owners = @(); Reason = 'CDP 响应存在，但找不到对应监听 socket' }
            }

            $roots = [Collections.Generic.HashSet[int]]::new()
            foreach ($proc in @($KnownProcesses)) { if ($proc -and -not $proc.HasExited) { [void]$roots.Add([int]$proc.Id) } }
            if ($ExePath) {
                foreach ($proc in @(Get-Process -ErrorAction SilentlyContinue)) {
                    try { if ($proc.Path -and $proc.Path -ieq $ExePath) { [void]$roots.Add([int]$proc.Id) } } catch { }
                }
            }

            foreach ($owner in $owners) {
                $current = [int]$owner
                $seen = [Collections.Generic.HashSet[int]]::new()
                for ($depth = 0; $depth -lt 24 -and $current -gt 0 -and $seen.Add($current); $depth++) {
                    if ($roots.Contains($current)) {
                        return [pscustomobject]@{ Known = $true; Owned = $true; Owners = $owners; Reason = "pid $owner 属于目标进程树" }
                    }
                    try { $row = Get-CimInstance -ClassName Win32_Process -Filter "ProcessId=$current" -ErrorAction Stop }
                    catch { $row = $null }
                    if (-not $row) { break }
                    if ($ExePath -and $row.ExecutablePath -and ([string]$row.ExecutablePath -ieq $ExePath)) {
                        return [pscustomobject]@{ Known = $true; Owned = $true; Owners = $owners; Reason = "pid $owner 的进程链命中目标 exe" }
                    }
                    $current = [int]$row.ParentProcessId
                }
            }
            return [pscustomobject]@{ Known = $true; Owned = $false; Owners = $owners; Reason = '监听进程不属于目标 exe/进程树' }
        }
        $existingCdp = if ($port) { Get-CdpInfo $port } else { $null }
        if ($existingCdp) {
            $ownership = Get-CdpPortOwnership $port $path $running
            if (-not $ownership.Known) { Stop-Hu "refused: 端口 $port 返回 CDP，但无法确认监听进程归属（$($ownership.Reason)）。不会把它当成目标 app。" 2 }
            if (-not $ownership.Owned) { Stop-Hu "refused: 端口 $port 已被其它 CDP 占用（owner pid=$($ownership.Owners -join ',')）。不会控制错误实例。" 2 }
            Write-Output "CDP: 127.0.0.1:$port 已通且归属目标（owner pid=$($ownership.Owners -join ',')）。下一步: node `"$PSScriptRoot\cdp.js`" $port list"
            break
        }
        if ($port -and $running.Count) {
            if (-not $relaunch) { Stop-Hu 'refused: app 正在运行而 CDP 未开启。带 --relaunch 会正常关闭并重启，可能影响未保存内容；确认后再执行。' 2 }
            if ($script:Dry) { Write-Output "dry: 将请求关闭 pid=$($running[0].Id)，随后以 --remote-debugging-port=$port 重启 $path"; break }
            foreach ($proc in $running) { if ($proc.MainWindowHandle -ne 0) { $proc.CloseMainWindow() | Out-Null } }
            $deadline = [DateTime]::UtcNow.AddSeconds(30)
            while (@($running | Where-Object { -not $_.HasExited }).Count -and [DateTime]::UtcNow -lt $deadline) { Start-Sleep -Milliseconds 200 }
            if (@($running | Where-Object { -not $_.HasExited }).Count) { Stop-Hu 'refused: app 30 秒内没有正常退出；可能有保存确认框。请用户处理，不会强杀。' 2 }
        }
        if ($background -and (-not $path -or [IO.Path]::GetExtension($path) -ne '.exe')) {
            Stop-Hu 'refused: --background 需要真实 exe 路径；开始菜单/UWP/.lnk 由 shell 接管启动，无法请求“不激活”。去掉 --background，或给出 exe 路径。' 2
        }
        if ($script:Dry) { Write-Output "dry: launch $(if($path){$path}else{"shell:AppsFolder\$appId"}) $(if($port){"--remote-debugging-port=$port"}) background=$background"; break }
        $previousForeground = [HuWin]::ForegroundWindow()
        $launched = $null
        if ($port) {
            if (-not $path -or [IO.Path]::GetExtension($path) -ne '.exe') { Stop-Hu '这个开始菜单/UWP app 无法从当前解析结果携带 CDP 参数启动；请提供真实 exe 路径。' 2 }
            $launched = Start-HuProcess $path "--remote-debugging-port=$port" -NoActivate:$background
            $deadline = [DateTime]::UtcNow.AddSeconds(20)
            $cdpInfo = $null
            while (-not $cdpInfo -and [DateTime]::UtcNow -lt $deadline) { Start-Sleep -Milliseconds 400; $cdpInfo = Get-CdpInfo $port }
            if (-not $cdpInfo) { Stop-Hu "app 已启动，但 20 秒内端口 $port 未出现 CDP。可能不是 Chromium、端口被策略禁用，或启动参数被 launcher 吃掉。" 2 }
            $ownership = Get-CdpPortOwnership $port $path @($launched)
            if (-not $ownership.Known -or -not $ownership.Owned) {
                Stop-Hu "effect=unknown: app 已启动，端口 $port 也返回 CDP，但无法证明二者属于同一实例（owner pid=$($ownership.Owners -join ',')；$($ownership.Reason)）。不会继续控制。" 2
            }
            Write-Output "CDP: 127.0.0.1:$port 已通且归属新实例（owner pid=$($ownership.Owners -join ',')）。下一步: node `"$PSScriptRoot\cdp.js`" $port list"
        } elseif ($path) {
            $launched = Start-HuProcess $path '' -NoActivate:$background
            if (-not $background) { Write-Output "已启动: $path pid=$($launched.Id)" }
        }
        else { Start-Process explorer.exe -ArgumentList "shell:AppsFolder\$appId" | Out-Null; Write-Output "已启动开始菜单应用: $name ($appId)" }
        if ($background -and $null -ne $launched) {
            # The no-activate request is advisory. Read the foreground back and say
            # exactly what happened instead of promising the user was not disturbed.
            $report = Get-HuLaunchReport $path ([int]$launched.Id) $previousForeground
            $windowText = if ($null -ne $report.Window) { Format-Window $report.Window } else { 'none（8 秒内未出现顶层窗口；可能是单实例转交、启动器或仍在加载）' }
            Write-Output "已后台启动: $path pid=$($launched.Id) foreground=$($report.Foreground)"
            Write-Output "窗口: $windowText"
            if ($report.ForegroundStolen) {
                $restoreText = if ($report.Restored) { "已在 $($report.RestoreAttempts) 次内把原前台还给用户" } else { '未能还原（原窗口已消失，或用户正在输入时系统拒绝了不带 Alt 解锁的 SetForegroundWindow）' }
                Write-HuWarning "⚠️ app 忽略了不激活请求并抢了前台；$restoreText。该 app 的档案应记录“--background 不生效”；它的窗口现在可能不在前台，读操作照常用 shot/CDP。"
            } elseif ($null -ne $report.Window) {
                Write-Output "前台未被打扰；可直接 win.ps1 shot $(Format-Hwnd $report.Window.Hwnd) <路径> 后台取证。"
            }
        }
        break
    }

    default { Stop-Hu "未知命令: $Command`n运行 win.ps1 help 查看用法。" }
}
} catch {
    if ($_.Exception -is [Management.Automation.ExitException]) { throw }
    $where = if ($_.ScriptStackTrace) { "`n位置: " + $_.ScriptStackTrace } else { '' }
    Stop-Hu ("错误: " + $_.Exception.Message + $where) 1
}

# PowerShell does not reset $LASTEXITCODE after a successful in-process .ps1
# invocation. Set it explicitly, but do not `exit 0`: ExitException would cut
# off downstream pipeline consumers such as `win.ps1 windows | Where-Object`.
$global:LASTEXITCODE = 0
