# Optional real-app profile for WPS 表格 (Kingsoft WPS Office 12.x, x86) via its
# L0 COM object model KET.Application. CoCreate always starts a private
# `wps.exe /prometheus /et /Automation` process even while the user's WPS is
# running, so this script never touches the user's documents: it writes to, saves
# from and quits only the instance whose pid did not exist before.
#
# Task: new workbook → 3 purchase rows → amount formulas → SUM → COM read-back →
# make the window visible → UIA/PrintWindow/screen cross-checks on the real
# XLMAIN window → save .xlsx → quit → verify the file without WPS (zip XML) →
# reopen it in a second private instance and read D5 again → quit.
#
# Facts this guards (2026-09-08, WPS 12.1.0.23125):
#   * 64-bit hosts can CoCreate the x86 out-of-proc server; Application.Name
#     reports "Microsoft Excel" and Version "12.0" (WPS mimics Excel).
#   * Application.Hwnd is not a top-level window; locate the main window by the
#     new pid and class XLMAIN (WPS reuses Excel's class name, title "WPS Office").
#     The larger KLiteMainWindowShadowBorder sibling is only the shadow.
#   * Excel.Application.12 in the 32-bit registry view also points at WPS et.exe;
#     use KET.Application to mean WPS unambiguously.

$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $PSScriptRoot
$win = Join-Path $root 'scripts\win.ps1'
$evidence = Join-Path ([IO.Path]::GetTempPath()) ("win-use-master-wps-$([Guid]::NewGuid().ToString('N'))")
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
function Get-WpsFamilyPids { @(Get-Process wps, et, wpp -ErrorAction SilentlyContinue | Select-Object -ExpandProperty Id) }
function Wait-Exit([int] $ProcessId, [int] $Seconds) {
    $deadline = [DateTime]::UtcNow.AddSeconds($Seconds)
    while ((Get-Process -Id $ProcessId -ErrorAction SilentlyContinue) -and [DateTime]::UtcNow -lt $deadline) { Start-Sleep -Milliseconds 250 }
    return -not [bool](Get-Process -Id $ProcessId -ErrorAction SilentlyContinue)
}

$before = Get-WpsFamilyPids
$app = $null; $mainPid = 0; $quitRequested = $false; $file = Join-Path $evidence 'wps-sales.xlsx'
try {
    $clock = [Diagnostics.Stopwatch]::StartNew()
    $app = New-Object -ComObject KET.Application; Keep $app
    $startupMs = $clock.ElapsedMilliseconds
    if ([string]$app.Path -notmatch 'WPS Office') { throw "KET.Application 解析到了 $($app.Path)，不是 WPS。" }
    $app.DisplayAlerts = $false
    $workbooks = $app.Workbooks; Keep $workbooks
    $wb = $workbooks.Add(); Keep $wb
    $app.Visible = $true
    Start-Sleep -Milliseconds 900
    $newPids = @(Get-WpsFamilyPids | Where-Object { $_ -notin $before })
    if (-not $newPids.Count) { throw 'refused: KET.Application 没有产生新进程，可能挂进了用户正在运行的 WPS；不会继续写入。' }
    $main = @([HuWin]::AllWindows() | Where-Object { $newPids -contains $_.Pid -and $_.Cls -eq 'XLMAIN' -and $_.W -gt 200 } | Sort-Object { $_.W * $_.H } -Descending | Select-Object -First 1)
    if (-not $main.Count) { throw "新进程 $($newPids -join ',') 里没有 XLMAIN 窗口。" }
    $mainPid = [int]$main[0].Pid
    $hwndText = '0x{0:X}' -f $main[0].Hwnd
    Write-Output "wps: pid=$mainPid startup=${startupMs}ms name=$($app.Name) version=$($app.Version) private-instance=True window=$hwndText class=$($main[0].Cls) title=$($main[0].Title) visible=$($main[0].Visible)"

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

    $read = @(& $win uiaread $hwndText 2>&1 | ForEach-Object { [string]$_ })
    if ($LASTEXITCODE) { throw "uiaread exit=$LASTEXITCODE" }
    $uiaCount = if ($read[0] -match 'elements=(\d+)') { [int]$Matches[1] } else { -1 }
    $uiaFormula = ($read -join "`n") -match [regex]::Escape('=SUM(D2:D4)')
    $list = @(& $win uia $hwndText 2>&1 | ForEach-Object { [string]$_ })
    $actionCount = if ($list[0] -match 'elements=(\d+)') { [int]$Matches[1] } else { -1 }
    $types = @($list | Where-Object { $_ -match '^e\d+ (\w+) ' } | ForEach-Object { $Matches[1] }) | Group-Object | Sort-Object Count -Descending | ForEach-Object { "$($_.Name)=$($_.Count)" }
    Write-Output "uia: readable=$uiaCount formulaBar(SUM)=$uiaFormula actionable=$actionCount types=$($types -join ',')"
    $shotOut = @(& $win shot $hwndText (Join-Path $evidence 'wps-shot.png') 2>&1 | ForEach-Object { [string]$_ })
    if ($LASTEXITCODE) { throw "shot exit=${LASTEXITCODE}: $($shotOut -join ' ')" }
    $shotReceipt = Get-Content -LiteralPath (Join-Path $evidence 'wps-shot.png.receipt.json') -Raw | ConvertFrom-Json
    $screenOut = @(& $win screen (Join-Path $evidence 'wps-screen.png') --window $hwndText 2>&1 | ForEach-Object { [string]$_ })
    $screenState = if ($LASTEXITCODE) { "refused/failed($LASTEXITCODE)" } elseif (($screenOut -join ' ') -match '(\d+)/(\d+) 个采样点被') { "occluded $($Matches[1])/$($Matches[2])" } else { 'unoccluded' }
    Write-Output "l3: printwindow=$($shotReceipt.imageSize.width)x$($shotReceipt.imageSize.height) buckets=$($shotReceipt.colorBuckets) frame=$($shotReceipt.frameColorBuckets) screen=$screenState"

    $wb.SaveAs($file, 51)
    if (-not (Test-Path -LiteralPath $file)) { throw 'SaveAs 没有产出文件。' }
    Write-Output "saved: $(Split-Path -Leaf $file) bytes=$((Get-Item -LiteralPath $file).Length) caption=$($app.Caption)"
    $wb.Close($false)
    if ([int]$workbooks.Count -ne 0) { throw "关闭后仍有 $($workbooks.Count) 个工作簿，不会 Quit。" }
    $quitRequested = $true
    $app.Quit()
} finally {
    if ($app -and -not $quitRequested -and $mainPid) {
        try { $wbs = $app.Workbooks; foreach ($w in @($wbs)) { try { $w.Close($false) } catch { } }; if ([int]$wbs.Count -eq 0) { $app.Quit() } } catch { }
    }
    Release-All
    $app = $null
}
$exited = Wait-Exit $mainPid 20
if (-not $exited) { Write-Warning "私有 WPS 实例 pid=$mainPid 在 Quit 后 20 秒仍在；不强杀。" }

Add-Type -AssemblyName System.IO.Compression.FileSystem
$zip = [IO.Compression.ZipFile]::OpenRead($file)
try { $reader = [IO.StreamReader]::new($zip.GetEntry('xl/worksheets/sheet1.xml').Open()); $sheetXml = $reader.ReadToEnd(); $reader.Dispose() } finally { $zip.Dispose() }
$m = [regex]::Match($sheetXml, '<c r="D5"[^>]*>(?:<f>([^<]*)</f>)?<v>([^<]*)</v>')
if (-not $m.Success -or $m.Groups[1].Value -ne 'SUM(D2:D4)' -or [double]$m.Groups[2].Value -ne 3640) {
    throw "xlsx 文件里 D5 不是 SUM(D2:D4)=3640：formula=$($m.Groups[1].Value) cached=$($m.Groups[2].Value)"
}
Write-Output 'file: D5 formula=SUM(D2:D4) cached=3640 (verified without WPS PASS)'

# Business side effect from a second private instance: the file WPS wrote can be
# reopened and yields the same total.
$before2 = Get-WpsFamilyPids
$app2 = $null; $pid2 = 0; $quit2Requested = $false
try {
    $app2 = New-Object -ComObject KET.Application; Keep $app2
    $app2.DisplayAlerts = $false
    $wbs2 = $app2.Workbooks; Keep $wbs2
    $wb2 = $wbs2.Open($file); Keep $wb2
    $pid2 = @(Get-WpsFamilyPids | Where-Object { $_ -notin $before2 } | Select-Object -First 1)
    $pid2 = if ($pid2.Count) { [int]$pid2[0] } else { 0 }
    $sheets2 = $wb2.Worksheets; Keep $sheets2
    $ws2 = $sheets2.Item(1); Keep $ws2
    $d5b = $ws2.Range('D5'); Keep $d5b
    $reopened = [double]$d5b.Value2
    if ([string]$ws2.Name -ne 'win-use-master' -or $reopened -ne 3640) { throw "重新打开后 sheet=$($ws2.Name) D5=$reopened，与保存前不一致。" }
    Write-Output "reopen: second private instance pid=$pid2 D5=$reopened sheet=$($ws2.Name) PASS"
    $wb2.Close($false)
    $quit2Requested = $true
    $app2.Quit()
} finally {
    if ($app2 -and -not $quit2Requested) {
        try {
            $open2 = $app2.Workbooks
            foreach ($item2 in @($open2)) { try { $item2.Close($false) } catch { } }
            if ([int]$open2.Count -eq 0) { $app2.Quit() }
        } catch { }
    }
    Release-All
    $app2 = $null
}
if ($pid2 -and -not (Wait-Exit $pid2 20)) { Write-Warning "第二个私有 WPS 实例 pid=$pid2 在 Quit 后 20 秒仍在；不强杀。" }
$leftover = @(Get-WpsFamilyPids | Where-Object { $_ -notin $before })
foreach ($id in $leftover) {
    # WPS spawns CEF helpers from the user's own instance; report whose child a leftover is
    # instead of assuming it is ours.
    $row = Get-CimInstance Win32_Process -Filter "ProcessId = $id" -ErrorAction SilentlyContinue
    $kind = if ($row.CommandLine -match 'CefRenderEntryPoint|--type=renderer') { 'cef-helper' } elseif ($row.CommandLine -match '/Automation') { 'automation' } else { 'other' }
    Write-Output "leftover: pid=$id ppid=$($row.ParentProcessId) kind=$kind ours=$($newPids -contains $id -or $id -eq $pid2)"
}
Write-Output "PASS: WPS 表格 12.x KET.Application profile private-instance write→readback→UIA/L3→save→file-verified→reopen quit-exited=$exited leftover-pids=$($leftover.Count) focus=0s"
} finally {
    # Outer privacy boundary: later XML/reopen failures still remove this run's evidence.
    $tempRoot = [IO.Path]::GetFullPath([IO.Path]::GetTempPath())
    $full = [IO.Path]::GetFullPath($evidence)
    if ([IO.Directory]::Exists($full) -and
        $full.StartsWith($tempRoot, [StringComparison]::OrdinalIgnoreCase) -and
        [IO.Path]::GetFileName($full).StartsWith('win-use-master-wps-', [StringComparison]::Ordinal)) {
        Remove-Item -LiteralPath $full -Recurse -Force -ErrorAction SilentlyContinue
    }
}
