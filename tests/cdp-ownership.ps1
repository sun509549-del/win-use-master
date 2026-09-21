param([int] $StartPort = 49333)

$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $PSScriptRoot
$win = Join-Path $root 'scripts\win.ps1'
$cdp = Join-Path $root 'scripts\cdp.js'
$fixture = Join-Path $PSScriptRoot 'cdp-fixture.js'
$node = (Get-Command node -CommandType Application -ErrorAction Stop | Select-Object -First 1).Source
$sessionPath = Join-Path ([IO.Path]::GetTempPath()) ("win-use-master-cdp-owner-session-$([Guid]::NewGuid().ToString('N')).json")
$oldSession = $env:WIN_USE_MASTER_CDP_SESSION
$env:WIN_USE_MASTER_CDP_SESSION = $sessionPath

$port = $StartPort
while ($port -le 65535 -and (Get-NetTCPConnection -State Listen -LocalPort $port -ErrorAction SilentlyContinue)) { $port++ }
if ($port -gt 65535) { throw "从 $StartPort 起找不到空闲测试端口。" }

$server = Start-Process -FilePath $node -ArgumentList @($fixture, [string]$port) -WindowStyle Hidden -PassThru
try {
    $deadline = [DateTime]::UtcNow.AddSeconds(8)
    while (-not (Get-NetTCPConnection -State Listen -LocalPort $port -ErrorAction SilentlyContinue) -and
        [DateTime]::UtcNow -lt $deadline) { Start-Sleep -Milliseconds 100 }
    if (-not (Get-NetTCPConnection -State Listen -LocalPort $port -ErrorAction SilentlyContinue)) {
        throw '本地 CDP fixture 没有开始监听。'
    }

    $direct = @(& $node $cdp $port click fixture-page '#must-not-run' 2>&1)
    if ($LASTEXITCODE -ne 2 -or (($direct -join "`n") -notmatch 'CDP 写操作需要有效授权会话')) {
        throw "直接调用 cdp.js 在没有授权会话时未被拒绝：exit=$LASTEXITCODE output=$($direct -join ' ')"
    }

    # 使用独立 pwsh，保证每次退出码不被上一次调用残留。
    $wrong = @(& pwsh -NoProfile -File $win open 'notepad.exe' --cdp $port --dry 2>&1)
    $wrongExit = $LASTEXITCODE
    if (Test-Path -LiteralPath $sessionPath) { throw '错误 owner 校验不应签发 CDP 会话。' }
    $right = @(& pwsh -NoProfile -File $win open 'node.exe' --cdp $port 2>&1)
    $rightExit = $LASTEXITCODE

    if ($wrongExit -ne 2 -or (($wrong | Out-String) -notmatch '其它 CDP 占用')) {
        throw "错误目标没有拒绝：exit=$wrongExit output=$($wrong -join ' ')"
    }
    if ($rightExit -ne 0 -or (($right | Out-String) -notmatch '归属目标')) {
        throw "正确 owner 没有接受：exit=$rightExit output=$($right -join ' ')"
    }
    $session = Get-Content -LiteralPath $sessionPath -Raw | ConvertFrom-Json
    if ($session.schema -ne 'win-use-master/cdp-session-v1' -or $session.port -ne $port -or
        $session.owners.Count -ne 1 -or $session.owners[0].pid -ne $server.Id -or
        $session.targetIds.Count -ne 1 -or $session.targetIds[0] -ne 'fixture-page') {
        throw '正确 owner 没有形成绑定 PID/启动时间/target 的 CDP 会话。'
    }
    Write-Output "PASS: direct mutation refused without session, owner mismatch=refused(2), owner match=session-bound(0), port=$port pid=$($server.Id)"
} finally {
    $env:WIN_USE_MASTER_CDP_SESSION = $oldSession
    if ($server -and -not $server.HasExited) {
        $server.Kill()
        $server.WaitForExit(3000) | Out-Null
    }
    if ([IO.File]::Exists($sessionPath) -and
        [IO.Path]::GetDirectoryName([IO.Path]::GetFullPath($sessionPath)).TrimEnd('\') -eq [IO.Path]::GetFullPath([IO.Path]::GetTempPath()).TrimEnd('\') -and
        [IO.Path]::GetFileName($sessionPath).StartsWith('win-use-master-cdp-owner-session-')) {
        [IO.File]::Delete($sessionPath)
    }
}
