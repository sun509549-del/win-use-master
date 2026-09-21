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
$script:RiskPolicy = $null
$CommandArgs = @($CommandArgs | Where-Object { $_ -notin @('--force', '--dry') })

function Stop-Hu {
    param([string] $Message, [int] $Code = 1)
    [Console]::Error.WriteLine($Message)
    exit $Code
}

function Write-HuWarning([string] $Message) {
    [Console]::Error.WriteLine($Message)
}

# doctor, cache management, cleanup planning and performance baselines run
# before Import-HuCore. Cache data never participates in write gates.
if ($Command -iin @('doctor','cache','cleanup','benchmark')) {
    if ($script:Force -or $script:Dry) { Stop-Hu "$Command 不接受 --force/--dry；不会把绕过类选项传入独立入口。" 2 }
    $entryName = switch ($Command.ToLowerInvariant()) {
        'doctor' { 'doctor.ps1' }
        'cache' { 'capability-cache.ps1' }
        'cleanup' { 'cleanup.ps1' }
        'benchmark' { 'benchmark.ps1' }
    }
    $entry = Join-Path $PSScriptRoot $entryName
    if (-not (Test-Path -LiteralPath $entry -PathType Leaf)) { Stop-Hu "$Command 独立入口缺失。" 1 }
    & $entry @CommandArgs
    exit $LASTEXITCODE
}

$riskPolicyCorePath = Join-Path $PSScriptRoot 'risk-policy-core.ps1'
if (-not (Test-Path -LiteralPath $riskPolicyCorePath -PathType Leaf)) { Stop-Hu 'refused: 高风险动作规则解释器不可用；没有执行。' 2 }
try { . $riskPolicyCorePath }
catch { Stop-Hu 'refused: 高风险动作规则解释器无法加载；没有执行。' 2 }

function Get-RiskPolicy {
    if ($script:RiskPolicy) { return $script:RiskPolicy }
    $path = Join-Path (Split-Path -Parent $PSScriptRoot) 'config\risk-actions.json'
    try { $policy = Import-WinUseRiskPolicy $path }
    catch { Stop-Hu 'refused: 高风险动作规则不可用或无效；没有执行。' 2 }
    $script:RiskPolicy = $policy
    return $script:RiskPolicy
}

function Find-BlockedActionRule([string] $Text) {
    $policy = Get-RiskPolicy
    try { return Find-WinUseBlockedTextRule $policy $Text }
    catch { Stop-Hu 'refused: 高风险动作规则匹配失败；没有执行。' 2 }
}

function Assert-SafeSemanticAction($Element, [string] $Layer, [switch] $ActionControlsOnly) {
    if ($null -eq $Element) { return }
    if ($ActionControlsOnly -and [string]$Element.controlType -notin @('Button','Hyperlink','MenuItem','CheckBox','RadioButton')) { return }
    $identity = @([string]$Element.name, [string]$Element.automationId, [string]$Element.className) -join ' '
    $rule = Find-BlockedActionRule $identity
    if ($rule) { Stop-Hu "refused: $Layer 命中高风险最终动作规则 $rule；没有执行。--force 不绕过。" 2 }
    if ([string]::IsNullOrWhiteSpace([string]$Element.name) -and
        [string]$Element.controlType -in @('Button','Hyperlink','MenuItem')) {
        Stop-Hu "refused: $Layer 的动作控件没有可核对标签；没有执行。--force 不绕过。" 2
    }
}

function Get-CanonicalKeyChord($Key) {
    $parts = [Collections.Generic.List[string]]::new()
    if ($Key.Ctrl) { $parts.Add('Ctrl') }
    if ($Key.Alt) { $parts.Add('Alt') }
    if ($Key.Shift) { $parts.Add('Shift') }
    if ($Key.Win) { $parts.Add('Win') }
    $parts.Add([string]$Key.Name)
    return $parts -join '+'
}

function Assert-SafeKeyChord($Key, [string] $Layer) {
    $canonical = Get-CanonicalKeyChord $Key
    if (@((Get-RiskPolicy).blockedKeyChords) -contains $canonical) {
        Stop-Hu "refused: $Layer 按键 $canonical 可能直接提交、保存或关闭；最终动作留给用户。--force 不绕过。" 2
    }
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
    $requirePrebuilt = [Environment]::GetEnvironmentVariable('WIN_USE_MASTER_REQUIRE_PREBUILT_HELPER') -eq '1'

    # A stale DLL is worse than a short one-time compile: it silently runs old
    # safety gates. Prefer source whenever it is newer.
    if ((Test-Path -LiteralPath $dll) -and
        (Get-Item -LiteralPath $dll).LastWriteTimeUtc -ge (Get-Item -LiteralPath $source).LastWriteTimeUtc) {
        try { Add-Type -Path $dll; return } catch {
            if ($requirePrebuilt) { Stop-Hu '预构建内核不可加载；benchmark 不会现场编译，请先运行 scripts/build.ps1。' 1 }
            Write-HuWarning "预编译内核加载失败，改为现场编译: $($_.Exception.Message)"
        }
    }

    if ($requirePrebuilt) { Stop-Hu '预构建内核缺失或过期；benchmark 不会现场编译，请先运行 scripts/build.ps1。' 1 }

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
        [int] $Limit = 300,
        [string] $ExactId = '',
        $Query = $null,
        [string] $Continuation = ''
    )
    $worker = Join-Path $PSScriptRoot 'uia-worker.ps1'
    if (-not (Test-Path -LiteralPath $worker -PathType Leaf)) { Stop-Hu "找不到 UIA worker: $worker" }
    $processStartTicks = 0L
    try { $processStartTicks = (Get-Process -Id $Window.Pid -ErrorAction Stop).StartTime.ToUniversalTime().Ticks } catch { }
    $request = [ordered]@{
        mode = $Mode; hwnd = [long]$Window.Hwnd; limit = $Limit
        window = [ordered]@{
            l = $Window.L; t = $Window.T; r = $Window.R; b = $Window.B
            pid = $Window.Pid; processStartTicks = $processStartTicks
        }
    }
    if ($Reference) { $request['reference'] = $Reference }
    if ($null -ne $Spec) { $request['spec'] = $Spec }
    if ($Mode -eq 'set') { $request['text'] = $Text }
    if ($ExactId) { $request['exactId'] = $ExactId }
    if ($null -ne $Query) { $request['query'] = $Query }
    if ($Continuation) { $request['continuation'] = $Continuation }

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

function Get-HuForegroundTransition([long] $Before, [long] $After, [long] $Target) {
    if ($After -eq $Before) {
        if ($After -eq $Target) { return 'target-already' }
        return 'unchanged'
    }
    if ($After -eq $Target) { return 'unexpected-target' }
    if ($Before -eq $Target) { return 'released-by-windows' }
    return 'changed-external'
}

function Format-Window($Window) {
    # Hidden windows (tray state, not-yet-shown editors, background dialogs) are
    # only listed with --all; calling them "current" would invite shot/screen/L2.
    $state = if ($Window.Iconic) { 'min' } elseif ($Window.Cloaked) { 'other-desktop/cloaked' } elseif (-not $Window.Visible) { 'hidden' } else { 'current' }
    $title = ([string]$Window.Title).Replace('"', '\"')
    return ('id={0} pid={1} owner="{2}" state={3} rect={4},{5} {6}x{7} class="{8}" title="{9}"' -f
        (Format-Hwnd $Window.Hwnd), $Window.Pid, $Window.Owner, $state,
        $Window.L, $Window.T, $Window.W, $Window.H, $Window.Cls, $title)
}

function Get-HuWindowState($Window) {
    if ($Window.Iconic) { return 'minimized' }
    if ($Window.Cloaked) { return 'cloaked' }
    if (-not $Window.Visible) { return 'hidden' }
    return 'current'
}

function ConvertTo-HuWindowRecord($Window, [bool] $Summary = $false) {
    return [pscustomobject][ordered]@{
        hwnd = Format-Hwnd $Window.Hwnd
        pid = [uint32]$Window.Pid
        owner = [string]$Window.Owner
        title = $(if ($Summary) { $null } else { [string]$Window.Title })
        className = [string]$Window.Cls
        state = Get-HuWindowState $Window
        rect = [pscustomobject][ordered]@{
            x = [int]$Window.L; y = [int]$Window.T
            width = [int]$Window.W; height = [int]$Window.H
        }
        flags = [pscustomobject][ordered]@{
            visible = [bool]$Window.Visible; minimized = [bool]$Window.Iconic
            maximized = [bool]$Window.Zoomed; cloaked = [bool]$Window.Cloaked
            toolWindow = [bool]$Window.Tool; hung = [bool]$Window.Hung
        }
    }
}

function Format-HuWindowSummary($Window) {
    $record = ConvertTo-HuWindowRecord $Window $true
    return ('id={0} pid={1} owner="{2}" state={3} rect={4},{5} {6}x{7} class="{8}" title=<redacted>' -f
        $record.hwnd, $record.pid, $record.owner, $record.state,
        $record.rect.x, $record.rect.y, $record.rect.width, $record.rect.height, $record.className)
}

function Get-HuTypeCounts([object[]] $Elements) {
    return @($Elements | Group-Object { [string]$_.ControlType } | Sort-Object Name | ForEach-Object {
        [pscustomobject][ordered]@{ controlType = [string]$_.Name; count = [int]$_.Count }
    })
}

function New-HuWindowsReport([object[]] $Windows, [int] $Hidden, [int] $Folded,
    [bool] $FilterApplied, [bool] $All, [bool] $Raw, [bool] $Summary) {
    return [pscustomobject][ordered]@{
        schema = 'win-use-master/windows-result-v1'
        observedAt = [DateTimeOffset]::Now.ToString('o')
        status = 'ok'
        privacy = [pscustomobject][ordered]@{
            mode = $(if ($Summary) { 'summary' } else { 'full' })
            collected = 'window-metadata'
            redactedFields = @(if ($Summary) { 'windows[].title' })
        }
        query = [pscustomobject][ordered]@{
            filterApplied = $FilterApplied; filterValueIncluded = $false
            all = $All; raw = $Raw
        }
        counts = [pscustomobject][ordered]@{
            returned = @($Windows).Count; hidden = $Hidden; folded = $Folded
        }
        windows = @($Windows | ForEach-Object { ConvertTo-HuWindowRecord $_ $Summary })
    }
}

function New-HuFrontmostReport([long] $Hwnd, $Window, [bool] $Summary) {
    $status = if ($Hwnd -eq 0) { 'none' } elseif ($null -eq $Window) { 'unlisted' } else { 'resolved' }
    return [pscustomobject][ordered]@{
        schema = 'win-use-master/frontmost-result-v1'
        observedAt = [DateTimeOffset]::Now.ToString('o')
        status = $status
        privacy = [pscustomobject][ordered]@{
            mode = $(if ($Summary) { 'summary' } else { 'full' })
            redactedFields = @(if ($Summary) { 'window.title' })
        }
        foregroundHwnd = $(if ($Hwnd -eq 0) { $null } else { Format-Hwnd $Hwnd })
        window = $(if ($null -eq $Window) { $null } else { ConvertTo-HuWindowRecord $Window $Summary })
    }
}

function New-HuIdleReport([double] $UserIdleSeconds, [double] $RawIdleSeconds,
    [long] $ForegroundHwnd, $ForegroundWindow, [bool] $Summary) {
    $known = $UserIdleSeconds -ge 0
    $rawKnown = $RawIdleSeconds -ge 0
    $presence = if (-not $known) { 'unknown' } elseif ($UserIdleSeconds -lt $script:IdleThresholdSeconds) { 'present' } else { 'idle' }
    $gate = if ($presence -eq 'unknown') { 'unknown' } elseif ($presence -eq 'present') { 'wait' } else { 'eligible' }
    $syntheticTrailApplied = $known -and $rawKnown -and $UserIdleSeconds -ge 3599 -and $RawIdleSeconds -lt 10
    return [pscustomobject][ordered]@{
        schema = 'win-use-master/idle-result-v1'
        observedAt = [DateTimeOffset]::Now.ToString('o')
        status = $(if ($known) { 'known' } else { 'unknown' })
        privacy = [pscustomobject][ordered]@{
            mode = $(if ($Summary) { 'summary' } else { 'full' })
            redactedFields = @(if ($Summary) { 'frontmost.window.title' })
        }
        idle = [pscustomobject][ordered]@{
            seconds = $(if ($known) { [Math]::Round($UserIdleSeconds, 3) } else { $null })
            rawSeconds = $(if ($rawKnown) { [Math]::Round($RawIdleSeconds, 3) } else { $null })
            thresholdSeconds = $script:IdleThresholdSeconds
            source = $(if (-not $known) { 'unknown' } elseif ($syntheticTrailApplied) { 'synthetic-input-trail' } else { 'system-last-input' })
        }
        presence = $presence
        coordinateGate = [pscustomobject][ordered]@{
            status = $gate; maximumWaitSeconds = $script:IdleWaitSeconds
        }
        frontmost = New-HuFrontmostReport $ForegroundHwnd $ForegroundWindow $Summary
        readCommandsAffected = $false
    }
}

function ConvertTo-HuUiaActionRecord($Element) {
    return [pscustomobject][ordered]@{
        ref = [string]$Element.Ref; controlType = [string]$Element.ControlType
        name = [string]$Element.Name; automationId = [string]$Element.AutomationId
        className = [string]$Element.ClassName; value = [string]$Element.Value
        screenRect = [pscustomobject][ordered]@{
            x = [double]$Element.X; y = [double]$Element.Y
            width = [double]$Element.Width; height = [double]$Element.Height
        }
        windowCenter = [pscustomobject][ordered]@{ x = [double]$Element.Cx; y = [double]$Element.Cy }
        enabled = [bool]$Element.Enabled; offscreen = [bool]$Element.Offscreen
        isPassword = [bool]$Element.IsPassword; patterns = @($Element.Patterns | ForEach-Object { [string]$_ })
    }
}

function ConvertTo-HuUiaReadableRecord($Element) {
    return [pscustomobject][ordered]@{
        controlType = [string]$Element.ControlType; name = [string]$Element.Name
        automationId = [string]$Element.AutomationId; value = [string]$Element.Value
        isPassword = [bool]$Element.IsPassword; offscreen = [bool]$Element.Offscreen
    }
}

function New-HuUiaElementsReport($Window, [object[]] $Elements, [int] $FirstPassCount, [bool] $Summary) {
    return [pscustomobject][ordered]@{
        schema = 'win-use-master/uia-elements-result-v1'
        observedAt = [DateTimeOffset]::Now.ToString('o')
        status = $(if (@($Elements).Count) { 'available' } else { 'empty' })
        target = [pscustomobject][ordered]@{ hwnd = Format-Hwnd $Window.Hwnd; pid = [uint32]$Window.Pid }
        privacy = [pscustomobject][ordered]@{
            mode = $(if ($Summary) { 'summary' } else { 'full' })
            collection = 'unchanged'
            itemsIncluded = -not $Summary
            redactedFields = @(if ($Summary) { 'items' } else { 'items[].value(password)' })
        }
        counts = [pscustomobject][ordered]@{ firstPass = $FirstPassCount; returned = @($Elements).Count }
        typeCounts = @(Get-HuTypeCounts $Elements)
        items = @(if (-not $Summary) { $Elements | ForEach-Object { ConvertTo-HuUiaActionRecord $_ } })
    }
}

function New-HuUiaReadReport($Window, [object[]] $Elements, $Options, $Page, [bool] $Summary) {
    $query = $Options.Query
    $criteria = [pscustomobject][ordered]@{
        idExact = [bool]([string]$query.idExact); idPrefix = [bool]([string]$query.idPrefix)
        controlType = [bool]([string]$query.controlType); nameExact = [bool]([string]$query.nameExact)
        namePrefix = [bool]([string]$query.namePrefix); withinId = [bool]([string]$query.withinId)
    }
    $mode = if ($Options.Structured) { 'structured' } elseif ($Options.ExactId) { 'exact-id' } elseif ($Options.Filter) { 'legacy-filter' } else { 'all' }
    $pageRecord = $null
    if ($null -ne $Page) {
        $pageRecord = [pscustomobject][ordered]@{
            schema = [string]$Page.schema; offset = [int]$Page.offset; nextOffset = [int]$Page.nextOffset
            matched = [int]$Page.matched; returned = [int]$Page.returned; hasMore = [bool]$Page.hasMore
            continuation = $(if ($Page.continuation) { [string]$Page.continuation } else { $null })
        }
    }
    return [pscustomobject][ordered]@{
        schema = 'win-use-master/uia-read-result-v1'
        observedAt = [DateTimeOffset]::Now.ToString('o')
        status = $(if (@($Elements).Count) { 'available' } else { 'empty' })
        target = [pscustomobject][ordered]@{ hwnd = Format-Hwnd $Window.Hwnd; pid = [uint32]$Window.Pid }
        privacy = [pscustomobject][ordered]@{
            mode = $(if ($Summary) { 'summary' } else { 'full' })
            collection = 'unchanged'
            itemsIncluded = -not $Summary
            redactedFields = @(if ($Summary) { 'items' } else { 'items[].value(password)' })
        }
        query = [pscustomobject][ordered]@{
            mode = $mode; valuesIncluded = $false; criteria = $criteria
            legacyFilterApplied = [bool]$Options.Filter
            limit = [int]$Options.Limit; limitExplicit = [bool]$Options.LimitExplicit
            continuationApplied = [bool]$Options.Continuation
        }
        counts = [pscustomobject][ordered]@{
            returned = @($Elements).Count
            password = @($Elements | Where-Object { [bool]$_.IsPassword }).Count
        }
        typeCounts = @(Get-HuTypeCounts $Elements)
        items = @(if (-not $Summary) { $Elements | ForEach-Object { ConvertTo-HuUiaReadableRecord $_ } })
        page = $pageRecord
    }
}

function New-HuWindowStateReport([string] $Action, $BeforeWindow, $AfterWindow,
    [Nullable[long]] $ForegroundBefore, [Nullable[long]] $ForegroundAfter,
    [string] $ForegroundTransition, [string] $Status, [bool] $Summary, [bool] $DryRun = $false) {
    $requestedState = if ($Action -eq 'minimize') { 'minimized' } else { 'current' }
    $beforeState = if ($null -eq $BeforeWindow) { $null } else { Get-HuWindowState $BeforeWindow }
    $afterState = if ($null -eq $AfterWindow) { $null } else { Get-HuWindowState $AfterWindow }
    $effect = if ($DryRun) { 'not-applied' }
        elseif ($Status -eq 'partial') { 'partial' }
        elseif ($Status -eq 'completed' -and $beforeState -eq $afterState) { 'unchanged' }
        elseif ($Status -eq 'completed') { 'changed' }
        elseif ($Status -eq 'refused') { 'none' }
        else { 'unknown' }
    return [pscustomobject][ordered]@{
        schema = 'win-use-master/window-state-result-v1'
        observedAt = [DateTimeOffset]::Now.ToString('o')
        status = $Status
        action = $Action
        requestedState = $requestedState
        effect = $effect
        privacy = [pscustomobject][ordered]@{
            mode = $(if ($Summary) { 'summary' } else { 'full' })
            selectorValueIncluded = $false
            redactedFields = @(if ($Summary) { 'before.title'; 'after.title' })
        }
        method = 'ShowWindow-no-activate'
        dryRun = $DryRun
        focus = [pscustomobject][ordered]@{
            borrowed = $false
            before = $(if ($null -eq $ForegroundBefore -or [long]$ForegroundBefore -eq 0) { $null } else { Format-Hwnd ([long]$ForegroundBefore) })
            after = $(if ($null -eq $ForegroundAfter -or [long]$ForegroundAfter -eq 0) { $null } else { Format-Hwnd ([long]$ForegroundAfter) })
            transition = $(if ($ForegroundTransition) { $ForegroundTransition } else { 'not-observed' })
        }
        before = $(if ($null -eq $BeforeWindow) { $null } else { ConvertTo-HuWindowRecord $BeforeWindow $Summary })
        after = $(if ($null -eq $AfterWindow) { $null } else { ConvertTo-HuWindowRecord $AfterWindow $Summary })
    }
}

function ConvertTo-HuJson($Value) {
    return ($Value | ConvertTo-Json -Depth 12)
}

function Stop-AmbiguousHuWindow([string] $Selector, [object[]] $Matches, [switch] $Summary) {
    if ($Summary) {
        Stop-Hu "refused: 窗口选择器匹配 $($Matches.Count) 个窗口；--summary 已省略选择器与候选详情，请改用明确 HWND。" 2
    }
    $shown = @($Matches | Select-Object -First 8 | ForEach-Object { '  ' + (Format-Window $_) })
    $more = if ($Matches.Count -gt $shown.Count) { "`n  ... 另有 $($Matches.Count - $shown.Count) 个候选" } else { '' }
    Stop-Hu ("refused: 窗口选择器「$Selector」匹配 $($Matches.Count) 个窗口，不会自动猜测目标。" +
        "`n候选：`n" + ($shown -join "`n") + $more +
        "`n请从 windows 输出中复制明确的 HWND（0x...）后重试。") 2
}

function Resolve-HuWindow([string] $Selector, [switch] $Summary) {
    $wins = Get-HuWindows
    $numeric = ConvertTo-Hwnd $Selector
    if ($null -ne $numeric) {
        $byHwnd = @($wins | Where-Object { $_.Hwnd -eq $numeric })
        if ($byHwnd.Count) { return $byHwnd[0] }
        $byPid = @($wins | Where-Object { $_.Pid -eq $numeric -and -not (Test-JunkWindow $_) } |
            Sort-Object @{ Expression = { $_.W * $_.H }; Descending = $true })
        if ($byPid.Count -gt 1) { Stop-AmbiguousHuWindow $Selector $byPid -Summary:$Summary }
        if ($byPid.Count -eq 1) { return $byPid[0] }
        if ($Summary) { Stop-Hu '找不到窗口/进程；--summary 已省略选择器。先运行 win.ps1 windows --summary。' }
        Stop-Hu "找不到窗口/进程 $Selector。先运行 win.ps1 windows。"
    }

    $matches = @($wins | Where-Object {
        -not (Test-JunkWindow $_) -and
        ($_.Owner.IndexOf($Selector, [StringComparison]::OrdinalIgnoreCase) -ge 0 -or
         $_.Title.IndexOf($Selector, [StringComparison]::OrdinalIgnoreCase) -ge 0)
    } | Sort-Object @{ Expression = { $_.W * $_.H }; Descending = $true })
    if (-not $matches.Count) {
        if ($Summary) { Stop-Hu '没有匹配窗口；--summary 已省略选择器。先运行 win.ps1 windows --summary。' }
        Stop-Hu "没有 owner/title 含「$Selector」的窗口。先运行 win.ps1 windows。"
    }
    if ($matches.Count -gt 1) { Stop-AmbiguousHuWindow $Selector $matches -Summary:$Summary }
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
    if ($null -eq $size -and -not $Window.Iconic -and [HuWin]::IsWindow([IntPtr][long]$Window.Hwnd)) {
        # A window that was just restored or is mid-animation can reject the first
        # PrintWindow outright (Electron/QQ observed). One bounded retry, not a loop.
        Start-Sleep -Milliseconds 400
        $size = [HuWin]::ShotWindowTimed([long]$Window.Hwnd, $full, $script:CaptureTimeoutMilliseconds)
        if ($null -ne $size) { $method = 'PrintWindow(PW_RENDERFULLCONTENT) retry-after-400ms' }
    }
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
function Get-BlankFrameHint($Result, $Window, $Elements = $null, [switch] $Summary) {
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
        elseif ($empty.Count) {
            $identity = if ($Summary) { [string]$empty[0].ControlType } else { "$($empty[0].ControlType)「$($empty[0].Name)」" }
            $semantic = " UIA 读到空的 $identity，与单色内容区一致：多半是空文档，不是截图失败。"
        }
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

function Get-UiaReadableElements($Window, [int] $Limit = 300, [string] $ExactId = '') {
    $reply = Invoke-UiaWorker $Window -Mode read -Limit $Limit -ExactId $ExactId
    if ($reply.TimedOut) { Stop-Hu 'UIA 读取超过 6 秒，已终止辅助进程；改用截图/CDP。' 2 }
    if ($reply.ExitCode -ne 0 -or $null -eq $reply.Result -or -not $reply.Result.ok) {
        Stop-Hu ("UIA 读取失败: " + $(if ($reply.Error) { $reply.Error } else { 'worker 无结果' })) $(if($reply.ExitCode -eq 2){2}else{1})
    }
    return @($reply.Result.items)
}

function Get-UiaReadableQueryResult($Window, [int] $Limit, $Query, [string] $Continuation = '') {
    $reply = Invoke-UiaWorker $Window -Mode read -Limit $Limit -Query $Query -Continuation $Continuation
    if ($reply.TimedOut) { Stop-Hu 'UIA 限定读取超过 6 秒，已终止辅助进程；continuation 不得重试，重新缩小查询范围。' 2 }
    if ($reply.ExitCode -ne 0 -or $null -eq $reply.Result -or -not $reply.Result.ok) {
        Stop-Hu ("UIA 限定读取失败: " + $(if ($reply.Error) { $reply.Error } else { 'worker 无结果' })) $(if($reply.ExitCode -eq 2){2}else{1})
    }
    if ([string]$reply.Result.schema -ne 'win-use-master/uia-query-result-v1' -or
        [string]$reply.Result.page.schema -ne 'win-use-master/uia-page-v1') {
        Stop-Hu 'UIA 限定读取返回了未知 schema；不会继续使用 continuation。' 2
    }
    return $reply.Result
}

function Get-UiaReadOptions([string[]] $Arguments) {
    $positionals = [Collections.Generic.List[string]]::new()
    $summary = $false
    $json = $false
    $values = [ordered]@{
        '--id' = ''; '--id-prefix' = ''; '--type' = ''; '--name' = ''
        '--name-prefix' = ''; '--within-id' = ''; '--limit' = ''; '--continuation' = ''
    }
    $seen = [Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
    for ($i = 0; $i -lt $Arguments.Count; $i++) {
        $token = $Arguments[$i]
        if ($token -eq '--summary') { $summary = $true; continue }
        if ($token -eq '--json') { $json = $true; continue }
        if ($values.Contains($token)) {
            if (-not $seen.Add($token) -or $i + 1 -ge $Arguments.Count -or
                [string]::IsNullOrWhiteSpace($Arguments[$i + 1]) -or $Arguments[$i + 1].StartsWith('--')) {
                Stop-Hu "uiaread $token 需要一个非空值，且只能指定一次。" 2
            }
            $i++; $values[$token] = $Arguments[$i]; continue
        }
        if ($token.StartsWith('--')) {
            Stop-Hu 'uiaread 只支持 --id/--id-prefix/--type/--name/--name-prefix/--within-id/--limit/--continuation/--summary/--json；未知选项已拒绝。' 2
        }
        $positionals.Add($token)
    }
    if ($values['--id'] -and $values['--id-prefix']) { Stop-Hu 'uiaread 的 --id 与 --id-prefix 不能同时使用。' 2 }
    if ($values['--name'] -and $values['--name-prefix']) { Stop-Hu 'uiaread 的 --name 与 --name-prefix 不能同时使用。' 2 }
    $allowedTypes = @('Text', 'Document', 'Edit', 'StatusBar', 'Header', 'HeaderItem')
    $type = ''
    if ($values['--type']) {
        $type = @($allowedTypes | Where-Object { $_ -ieq $values['--type'] } | Select-Object -First 1)
        if (-not $type.Count) { Stop-Hu "uiaread --type 只支持: $($allowedTypes -join ', ')。" 2 }
        $type = $type[0]
    }
    $limit = 300
    $limitExplicit = [bool]$values['--limit']
    if ($limitExplicit -and (-not [int]::TryParse($values['--limit'], [ref]$limit) -or $limit -lt 1 -or $limit -gt 500)) {
        Stop-Hu 'uiaread --limit 必须是 1..500 的整数。' 2
    }
    $continuation = $values['--continuation']
    if ($continuation -and ($continuation.Length -gt 2048 -or $continuation -notmatch '^[A-Za-z0-9_-]+$')) {
        Stop-Hu 'uiaread --continuation 格式无效；请从第一页重新查询。' 2
    }
    $hasQueryOptions = $seen.Count -gt 0
    $structured = $hasQueryOptions -and -not ($seen.Count -eq 1 -and $seen.Contains('--id'))
    if ($positionals.Count -lt 1 -or $positionals.Count -gt 2 -or ($hasQueryOptions -and $positionals.Count -gt 1)) {
        Stop-Hu '用法: uiaread <target> [旧过滤词 | 限定查询选项] [--summary]；旧过滤词不能与限定查询混用。' 2
    }
    $query = [pscustomobject][ordered]@{
        idExact = $values['--id']
        idPrefix = $values['--id-prefix']
        controlType = $type
        nameExact = $values['--name']
        namePrefix = $values['--name-prefix']
        withinId = $values['--within-id']
    }
    return [pscustomobject]@{
        Target = $positionals[0]; ExactId = $values['--id']; Summary = $summary; Json = $json
        Filter = $(if ($positionals.Count -gt 1) { $positionals[1] } else { '' })
        Structured = $structured; Query = $query; Limit = $limit; LimitExplicit = $limitExplicit
        Continuation = $continuation
    }
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
        return [pscustomobject]@{ X = [int]$el.Cx; Y = [int]$el.Cy; VerifyX = [int]$inkX; VerifyY = [int]$el.Cy; ScreenX = [int]($Window.L + $el.Cx); ScreenY = [int]($Window.T + $el.Cy); Note = "$($Matches[1]) from UIA map"; SemanticElement = $el }
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
    return [pscustomobject]@{ X = [int][Math]::Round($rx); Y = [int][Math]::Round($ry); VerifyX = [int][Math]::Round($rx); VerifyY = [int][Math]::Round($ry); ScreenX = [int][Math]::Round($Window.L + $rx); ScreenY = [int][Math]::Round($Window.T + $ry); Note = $note; SemanticElement = $null }
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
  win.ps1 windows [关键词] [--all] [--raw] [--json] [--summary] # JSON 不回显过滤词；summary 隐去标题
  win.ps1 see <hwnd|pid|owner> [path] [--summary] # summary 不在终端展开 UIA 名称；也接受 --out path（仅进程内）
  win.ps1 shot <hwnd|owner> <path>
  win.ps1 shotfg <hwnd|owner> <path>          # 后台空图才短暂借焦点
  win.ps1 screen <path> [--window <target>] [--region x y w h]   # 桌面合成截图，交叉验证 PrintWindow
  win.ps1 uia <hwnd|pid|owner> [--summary] [--json] # summary 只保留计数/类型
  win.ps1 uiaread <target> [旧过滤词 | 查询选项] [--summary] [--json]
    查询: [--id ID|--id-prefix P] [--type TYPE] [--name NAME|--name-prefix P]
          [--within-id ID] [--limit 1..500] [--continuation TOKEN]
  win.ps1 idle | frontmost [--json] [--summary]
  win.ps1 restore | minimize <hwnd|pid|owner> [--json] [--summary] # 用户要求时才改变状态；不激活；隐藏窗口拒绝

语义写入（通常不抢焦点）:
  win.ps1 uiaset <target> <eN|first> <text> [@uia.json]
  win.ps1 invoke <target> <eN> [@uia.json]

坐标写入（会短暂借焦点，默认先等用户空闲）:
  win.ps1 clickin <target> <x> <y> [@shot.png] [shot out.png] [--dry]
  win.ps1 hoverin <target> <x> <y> [@shot.png] [holdms] [shot out.png]
  win.ps1 scrollin <target> <x> <y> <delta> [steps] [--horizontal]
  win.ps1 type <target> <text> [--replace]
  win.ps1 key <target> <Ctrl+A|Escape|Tab|...> [--dry]  # Enter/保存/关闭类最终动作拒绝
  win.ps1 op <target> <x> <y> <text> [@shot.png] [--replace] [shot out.png]

应用与状态:
  win.ps1 doctor [--json|--summary]             # 只读环境诊断；不构建、不启动、不修复
  win.ps1 cache show|record <probe.json>|clear <key|--all> [--json] [--summary] # 建议性能力缓存；从不授权写操作
  win.ps1 cleanup [--dry-run] [--json] [--summary] # 临时对象只读清单；本版本不提供 --apply
  win.ps1 benchmark [--quick] [--no-cdp] [--json] [--summary] # 聚合性能基线；只读，无头 CDP fixture 可选
  win.ps1 open <显示名|进程名|exe路径> [--cdp port] [--relaunch] [--background] [--dry]
  win.ps1 com <ProgID> [--dry]                 # COM 身份核对：--dry 只读 64/32 位注册；否则新起私有实例核对 exe 后 Quit
  win.ps1 hud [毫秒] [文案] [corner|glow|plain]
  probe.ps1 <显示名|进程名|exe路径> [--json] [--summary] [--no-cache]
  node cdp.js <port> list|inspect ... [--json] [--summary] # 其它命令见 cdp.js help

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
        $unknownOptions = @($CommandArgs | Where-Object { $_.StartsWith('--') -and $_ -notin @('--all', '--raw', '--json', '--summary') })
        $positionals = @($CommandArgs | Where-Object { -not $_.StartsWith('--') })
        if ($unknownOptions.Count -or $positionals.Count -gt 1) {
            Stop-Hu 'windows 只支持一个过滤词与 --all/--raw/--json/--summary；未知或多余参数已拒绝。' 2
        }
        $all = $CommandArgs -contains '--all'
        $raw = $CommandArgs -contains '--raw'
        $jsonOnly = $CommandArgs -contains '--json'
        $summaryOnly = $CommandArgs -contains '--summary'
        $filter = @($CommandArgs | Where-Object { $_ -notin @('--all', '--raw', '--json', '--summary') } | Select-Object -First 1)
        $hidden = 0; $folded = 0
        $shownWindows = [Collections.Generic.List[object]]::new()
        foreach ($w in (Get-HuWindows | Sort-Object Owner, Hwnd)) {
            if ($filter.Count -and
                $w.Owner.IndexOf($filter[0], [StringComparison]::OrdinalIgnoreCase) -lt 0 -and
                $w.Title.IndexOf($filter[0], [StringComparison]::OrdinalIgnoreCase) -lt 0) { continue }
            if (-not $all -and (Test-JunkWindow $w)) { $hidden++; continue }
            # Qt/CEF apps create hundreds of invisible message-only windows (0x0,
            # 202x56, 1x1). They are never a capture or UIA target; fold them even
            # under --all unless --raw asks for the complete list.
            if ($all -and -not $raw -and -not $w.Visible -and (($w.W -eq 0 -or $w.H -eq 0) -or ([string]::IsNullOrWhiteSpace($w.Title) -and ($w.W -lt 100 -or $w.H -lt 60)))) { $folded++; continue }
            $shownWindows.Add($w)
            if (-not $jsonOnly) {
                Write-Output $(if ($summaryOnly) { Format-HuWindowSummary $w } else { Format-Window $w })
            }
        }
        if ($jsonOnly) {
            Write-Output (ConvertTo-HuJson (New-HuWindowsReport @($shownWindows) $hidden $folded ([bool]$filter.Count) $all $raw $summaryOnly))
        } else {
            if ($hidden) { Write-Output "（已隐藏 $hidden 个系统残留/浮层窗口；加 --all 显示）" }
            if ($folded) { Write-Output "（已折叠 $folded 个无标题的隐藏消息窗；加 --raw 全部显示）" }
        }
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
        $summaryOnly = $CommandArgs -contains '--summary'
        $seeArgs = @($CommandArgs | Where-Object { $_ -ne '--summary' })
        if (-not $seeArgs.Count) { Stop-Hu '用法: win.ps1 see <hwnd|pid|owner> [路径 | --out 路径] [--summary]' }
        $w = Resolve-HuWindow $seeArgs[0]
        # Positional path is the portable form. `--out` only works for in-process
        # `& win.ps1` calls: under `pwsh -File` the host binds `--out` as the
        # ambiguous common parameter prefix -Out(Variable|Buffer) before the
        # script runs, so it cannot be repaired here.
        $outIndex = [Array]::IndexOf($seeArgs, '--out')
        $out = if ($outIndex -ge 0 -and $outIndex + 1 -lt $seeArgs.Count) { Get-AbsolutePath $seeArgs[$outIndex + 1] }
               elseif ($seeArgs.Count -ge 2 -and -not $seeArgs[1].StartsWith('--')) { Get-AbsolutePath $seeArgs[1] }
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
            if ($summaryOnly) {
                Write-Output "窗口: id=$(Format-Hwnd $w.Hwnd) pid=$($w.Pid) mode=summary receipt=$sidecar"
            } else { Write-Output "窗口: $(Format-Window $w) receipt=$sidecar" }
            if ($shot.Colors -lt 6) { Write-Output (Get-BlankFrameHint $shot $w $elements -Summary:$summaryOnly) }
            if (-not $elements.Count) { Write-Output 'UIA 元素表: 无。可能 app 不暴露、窗口在其它虚拟桌面，或 Chromium 树断开；改 CDP/坐标。' }
            elseif ($summaryOnly) {
                $types = @($elements | Group-Object ControlType | Sort-Object Name | ForEach-Object { "$($_.Name)=$($_.Count)" }) -join ', '
                Write-Output "UIA 元素表 $($elements.Count) 个，map=$mapPath；--summary 已省略名称/值（类型: $types）。map 与截图仍可能敏感，用后清理。"
            }
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
        $summaryOnly = $CommandArgs -contains '--summary'
        $jsonOnly = $CommandArgs -contains '--json'
        $unknownOptions = @($CommandArgs | Where-Object { $_.StartsWith('--') -and $_ -notin @('--summary', '--json') })
        $uiaArgs = @($CommandArgs | Where-Object { $_ -notin @('--summary', '--json') })
        if ($unknownOptions.Count -or $uiaArgs.Count -ne 1) { Stop-Hu '用法: win.ps1 uia <hwnd|pid|owner> [--summary] [--json]；未知或多余参数已拒绝。' 2 }
        $w = Resolve-HuWindow $uiaArgs[0]
        $first = @(Get-UiaElements $w)
        Start-Sleep -Milliseconds 250
        $elements = @(Get-UiaElements $w)
        if ($jsonOnly) {
            Write-Output (ConvertTo-HuJson (New-HuUiaElementsReport $w $elements $first.Count $summaryOnly))
            break
        }
        Write-Output "UIA window=$(Format-Hwnd $w.Hwnd) pid=$($w.Pid) elements=$($elements.Count) first-pass=$($first.Count)$(if($summaryOnly){' mode=summary'})"
        if ($summaryOnly -and $elements.Count) {
            $types = @($elements | Group-Object ControlType | Sort-Object Name | ForEach-Object { "$($_.Name)=$($_.Count)" }) -join ', '
            Write-Output "UIA --summary 已省略名称/值（类型: $types）。"
        } elseif (-not $summaryOnly) {
            $elements | ForEach-Object { Write-Output (Format-UiaElement $_) }
        }
        if (-not $elements.Count) { Write-Output '→ L1 暂不可用：Chromium 系走 CDP，其它走 L2 坐标。' }
        else { Write-Output '→ L1 有希望，但 SetValue/Invoke 返回成功仍须截图或副作用验证。' }
        break
    }

    'uiaread' {
        $options = Get-UiaReadOptions $CommandArgs
        $summaryOnly = $options.Summary
        $jsonOnly = $options.Json
        $w = Resolve-HuWindow $options.Target
        $filter = $options.Filter
        $page = $null
        if ($options.Structured) {
            $result = Get-UiaReadableQueryResult $w $options.Limit $options.Query $options.Continuation
            $elements = @($result.items)
            $page = $result.page
        } else {
            $elements = @(Get-UiaReadableElements $w -ExactId $options.ExactId)
        }
        if ($filter) {
            $elements = @($elements | Where-Object {
                $_.Name.IndexOf($filter, [StringComparison]::OrdinalIgnoreCase) -ge 0 -or
                $_.AutomationId.IndexOf($filter, [StringComparison]::OrdinalIgnoreCase) -ge 0 -or
                $_.Value.IndexOf($filter, [StringComparison]::OrdinalIgnoreCase) -ge 0
            })
        }
        if ($jsonOnly) {
            Write-Output (ConvertTo-HuJson (New-HuUiaReadReport $w $elements $options $page $summaryOnly))
            break
        }
        $shownFilter = if ($summaryOnly -and $filter) { '<set>' } elseif ($filter) { '"' + $filter + '"' } else { '<none>' }
        if ($options.Structured) { $shownFilter = '<structured>' }
        elseif ($options.ExactId) { $shownFilter = '<exact-id>' }
        $pageText = if ($null -ne $page) { " page=$($page.offset):$($page.nextOffset)/$($page.matched) has-more=$([string]$page.hasMore).ToLowerInvariant()" } else { '' }
        Write-Output "UIA read window=$(Format-Hwnd $w.Hwnd) pid=$($w.Pid) elements=$($elements.Count) filter=$shownFilter$pageText$(if($summaryOnly){' mode=summary'})"
        if ($summaryOnly -and $elements.Count) {
            $types = @($elements | Group-Object ControlType | Sort-Object Name | ForEach-Object { "$($_.Name)=$($_.Count)" }) -join ', '
            Write-Output "UIA read --summary 已省略名称/值（类型: $types，password=$(@($elements | Where-Object IsPassword).Count)）。"
        } elseif (-not $summaryOnly) {
            $elements | ForEach-Object { Write-Output (Format-UiaReadableElement $_) }
        }
        if ($null -ne $page -and $page.hasMore) {
            Write-Output "continuation=$($page.continuation)（下一页必须重复相同查询条件；树变化会退出 2）"
        }
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
        # Resolve and risk-check in a read-only worker before creating any
        # before-action evidence. The action worker resolves the same semantic
        # identity again immediately before invoking it.
        $spec = Resolve-UiaReference $w $CommandArgs[1] $map
        Assert-SafeSemanticAction $spec 'L1 UIA invoke'
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
        Assert-SafeSemanticAction $point.SemanticElement 'L2 UIA-map click' -ActionControlsOnly
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
        if ($CommandArgs.Count -lt 2) { Stop-Hu '用法: win.ps1 key <target> <Ctrl+A|Escape|Tab|...> [--dry]；Enter/保存/关闭类最终动作拒绝' }
        $w = Resolve-HuWindow $CommandArgs[0]; $key = Parse-KeyChord $CommandArgs[1]
        Assert-SafeKeyChord $key 'L2 SendInput'
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
                request = [ordered]@{ chord = $CommandArgs[1]; forceRequested = $script:Force; riskPolicy = 'win-use-master/risk-actions-v1' }
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
        Assert-SafeSemanticAction $point.SemanticElement 'L2 UIA-map input click' -ActionControlsOnly
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
        if (@($CommandArgs | Where-Object { $_ -notin @('--json', '--summary') }).Count) {
            Stop-Hu 'idle 只支持 --json 与 --summary；未知参数已拒绝。' 2
        }
        $jsonOnly = $CommandArgs -contains '--json'; $summaryOnly = $CommandArgs -contains '--summary'
        $idle = [HuWin]::UserIdleSeconds(); $rawIdle = [HuWin]::IdleSeconds(); $fg = [HuWin]::ForegroundWindow().ToInt64(); $front = @((Get-HuWindows) | Where-Object { $_.Hwnd -eq $fg })
        if ($jsonOnly) {
            $frontWindow = if ($front.Count) { $front[0] } else { $null }
            Write-Output (ConvertTo-HuJson (New-HuIdleReport $idle $rawIdle $fg $frontWindow $summaryOnly))
            break
        }
        $frontText = if ($front.Count) { "$($front[0].Owner) $(Format-Hwnd $fg) `"$($front[0].Title)`"" } else { Format-Hwnd $fg }
        if ($summaryOnly -and $front.Count) { $frontText = "$($front[0].Owner) $(Format-Hwnd $fg) title=<redacted>" }
        $verdict = if ($idle -lt $script:IdleThresholdSeconds) { '🔴 用户在场；坐标写会先等，最多 15 秒' } else { '🟢 用户空闲；坐标写可进入借焦点流程' }
        $trail = if ($idle -ge 3599 -and $rawIdle -lt 10) { "；最近一次输入为本工具合成事件，原始空闲 $([Math]::Round($rawIdle,1))s" } else { '' }
        Write-Output ("用户键鼠空闲 {0:F1}s（阈值 {1:F0}s）{2} 前台: {3}`n{4}`n注：windows/shot/see/uia/CDP 等读操作不受此闸影响。" -f $idle,$script:IdleThresholdSeconds,$trail,$frontText,$verdict)
        break
    }

    'frontmost' {
        if (@($CommandArgs | Where-Object { $_ -notin @('--json', '--summary') }).Count) {
            Stop-Hu 'frontmost 只支持 --json 与 --summary；未知参数已拒绝。' 2
        }
        $jsonOnly = $CommandArgs -contains '--json'; $summaryOnly = $CommandArgs -contains '--summary'
        $fg = [HuWin]::ForegroundWindow().ToInt64(); $front = @((Get-HuWindows) | Where-Object { $_.Hwnd -eq $fg })
        if ($jsonOnly) {
            $frontWindow = if ($front.Count) { $front[0] } else { $null }
            Write-Output (ConvertTo-HuJson (New-HuFrontmostReport $fg $frontWindow $summaryOnly))
        } elseif ($front.Count) {
            Write-Output $(if ($summaryOnly) { Format-HuWindowSummary $front[0] } else { Format-Window $front[0] })
        } else { Write-Output (Format-Hwnd $fg) }
        break
    }

    # L0 COM identity check. Registry part is read-only and shows who answers the
    # ProgID in the 64-bit and 32-bit views (WPS hijacks Excel's ProgIDs in the
    # 32-bit view). Without --dry it CoCreates the object, which for Office-style
    # servers starts a private /automation process; that process is the only one
    # this command will Quit. Anything preexisting is never touched.
    'com' {
        if (-not $CommandArgs.Count -or $CommandArgs[0].StartsWith('--')) { Stop-Hu '用法: win.ps1 com <ProgID> [--dry]（--dry 只读注册表；否则会新起私有实例做身份核对后 Quit）' }
        $progId = $CommandArgs[0]
        $clsid = $null
        try { $clsid = [string](Get-ItemProperty -LiteralPath "Registry::HKEY_CLASSES_ROOT\$progId\CLSID" -ErrorAction Stop).'(default)' } catch { }
        if (-not $clsid) { Stop-Hu "注册表里没有 ProgID「$progId」（HKCR\$progId\CLSID 不存在）。" 1 }
        $server64 = try { [string](Get-ItemProperty -LiteralPath "Registry::HKEY_CLASSES_ROOT\CLSID\$clsid\LocalServer32" -ErrorAction Stop).'(default)' } catch { '' }
        $server32 = try { [string](Get-ItemProperty -LiteralPath "Registry::HKEY_CLASSES_ROOT\WOW6432Node\CLSID\$clsid\LocalServer32" -ErrorAction Stop).'(default)' } catch { '' }
        $inproc64 = try { [string](Get-ItemProperty -LiteralPath "Registry::HKEY_CLASSES_ROOT\CLSID\$clsid\InprocServer32" -ErrorAction Stop).'(default)' } catch { '' }
        Write-Output "com $progId clsid=$clsid host=$(if ([Environment]::Is64BitProcess) { '64' } else { '32' })-bit pwsh"
        Write-Output "  64-bit LocalServer32: $(if ($server64) { $server64 } elseif ($inproc64) { "(InprocServer32) $inproc64" } else { '<无>' })"
        Write-Output "  32-bit LocalServer32: $(if ($server32) { $server32 } else { '<无>' })"
        if ($server64 -and $server32 -and ($server64 -ne $server32)) {
            Write-Output '  ⚠️ 两个视图指向不同的 exe：64 位宿主与 32 位宿主拿到的不是同一个 app。不要按名字判断，按 exe 路径。'
        }
        if ($script:Dry) { Write-Output 'dry: 未实例化。去掉 --dry 会 CoCreate（多数 Office 类 app 会新起一个私有自动化进程），核对身份后 Quit 该私有实例。'; break }

        $beforePids = [Collections.Generic.HashSet[int]]::new()
        foreach ($p in @(Get-Process -ErrorAction SilentlyContinue)) { [void]$beforePids.Add([int]$p.Id) }
        $clock = [Diagnostics.Stopwatch]::StartNew()
        $obj = $null
        try { $obj = New-Object -ComObject $progId -ErrorAction Stop }
        catch { Stop-Hu "CoCreate 失败: $($_.Exception.Message)" 1 }
        $createdMs = $clock.ElapsedMilliseconds
        Start-Sleep -Milliseconds 400
        $newProcs = @(Get-Process -ErrorAction SilentlyContinue | Where-Object { -not $beforePids.Contains([int]$_.Id) })
        $facts = [ordered]@{}
        foreach ($prop in @('Name', 'Version', 'Build', 'Path', 'Visible', 'UserControl')) {
            try { $v = $obj.$prop; if ($null -ne $v) { $facts[$prop] = [string]$v } } catch { }
        }
        $hwnd = 0L; try { $hwnd = [long]$obj.Hwnd } catch { }
        $ownerPid = 0; $ownerExe = ''
        if ($hwnd) {
            $ownerWin = @((Get-HuWindows) | Where-Object { $_.Hwnd -eq $hwnd } | Select-Object -First 1)
            if ($ownerWin.Count) { $ownerPid = [int]$ownerWin[0].Pid; try { $ownerExe = (Get-Process -Id $ownerPid -ErrorAction Stop).Path } catch { } }
        }
        if (-not $ownerPid -and $newProcs.Count) { $ownerPid = [int]$newProcs[0].Id; try { $ownerExe = $newProcs[0].Path } catch { } }
        $private = ($ownerPid -ne 0) -and -not $beforePids.Contains($ownerPid)
        Write-Output ("created in {0}ms; new processes: {1}" -f $createdMs, $(if ($newProcs.Count) { ($newProcs | ForEach-Object { "$($_.Id) $($_.ProcessName)" }) -join ', ' } else { '<无，可能挂进了已运行实例或是进程内服务器>' }))
        Write-Output ("identity: {0} hwnd={1} pid={2} exe={3} private-instance={4}" -f (($facts.GetEnumerator() | ForEach-Object { "$($_.Key)=$($_.Value)" }) -join ' '), $(if ($hwnd) { Format-Hwnd $hwnd } else { '<无>' }), $ownerPid, $(if ($ownerExe) { $ownerExe } else { '<未知>' }), $private)
        if ($server32 -and $ownerExe -and $server32.IndexOf([IO.Path]::GetFileName($ownerExe), [StringComparison]::OrdinalIgnoreCase) -ge 0 -and $server64 -and $server64.IndexOf([IO.Path]::GetFileName($ownerExe), [StringComparison]::OrdinalIgnoreCase) -lt 0) {
            Write-Output '  ⚠️ 应答者是 32 位视图里注册的 exe，不是 64 位视图里的那个。'
        }
        $quitState = 'skipped（非私有实例或无 Quit，不能动用户会话）'
        if ($private) {
            try { $obj.Quit(); $quitState = 'called' } catch { $quitState = "no Quit: $($_.Exception.Message.Split([char]10)[0])" }
        }
        try { [void][Runtime.InteropServices.Marshal]::FinalReleaseComObject($obj) } catch { }
        $obj = $null
        [GC]::Collect(); [GC]::WaitForPendingFinalizers()
        if ($private -and $quitState -eq 'called') {
            $deadline = [DateTime]::UtcNow.AddSeconds(30)
            while ((Get-Process -Id $ownerPid -ErrorAction SilentlyContinue) -and [DateTime]::UtcNow -lt $deadline) { Start-Sleep -Milliseconds 250 }
            $exited = -not [bool](Get-Process -Id $ownerPid -ErrorAction SilentlyContinue)
            $quitState += "; exited within 30s: $exited"
            if (-not $exited) { $quitState += "（Excel 类 app 在从未打开文档时 Quit 后可滞留数分钟，最终随 DCOM 超时退出；不强杀。pid=$ownerPid 是本命令新起的私有实例）" }
        }
        Write-Output "teardown: quit=$quitState"
        Write-Output '说明: 只核对身份，不读写文档。真正的对象模型调用请写脚本：先 Workbooks/Documents.Add 再设 Visible，COM 对象不经函数返回，RCW 全释放后再 Quit。'
        break
    }

    # Explicit window-state changes the user asked for. They never activate, never
    # touch hidden/cloaked windows, and report the state before and after so the
    # agent can put the window back the way it found it.
    { $_ -in @('restore', 'minimize') } {
        $jsonOnly = $CommandArgs -contains '--json'; $summaryOnly = $CommandArgs -contains '--summary'
        $unknownOptions = @($CommandArgs | Where-Object { $_.StartsWith('--') -and $_ -notin @('--json', '--summary') })
        $stateArgs = @($CommandArgs | Where-Object { $_ -notin @('--json', '--summary') })
        if ($script:Force -or $unknownOptions.Count -or $stateArgs.Count -ne 1) {
            Stop-Hu "用法: win.ps1 $Command <hwnd|pid|owner> [--json] [--summary] [--dry]；未知或多余参数已拒绝。" 2
        }
        $w = Resolve-HuWindow $stateArgs[0] -Summary:$summaryOnly
        if ($w.Cloaked -or -not $w.Visible) {
            $reason = if ($w.Cloaked) { '目标窗口在其它虚拟桌面或被 DWM cloaked。' } else { '目标窗口是隐藏窗口（托盘态/未显示）；显示它是 app 自己的决定，请用户打开。' }
            if ($jsonOnly) {
                Write-Output (ConvertTo-HuJson (New-HuWindowStateReport $Command $w $null $null $null 'not-observed' 'refused' $summaryOnly $false))
                [Console]::Error.WriteLine("refused: $reason")
                exit 2
            }
            Stop-Hu "refused: 目标窗口 $(Format-Hwnd $w.Hwnd) $reason" 2
        }
        $wanted = ($Command -eq 'minimize')
        if ($script:Dry) {
            if ($jsonOnly) { Write-Output (ConvertTo-HuJson (New-HuWindowStateReport $Command $w $w $null $null 'not-observed' 'planned' $summaryOnly $true)) }
            else { Write-Output "dry: $Command $(Format-Hwnd $w.Hwnd) currently=$(if ($w.Iconic) { 'min' } else { 'current' }) -> $(if ($wanted) { 'min' } else { 'current' })（SW_SHOW*NOACTIVE，不激活）" }
            break
        }
        $beforeWindow = $w
        $beforeText = Format-Window $w
        $foregroundBefore = [HuWin]::ForegroundWindow().ToInt64()
        $ok = if ($wanted) { [HuWin]::MinimizeNoActivate([long]$w.Hwnd) } else { [HuWin]::RestoreNoActivate([long]$w.Hwnd) }
        Start-Sleep -Milliseconds 150
        $after = @((Get-HuWindows) | Where-Object { $_.Hwnd -eq $w.Hwnd })
        if (-not $ok -or -not $after.Count -or [bool]$after[0].Iconic -ne $wanted) {
            if ($jsonOnly) {
                $afterWindow = if ($after.Count) { $after[0] } else { $null }
                Write-Output (ConvertTo-HuJson (New-HuWindowStateReport $Command $beforeWindow $afterWindow $foregroundBefore $null 'not-observed' 'error' $summaryOnly $false))
                [Console]::Error.WriteLine("$Command 未达到请求状态；效果未知，不要自动重试。")
                exit 1
            }
            Stop-Hu "$Command 未达到请求状态：窗口拒绝了状态改变、已消失或回读不符。before: $beforeText" 1
        }
        $foregroundAfter = [HuWin]::ForegroundWindow().ToInt64()
        $foregroundState = Get-HuForegroundTransition $foregroundBefore $foregroundAfter ([long]$w.Hwnd)
        if ($jsonOnly) {
            $status = if ($foregroundState -eq 'unexpected-target') { 'partial' } else { 'completed' }
            Write-Output (ConvertTo-HuJson (New-HuWindowStateReport $Command $beforeWindow $after[0] $foregroundBefore $foregroundAfter $foregroundState $status $summaryOnly $false))
            if ($status -eq 'partial') {
                [Console]::Error.WriteLine("refused: $Command 已改变窗口状态，但目标意外取得前台；结果为 partial，未继续操作。")
                exit 2
            }
            break
        }
        Write-Output "$Command ok（SW_SHOW*NOACTIVE） foreground=$foregroundState before=$(Format-Hwnd $foregroundBefore) after=$(Format-Hwnd $foregroundAfter)"
        Write-Output "before: $beforeText"
        Write-Output "after:  $(Format-Window $after[0])"
        if ($foregroundState -eq 'unexpected-target') {
            Stop-Hu "refused: $Command 已改变窗口状态，但目标意外取得前台；结果为 partial，未继续操作。" 2
        }
        if (-not $wanted) { Write-Output "提示: 看完记得 win.ps1 minimize $(Format-Hwnd $w.Hwnd) 还原用户布局；刚还原的窗口首帧 PrintWindow 可能需要一两秒。" }
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
        function Get-CdpSessionPath([int]$Port) {
            $override = [Environment]::GetEnvironmentVariable('WIN_USE_MASTER_CDP_SESSION')
            if (-not [string]::IsNullOrWhiteSpace($override)) { return Get-AbsolutePath $override }
            $local = [Environment]::GetFolderPath([Environment+SpecialFolder]::LocalApplicationData)
            return Join-Path $local "win-use-master\sessions\cdp-$Port.json"
        }
        function Write-CdpSessionManifest([int]$Port, [string]$ExePath, [int[]]$OwnerPids) {
            $ownerRows = @()
            foreach ($ownerPid in @($OwnerPids | Sort-Object -Unique)) {
                try {
                    $proc = Get-Process -Id $ownerPid -ErrorAction Stop
                    $ownerRows += [ordered]@{
                        pid = [int]$proc.Id
                        executablePath = [IO.Path]::GetFullPath($proc.Path)
                        startTimeUtc = $proc.StartTime.ToUniversalTime().ToString('o')
                    }
                } catch {
                    Stop-Hu "refused: CDP owner pid=$ownerPid 在授权落盘前已消失或身份不可读；请重新运行 open --cdp。" 2
                }
            }
            if (-not $ownerRows.Count) { Stop-Hu 'refused: CDP 授权没有可绑定的监听进程。' 2 }

            try {
                $targetResponse = Invoke-WebRequest -Uri "http://127.0.0.1:$Port/json/list" -TimeoutSec 2 -Proxy $null
                $targets = @($targetResponse.Content | ConvertFrom-Json)
            } catch {
                Stop-Hu "refused: CDP /json/list 不可读，不能绑定可写 target：$($_.Exception.Message)" 2
            }
            $targetIds = @()
            foreach ($target in $targets) {
                if ($target.type -eq 'page' -and $target.id) {
                    $targetIds += [string]$target.id
                }
            }
            $targetIds = @($targetIds | Sort-Object -Unique)
            if (-not $targetIds.Count) { Stop-Hu 'refused: CDP 当前没有可绑定的 page target；不会签发写授权。' 2 }

            $now = [DateTime]::UtcNow
            $manifest = [ordered]@{
                schema = 'win-use-master/cdp-session-v1'
                sessionId = [Guid]::NewGuid().ToString('N')
                port = $Port
                createdAt = $now.ToString('o')
                expiresAt = $now.AddMinutes(30).ToString('o')
                authorizedApp = [ordered]@{
                    executableName = if ($ExePath) { [IO.Path]::GetFileName($ExePath) } else { '' }
                }
                owners = @($ownerRows)
                targetIds = @($targetIds)
            }
            $sessionPath = Get-CdpSessionPath $Port
            Ensure-Parent $sessionPath
            $tempPath = "$sessionPath.$([Guid]::NewGuid().ToString('N')).tmp"
            try {
                $json = $manifest | ConvertTo-Json -Depth 6
                [IO.File]::WriteAllText($tempPath, $json + "`n", [Text.UTF8Encoding]::new($false))
                [IO.File]::Move($tempPath, $sessionPath, $true)
            } finally {
                if ([IO.File]::Exists($tempPath)) { [IO.File]::Delete($tempPath) }
            }
            return $sessionPath
        }
        $existingCdp = if ($port) { Get-CdpInfo $port } else { $null }
        if ($existingCdp) {
            $ownership = Get-CdpPortOwnership $port $path $running
            if (-not $ownership.Known) { Stop-Hu "refused: 端口 $port 返回 CDP，但无法确认监听进程归属（$($ownership.Reason)）。不会把它当成目标 app。" 2 }
            if (-not $ownership.Owned) { Stop-Hu "refused: 端口 $port 已被其它 CDP 占用（owner pid=$($ownership.Owners -join ',')）。不会控制错误实例。" 2 }
            if ($script:Dry) {
                Write-Output "dry: CDP 127.0.0.1:$port 已通且归属目标（owner pid=$($ownership.Owners -join ',')）；未写入授权会话。"
                break
            }
            $sessionPath = Write-CdpSessionManifest $port $path $ownership.Owners
            Write-Output "CDP: 127.0.0.1:$port 已通且归属目标（owner pid=$($ownership.Owners -join ',')），写授权有效 30 分钟 session=$sessionPath。下一步: node `"$PSScriptRoot\cdp.js`" $port list"
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
            $sessionPath = Write-CdpSessionManifest $port $path $ownership.Owners
            Write-Output "CDP: 127.0.0.1:$port 已通且归属新实例（owner pid=$($ownership.Owners -join ',')），写授权有效 30 分钟 session=$sessionPath。下一步: node `"$PSScriptRoot\cdp.js`" $port list"
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
