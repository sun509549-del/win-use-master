param([int] $StartPort = 49433)

$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $PSScriptRoot
$cdp = Join-Path $root 'scripts\cdp.js'
$node = (Get-Command node -ErrorAction Stop).Source
$edgeCandidates = @(
    'C:\Program Files (x86)\Microsoft\Edge\Application\msedge.exe',
    'C:\Program Files\Microsoft\Edge\Application\msedge.exe'
)
$edgeExe = $edgeCandidates | Where-Object { Test-Path -LiteralPath $_ } | Select-Object -First 1
if (-not $edgeExe) { throw '找不到 Microsoft Edge，无法运行真实 CDP 动作收据回归。' }

$port = $StartPort
while ($port -le 65535 -and (Get-NetTCPConnection -State Listen -LocalPort $port -ErrorAction SilentlyContinue)) { $port++ }
if ($port -gt 65535) { throw "从 $StartPort 起找不到空闲测试端口。" }

$tempRoot = Join-Path ([IO.Path]::GetTempPath()) ("win-use-master-cdp-receipt-test-" + [Guid]::NewGuid().ToString('N'))
$profile = Join-Path $tempRoot 'edge-profile'
[IO.Directory]::CreateDirectory($profile) | Out-Null
$receipts = @{
    Text = Join-Path $tempRoot 'text.json'
    Insert = Join-Path $tempRoot 'insert.json'
    SelectAll = Join-Path $tempRoot 'selectall.json'
    Revert = Join-Path $tempRoot 'revert.json'
    Click = Join-Path $tempRoot 'click.json'
    Press = Join-Path $tempRoot 'press.json'
    Act = Join-Path $tempRoot 'act.json'
    Error = Join-Path $tempRoot 'error.json'
    Timeout = Join-Path $tempRoot 'timeout.json'
    ActDeadline = Join-Path $tempRoot 'act-deadline.json'
}

$edge = $null
try {
    $edgeArgs = @(
        '--headless=new', "--remote-debugging-port=$port", "--user-data-dir=$profile",
        '--no-first-run', '--no-default-browser-check', '--disable-background-networking',
        '--remote-allow-origins=*', 'about:blank'
    )
    $edge = Start-Process -FilePath $edgeExe -ArgumentList $edgeArgs -WindowStyle Hidden -PassThru
    # A cold GitHub runner creates the profile and warms Edge on first launch;
    # 12 s was observed to be too tight there. The loop exits as soon as CDP answers.
    $readyClock = [Diagnostics.Stopwatch]::StartNew()
    $deadline = [DateTime]::UtcNow.AddSeconds(30)
    do {
        try { $targets = Invoke-RestMethod -Uri "http://127.0.0.1:$port/json/list" -TimeoutSec 1 } catch { $targets = $null }
        if ($targets) { break }
        Start-Sleep -Milliseconds 100
    } while ([DateTime]::UtcNow -lt $deadline)
    if (-not $targets) {
        $edgeState = if ($edge.HasExited) { "Edge 已退出 exit=$($edge.ExitCode)" } else { 'Edge 仍在运行但 /json/list 无响应' }
        throw "临时 Edge CDP 实例 $([int]$readyClock.Elapsed.TotalSeconds)s 内没有就绪（$edgeState，port=$port）。"
    }
    Write-Output "edge-ready: $([Math]::Round($readyClock.Elapsed.TotalSeconds,1))s port=$port"

    # #ce mimics Slate/ProseMirror composers: a contenteditable div with
    # role=textbox, whose collected kind is div/textbox rather than div/editable.
    $setupJs = "document.body.innerHTML='<input id=i value=abc><button id=b onclick=`"this.disabled=true`">Go</button><button id=b2 onclick=`"this.remove()`">Gone</button><div id=ce role=textbox contenteditable=true>seed</div>'; 'ready'"
    $setup = @(& $node $cdp $port eval auto $setupJs 2>&1)
    if ($LASTEXITCODE -ne 0 -or (($setup | Out-String) -notmatch 'ready')) { throw "fixture 初始化失败：$($setup -join ' ')" }

    $secret = 's3cr3t-value'
    $textOut = @(& $node $cdp $port text auto '#i' $secret --receipt $receipts.Text 2>&1)
    if ($LASTEXITCODE -ne 0) { throw "text 失败：$($textOut -join ' ')" }
    $textReceipt = Get-Content -LiteralPath $receipts.Text -Raw | ConvertFrom-Json
    $textRaw = Get-Content -LiteralPath $receipts.Text -Raw
    if ($textReceipt.schema -ne 'win-use-master/action-receipt-v1' -or
        $textReceipt.action.textLength -ne $secret.Length -or $textReceipt.focus.borrowed -ne $false -or
        $textReceipt.verification.effect -ne 'partial' -or $textRaw.Contains($secret) -or $textRaw.Contains('#i')) {
        throw 'text 收据字段、effect 或脱敏不符合约定。'
    }

    $editorSecret = 'private-draft-text'
    $insertOut = @(& $node $cdp $port insert auto '#ce' $editorSecret --receipt $receipts.Insert 2>&1)
    if ($LASTEXITCODE -ne 0) { throw "insert 失败：$($insertOut -join ' ')" }
    $insertText = $insertOut | Out-String
    $insertReceipt = Get-Content -LiteralPath $receipts.Insert -Raw | ConvertFrom-Json
    if ($insertText.Contains($editorSecret) -or $insertText -notmatch '~ ref=e\d+ div/textbox text <\d+ chars>→<\d+ chars>' -or
        $insertReceipt.action.textLength -ne $editorSecret.Length -or (Get-Content -LiteralPath $receipts.Insert -Raw).Contains($editorSecret)) {
        throw "role=textbox 编辑器的终端差分或收据泄露了输入正文：$($insertOut -join ' | ')"
    }
    $selectAllOut = @(& $node $cdp $port press auto SelectAll '#ce' --receipt $receipts.SelectAll 2>&1)
    if ($LASTEXITCODE -ne 0) { throw "press SelectAll 失败：$($selectAllOut -join ' ')" }
    $revertOut = @(& $node $cdp $port press auto Backspace '#ce' --receipt $receipts.Revert 2>&1)
    if ($LASTEXITCODE -ne 0) { throw "press Backspace 失败：$($revertOut -join ' ')" }
    # A plain contenteditable keeps a placeholder <br> after deleting everything, so
    # measure the remaining text rather than innerText/childNodes.
    $editorLeft = & $node $cdp $port eval auto "document.getElementById('ce').textContent.trim().length" 2>&1
    if ([string]($editorLeft | Select-Object -Last 1) -ne '0') { throw "SelectAll+Backspace 没有清空 role=textbox 编辑器：剩余 $editorLeft" }
    Write-Output 'editor-redaction+revert: role=textbox insert redacted, SelectAll+Backspace cleared PASS'

    $clickOut = @(& $node $cdp $port click auto '#b' --receipt $receipts.Click 2>&1)
    if ($LASTEXITCODE -ne 0) { throw "click 失败：$($clickOut -join ' ')" }
    $clickReceipt = Get-Content -LiteralPath $receipts.Click -Raw | ConvertFrom-Json
    if ($clickReceipt.verification.effect -ne 'partial' -or $clickReceipt.verification.diff.changed -lt 1) {
        throw 'click 没有记录 disabled 语义变化。'
    }

    $pressOut = @(& $node $cdp $port press auto Backspace '#i' --receipt $receipts.Press 2>&1)
    if ($LASTEXITCODE -ne 0) { throw "press 失败：$($pressOut -join ' ')" }
    $pressReceipt = Get-Content -LiteralPath $receipts.Press -Raw | ConvertFrom-Json
    if ($pressReceipt.action.key -ne 'Backspace' -or $pressReceipt.verification.effect -ne 'partial') {
        throw 'press 收据缺少按键或语义变化。'
    }

    $actSecret = 'private-act'
    $actScript = "text #i `"$actSecret`"`nclick #b2"
    $actOut = @(& $node $cdp $port act auto $actScript --receipt $receipts.Act 2>&1)
    if ($LASTEXITCODE -ne 0) { throw "act 失败：$($actOut -join ' ')" }
    $actReceipt = Get-Content -LiteralPath $receipts.Act -Raw | ConvertFrom-Json
    $actRaw = Get-Content -LiteralPath $receipts.Act -Raw
    if ($actReceipt.action.stepsCompleted -ne 2 -or $actReceipt.events.Count -ne 2 -or
        $actReceipt.verification.effect -ne 'partial' -or $actRaw.Contains($actSecret) -or
        (($actOut | Out-String).Contains($actSecret))) {
        throw "act 聚合收据、步骤计数或日志脱敏不符合约定：steps=$($actReceipt.action.stepsCompleted) events=$($actReceipt.events.Count) effect=$($actReceipt.verification.effect) receiptLeak=$($actRaw.Contains($actSecret)) logLeak=$(($actOut | Out-String).Contains($actSecret)) output=$($actOut -join ' | ')"
    }

    $errorOut = @(& $node $cdp $port click auto '#missing-private-selector' --receipt $receipts.Error 2>&1)
    $errorExit = $LASTEXITCODE
    $errorReceipt = Get-Content -LiteralPath $receipts.Error -Raw | ConvertFrom-Json
    $errorRaw = Get-Content -LiteralPath $receipts.Error -Raw
    if ($errorExit -ne 1 -or $errorReceipt.result.status -ne 'error' -or
        $errorReceipt.verification.effect -ne 'unknown' -or $errorRaw.Contains('#missing-private-selector')) {
        throw "失败动作没有形成脱敏 unknown 收据：exit=$errorExit status=$($errorReceipt.result.status) effect=$($errorReceipt.verification.effect) leak=$($errorRaw.Contains('#missing-private-selector')) output=$($errorOut -join ' | ')"
    }

    $oldHang = $env:HUASHU_CDP_TEST_HANG
    $clock = [Diagnostics.Stopwatch]::StartNew()
    try {
        $env:HUASHU_CDP_TEST_HANG = 'action'
        $timeoutOut = @(& $node $cdp $port click auto '#b' --receipt $receipts.Timeout 2>&1)
        $timeoutExit = $LASTEXITCODE
    } finally {
        $clock.Stop()
        $env:HUASHU_CDP_TEST_HANG = $oldHang
    }
    $timeoutReceipt = Get-Content -LiteralPath $receipts.Timeout -Raw | ConvertFrom-Json
    # 6 s request deadline plus Node start-up, target listing and connect. Without
    # the deadline the hang would never return, so 12 s still proves it is bounded.
    if ($timeoutExit -ne 2 -or $clock.Elapsed.TotalSeconds -lt 5.5 -or $clock.Elapsed.TotalSeconds -gt 12 -or
        $timeoutReceipt.result.status -ne 'error' -or $timeoutReceipt.result.timedOut -ne $true -or
        $timeoutReceipt.result.errorType -ne 'CdpTimeoutError' -or $timeoutReceipt.verification.effect -ne 'unknown') {
        throw "CDP request 超时约定失败：exit=$timeoutExit elapsed=$([Math]::Round($clock.Elapsed.TotalSeconds,2))s status=$($timeoutReceipt.result.status) type=$($timeoutReceipt.result.errorType) effect=$($timeoutReceipt.verification.effect) output=$($timeoutOut -join ' | ')"
    }

    $deadlineOut = @(& $node $cdp $port act auto 'sleep 121' --receipt $receipts.ActDeadline 2>&1)
    $deadlineExit = $LASTEXITCODE
    $deadlineReceipt = Get-Content -LiteralPath $receipts.ActDeadline -Raw | ConvertFrom-Json
    if ($deadlineExit -ne 2 -or $deadlineReceipt.result.timedOut -ne $true -or
        $deadlineReceipt.verification.effect -ne 'unknown' -or $deadlineReceipt.action.stepsCompleted -ne 0) {
        throw "act 总截止时间约定失败：exit=$deadlineExit timedOut=$($deadlineReceipt.result.timedOut) effect=$($deadlineReceipt.verification.effect) steps=$($deadlineReceipt.action.stepsCompleted) output=$($deadlineOut -join ' | ')"
    }

    Write-Output "PASS: CDP action receipts text/click/press/act/error/request-timeout/act-deadline, redacted input+CSS, timeout=$([Math]::Round($clock.Elapsed.TotalSeconds,2))s port=$port"
} finally {
    # 只终止命令行中带本测试唯一 profile 路径的 Edge 进程。
    $owned = @(Get-CimInstance Win32_Process -Filter "Name = 'msedge.exe'" -ErrorAction SilentlyContinue |
        Where-Object { $_.CommandLine -and $_.CommandLine.Contains($profile) })
    foreach ($proc in ($owned | Sort-Object ProcessId -Descending)) {
        Stop-Process -Id $proc.ProcessId -Force -ErrorAction SilentlyContinue
    }
    if ($edge -and -not $edge.HasExited) { Stop-Process -Id $edge.Id -Force -ErrorAction SilentlyContinue }

    $tempBase = [IO.Path]::GetFullPath([IO.Path]::GetTempPath()).TrimEnd('\') + '\'
    $resolvedTemp = [IO.Path]::GetFullPath($tempRoot)
    if ($resolvedTemp.StartsWith($tempBase, [StringComparison]::OrdinalIgnoreCase) -and
        [IO.Path]::GetFileName($resolvedTemp).StartsWith('win-use-master-cdp-receipt-test-', [StringComparison]::Ordinal)) {
        Remove-Item -LiteralPath $resolvedTemp -Recurse -Force -ErrorAction SilentlyContinue
    } else {
        throw "拒绝清理未验证的临时目录：$resolvedTemp"
    }
}
