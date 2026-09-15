param([int] $StartPort = 49433)

$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $PSScriptRoot
$cdp = Join-Path $root 'scripts\cdp.js'
$win = Join-Path $root 'scripts\win.ps1'
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
$sessionPath = Join-Path $tempRoot 'cdp-session.json'
$oldSession = $env:WIN_USE_MASTER_CDP_SESSION
$env:WIN_USE_MASTER_CDP_SESSION = $sessionPath
$receipts = @{
    Setup = Join-Path $tempRoot 'setup.json'
    Text = Join-Path $tempRoot 'text.json'
    Insert = Join-Path $tempRoot 'insert.json'
    SelectAll = Join-Path $tempRoot 'selectall.json'
    Revert = Join-Path $tempRoot 'revert.json'
    Click = Join-Path $tempRoot 'click.json'
    RiskClick = Join-Path $tempRoot 'risk-click.json'
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

    $unauthorized = @(& $node $cdp $port click auto '#must-not-run' 2>&1)
    if ($LASTEXITCODE -ne 2 -or (($unauthorized -join "`n") -notmatch 'CDP 写操作需要有效授权会话')) {
        throw "无授权会话的直接 CDP 写入没有在连接/动作前拒绝：exit=$LASTEXITCODE output=$($unauthorized -join ' | ')"
    }
    $authorize = @(& pwsh -NoProfile -File $win open $edgeExe --cdp $port 2>&1)
    if ($LASTEXITCODE -ne 0 -or (($authorize -join "`n") -notmatch '写授权有效 30 分钟') -or -not (Test-Path -LiteralPath $sessionPath)) {
        throw "临时 Edge 没有获得 CDP 写授权：exit=$LASTEXITCODE output=$($authorize -join ' | ')"
    }
    $session = Get-Content -LiteralPath $sessionPath -Raw | ConvertFrom-Json
    if ($session.schema -ne 'win-use-master/cdp-session-v1' -or $session.port -ne $port -or
        -not $session.sessionId -or -not $session.owners.Count -or -not $session.targetIds.Count) {
        throw 'CDP 写授权没有绑定 session/owner/target。'
    }
    $targetRows = @(& $node $cdp $port list 2>&1 | Where-Object { [string]$_ -match '^page\t' -and [string]$_ -match '\tabout:blank$' })
    if ($targetRows.Count -ne 1) { throw "无法唯一定位测试 about:blank target：$($targetRows -join ' | ')" }
    $targetId = ([string]$targetRows[0] -split "`t")[1]
    if ($session.targetIds -notcontains $targetId) { throw "测试 target $targetId 不在授权集合中。" }
    Write-Output "cdp-session: owner+start-time+target bound session=$($session.sessionId) target=$targetId"

    # #ce mimics Slate/ProseMirror composers: a contenteditable div with
    # role=textbox, whose collected kind is div/textbox rather than div/editable.
    $setupJs = "document.title='private-marker-cdp-inspect'; document.body.innerHTML='<input id=i value=abc><button id=b onclick=`"this.disabled=true`">Go</button><button id=b2 onclick=`"this.remove()`">Gone</button><button id=danger onclick=`"document.body.dataset.dangerClicked=1`">发送</button><button id=sendButton onclick=`"document.body.dataset.identifierRan=1`">Go</button><form onsubmit=`"document.body.dataset.submitRan=1;return false`"><button id=implicit></button></form><div id=ce role=textbox contenteditable=true>seed</div>'; 'ready'"
    $setup = @(& $node $cdp $port eval-unsafe $targetId $setupJs --allow-side-effects --receipt $receipts.Setup 2>&1)
    if ($LASTEXITCODE -ne 0 -or (($setup | Out-String) -notmatch 'ready')) {
        $currentTargets = @(& $node $cdp $port list 2>&1)
        throw "fixture 初始化失败：authorized=$($session.targetIds -join ',') current=$($currentTargets -join ' | ') output=$($setup -join ' ')"
    }
    $setupReceipt = Get-Content -LiteralPath $receipts.Setup -Raw | ConvertFrom-Json
    $setupRaw = Get-Content -LiteralPath $receipts.Setup -Raw
    if ($setupReceipt.action.kind -ne 'eval-unsafe' -or $setupReceipt.action.explicitSideEffects -ne $true -or
        $setupReceipt.action.expression.length -ne $setupJs.Length -or -not $setupReceipt.action.expression.sha256 -or
        $setupReceipt.verification.effect -ne 'unknown' -or
        ($setupReceipt.verification.diff.added + $setupReceipt.verification.diff.removed + $setupReceipt.verification.diff.changed) -lt 1 -or
        $setupRaw.Contains($setupJs)) {
        throw 'eval-unsafe 没有形成脱敏的显式副作用回执。'
    }

    $inspectSummaryOut = @(& $node $cdp $port inspect $targetId '#i' --json --summary 2>&1)
    $inspectSummaryExit = $LASTEXITCODE
    $inspectSummaryRaw = $inspectSummaryOut -join "`n"
    try { $inspectSummary = $inspectSummaryRaw | ConvertFrom-Json } catch { throw "inspect summary 不是单一 JSON 文档：$inspectSummaryRaw" }
    if ($inspectSummaryExit -ne 0 -or $inspectSummary.schema -ne 'win-use-master/cdp-inspect-result-v1' -or
        $inspectSummary.status -ne 'found' -or $inspectSummary.element.textLength -ne 3 -or
        $null -ne $inspectSummary.target.title -or $null -ne $inspectSummary.target.url -or
        $inspectSummaryRaw.Contains('private-marker') -or $inspectSummaryRaw.Contains('#i')) {
        throw "inspect summary schema、状态或脱敏不符合约定：exit=$inspectSummaryExit output=$inspectSummaryRaw"
    }
    $inspectFullOut = @(& $node $cdp $port inspect $targetId '#i' --json 2>&1)
    $inspectFullExit = $LASTEXITCODE
    $inspectFullRaw = $inspectFullOut -join "`n"
    $inspectFull = $inspectFullRaw | ConvertFrom-Json
    if ($inspectFullExit -ne 0 -or $inspectFull.target.title -ne 'private-marker-cdp-inspect' -or
        $inspectFull.target.url -ne 'about:blank' -or $inspectFullRaw.Contains('#i')) {
        throw "inspect full JSON 丢失安全目标身份或复制了 selector：$inspectFullRaw"
    }
    $inspectTypo = @(& $node $cdp $port inspect $targetId '#i' --json --summmary 2>&1)
    if ($LASTEXITCODE -ne 2 -or (($inspectTypo -join "`n").Contains('private-marker-cdp-inspect'))) {
        throw "inspect 拼错 summary 没有在输出 target 前失败关闭：exit=$LASTEXITCODE output=$($inspectTypo -join ' | ')"
    }
    $inspectMissing = @(& $node $cdp $port inspect $targetId '#private-marker-missing-selector' --json --summary 2>&1)
    if ($LASTEXITCODE -ne 1 -or (($inspectMissing -join "`n").Contains('private-marker-missing-selector'))) {
        throw "inspect summary 未命中错误泄露了 CSS selector：exit=$LASTEXITCODE output=$($inspectMissing -join ' | ')"
    }
    Write-Output 'machine-output: CDP inspect full/summary schemas and fail-closed options PASS'

    $blockedEval = @(& $node $cdp $port eval $targetId "document.body.dataset.mustNotExist='blocked'" 2>&1)
    if ($LASTEXITCODE -ne 2 -or (($blockedEval -join "`n") -notmatch '只允许浏览器能证明无副作用')) {
        throw "eval 默认模式没有拒绝可能的副作用：exit=$LASTEXITCODE output=$($blockedEval -join ' | ')"
    }
    $missingConfirmation = @(& $node $cdp $port eval-unsafe auto "document.body.dataset.mustNotExist='unsafe'" 2>&1)
    if ($LASTEXITCODE -ne 2 -or (($missingConfirmation -join "`n") -notmatch '必须且只能提供一次 --allow-side-effects')) {
        throw "eval-unsafe 没有要求显式副作用确认：exit=$LASTEXITCODE output=$($missingConfirmation -join ' | ')"
    }
    $blockedState = @(& $node $cdp $port eval-read $targetId "document.body.dataset.mustNotExist === undefined" 2>&1)
    if ($LASTEXITCODE -ne 0 -or [string]($blockedState | Select-Object -Last 1) -ne 'true') {
        throw "被拒绝的 eval 仍产生了副作用，或 eval-read 无法完成只读核对：$($blockedState -join ' | ')"
    }
    Write-Output 'eval-safety: read-only default, explicit unsafe receipt, refused calls had zero side effect PASS'

    $riskClick = @(& $node $cdp $port click $targetId '#danger' --receipt $receipts.RiskClick 2>&1)
    if ($LASTEXITCODE -ne 2 -or (($riskClick -join "`n") -notmatch '高风险最终动作') -or -not (Test-Path -LiteralPath $receipts.RiskClick)) {
        throw "危险 CDP click 没有在动作前拒绝：exit=$LASTEXITCODE output=$($riskClick -join ' | ')"
    }
    $riskReceipt = Get-Content -LiteralPath $receipts.RiskClick -Raw | ConvertFrom-Json
    if ($riskReceipt.result.status -ne 'refused' -or $riskReceipt.riskGuard.decision -ne 'refused' -or
        $riskReceipt.riskGuard.schema -ne 'win-use-master/risk-actions-v1') {
        throw '危险 CDP click 的收据没有记录统一风险规则与拒绝结果。'
    }
    $riskMouse = @(& $node $cdp $port mouse $targetId '#danger' 2>&1)
    if ($LASTEXITCODE -ne 2 -or (($riskMouse -join "`n") -notmatch '高风险最终动作')) {
        throw "危险 CDP mouse 没有在指针事件前拒绝：exit=$LASTEXITCODE output=$($riskMouse -join ' | ')"
    }
    $identifierClick = @(& $node $cdp $port click $targetId '#sendButton' 2>&1)
    if ($LASTEXITCODE -ne 2 -or (($identifierClick -join "`n") -notmatch '高风险最终动作')) {
        throw "camelCase id 中的危险语义没有在 CDP click 前拒绝：exit=$LASTEXITCODE output=$($identifierClick -join ' | ')"
    }
    $implicitSubmit = @(& $node $cdp $port click $targetId '#implicit' 2>&1)
    if ($LASTEXITCODE -ne 2 -or (($implicitSubmit -join "`n") -notmatch '表单提交语义')) {
        throw "无标签 form-submit 没有在动作前拒绝：exit=$LASTEXITCODE output=$($implicitSubmit -join ' | ')"
    }
    $riskEnter = @(& $node $cdp $port press $targetId Enter '#i' 2>&1)
    if ($LASTEXITCODE -ne 2 -or (($riskEnter -join "`n") -notmatch '可能直接提交')) {
        throw "CDP Enter 没有在聚焦/按键事件前拒绝：exit=$LASTEXITCODE output=$($riskEnter -join ' | ')"
    }
    $riskState = @(& $node $cdp $port eval-read $targetId "document.body.dataset.dangerClicked === undefined && document.body.dataset.identifierRan === undefined && document.body.dataset.submitRan === undefined" 2>&1)
    if ($LASTEXITCODE -ne 0 -or [string]($riskState | Select-Object -Last 1) -ne 'true') {
        throw "被拒绝的 CDP click/mouse/form-submit/Enter 仍产生了页面副作用：$($riskState -join ' | ')"
    }
    Write-Output 'risk-policy: CDP text/id/mouse/form-submit/Enter refused before side effect PASS'

    $secret = 's3cr3t-value'
    $textOut = @(& $node $cdp $port text $targetId '#i' $secret --receipt $receipts.Text 2>&1)
    if ($LASTEXITCODE -ne 0) { throw "text 失败：$($textOut -join ' ')" }
    $textReceipt = Get-Content -LiteralPath $receipts.Text -Raw | ConvertFrom-Json
    $textRaw = Get-Content -LiteralPath $receipts.Text -Raw
    if ($textReceipt.schema -ne 'win-use-master/action-receipt-v1' -or
        $textReceipt.action.textLength -ne $secret.Length -or $textReceipt.focus.borrowed -ne $false -or
        $textReceipt.verification.effect -ne 'partial' -or $textReceipt.authorization.sessionId -ne $session.sessionId -or
        $textReceipt.authorization.targetBound -ne $true -or $textRaw.Contains($secret) -or $textRaw.Contains('#i')) {
        throw 'text 收据字段、effect 或脱敏不符合约定。'
    }

    $editorSecret = 'private-draft-text'
    $insertOut = @(& $node $cdp $port insert $targetId '#ce' $editorSecret --receipt $receipts.Insert 2>&1)
    if ($LASTEXITCODE -ne 0) { throw "insert 失败：$($insertOut -join ' ')" }
    $insertText = $insertOut | Out-String
    $insertReceipt = Get-Content -LiteralPath $receipts.Insert -Raw | ConvertFrom-Json
    if ($insertText.Contains($editorSecret) -or $insertText -notmatch '~ ref=e\d+ div/textbox text <\d+ chars>→<\d+ chars>' -or
        $insertReceipt.action.textLength -ne $editorSecret.Length -or (Get-Content -LiteralPath $receipts.Insert -Raw).Contains($editorSecret)) {
        throw "role=textbox 编辑器的终端差分或收据泄露了输入正文：$($insertOut -join ' | ')"
    }
    $selectAllOut = @(& $node $cdp $port press $targetId SelectAll '#ce' --receipt $receipts.SelectAll 2>&1)
    if ($LASTEXITCODE -ne 0) { throw "press SelectAll 失败：$($selectAllOut -join ' ')" }
    $revertOut = @(& $node $cdp $port press $targetId Backspace '#ce' --receipt $receipts.Revert 2>&1)
    if ($LASTEXITCODE -ne 0) { throw "press Backspace 失败：$($revertOut -join ' ')" }
    # A plain contenteditable keeps a placeholder <br> after deleting everything, so
    # measure the remaining text rather than innerText/childNodes.
    $editorInspect = @(& $node $cdp $port inspect $targetId '#ce' 2>&1)
    $editorState = [string]($editorInspect | Where-Object { [string]$_ -match '^\{' } | Select-Object -Last 1) | ConvertFrom-Json
    if ($LASTEXITCODE -ne 0 -or -not $editorState.found -or $editorState.textLength -ne 0) {
        throw "SelectAll+Backspace 没有清空 role=textbox 编辑器：$($editorInspect -join ' | ')"
    }
    Write-Output 'editor-redaction+revert: role=textbox insert redacted, SelectAll+Backspace cleared PASS'

    $clickOut = @(& $node $cdp $port click $targetId '#b' --receipt $receipts.Click 2>&1)
    if ($LASTEXITCODE -ne 0) { throw "click 失败：$($clickOut -join ' ')" }
    $clickReceipt = Get-Content -LiteralPath $receipts.Click -Raw | ConvertFrom-Json
    if ($clickReceipt.verification.effect -ne 'partial' -or $clickReceipt.verification.diff.changed -lt 1) {
        throw 'click 没有记录 disabled 语义变化。'
    }

    $pressOut = @(& $node $cdp $port press $targetId Backspace '#i' --receipt $receipts.Press 2>&1)
    if ($LASTEXITCODE -ne 0) { throw "press 失败：$($pressOut -join ' ')" }
    $pressReceipt = Get-Content -LiteralPath $receipts.Press -Raw | ConvertFrom-Json
    if ($pressReceipt.action.key -ne 'Backspace' -or $pressReceipt.verification.effect -ne 'partial') {
        throw 'press 收据缺少按键或语义变化。'
    }

    $actSecret = 'private-act'
    $actScript = "text #i `"$actSecret`"`nclick #b2"
    $actOut = @(& $node $cdp $port act $targetId $actScript --receipt $receipts.Act 2>&1)
    if ($LASTEXITCODE -ne 0) { throw "act 失败：$($actOut -join ' ')" }
    $actReceipt = Get-Content -LiteralPath $receipts.Act -Raw | ConvertFrom-Json
    $actRaw = Get-Content -LiteralPath $receipts.Act -Raw
    if ($actReceipt.action.stepsCompleted -ne 2 -or $actReceipt.events.Count -ne 2 -or
        $actReceipt.verification.effect -ne 'partial' -or $actRaw.Contains($actSecret) -or
        (($actOut | Out-String).Contains($actSecret))) {
        throw "act 聚合收据、步骤计数或日志脱敏不符合约定：steps=$($actReceipt.action.stepsCompleted) events=$($actReceipt.events.Count) effect=$($actReceipt.verification.effect) receiptLeak=$($actRaw.Contains($actSecret)) logLeak=$(($actOut | Out-String).Contains($actSecret)) output=$($actOut -join ' | ')"
    }

    $errorOut = @(& $node $cdp $port click $targetId '#missing-private-selector' --receipt $receipts.Error 2>&1)
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
        $timeoutOut = @(& $node $cdp $port click $targetId '#b' --receipt $receipts.Timeout 2>&1)
        $timeoutExit = $LASTEXITCODE
    } finally {
        $clock.Stop()
        $env:HUASHU_CDP_TEST_HANG = $oldHang
    }
    $timeoutReceipt = Get-Content -LiteralPath $receipts.Timeout -Raw | ConvertFrom-Json
    # 6 s request deadline plus Node start-up, two independent owner checks,
    # target listing and connect. Without the deadline the hang would never
    # return; allow cold Windows runners enough time for the pwsh identity checks.
    if ($timeoutExit -ne 2 -or $clock.Elapsed.TotalSeconds -lt 5.5 -or $clock.Elapsed.TotalSeconds -gt 22 -or
        $timeoutReceipt.result.status -ne 'error' -or $timeoutReceipt.result.timedOut -ne $true -or
        $timeoutReceipt.result.errorType -ne 'CdpTimeoutError' -or $timeoutReceipt.verification.effect -ne 'unknown') {
        throw "CDP request 超时约定失败：exit=$timeoutExit elapsed=$([Math]::Round($clock.Elapsed.TotalSeconds,2))s status=$($timeoutReceipt.result.status) type=$($timeoutReceipt.result.errorType) effect=$($timeoutReceipt.verification.effect) output=$($timeoutOut -join ' | ')"
    }

    $deadlineOut = @(& $node $cdp $port act $targetId 'sleep 121' --receipt $receipts.ActDeadline 2>&1)
    $deadlineExit = $LASTEXITCODE
    if (-not (Test-Path -LiteralPath $receipts.ActDeadline)) {
        throw "act 总截止时间命令没有生成收据：exit=$deadlineExit output=$($deadlineOut -join ' | ')"
    }
    $deadlineReceipt = Get-Content -LiteralPath $receipts.ActDeadline -Raw | ConvertFrom-Json
    if ($deadlineExit -ne 2 -or $deadlineReceipt.result.timedOut -ne $true -or
        $deadlineReceipt.verification.effect -ne 'unknown' -or $deadlineReceipt.action.stepsCompleted -ne 0) {
        throw "act 总截止时间约定失败：exit=$deadlineExit timedOut=$($deadlineReceipt.result.timedOut) effect=$($deadlineReceipt.verification.effect) steps=$($deadlineReceipt.action.stepsCompleted) output=$($deadlineOut -join ' | ')"
    }

    # A browser may rebuild its CDP listener process during a long deadline test.
    # The old owner-bound session must then fail closed. Explicitly authorize the
    # current owner/target again before mutating the manifest so each following
    # assertion reaches the guard it intends to test.
    function Get-FreshGuardSession([string] $GuardName) {
        $reauthorize = @(& pwsh -NoProfile -File $win open $edgeExe --cdp $port 2>&1)
        if ($LASTEXITCODE -ne 0 -or (($reauthorize -join "`n") -notmatch '写授权有效 30 分钟')) {
            throw "$GuardName 前无法重新绑定当前 CDP owner：exit=$LASTEXITCODE output=$($reauthorize -join ' | ')"
        }
        $freshRaw = Get-Content -LiteralPath $sessionPath -Raw
        $fresh = $freshRaw | ConvertFrom-Json
        if ($fresh.targetIds -notcontains $targetId) {
            throw "$GuardName 前重新授权的 target 集合不再包含测试页：$($fresh.targetIds -join ',')"
        }
        return $freshRaw
    }

    $sessionRaw = Get-FreshGuardSession 'owner mismatch guard'
    $beforeGuardOut = @(& $node $cdp $port inspect $targetId '#i' 2>&1)
    $beforeGuard = [string]($beforeGuardOut | Where-Object { [string]$_ -match '^\{' } | Select-Object -Last 1) | ConvertFrom-Json
    try {
        $wrongOwnerSession = $sessionRaw | ConvertFrom-Json
        $wrongOwnerSession.owners[0].startTimeUtc = '2000-01-01T00:00:00.0000000Z'
        $wrongOwnerSession | ConvertTo-Json -Depth 6 | Set-Content -LiteralPath $sessionPath -Encoding utf8
        $ownerBlocked = @(& $node $cdp $port text $targetId '#i' 'must-not-write-owner' 2>&1)
        if ($LASTEXITCODE -ne 2 -or (($ownerBlocked -join "`n") -notmatch '路径或启动时间已变化')) {
            throw "owner 身份变化没有在写入前拒绝：exit=$LASTEXITCODE output=$($ownerBlocked -join ' | ')"
        }
    } finally { [IO.File]::WriteAllText($sessionPath, $sessionRaw, [Text.UTF8Encoding]::new($false)) }

    $sessionRaw = Get-FreshGuardSession 'multi-target auto guard'
    try {
        $multiTargetSession = $sessionRaw | ConvertFrom-Json
        $multiTargetSession.targetIds = @($multiTargetSession.targetIds) + 'additional-authorized-page'
        $multiTargetSession | ConvertTo-Json -Depth 6 | Set-Content -LiteralPath $sessionPath -Encoding utf8
        $autoBlocked = @(& $node $cdp $port text auto '#i' 'must-not-write-auto' 2>&1)
        if ($LASTEXITCODE -ne 2 -or (($autoBlocked -join "`n") -notmatch '写操作不能使用 auto')) {
            throw "多 target 会话仍允许 auto 写入：exit=$LASTEXITCODE output=$($autoBlocked -join ' | ')"
        }
    } finally { [IO.File]::WriteAllText($sessionPath, $sessionRaw, [Text.UTF8Encoding]::new($false)) }

    $sessionRaw = Get-FreshGuardSession 'target mismatch guard'
    try {
        $wrongTargetSession = $sessionRaw | ConvertFrom-Json
        $wrongTargetSession.targetIds = @('not-the-current-target')
        $wrongTargetSession | ConvertTo-Json -Depth 6 | Set-Content -LiteralPath $sessionPath -Encoding utf8
        $targetBlocked = @(& $node $cdp $port text $targetId '#i' 'must-not-write-target' 2>&1)
        if ($LASTEXITCODE -ne 2 -or (($targetBlocked -join "`n") -notmatch '不在本次 CDP 写授权')) {
            throw "未授权 target 没有在写入前拒绝：exit=$LASTEXITCODE output=$($targetBlocked -join ' | ')"
        }
    } finally { [IO.File]::WriteAllText($sessionPath, $sessionRaw, [Text.UTF8Encoding]::new($false)) }

    $sessionRaw = Get-FreshGuardSession 'expiry guard'
    try {
        $expiredSession = $sessionRaw | ConvertFrom-Json
        $expiredSession.expiresAt = '2000-01-01T00:00:00.0000000Z'
        $expiredSession | ConvertTo-Json -Depth 6 | Set-Content -LiteralPath $sessionPath -Encoding utf8
        $expiryBlocked = @(& $node $cdp $port text $targetId '#i' 'must-not-write-expired' 2>&1)
        if ($LASTEXITCODE -ne 2 -or (($expiryBlocked -join "`n") -notmatch '写授权已过期')) {
            throw "过期 CDP 会话没有在写入前拒绝：exit=$LASTEXITCODE output=$($expiryBlocked -join ' | ')"
        }
    } finally { [IO.File]::WriteAllText($sessionPath, $sessionRaw, [Text.UTF8Encoding]::new($false)) }
    $afterGuardOut = @(& $node $cdp $port inspect $targetId '#i' 2>&1)
    $afterGuard = [string]($afterGuardOut | Where-Object { [string]$_ -match '^\{' } | Select-Object -Last 1) | ConvertFrom-Json
    if ($beforeGuard.textLength -ne $afterGuard.textLength) { throw 'target/过期会话拒绝后输入框仍发生了变化。' }
    Write-Output 'cdp-session-guards: missing/owner-mismatch/multi-target-auto/target-mismatch/expired refused before side effect PASS'

    Write-Output "PASS: CDP bound-session, safe/unsafe eval and action receipts text/click/press/act/error/request-timeout/act-deadline, redacted input+CSS, timeout=$([Math]::Round($clock.Elapsed.TotalSeconds,2))s port=$port"
} finally {
    $env:WIN_USE_MASTER_CDP_SESSION = $oldSession
    # Only stop Edge processes whose command line contains this run's unique
    # profile. Child processes can keep files locked briefly after the browser
    # process exits, so keep re-querying this exact profile before deletion.
    $processDeadline = [DateTime]::UtcNow.AddSeconds(8)
    do {
        $owned = @(Get-CimInstance Win32_Process -Filter "Name = 'msedge.exe'" -ErrorAction SilentlyContinue |
            Where-Object { $_.CommandLine -and $_.CommandLine.Contains($profile) })
        foreach ($proc in ($owned | Sort-Object ProcessId -Descending)) {
            Stop-Process -Id $proc.ProcessId -Force -ErrorAction SilentlyContinue
        }
        if (-not $owned.Count) { break }
        Start-Sleep -Milliseconds 150
    } while ([DateTime]::UtcNow -lt $processDeadline)
    $owned = @(Get-CimInstance Win32_Process -Filter "Name = 'msedge.exe'" -ErrorAction SilentlyContinue |
        Where-Object { $_.CommandLine -and $_.CommandLine.Contains($profile) })
    if ($owned.Count) { throw "本测试的 Edge 进程在 8 秒内没有退出：$(@($owned.ProcessId) -join ',')" }

    $tempBase = [IO.Path]::GetFullPath([IO.Path]::GetTempPath()).TrimEnd('\') + '\'
    $resolvedTemp = [IO.Path]::GetFullPath($tempRoot)
    if ($resolvedTemp.StartsWith($tempBase, [StringComparison]::OrdinalIgnoreCase) -and
        [IO.Path]::GetFileName($resolvedTemp).StartsWith('win-use-master-cdp-receipt-test-', [StringComparison]::Ordinal)) {
        $cleanupError = $null
        for ($attempt = 0; $attempt -lt 8 -and (Test-Path -LiteralPath $resolvedTemp); $attempt++) {
            try {
                Remove-Item -LiteralPath $resolvedTemp -Recurse -Force -ErrorAction Stop
                $cleanupError = $null
            } catch {
                $cleanupError = $_.Exception.Message
                Start-Sleep -Milliseconds 250
            }
        }
        if (Test-Path -LiteralPath $resolvedTemp) {
            throw "本测试的临时 profile 清理失败：$cleanupError"
        }
    } else {
        throw "拒绝清理未验证的临时目录：$resolvedTemp"
    }
}
