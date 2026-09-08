param(
    [switch] $KeepEvidence,
    [switch] $RequireCoordinate
)

$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $PSScriptRoot
$scripts = Join-Path $root 'scripts'
$win = Join-Path $scripts 'win.ps1'
$probe = Join-Path $scripts 'probe.ps1'
$fixture = Join-Path $PSScriptRoot 'fixture.ps1'
$evidence = Join-Path ([IO.Path]::GetTempPath()) ("win-use-master-smoke-$([Guid]::NewGuid().ToString('N'))")
$transientEvidence = [Collections.Generic.List[string]]::new()
[IO.Directory]::CreateDirectory($evidence) | Out-Null

$scriptFiles = @(
    (Join-Path $scripts 'build.ps1')
    (Join-Path $scripts 'win.ps1')
    (Join-Path $scripts 'uia-worker.ps1')
    (Join-Path $scripts 'probe.ps1')
)
foreach ($file in $scriptFiles) {
    $tokens = $null; $errors = $null
    [Management.Automation.Language.Parser]::ParseFile($file, [ref]$tokens, [ref]$errors) | Out-Null
    if ($errors.Count) { throw "$file 有 $($errors.Count) 个 PowerShell 语法错误。" }
}
& (Join-Path $scripts 'build.ps1') -Force
if ($LASTEXITCODE) { throw "build.ps1 exit=$LASTEXITCODE" }

$fixtureProcess = $null
try {
    $hostExe = (Get-Process -Id $PID).Path
    # The fixture itself must be visible for PrintWindow/UIA. Reuse the current
    # console so no extra terminal window is created.
    $fixtureProcess = Start-Process -FilePath $hostExe -ArgumentList @('-NoProfile','-File',"`"$fixture`"") -NoNewWindow -PassThru
    $deadline = [DateTime]::UtcNow.AddSeconds(12)
    $line = $null
    while (-not $line -and [DateTime]::UtcNow -lt $deadline) {
        Start-Sleep -Milliseconds 200
        $candidates = @(& $win windows 'smoke fixture' --all 2>$null)
        # Title-only selection can accidentally reuse a stale/minimized fixture
        # from another run. Bind readiness to the process started above and wait
        # until its window is on the current desktop and not minimized.
        $pidToken = " pid=$($fixtureProcess.Id) "
        $line = @($candidates | Where-Object {
            $_ -match '^id=0x' -and $_.Contains($pidToken) -and $_ -match ' state=current '
        } | Select-Object -First 1)
        if (-not $line.Count) { $line = $null }
    }
    if (-not $line.Count -or $line[0] -notmatch 'id=(0x[0-9A-F]+)') { throw '测试窗口 12 秒内没有出现。' }
    $hwnd = $Matches[1]
    Write-Output "fixture: $hwnd pid=$($fixtureProcess.Id)"

    $shot = Join-Path $evidence 'shot.png'
    $see = Join-Path $evidence 'see.png'
    & $win shot $hwnd $shot
    if ($LASTEXITCODE) { throw "shot exit=$LASTEXITCODE" }
    & $win see $hwnd --out $see | Select-Object -First 30
    if ($LASTEXITCODE) { throw "see exit=$LASTEXITCODE" }
    # `--out` is bound as the ambiguous -Out(Variable|Buffer) prefix by a real
    # `pwsh -File` host, so the positional path must work through a child host.
    $seePositional = Join-Path $evidence 'see-positional.png'
    $seePositionalOut = @(& $hostExe -NoProfile -File $win see $hwnd $seePositional 2>&1)
    if ($LASTEXITCODE -or -not (Test-Path -LiteralPath $seePositional) -or -not (Test-Path -LiteralPath ($seePositional + '.uia.json'))) {
        throw "pwsh -File see <hwnd> <path> 失败：$($seePositionalOut -join ' ')"
    }
    Write-Output 'see-positional: pwsh -File PASS'

    & $win clickin $hwnd 0.5 0.5 --dry
    if ($LASTEXITCODE) { throw "clickin --dry exit=$LASTEXITCODE" }
    & $win clickin $hwnd ("e1@" + $see + '.uia.json') 0 --dry
    if ($LASTEXITCODE) { throw "UIA map reference --dry exit=$LASTEXITCODE" }
    # Stop-Hu writes directly to Console.Error.  Invoke a real child pwsh so
    # both stderr text and the process exit code are observable by the test.
    $oversizeType = @(& $hostExe -NoProfile -File $win type $hwnd ('x' * 1001) --dry 2>&1)
    if ($LASTEXITCODE -ne 2 -or (($oversizeType -join "`n") -notmatch '单次输入最多 1000')) {
        throw 'L2 超长输入没有在发送前明确拒绝。'
    }
    $oversizeScroll = @(& $hostExe -NoProfile -File $win scrollin $hwnd 0.5 0.5 120 201 --dry 2>&1)
    if ($LASTEXITCODE -ne 2 -or (($oversizeScroll -join "`n") -notmatch '不能超过 200')) {
        throw 'L2 超长滚动没有在发送前明确拒绝。'
    }
    $horizScroll = @(& $win scrollin $hwnd 0.5 0.5 120 3 --horizontal --dry)
    if ($LASTEXITCODE -or (($horizScroll -join "`n") -notmatch 'axis=horizontal')) {
        throw "scrollin --horizontal --dry 没有声明横向轴：$($horizScroll -join ' ')"
    }
    Write-Output 'bounded-focus-actions: PASS'
    $coordinateState = 'SKIP(user-active)'
    $idle = [HuWin]::UserIdleSeconds()
    if ($RequireCoordinate -or $idle -ge 2.0) {
        $mapData = Get-Content -LiteralPath ($see + '.uia.json') -Raw | ConvertFrom-Json
        $receiptData = Get-Content -LiteralPath ($see + '.receipt.json') -Raw | ConvertFrom-Json
        $editSpec = @($mapData.elements | Where-Object { $_.ref -eq 'e1' } | Select-Object -First 1)
        if (-not $editSpec.Count) { throw 'see map 中没有 e1。' }
        $inkPhysicalX = [double]$editSpec[0].cx - [double]$editSpec[0].width / 2 + [Math]::Min(40, [double]$editSpec[0].width / 4)
        $imageX = ($inkPhysicalX / [double]$receiptData.imageToWindowScale.x).ToString('0.###', [Globalization.CultureInfo]::InvariantCulture)
        $imageY = ([double]$editSpec[0].cy / [double]$receiptData.imageToWindowScale.y).ToString('0.###', [Globalization.CultureInfo]::InvariantCulture)
        $coordinateShot = Join-Path $evidence 'coordinate-after.png'
        $opOutput = @(& $win op $hwnd $imageX $imageY 'coordinate-smoke' "@$see" --replace shot $coordinateShot)
        $opExit = $LASTEXITCODE
        # Sample the presence trail immediately: the raw idle clock must still be
        # within the trail window (10 s) while the effective idle already excludes
        # our own SendInput. Doing this after the UIA read-back made it depend on
        # machine load.
        $rawAfter = [HuWin]::IdleSeconds()
        $userAfter = [HuWin]::UserIdleSeconds()
        $opOutput | Write-Output
        if ($opExit) {
            if ($RequireCoordinate -or $opExit -ne 2) { throw "op exit=$opExit" }
            $coordinateState = 'SKIP(safety-refusal)'
        } else {
            if (($opOutput -join "`n") -notmatch 'op finished；(?:借焦点 [0-9.]+s 后已还原|目标本就在前台，未切换焦点)') {
                throw 'op 没有给出可审计的真实焦点占用结果。'
            }
            if ($rawAfter -ge 8 -or $userAfter -lt 2) {
                throw "自身输入尾迹没有被安全排除：raw=$rawAfter user=$userAfter"
            }
            Write-Output ("presence-trail: PASS raw={0:F2}s effective={1:F0}s" -f $rawAfter,$userAfter)
            $opReceipt = Get-Content -LiteralPath ($coordinateShot + '.receipt.json') -Raw | ConvertFrom-Json
            if ($opReceipt.action.kind -ne 'op' -or $opReceipt.action.layer -ne 'L2' -or
                -not $opReceipt.verification.before.sha256 -or -not $opReceipt.verification.effect -or
                $opReceipt.action.request.PSObject.Properties.Name -contains 'text') {
                throw 'op 收据没有形成脱敏的 before/action/after/effect 证据链。'
            }
            Write-Output 'action-receipt: L2 chain PASS'
            $coordinateReadback = @()
            for ($attempt = 0; $attempt -lt 5; $attempt++) {
                $coordinateReadback = @(& $win uia $hwnd)
                if (($coordinateReadback -join "`n") -match 'value="coordinate-smoke"') { break }
                Start-Sleep -Milliseconds 250
            }
            if ($LASTEXITCODE -or (($coordinateReadback -join "`n") -notmatch 'value="coordinate-smoke"')) {
                throw 'op 完成后 UIA 没有读回 coordinate-smoke。'
            }
            $coordinateState = 'PASS'
        }
    } else {
        Write-Output ("coordinate: SKIP，用户仅空闲 {0:F1}s；用 -RequireCoordinate 做发布级严格回归。" -f $idle)
    }

    # Keep the foreground-sensitive L2 check near fixture startup. Read-only
    # probing and semantic UIA checks follow so they cannot consume the
    # foreground-activation window granted by Windows.
    $probeReport = @(& $probe 'smoke fixture')
    $probeText = $probeReport -join "`n"
    if ($LASTEXITCODE -or ($probeText -notmatch "(?m)^相关 PID: $($fixtureProcess.Id)$") -or
        ($probeText -notmatch 'editable=1') -or ($probeText -notmatch 'actionable=1')) {
        throw '动态 probe 没有严格限定 fixture PID，或 UIA 统计异常。'
    }
    if ($probeText -notmatch 'COM 自动化对象模型') {
        throw 'probe 没有输出 COM 只读节。'
    }
    Write-Output 'probe: read-only PID scoping/UIA/COM PASS'

    $uia = @(& $win uia $hwnd)
    if ($LASTEXITCODE -or -not ($uia -match 'Edit')) { throw 'UIA 没有枚举到 fixture Edit。' }
    $uia | Select-Object -First 20
    $uiaRead = @(& $win uiaread $hwnd 'instructionLabel')
    if ($LASTEXITCODE -or (($uiaRead -join "`n") -notmatch 'Safe local automation fixture')) {
        throw 'uiaread 没有读取到 fixture 静态文本。'
    }
    Write-Output 'uiaread: static text PASS'
    $uiasetOutput = @(& $win uiaset $hwnd first 'semantic-smoke')
    $uiasetOutput | Write-Output
    if ($LASTEXITCODE) { throw "uiaset exit=$LASTEXITCODE" }
    $uiasetReceiptPath = $null
    foreach ($line in $uiasetOutput) {
        if ($line -match '^verification: (.+) receipt=(.+)$') { $uiasetReceiptPath = $Matches[2]; [void]$transientEvidence.Add($Matches[1]); [void]$transientEvidence.Add($Matches[2]) }
    }
    if (-not $uiasetReceiptPath) { throw 'uiaset 没有输出验证收据。' }
    $uiasetReceipt = Get-Content -LiteralPath $uiasetReceiptPath -Raw | ConvertFrom-Json
    if ($uiasetReceipt.action.kind -ne 'uiaset' -or $uiasetReceipt.action.layer -ne 'L1' -or
        $uiasetReceipt.action.semanticReadback -ne 'matched-changed' -or -not $uiasetReceipt.verification.before.sha256) {
        throw 'uiaset 收据没有形成语义读回证据链。'
    }
    Write-Output 'action-receipt: L1 chain PASS'

    $button = $uia | Where-Object { $_ -match '^(e\d+) Button ' } | Select-Object -First 1
    if ($button -and $button -match '^(e\d+)') {
        $invokeOutput = @(& $win invoke $hwnd $Matches[1] ("@" + $see + '.uia.json'))
        $invokeOutput | Write-Output
        if ($LASTEXITCODE) { throw "invoke exit=$LASTEXITCODE" }
        foreach ($line in $invokeOutput) {
            if ($line -match '^verification: (.+) receipt=(.+)$') { [void]$transientEvidence.Add($Matches[1]); [void]$transientEvidence.Add($Matches[2]) }
        }
        $statusRead = @(& $win uiaread $hwnd 'fixtureStatus')
        if ($LASTEXITCODE -or (($statusRead -join "`n") -notmatch 'status: semantic-smoke')) {
            throw 'InvokePattern 后 uiaread 没有读回 fixture 状态。'
        }
        Write-Output 'uiaread: action side-effect PASS'
    }
    $oldHud = $env:WIN_USE_MASTER_HUD
    $oldHudStyle = $env:WIN_USE_MASTER_HUD_STYLE
    $oldHudCapturable = $env:WIN_USE_MASTER_HUD_CAPTURABLE
    try {
        $env:WIN_USE_MASTER_HUD = $null
        $env:WIN_USE_MASTER_HUD_STYLE = 'plain'
        $env:WIN_USE_MASTER_HUD_CAPTURABLE = '1'
        $hudOut = @(& $win hud 80 'win-use-master smoke')
        if ($LASTEXITCODE -or (($hudOut -join ' ') -notmatch 'style=plain capturable=True')) {
            throw "HUD 样式/可捕获开关失败：$($hudOut -join ' ')"
        }
        $env:WIN_USE_MASTER_HUD = '0'
        $disabledHud = @(& $win hud 80 'disabled smoke' glow)
        if ($LASTEXITCODE -or (($disabledHud -join ' ') -notmatch 'HUD disabled')) {
            throw "HUD 关闭开关失败：$($disabledHud -join ' ')"
        }
        Write-Output 'hud-config: style/capturable/disable PASS'
    } finally {
        $env:WIN_USE_MASTER_HUD = $oldHud
        $env:WIN_USE_MASTER_HUD_STYLE = $oldHudStyle
        $env:WIN_USE_MASTER_HUD_CAPTURABLE = $oldHudCapturable
    }

    $screenPath = Join-Path $evidence 'screen-window.png'
    $screenOut = @(& $win screen $screenPath --window $hwnd)
    if ($LASTEXITCODE) { throw "screen --window exit=$LASTEXITCODE" }
    $screenReceipt = Get-Content -LiteralPath ($screenPath + '.receipt.json') -Raw | ConvertFrom-Json
    if (-not $screenReceipt.composition -or $screenReceipt.method -notmatch 'CopyFromScreen') {
        throw 'screen 收据没有标记桌面合成方法。'
    }
    $regionPath = Join-Path $evidence 'screen-region.png'
    $regionOut = @(& $win screen $regionPath --region 0 0 80 80)
    if ($LASTEXITCODE -or -not (Test-Path -LiteralPath $regionPath)) { throw "screen --region 失败：$($regionOut -join ' ')" }
    $both = @(& $hostExe -NoProfile -File $win screen (Join-Path $evidence 'screen-both.png') --window $hwnd --region 0 0 80 80 2>&1)
    if ($LASTEXITCODE -eq 0 -or (($both -join "`n") -notmatch '只能选一个')) {
        throw 'screen 同时给 --window 和 --region 没有拒绝。'
    }
    Write-Output 'screen: window/region/mutex PASS'

    # Explicit window-state commands: minimize then restore the fixture without
    # activating it; the foreground must be unchanged and shot must work again.
    $fgBefore = [HuWin]::ForegroundWindow().ToInt64()
    $minOut = @(& $win minimize $hwnd)
    if ($LASTEXITCODE -or (($minOut -join "`n") -notmatch 'after:  id=.* state=min ')) { throw "minimize 失败：$($minOut -join ' ')" }
    $minShot = @(& $hostExe -NoProfile -File $win shot $hwnd (Join-Path $evidence 'minimized.png') 2>&1)
    if ($LASTEXITCODE -ne 2) { throw "最小化窗口的 shot 应退出 2，得到 $LASTEXITCODE：$($minShot -join ' ')" }
    $restoreOut = @(& $win restore $hwnd)
    if ($LASTEXITCODE -or (($restoreOut -join "`n") -notmatch 'after:  id=.* state=current ')) { throw "restore 失败：$($restoreOut -join ' ')" }
    if ([HuWin]::ForegroundWindow().ToInt64() -ne $fgBefore) { throw 'restore/minimize 改变了前台窗口。' }
    & $win shot $hwnd (Join-Path $evidence 'restored.png') | Out-Null
    if ($LASTEXITCODE) { throw "restore 后 shot exit=$LASTEXITCODE" }
    Write-Output 'window-state: minimize/restore no-activate PASS'

    $notepad = Join-Path $env:SystemRoot 'System32\notepad.exe'
    $bgDry = @(& $win open $notepad --background --dry)
    if ($LASTEXITCODE -or (($bgDry -join ' ') -notmatch 'background=True')) {
        throw "open --background --dry 失败：$($bgDry -join ' ')"
    }
    $nonExe = Join-Path $root 'SKILL.md'
    $bgRefuse = @(& $hostExe -NoProfile -File $win open $nonExe --background --dry 2>&1)
    if ($LASTEXITCODE -ne 2 -or (($bgRefuse -join "`n") -notmatch '--background 需要真实 exe')) {
        throw "open --background 对非 exe 没有拒绝：$($bgRefuse -join ' ')"
    }
    Write-Output 'open-background: dry/exe-only PASS'

    if (-not (Test-Path -LiteralPath ($shot + '.receipt.json'))) { throw 'shot receipt 未生成。' }
    if (-not (Test-Path -LiteralPath ($see + '.uia.json'))) { throw 'see UIA map 未生成。' }
    $evidenceLabel = if ($KeepEvidence) { $evidence } else { 'temporary(auto-cleaned)' }
    Write-Output "PASS: build/windows/probe/shot/see/screen/uia/uiaread/uiaset/invoke/dry-gates/bounded-focus/hud/window-state/open-bg coordinate=$coordinateState evidence=$evidenceLabel"
} finally {
    if ($fixtureProcess -and -not $fixtureProcess.HasExited) {
        $fixtureProcess.CloseMainWindow() | Out-Null
        if (-not $fixtureProcess.WaitForExit(3000)) { $fixtureProcess.Kill() }
    }
    if (-not $KeepEvidence -and [IO.Directory]::Exists($evidence) -and
        $evidence.StartsWith([IO.Path]::GetTempPath(), [StringComparison]::OrdinalIgnoreCase) -and
        [IO.Path]::GetFileName($evidence).StartsWith('win-use-master-smoke-')) {
        [IO.Directory]::Delete($evidence, $true)
    }
    if (-not $KeepEvidence) {
        $tempRoot = [IO.Path]::GetFullPath([IO.Path]::GetTempPath()).TrimEnd('\')
        foreach ($item in @($transientEvidence | Select-Object -Unique)) {
            $full = [IO.Path]::GetFullPath($item)
            $parent = [IO.Path]::GetFullPath([IO.Path]::GetDirectoryName($full)).TrimEnd('\')
            $name = [IO.Path]::GetFileName($full)
            if ([string]::Equals($parent, $tempRoot, [StringComparison]::OrdinalIgnoreCase) -and
                $name -match '^(uiaset|invoke)-after-[0-9a-f]{32}\.png(\.receipt\.json)?$' -and
                [IO.File]::Exists($full)) {
                [IO.File]::Delete($full)
            }
        }
    }
}
