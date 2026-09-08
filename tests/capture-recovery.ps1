$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $PSScriptRoot
$win = Join-Path $root 'scripts\win.ps1'
$fixture = Join-Path $PSScriptRoot 'sibling-fixture.ps1'
$evidence = Join-Path ([IO.Path]::GetTempPath()) ("win-use-master-capture-$([Guid]::NewGuid().ToString('N'))")
[IO.Directory]::CreateDirectory($evidence) | Out-Null

$fixtureProcess = $null
try {
    $hostExe = (Get-Process -Id $PID).Path
    $fixtureProcess = Start-Process -FilePath $hostExe -ArgumentList @('-NoProfile','-File',"`"$fixture`"") -NoNewWindow -PassThru
    $deadline = [DateTime]::UtcNow.AddSeconds(12)
    $line = $null
    while (-not $line -and [DateTime]::UtcNow -lt $deadline) {
        Start-Sleep -Milliseconds 200
        $line = @(& $win windows 'sibling shell' --all 2>$null | Where-Object { $_ -match '^id=0x' } | Select-Object -First 1)
        if (-not $line.Count) { $line = $null }
    }
    if (-not $line.Count -or $line[0] -notmatch 'id=(0x[0-9A-F]+)') { throw '兄弟窗口 fixture 12 秒内没有出现。' }
    $shellHwnd = $Matches[1]
    $deadlineShot = Join-Path $evidence 'deadline.png'
    $deadlineClock = [Diagnostics.Stopwatch]::StartNew()
    $deadlineResult = [HuWin]::ShotWindowTimed([Convert]::ToInt64($shellHwnd.Substring(2), 16), $deadlineShot, 1)
    $deadlineClock.Stop()
    if ($deadlineClock.ElapsedMilliseconds -gt 1000) { throw "1ms 截图看门狗阻塞了 $($deadlineClock.ElapsedMilliseconds)ms。" }
    if ($null -eq $deadlineResult) {
        Start-Sleep -Milliseconds 150
        if (Test-Path -LiteralPath $deadlineShot) { throw '超时 worker 晚到后覆盖了目标路径。' }
        Write-Output "capture-watchdog: timeout-clean PASS elapsed=$($deadlineClock.ElapsedMilliseconds)ms"
    } else {
        if (-not (Test-Path -LiteralPath $deadlineShot -PathType Leaf)) { throw '看门狗返回截图尺寸但没有发布完整文件。' }
        Write-Output "capture-watchdog: completed-within-deadline PASS elapsed=$($deadlineClock.ElapsedMilliseconds)ms"
    }
    $shot = Join-Path $evidence 'recovered.png'
    $output = @(& $win shot $shellHwnd $shot)
    $output | Write-Output
    if ($LASTEXITCODE) { throw "shot exit=$LASTEXITCODE" }
    if (($output -join "`n") -notmatch "recovered-from=$([regex]::Escape($shellHwnd))") { throw 'shot 没有报告兄弟窗口自愈。' }
    $receipt = Get-Content -LiteralPath ($shot + '.receipt.json') -Raw | ConvertFrom-Json
    if ($receipt.method -ne 'PrintWindow sibling-renderer recovery') { throw "意外截图方法: $($receipt.method)" }
    if ($receipt.recoveredFrom.hwnd -ne $shellHwnd) { throw '收据没有记录原壳窗口 HWND。' }
    if ($receipt.window.title -ne 'win-use-master sibling renderer') { throw '没有选中同进程渲染窗口。' }
    if ([int]$receipt.colorBuckets -lt 6) { throw '自愈后的图仍接近纯色。' }
    Write-Output "PASS: sibling-renderer recovery shell=$shellHwnd renderer=$($receipt.window.hwnd) colors=$($receipt.colorBuckets)"
} finally {
    if ($fixtureProcess -and -not $fixtureProcess.HasExited) {
        $fixtureProcess.CloseMainWindow() | Out-Null
        if (-not $fixtureProcess.WaitForExit(3000)) { $fixtureProcess.Kill() }
    }
    $tempRoot = [IO.Path]::GetFullPath([IO.Path]::GetTempPath()).TrimEnd('\')
    $fullEvidence = [IO.Path]::GetFullPath($evidence)
    if ([IO.Directory]::Exists($fullEvidence) -and
        [IO.Path]::GetDirectoryName($fullEvidence).TrimEnd('\') -eq $tempRoot -and
        [IO.Path]::GetFileName($fullEvidence).StartsWith('win-use-master-capture-')) {
        [IO.Directory]::Delete($fullEvidence, $true)
    }
}
