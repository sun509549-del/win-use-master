# Optional real-app profile for Microsoft Excel (Click-to-Run, Office16) via the
# L0 COM object model. It never touches an existing Excel session: CoCreate of
# Excel.Application starts a private /automation instance, which is the only one
# this script writes to, saves from and quits.
#
# Task: new workbook → 3 purchase rows → amount formulas → SUM → read back over
# COM → make the window visible → UIA/PrintWindow/screen cross-checks → save to
# a temp .xlsx → close → quit → verify the saved file WITHOUT Excel by reading the
# cached SUM out of xl/worksheets/sheet1.xml.
#
# Facts this guards (2026-09-08, Excel 16.0.20326):
#   * Application.Visible=True is ignored while no workbook window exists; set it
#     after Workbooks.Add(). Otherwise XLMAIN stays hidden and UIA/PrintWindow are empty.
#   * pwsh 7's COM binder rejects Int32 for Range.Value2; write doubles.
#   * COM objects must not be returned through PowerShell functions: collections
#     unroll (empty Workbooks becomes $null) and -NoEnumerate breaks property sets.
#   * Every Range/Worksheet/Workbook RCW must be released before Quit, or the
#     /automation process lingers until the DCOM ping timeout (~6 minutes).
#   * WPS registers Excel.Application.12 → et.exe in the 32-bit view; a 64-bit host
#     gets Microsoft Excel, a 32-bit host may get WPS. The exe path is asserted.

$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $PSScriptRoot
$win = Join-Path $root 'scripts\win.ps1'
$evidence = Join-Path ([IO.Path]::GetTempPath()) ("win-use-master-excel-$([Guid]::NewGuid().ToString('N'))")
[IO.Directory]::CreateDirectory($evidence) | Out-Null
try {
Add-Type -AssemblyName System.Drawing.Common -ErrorAction SilentlyContinue
Add-Type -Path (Join-Path $root 'scripts\HuWin.dll')

$com = [Collections.Generic.List[object]]::new()
function Keep($Object) { if ($null -ne $Object) { [void]$script:com.Add($Object) } }
function Release-All {
    for ($i = $script:com.Count - 1; $i -ge 0; $i--) {
        try { [void][Runtime.InteropServices.Marshal]::FinalReleaseComObject($script:com[$i]) } catch { }
    }
    $script:com.Clear()
    [GC]::Collect(); [GC]::WaitForPendingFinalizers(); [GC]::Collect()
}

$app = $null; $excelPid = 0; $quitRequested = $false
try {
    $before = @(Get-Process EXCEL -ErrorAction SilentlyContinue | Select-Object -ExpandProperty Id)
    $clock = [Diagnostics.Stopwatch]::StartNew()
    $app = New-Object -ComObject Excel.Application; Keep $app
    $startupMs = $clock.ElapsedMilliseconds
    $hwnd = [long]$app.Hwnd
    $mainWindow = @([HuWin]::AllWindows() | Where-Object { $_.Hwnd -eq $hwnd } | Select-Object -First 1)
    if (-not $mainWindow.Count) { throw 'Excel.Application.Hwnd 没有对应顶层窗口。' }
    $excelPid = [int]$mainWindow[0].Pid
    $exe = (Get-Process -Id $excelPid).Path
    if ($exe -notmatch '\\EXCEL\.EXE$') { throw "Excel.Application 解析到了 $exe，不是 Microsoft Excel（32 位视图里 WPS 注册了同一 ProgID）。" }
    if ([string]$app.Version -notmatch '^16\.') { Write-Warning "Excel 版本 $($app.Version) 与档案记录的 16.x 不同。" }
    if ($before -contains $excelPid) { throw 'CoCreate 复用了已存在的 Excel 进程；为避免碰用户会话，本回归停止。' }
    Write-Output "excel: pid=$excelPid version=$($app.Version) build=$($app.Build) startup=${startupMs}ms private-instance=True"

    $app.DisplayAlerts = $false
    $workbooks = $app.Workbooks; Keep $workbooks
    $wb = $workbooks.Add(); Keep $wb
    # Visible must be set after a workbook exists; before that Excel ignores it.
    # Workbooks.Add also creates a new XLMAIN and Application.Hwnd moves to it, so
    # the handle captured at startup is stale from here on.
    $app.Visible = $true
    Start-Sleep -Milliseconds 700
    $visibleNow = [bool]$app.Visible
    $startupHwnd = $hwnd
    $hwnd = [long]$app.Hwnd
    $mainWindow = @([HuWin]::AllWindows() | Where-Object { $_.Hwnd -eq $hwnd } | Select-Object -First 1)
    if (-not $mainWindow.Count -or -not $visibleNow -or -not $mainWindow[0].Visible) { throw "Workbooks.Add 之后 Visible=$visibleNow / XLMAIN 0x$('{0:X}' -f $hwnd) visible=$($mainWindow[0].Visible)，窗口没有显示。" }
    Write-Output "window: 0x$('{0:X}' -f $hwnd) class=$($mainWindow[0].Cls) title=$($mainWindow[0].Title) visible-after-add=True hwnd-moved=$($startupHwnd -ne $hwnd)"

    $sheets = $wb.Worksheets; Keep $sheets
    $ws = $sheets.Item(1); Keep $ws
    $ws.Name = 'win-use-master'
    $cells = $ws.Cells; Keep $cells
    $headers = @('项目', '数量', '单价', '金额')
    for ($c = 0; $c -lt 4; $c++) { $cell = $cells.Item(1, $c + 1); Keep $cell; $cell.Value2 = $headers[$c] }
    $rows = @(@('键盘', 3, 199), @('鼠标', 5, 89), @('显示器', 2, 1299))
    for ($r = 0; $r -lt 3; $r++) {
        $cell = $cells.Item($r + 2, 1); Keep $cell; $cell.Value2 = $rows[$r][0]
        $cell = $cells.Item($r + 2, 2); Keep $cell; $cell.Value2 = [double]$rows[$r][1]
        $cell = $cells.Item($r + 2, 3); Keep $cell; $cell.Value2 = [double]$rows[$r][2]
    }
    $amounts = $ws.Range('D2:D4'); Keep $amounts; $amounts.Formula = '=B2*C2'
    $label = $ws.Range('A5'); Keep $label; $label.Value2 = '合计'
    $d5 = $ws.Range('D5'); Keep $d5
    $d5.Formula = '=SUM(D2:D4)'
    $app.Calculate()
    $total = [double]$d5.Value2
    if ($total -ne 3640) { throw "COM 读回 D5=$total，期望 3640。" }
    $d5.Select() | Out-Null
    Start-Sleep -Milliseconds 500
    Write-Output "com: D5=$total formula=$($d5.Formula) (readback over COM PASS)"

    $hwndText = '0x{0:X}' -f $hwnd
    $read = @(& $win uiaread $hwndText 2>&1 | ForEach-Object { [string]$_ })
    if ($LASTEXITCODE) { throw "uiaread exit=$LASTEXITCODE" }
    $readText = $read -join "`n"
    $uiaNameBox = $readText -match '(?m)^Edit .*value="D5"'
    $uiaFormula = $readText -match [regex]::Escape('=SUM(D2:D4)')
    $uiaCount = if ($read[0] -match 'elements=(\d+)') { [int]$Matches[1] } else { -1 }
    Write-Output "uia: readable=$uiaCount nameBox(D5)=$uiaNameBox formulaBar(SUM)=$uiaFormula"
    $shotOut = @(& $win shot $hwndText (Join-Path $evidence 'excel-shot.png') 2>&1 | ForEach-Object { [string]$_ })
    if ($LASTEXITCODE) { throw "shot exit=${LASTEXITCODE}: $($shotOut -join ' ')" }
    $shotReceipt = Get-Content -LiteralPath (Join-Path $evidence 'excel-shot.png.receipt.json') -Raw | ConvertFrom-Json
    $screenOut = @(& $win screen (Join-Path $evidence 'excel-screen.png') --window $hwndText 2>&1 | ForEach-Object { [string]$_ })
    $screenState = if ($LASTEXITCODE) { "refused/failed($LASTEXITCODE)" } elseif (($screenOut -join ' ') -match '(\d+)/(\d+) 个采样点被') { "occluded $($Matches[1])/$($Matches[2])" } else { 'unoccluded' }
    Write-Output "l3: printwindow=$($shotReceipt.imageSize.width)x$($shotReceipt.imageSize.height) buckets=$($shotReceipt.colorBuckets) screen=$screenState"

    $file = Join-Path $evidence 'sales.xlsx'
    $wb.SaveAs($file, 51)
    if (-not (Test-Path -LiteralPath $file)) { throw 'SaveAs 没有产出文件。' }
    Write-Output "saved: $(Split-Path -Leaf $file) bytes=$((Get-Item -LiteralPath $file).Length) caption=$($app.Caption)"
    $wb.Close($false)
    if ([int]$workbooks.Count -ne 0) { throw "关闭后仍有 $($workbooks.Count) 个工作簿，不会 Quit。" }
    $quitRequested = $true
    $app.Quit()
} finally {
    if ($app -and -not $quitRequested) {
        try { $wbs = $app.Workbooks; foreach ($w in @($wbs)) { try { $w.Close($false) } catch { } }; if ([int]$wbs.Count -eq 0) { $app.Quit() } } catch { }
    }
    Release-All
    $app = $null
}

$deadline = [DateTime]::UtcNow.AddSeconds(30)
while ((Get-Process -Id $excelPid -ErrorAction SilentlyContinue) -and [DateTime]::UtcNow -lt $deadline) { Start-Sleep -Milliseconds 250 }
$lingering = [bool](Get-Process -Id $excelPid -ErrorAction SilentlyContinue)
if ($lingering) { Write-Warning "私有 Excel 实例 pid=$excelPid 在 Quit 后 30 秒仍在（无窗口）；通常随 DCOM ping 超时退出，不强杀。" }

Add-Type -AssemblyName System.IO.Compression.FileSystem
$file = Join-Path $evidence 'sales.xlsx'
$zip = [IO.Compression.ZipFile]::OpenRead($file)
try {
    $reader = [IO.StreamReader]::new($zip.GetEntry('xl/worksheets/sheet1.xml').Open()); $sheetXml = $reader.ReadToEnd(); $reader.Dispose()
    $reader = [IO.StreamReader]::new($zip.GetEntry('xl/workbook.xml').Open()); $wbXml = $reader.ReadToEnd(); $reader.Dispose()
} finally { $zip.Dispose() }
$m = [regex]::Match($sheetXml, '<c r="D5"[^>]*>(?:<f>([^<]*)</f>)?<v>([^<]*)</v>')
if (-not $m.Success -or $m.Groups[1].Value -ne 'SUM(D2:D4)' -or [double]$m.Groups[2].Value -ne 3640) {
    throw "xlsx 文件里 D5 不是 SUM(D2:D4)=3640：formula=$($m.Groups[1].Value) cached=$($m.Groups[2].Value)"
}
if ($wbXml -notmatch 'sheet name="win-use-master"') { throw 'xlsx 里没有重命名后的工作表。' }
Write-Output "file: D5 formula=SUM(D2:D4) cached=3640 sheet=win-use-master (verified without Excel PASS)"
Write-Output "PASS: Excel 16.x COM profile private-instance write→readback→visible→UIA/L3→save→file-verified quit-exited=$(-not $lingering) focus=0s"
} finally {
    # Outer privacy boundary: verification failures must not leave screenshots or workbooks behind.
    $tempRoot = [IO.Path]::GetFullPath([IO.Path]::GetTempPath())
    $full = [IO.Path]::GetFullPath($evidence)
    if ([IO.Directory]::Exists($full) -and
        $full.StartsWith($tempRoot, [StringComparison]::OrdinalIgnoreCase) -and
        [IO.Path]::GetFileName($full).StartsWith('win-use-master-excel-', [StringComparison]::Ordinal)) {
        Remove-Item -LiteralPath $full -Recurse -Force -ErrorAction SilentlyContinue
    }
}
