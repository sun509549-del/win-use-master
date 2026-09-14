# Optional read-only profile for Windows 11 Settings (zh-CN).
#
# Safety: refuses when SystemSettings or its visible Settings frame already
# exists, never invokes a control or writes a value, and closes only the exact
# frame it opened. The screenshot/UIA map may contain account and device names,
# so all evidence stays in a unique temp directory and is deleted in finally.

$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $PSScriptRoot
$win = Join-Path $root 'scripts\win.ps1'
$evidence = Join-Path ([IO.Path]::GetTempPath()) ("win-use-master-settings-$([Guid]::NewGuid().ToString('N'))")
$settingsOpened = $false
$settingsHwnd = $null
$framePid = 0
$passMessage = $null
$cleanupError = $null
[IO.Directory]::CreateDirectory($evidence) | Out-Null

try {
    $existingProcesses = @(Get-Process SystemSettings -ErrorAction SilentlyContinue)
    $existingFrames = @(& $win windows '设置' --all | Where-Object {
        $_ -match 'state=(current|min)' -and $_ -match 'class="ApplicationFrameWindow"' -and $_ -match 'title="设置"'
    })
    if ($existingProcesses.Count -or $existingFrames.Count) {
        throw 'refused: Windows 设置已在运行；为避免改变用户的页面和窗口状态，本档案不会复用它。'
    }

    & $win open '设置' | Out-Null
    if ($LASTEXITCODE) { throw "启动 Windows 设置失败 exit=$LASTEXITCODE" }
    $settingsOpened = $true

    $deadline = [DateTime]::UtcNow.AddSeconds(25)
    $windowLine = $null
    while (-not $windowLine -and [DateTime]::UtcNow -lt $deadline) {
        Start-Sleep -Milliseconds 200
        $windowLine = @(& $win windows '设置' --all | Where-Object {
            $_ -match 'state=current' -and $_ -match 'class="ApplicationFrameWindow"' -and $_ -match 'title="设置"'
        } | Select-Object -First 1)
        if (-not $windowLine.Count) { $windowLine = $null }
    }
    if (-not $windowLine -or $windowLine[0] -notmatch '^id=(0x[0-9A-F]+) pid=(\d+)') {
        throw 'Windows 设置顶层窗口 25 秒内没有出现。'
    }
    $settingsHwnd = $Matches[1]
    $framePid = [int]$Matches[2]

    $seePath = Join-Path $evidence 'settings-see.png'
    $seeOutput = @(& $win see $settingsHwnd $seePath --summary)
    if ($LASTEXITCODE) { throw "Windows 设置 see 失败 exit=$LASTEXITCODE" }

    $receiptPath = $seePath + '.receipt.json'
    $mapPath = $seePath + '.uia.json'
    $receipt = Get-Content -LiteralPath $receiptPath -Raw -Encoding utf8 | ConvertFrom-Json
    $map = Get-Content -LiteralPath $mapPath -Raw -Encoding utf8 | ConvertFrom-Json
    if ([string]$receipt.schema -ne 'win-use-master/receipt-v1') { throw 'Windows 设置截图收据 schema 不匹配。' }
    if ([string]$receipt.window.hwnd -ne $settingsHwnd -or [string]$receipt.window.title -ne '设置') {
        throw 'Windows 设置截图收据没有绑定到请求窗口。'
    }
    if ([int]$receipt.colorBuckets -lt 20) { throw "Windows 设置后台截图颜色桶异常：$($receipt.colorBuckets)" }
    if ([string]$map.schema -ne 'win-use-master/uia-map-v1' -or [string]$map.window.hwnd -ne $settingsHwnd) {
        throw 'Windows 设置 UIA map schema 或窗口身份不匹配。'
    }
    $seeText = $seeOutput -join "`n"
    if ($seeText -notmatch '--summary 已省略名称/值' -or $seeText -match 'CommandSearchTextBox|UserProfileControlButton') {
        throw 'Windows 设置 see --summary 没有抑制 UIA 语义明细。'
    }
    foreach ($sensitiveName in @($map.elements | Where-Object automationId -EQ 'UserProfileControlButton' | Select-Object -ExpandProperty name)) {
        if ($sensitiveName -and $seeText.Contains([string]$sensitiveName)) {
            throw 'Windows 设置 see --summary 泄露了账户控件名称。'
        }
    }
    $uiaSummary = @(& $win uia $settingsHwnd --summary)
    $uiaSummaryExit = $LASTEXITCODE
    $uiaReadSummary = @(& $win uiaread $settingsHwnd --summary)
    $uiaReadSummaryExit = $LASTEXITCODE
    $summaryText = @($uiaSummary + $uiaReadSummary) -join "`n"
    if ($uiaSummaryExit -or $uiaReadSummaryExit -or $summaryText -notmatch 'UIA --summary 已省略名称/值' -or
        $summaryText -notmatch 'UIA read --summary 已省略名称/值' -or
        $summaryText -match 'CommandSearchTextBox|UserProfileControlButton') {
        throw 'Windows 设置 uia/uiaread --summary 没有抑制 UIA 语义明细。'
    }
    foreach ($sensitiveName in @($map.elements | Where-Object automationId -EQ 'UserProfileControlButton' | Select-Object -ExpandProperty name)) {
        if ($sensitiveName -and $summaryText.Contains([string]$sensitiveName)) {
            throw 'Windows 设置 UIA 摘要命令泄露了账户控件名称。'
        }
    }

    $searchBoxes = @($map.elements | Where-Object {
        $_.controlType -eq 'Edit' -and $_.automationId -eq 'CommandSearchTextBox' -and
        'ValuePattern' -in @($_.patterns) -and -not $_.isPassword
    })
    if ($searchBoxes.Count -ne 1) { throw "CommandSearchTextBox 命中 $($searchBoxes.Count) 个。" }
    $closeButtons = @($map.elements | Where-Object {
        $_.controlType -eq 'Button' -and $_.automationId -eq 'Close' -and 'InvokePattern' -in @($_.patterns)
    })
    if ($closeButtons.Count -ne 1) { throw "设置窗口关闭按钮命中 $($closeButtons.Count) 个。" }

    # Exact IDs are selected in the worker before reading Name/Value; fuzzy
    # filtering could read or return unrelated account/device content.
    $label = @(& $win uiaread $settingsHwnd --id SettingsLabel)
    if ($LASTEXITCODE -or (($label -join "`n") -notmatch 'Text name="设置" id="SettingsLabel"')) {
        throw 'Windows 设置标题没有通过独立 UIA 只读路径回读。'
    }
    $search = @(& $win uiaread $settingsHwnd --id CommandSearchTextBox)
    if ($LASTEXITCODE -or (($search -join "`n") -notmatch 'Edit name="搜索框，查找设置" id="CommandSearchTextBox"')) {
        throw 'Windows 设置搜索框没有通过独立 UIA 只读路径回读。'
    }

    $passMessage = "PASS: Windows Settings $([Environment]::OSVersion.Version) isolated read-only profile host=ApplicationFrameHost UIA-search=unique PrintWindow-colors=$($receipt.colorBuckets) writes=0 evidence=cleaned"
} finally {
    if ($settingsOpened) {
        $frame = if ($framePid -gt 0) { Get-Process -Id $framePid -ErrorAction SilentlyContinue } else { $null }
        if ($frame -and $frame.MainWindowTitle -eq '设置' -and
            (-not $settingsHwnd -or ('0x{0:X}' -f $frame.MainWindowHandle.ToInt64()) -eq $settingsHwnd)) {
            $frame.CloseMainWindow() | Out-Null
        }
    }
    $fullEvidence = [IO.Path]::GetFullPath($evidence)
    $tempRoot = [IO.Path]::GetFullPath([IO.Path]::GetTempPath())
    if ([IO.Directory]::Exists($fullEvidence) -and
        $fullEvidence.StartsWith($tempRoot, [StringComparison]::OrdinalIgnoreCase) -and
        [IO.Path]::GetFileName($fullEvidence).StartsWith('win-use-master-settings-')) {
        [IO.Directory]::Delete($fullEvidence, $true)
    }
    if ($settingsOpened) {
        $deadline = [DateTime]::UtcNow.AddSeconds(8)
        do {
            $remaining = @(Get-Process SystemSettings -ErrorAction SilentlyContinue)
            if (-not $remaining.Count) { break }
            Start-Sleep -Milliseconds 200
        } while ([DateTime]::UtcNow -lt $deadline)
        if ($remaining.Count) { $cleanupError = 'Windows 设置内容进程在关闭精确窗口后仍未退出。' }
    }
}

if ($cleanupError) { throw $cleanupError }
Write-Output $passMessage
