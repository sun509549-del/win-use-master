$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $PSScriptRoot
$win = Join-Path $root 'scripts\win.ps1'
$fixture = Join-Path $PSScriptRoot 'fixture.ps1'
$fixtureProcess = $null
$transientEvidence = [Collections.Generic.List[string]]::new()
$previousHook = [Environment]::GetEnvironmentVariable('HUASHU_UIA_WORKER_TEST_HANG', 'Process')
$workerPidsBefore = @(Get-CimInstance Win32_Process -Filter "Name='pwsh.exe'" -ErrorAction SilentlyContinue |
    Where-Object CommandLine -Match 'uia-worker\.ps1' | Select-Object -ExpandProperty ProcessId)

try {
    $hostExe = (Get-Process -Id $PID).Path
    $fixtureProcess = Start-Process -FilePath $hostExe -ArgumentList @('-NoProfile','-File',"`"$fixture`"") -NoNewWindow -PassThru
    $deadline = [DateTime]::UtcNow.AddSeconds(12)
    $line = $null
    while (-not $line -and [DateTime]::UtcNow -lt $deadline) {
        Start-Sleep -Milliseconds 200
        $line = @(& $win windows 'smoke fixture' --all 2>$null | Where-Object { $_ -match '^id=0x' } | Select-Object -First 1)
        if (-not $line.Count) { $line = $null }
    }
    if (-not $line.Count -or $line[0] -notmatch 'id=(0x[0-9A-F]+)') { throw 'UIA timeout fixture 12 秒内没有出现。' }
    $hwnd = $Matches[1]

    [Environment]::SetEnvironmentVariable('HUASHU_UIA_WORKER_TEST_HANG', 'set', 'Process')
    $clock = [Diagnostics.Stopwatch]::StartNew()
    $output = @(& $hostExe -NoProfile -File $win uiaset $hwnd first 'timeout-probe' 2>&1)
    $exitCode = $LASTEXITCODE
    $clock.Stop()
    [Environment]::SetEnvironmentVariable('HUASHU_UIA_WORKER_TEST_HANG', $previousHook, 'Process')

    $text = ($output | ForEach-Object { [string]$_ }) -join "`n"
    if ($exitCode -ne 2 -or $text -notmatch 'effect=unknown: UIA SetValue 超时') {
        throw "UIA 写超时没有以 unknown/2 停止。exit=$exitCode output=$text"
    }
    if ($clock.Elapsed.TotalSeconds -lt 5.5 -or $clock.Elapsed.TotalSeconds -gt 10) {
        throw "UIA 6 秒截止耗时异常: $($clock.Elapsed.TotalSeconds.ToString('F2'))s"
    }
    foreach ($item in $output) {
        $entry = [string]$item
        if ($entry -match '^verification: (.+) receipt=(.+)$') {
            [void]$transientEvidence.Add($Matches[1]); [void]$transientEvidence.Add($Matches[2])
            $receipt = Get-Content -LiteralPath $Matches[2] -Raw | ConvertFrom-Json
            if (-not $receipt.action.worker.timedOut -or $receipt.verification.effect -ne 'unknown') {
                throw 'UIA 超时 after 收据没有记录 worker timeout/effect=unknown。'
            }
        }
    }
    if (-not $transientEvidence.Count) { throw 'UIA 超时后没有留下可审计的 after 收据。' }

    $readback = @(& $win uiaread $hwnd fixtureInput)
    if ($LASTEXITCODE -or (($readback -join "`n") -match 'timeout-probe')) {
        throw '测试注入的 worker hang 不应改变 fixture 输入值。'
    }
    Write-Output ("PASS: isolated UIA write timeout={0:F2}s exit=2 receipt-effect=unknown" -f $clock.Elapsed.TotalSeconds)
} finally {
    [Environment]::SetEnvironmentVariable('HUASHU_UIA_WORKER_TEST_HANG', $previousHook, 'Process')
    if ($fixtureProcess -and -not $fixtureProcess.HasExited) {
        $fixtureProcess.CloseMainWindow() | Out-Null
        if (-not $fixtureProcess.WaitForExit(3000)) { $fixtureProcess.Kill() }
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
    $workersAfter = @(Get-CimInstance Win32_Process -Filter "Name='pwsh.exe'" -ErrorAction SilentlyContinue |
        Where-Object CommandLine -Match 'uia-worker\.ps1')
    foreach ($worker in $workersAfter) {
        if ([int]$worker.ProcessId -notin $workerPidsBefore) {
            Stop-Process -Id ([int]$worker.ProcessId) -Force -ErrorAction SilentlyContinue
        }
    }
}
