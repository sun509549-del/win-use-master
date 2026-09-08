# Optional real-app regression for the localized Windows Calculator profile.
# It refuses to reuse an existing Calculator window so user state is untouched.

$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $PSScriptRoot
$win = Join-Path $root 'scripts\win.ps1'
$evidence = Join-Path ([IO.Path]::GetTempPath()) ("win-use-master-calculator-$([Guid]::NewGuid().ToString('N'))")
$transientEvidence = [Collections.Generic.List[string]]::new()
$calculatorOpened = $false
$calculatorHwnd = $null
$framePid = 0
[IO.Directory]::CreateDirectory($evidence) | Out-Null

function Add-TransientEvidence($Output) {
    foreach ($item in $Output) {
        $line = [string]$item
        if ($line -match '^verification: (.+) receipt=(.+)$') {
            [void]$transientEvidence.Add($Matches[1])
            [void]$transientEvidence.Add($Matches[2])
        }
    }
}

function Get-MapRef($Map, [string] $AutomationId) {
    $matches = @($Map.elements | Where-Object automationId -EQ $AutomationId)
    if ($matches.Count -ne 1) { throw "Calculator AutomationId=$AutomationId 命中 $($matches.Count) 个元素。" }
    return [string]$matches[0].ref
}

try {
    $existing = @(& $win windows '计算器' --all | Where-Object { $_ -match 'state=current' -and $_ -match 'title="计算器"' })
    if ($existing.Count) { throw 'refused: 计算器已经打开；为避免改变用户现有状态，本档案回归不会复用它。' }

    & $win open '计算器' | Out-Null
    if ($LASTEXITCODE) { throw "启动计算器失败 exit=$LASTEXITCODE" }
    $calculatorOpened = $true
    $deadline = [DateTime]::UtcNow.AddSeconds(25)
    $windowLine = $null
    while (-not $windowLine -and [DateTime]::UtcNow -lt $deadline) {
        Start-Sleep -Milliseconds 200
        $windowLine = @(& $win windows '计算器' --all | Where-Object { $_ -match 'state=current' -and $_ -match 'title="计算器"' } | Select-Object -First 1)
        if (-not $windowLine.Count) { $windowLine = $null }
    }
    if (-not $windowLine -or $windowLine[0] -notmatch '^id=(0x[0-9A-F]+) pid=(\d+)') { throw '计算器窗口 25 秒内没有出现。' }
    $calculatorHwnd = $Matches[1]; $framePid = [int]$Matches[2]

    $see = Join-Path $evidence 'calculator-see.png'
    & $win see $calculatorHwnd --out $see | Out-Null
    if ($LASTEXITCODE) { throw "calculator see exit=$LASTEXITCODE" }
    $mapPath = $see + '.uia.json'
    $map = Get-Content -LiteralPath $mapPath -Raw | ConvertFrom-Json
    $sequence = @('clearButton','num1Button','plusButton','num2Button','equalButton')
    foreach ($automationId in $sequence) {
        $ref = Get-MapRef $map $automationId
        $actionOutput = @(& $win invoke $calculatorHwnd $ref ("@" + $mapPath))
        Add-TransientEvidence $actionOutput
        if ($LASTEXITCODE) { throw "Calculator invoke $automationId exit=$LASTEXITCODE" }
    }
    $result = @(& $win uiaread $calculatorHwnd CalculatorResults)
    if ($LASTEXITCODE -or (($result -join "`n") -notmatch '显示为 3')) { throw '计算器没有独立回读到 1+2=3。' }

    $clearRef = Get-MapRef $map 'clearButton'
    $restoreOutput = @(& $win invoke $calculatorHwnd $clearRef ("@" + $mapPath))
    Add-TransientEvidence $restoreOutput
    if ($LASTEXITCODE) { throw "Calculator restore exit=$LASTEXITCODE" }
    $restored = @(& $win uiaread $calculatorHwnd CalculatorResults)
    if ($LASTEXITCODE -or (($restored -join "`n") -notmatch '显示为 0')) { throw '计算器没有恢复为 0。' }
    Write-Output 'PASS: Calculator 11.x isolated-UIA profile 1+2=3, restored=0, focus=0s'
} finally {
    if ($calculatorOpened -and $framePid -gt 0) {
        $frameProcess = Get-Process -Id $framePid -ErrorAction SilentlyContinue
        if ($frameProcess -and $frameProcess.MainWindowTitle -eq '计算器' -and
            ('0x{0:X}' -f $frameProcess.MainWindowHandle.ToInt64()) -eq $calculatorHwnd) {
            $frameProcess.CloseMainWindow() | Out-Null
        }
    }
    foreach ($path in @($transientEvidence | Select-Object -Unique)) {
        $full = [IO.Path]::GetFullPath($path)
        $tempRoot = [IO.Path]::GetFullPath([IO.Path]::GetTempPath())
        if ($full.StartsWith($tempRoot, [StringComparison]::OrdinalIgnoreCase) -and
            [IO.Path]::GetFileName($full) -match '^invoke-after-[0-9a-f]{32}\.png(\.receipt\.json)?$' -and
            [IO.File]::Exists($full)) {
            [IO.File]::Delete($full)
        }
    }
    $fullEvidence = [IO.Path]::GetFullPath($evidence)
    $tempRoot = [IO.Path]::GetFullPath([IO.Path]::GetTempPath())
    if ([IO.Directory]::Exists($fullEvidence) -and
        $fullEvidence.StartsWith($tempRoot, [StringComparison]::OrdinalIgnoreCase) -and
        [IO.Path]::GetFileName($fullEvidence).StartsWith('win-use-master-calculator-')) {
        [IO.Directory]::Delete($fullEvidence, $true)
    }
}
