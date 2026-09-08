# Optional real-app regression for the Windows 11 Notepad (Store, zh-CN) profile.
# Notepad exposes its text area as a RichEditD2DPT *Document* (not Edit) with
# ValuePattern, so this covers the Document path of uia-worker/first as well as
# the "empty white document is not a blank frame" diagnostic.
#
# Safety: refuses when Notepad is already running, and refuses to write when the
# fresh instance restored a previous session (more than one tab, a modified tab
# or a non-empty document). The write is reverted to an empty document before the
# window is closed, so no save prompt and no persisted session content remain.

$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $PSScriptRoot
$win = Join-Path $root 'scripts\win.ps1'
$evidence = Join-Path ([IO.Path]::GetTempPath()) ("win-use-master-notepad-$([Guid]::NewGuid().ToString('N'))")
$transientEvidence = [Collections.Generic.List[string]]::new()
$notepadOpened = $false
$notepadPid = 0
$notepadHwnd = $null
# Notepad 11 closes a modified tab without prompting and restores it on the next
# launch, so a failed run must clear its own text before the window is closed.
$wroteText = $false
$restored = $false
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

function Get-ReceiptPath($Output) {
    foreach ($item in $Output) {
        if ([string]$item -match '^verification: .+ receipt=(.+)$') { return $Matches[1] }
    }
    return $null
}

try {
    if (@(Get-Process Notepad -ErrorAction SilentlyContinue).Count) {
        throw 'refused: 记事本已在运行；为避免碰到用户未保存的标签页，本档案回归不会复用它。'
    }

    & $win open '记事本' | Out-Null
    if ($LASTEXITCODE) { throw "启动记事本失败 exit=$LASTEXITCODE" }
    $notepadOpened = $true
    $deadline = [DateTime]::UtcNow.AddSeconds(25)
    $windowLine = $null
    while (-not $windowLine -and [DateTime]::UtcNow -lt $deadline) {
        Start-Sleep -Milliseconds 250
        $windowLine = @(& $win windows 'Notepad' --all | Where-Object {
            $_ -match 'state=current' -and $_ -match 'owner="Notepad"' -and $_ -match 'class="Notepad"'
        } | Select-Object -First 1)
        if (-not $windowLine.Count) { $windowLine = $null }
    }
    if (-not $windowLine -or $windowLine[0] -notmatch '^id=(0x[0-9A-F]+) pid=(\d+)') { throw '记事本窗口 25 秒内没有出现。' }
    $notepadHwnd = $Matches[1]; $notepadPid = [int]$Matches[2]
    # The first sighting can be the launch animation; let geometry settle.
    Start-Sleep -Milliseconds 800

    $see = Join-Path $evidence 'notepad-see.png'
    $seeOutput = @(& $win see $notepadHwnd $see)
    if ($LASTEXITCODE) { throw "notepad see exit=$LASTEXITCODE" }
    $map = Get-Content -LiteralPath ($see + '.uia.json') -Raw | ConvertFrom-Json
    $receipt = Get-Content -LiteralPath ($see + '.receipt.json') -Raw | ConvertFrom-Json

    $tabs = @($map.elements | Where-Object controlType -EQ 'TabItem')
    $docs = @($map.elements | Where-Object { $_.controlType -eq 'Document' -and @($_.patterns) -contains 'ValuePattern' })
    if ($docs.Count -ne 1) { throw "记事本 Document(ValuePattern) 控件命中 $($docs.Count) 个，档案定位规则失效。" }
    if ($tabs.Count -ne 1 -or $tabs[0].name -notmatch '未修改' -or -not [string]::IsNullOrEmpty([string]$docs[0].value)) {
        throw 'refused: 记事本恢复了上一次会话（多个标签、已修改标签或非空文档）；不会向用户内容写入。'
    }
    if ($docs[0].className -ne 'RichEditD2DPT') { Write-Warning "Document className=$($docs[0].className)，与档案记录的 RichEditD2DPT 不同；请核对版本漂移。" }

    # An empty white document trips the interior blank heuristic. The tool must
    # then report a rendered frame plus the empty Document instead of a failure.
    if ([int]$receipt.colorBuckets -lt 6) {
        if ($null -eq $receipt.frameColorBuckets -or [int]$receipt.frameColorBuckets -lt 6) { throw "空文档的整帧桶数 $($receipt.frameColorBuckets) 也接近纯色；PrintWindow 对本版记事本可能真的没渲染。" }
        if (($seeOutput -join "`n") -notmatch '窗口框/工具栏已渲染' -or ($seeOutput -join "`n") -notmatch '空的 Document') {
            throw "see 没有把空白文档与截图失败区分开：$($seeOutput -join ' ')"
        }
        Write-Output "blank-heuristic: interior=$($receipt.colorBuckets) frame=$($receipt.frameColorBuckets) explained-by-empty-Document PASS"
    }

    $text = 'win-use-master notepad profile'
    $wroteText = $true
    $setOutput = @(& $win uiaset $notepadHwnd first $text)
    Add-TransientEvidence $setOutput
    if ($LASTEXITCODE) { throw "uiaset exit=$LASTEXITCODE" }
    if (($setOutput -join "`n") -notmatch 'uiaset e\d+ len=\d+ readback-len=\d+') { throw "uiaset 没有报告读回：$($setOutput -join ' ')" }
    $setReceiptPath = Get-ReceiptPath $setOutput
    if (-not $setReceiptPath) { throw 'uiaset 没有输出验证收据。' }
    $setReceipt = Get-Content -LiteralPath $setReceiptPath -Raw | ConvertFrom-Json
    if ($setReceipt.action.target.controlType -ne 'Document' -or $setReceipt.action.semanticReadback -ne 'matched-changed') {
        throw "uiaset 收据不是 Document + matched-changed：controlType=$($setReceipt.action.target.controlType) readback=$($setReceipt.action.semanticReadback)"
    }

    $readAfter = @(& $win uiaread $notepadHwnd)
    if ($LASTEXITCODE) { throw "uiaread exit=$LASTEXITCODE" }
    $readAfterText = $readAfter -join "`n"
    if ($readAfterText -notmatch ('(?m)^Document .*value="' + [regex]::Escape($text) + '"')) { throw '独立 uiaread 没有读回 Document 新值。' }
    if ($readAfterText -notmatch "(?m)^Text .*value=`"$($text.Length) 个字符`"") { throw '状态栏字符数没有随写入变化（应用状态指示器未确认）。' }
    $uiaAfter = @(& $win uia $notepadHwnd)
    if ($LASTEXITCODE -or (($uiaAfter -join "`n") -notmatch '(?m)^e\d+ TabItem ".*已修改')) { throw '标签页没有进入“已修改”状态。' }
    Write-Output "write: Document ValuePattern len=$($text.Length) readback+status+tab PASS"

    $clearOutput = @(& $win uiaset $notepadHwnd first '')
    Add-TransientEvidence $clearOutput
    if ($LASTEXITCODE) { throw "uiaset(clear) exit=$LASTEXITCODE" }
    $readRestored = @(& $win uiaread $notepadHwnd)
    if ($LASTEXITCODE) { throw "uiaread(restored) exit=$LASTEXITCODE" }
    $readRestoredText = $readRestored -join "`n"
    if ($readRestoredText -match '(?m)^Document .*value=".+"') { throw '清空后 Document 仍有内容。' }
    if ($readRestoredText -notmatch '(?m)^Text .*value="0 个字符"') { throw '清空后状态栏没有回到 0 个字符。' }
    $uiaRestored = @(& $win uia $notepadHwnd)
    if ($LASTEXITCODE -or (($uiaRestored -join "`n") -notmatch '(?m)^e\d+ TabItem ".*未修改')) { throw '清空后标签页没有回到“未修改”。' }
    $restored = $true
    Write-Output 'PASS: Notepad 11.x Document/ValuePattern profile write+readback, indicators, restored=0 chars, focus=0s'
} finally {
    if ($notepadOpened -and $notepadPid -gt 0) {
        $proc = Get-Process -Id $notepadPid -ErrorAction SilentlyContinue
        if ($proc -and $wroteText -and -not $restored -and $notepadHwnd) {
            try {
                $cleanup = @(& $win uiaset $notepadHwnd first '' 2>&1)
                Add-TransientEvidence $cleanup
                $check = @(& $win uiaread $notepadHwnd 2>&1) -join "`n"
                if ($check -notmatch '(?m)^Text .*value="0 个字符"') { Write-Warning '失败后没能把记事本清空；关闭后它会把测试文本恢复进下次会话，请手动删除。' }
            } catch { Write-Warning "失败后清空记事本出错：$($_.Exception.Message)" }
        }
        if ($proc) {
            $proc.CloseMainWindow() | Out-Null
            if (-not $proc.WaitForExit(8000)) {
                Write-Warning '记事本 8 秒内没有退出（可能出现保存提示）；不会强杀，请用户处理。'
            }
        }
    }
    foreach ($path in @($transientEvidence | Select-Object -Unique)) {
        $full = [IO.Path]::GetFullPath($path)
        $tempRoot = [IO.Path]::GetFullPath([IO.Path]::GetTempPath())
        if ($full.StartsWith($tempRoot, [StringComparison]::OrdinalIgnoreCase) -and
            [IO.Path]::GetFileName($full) -match '^uiaset-after-[0-9a-f]{32}\.png(\.receipt\.json)?$' -and
            [IO.File]::Exists($full)) {
            [IO.File]::Delete($full)
        }
    }
    $fullEvidence = [IO.Path]::GetFullPath($evidence)
    $tempRoot = [IO.Path]::GetFullPath([IO.Path]::GetTempPath())
    if ([IO.Directory]::Exists($fullEvidence) -and
        $fullEvidence.StartsWith($tempRoot, [StringComparison]::OrdinalIgnoreCase) -and
        [IO.Path]::GetFileName($fullEvidence).StartsWith('win-use-master-notepad-')) {
        [IO.Directory]::Delete($fullEvidence, $true)
    }
}
