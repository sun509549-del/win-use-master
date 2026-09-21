# Optional real-app profile for WorkBuddy AI (Windows, Electron with a Slate
# composer). It exercises the L0/CDP write path end to end with zero focus use:
# insert into the composer, watch the send button enable, revert with
# SelectAll+Backspace, watch it disable again. Never presses Enter, never clicks
# 发送, never touches 重启升级.
#
# Precondition (must be done by the user, it restarts/starts the app):
#   pwsh -NoProfile -File scripts/win.ps1 open "<path>\WorkBuddyAI.exe" --cdp <port> --background
# This test never launches, relaunches or closes the app. It refuses when no
# authorized CDP instance is present or when the composer already holds a draft.

param([int] $Port = 9333)

$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $PSScriptRoot
$win = Join-Path $root 'scripts\win.ps1'
$cdp = Join-Path $root 'scripts\cdp.js'
$node = (Get-Command node -CommandType Application -ErrorAction Stop | Select-Object -First 1).Source
$tempRoot = Join-Path ([IO.Path]::GetTempPath()) ("win-use-master-workbuddy-$([Guid]::NewGuid().ToString('N'))")
[IO.Directory]::CreateDirectory($tempRoot) | Out-Null
$probeText = 'win-use-master cdp probe'
$composer = '[data-slate-editor="true"]'
$script:TargetId = $null

function Get-Inspect([string] $Selector, [string] $Target = '') {
    $resolvedTarget = if ($Target) { $Target } else { $script:TargetId }
    if (-not $resolvedTarget) { throw 'inspect 需要先确定 target id。' }
    $out = @(& $node $cdp $Port inspect $resolvedTarget $Selector 2>&1)
    if ($LASTEXITCODE -ne 0) { throw "cdp inspect 失败：$($out -join ' ')" }
    $json = [string]($out | Where-Object { [string]$_ -match '^\{' } | Select-Object -Last 1)
    if (-not $json) { throw "cdp inspect 没有返回 JSON：$($out -join ' ')" }
    return ($json | ConvertFrom-Json)
}

try {
    if (-not @(Get-Process WorkBuddyAI -ErrorAction SilentlyContinue).Count) {
        Write-Output 'refused: WorkBuddyAI 未运行。请用户先以 --cdp 启动授权实例；本测试不会自行启动。'
        exit 2
    }
    try { $version = Invoke-RestMethod -Uri "http://127.0.0.1:$Port/json/version" -TimeoutSec 2 -Proxy $null } catch { $version = $null }
    if (-not $version -or -not $version.webSocketDebuggerUrl) {
        Write-Output "refused: 127.0.0.1:$Port 没有 CDP。WorkBuddy 正在运行但未开调试端口；需要用户决定是否 --relaunch，本测试不会重启它。"
        exit 2
    }
    # open with an existing CDP port only verifies socket ownership; it launches nothing.
    $ownership = @(& $win open WorkBuddyAI --cdp $Port 2>&1)
    if ($LASTEXITCODE -ne 0 -or (($ownership -join "`n") -notmatch '已通且归属目标')) {
        throw "CDP 端口 $Port 的归属没有通过校验：$($ownership -join ' ')"
    }

    $targets = @(& $node $cdp $Port list 2>&1)
    $pageIds = @($targets | Where-Object { $_ -match '^page\t' } | ForEach-Object { ([string]$_ -split "`t")[1] })
    if ($LASTEXITCODE -ne 0 -or -not $pageIds.Count) { throw "cdp list 没有 page target：$($targets -join ' ')" }

    $composerTargets = @()
    foreach ($candidateId in $pageIds) {
        try {
            $candidateState = Get-Inspect $composer $candidateId
            if ($candidateState.found) { $composerTargets += [pscustomobject]@{ Id = $candidateId; State = $candidateState } }
        } catch { }
    }
    if (-not $composerTargets.Count) { throw '没有任何已授权 page target 包含 Slate 输入区；版本可能漂移，先重新 snapshot。' }
    if ($composerTargets.Count -gt 1) {
        Write-Output "refused: 有 $($composerTargets.Count) 个 page target 包含输入区，无法唯一确定目标；不会写入。"
        exit 2
    }
    $script:TargetId = $composerTargets[0].Id
    $stateObj = $composerTargets[0].State
    if (-not $stateObj.placeholderVisible) {
        Write-Output 'refused: 输入区已有用户草稿（占位符未显示）；不会覆盖或追加。'
        exit 2
    }
    if ($stateObj.role -ne 'textbox') { Write-Warning "输入区 role=$($stateObj.role)，与档案记录的 textbox 不同；请核对版本漂移。" }

    $sendBefore = @(& $node $cdp $Port find $script:TargetId '发送' --role button 2>&1)
    if ($LASTEXITCODE -ne 0 -or (($sendBefore -join "`n") -notmatch '^ref=e\d+ button "发送" .*\[disabled\]')) {
        throw "空输入区时发送键不是 disabled，状态指示器不可用：$($sendBefore -join ' ')"
    }

    $recipe = @(
        '# WorkBuddy AI composer: reversible write, never sends',
        'find "发送" --role button',
        "insert '$composer' `"$probeText`"",
        'find "发送" --role button',
        "press SelectAll '$composer'",
        "press Backspace '$composer'",
        'find "发送" --role button'
    ) -join "`n"
    $recipePath = Join-Path $tempRoot 'recipe.act.txt'
    Set-Content -LiteralPath $recipePath -Value $recipe -Encoding utf8
    $receiptPath = Join-Path $tempRoot 'act.json'
    $actOut = @(& $node $cdp $Port act $script:TargetId $recipePath --receipt $receiptPath 2>&1)
    $actText = ($actOut | ForEach-Object { [string]$_ }) -join "`n"
    if ($LASTEXITCODE -ne 0) { throw "act 失败：$actText" }
    if ($actText -notmatch 'done: 6 步全部完成') { throw "act 没有完成 6 步：$actText" }
    if ($actText -notmatch 'button disabled true→false' -or $actText -notmatch 'button disabled false→true') {
        throw "发送键没有经历 disabled→enabled→disabled：$actText"
    }
    if ($actText.Contains($probeText)) { throw '终端差分泄露了输入正文（role=textbox 编辑器应只显示字符数）。' }
    $receipt = Get-Content -LiteralPath $receiptPath -Raw | ConvertFrom-Json
    $receiptRaw = Get-Content -LiteralPath $receiptPath -Raw
    if ($receipt.action.stepsCompleted -ne 6 -or $receipt.events.Count -ne 3 -or
        $receipt.events[0].effect -ne 'partial' -or $receipt.events[2].effect -ne 'partial' -or
        $receipt.events[0].action.textLength -ne $probeText.Length -or
        $receiptRaw.Contains($probeText) -or $receipt.target.url -match '\?') {
        throw "act 收据不符合约定：steps=$($receipt.action.stepsCompleted) events=$($receipt.events.Count) url=$($receipt.target.url)"
    }

    $after = Get-Inspect $composer
    $sendAfter = @(& $node $cdp $Port find $script:TargetId '发送' --role button 2>&1)
    if (-not $after.placeholderVisible -or $after.textLength -ne 0 -or (($sendAfter -join "`n") -notmatch '\[disabled\]')) {
        throw '撤回后输入区没有回到占位符状态或发送键未回到 disabled；请人工检查输入区。'
    }
    Write-Output "PASS: WorkBuddy AI CDP profile insert($($probeText.Length))→send enabled→SelectAll+Backspace→send disabled, focus=0s, port=$Port"
} finally {
    $tempBase = [IO.Path]::GetFullPath([IO.Path]::GetTempPath()).TrimEnd('\') + '\'
    $resolved = [IO.Path]::GetFullPath($tempRoot)
    if ($resolved.StartsWith($tempBase, [StringComparison]::OrdinalIgnoreCase) -and
        [IO.Path]::GetFileName($resolved).StartsWith('win-use-master-workbuddy-', [StringComparison]::Ordinal)) {
        Remove-Item -LiteralPath $resolved -Recurse -Force -ErrorAction SilentlyContinue
    }
}
