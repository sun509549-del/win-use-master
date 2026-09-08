param([int] $StartPort = 49333)

$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $PSScriptRoot
$win = Join-Path $root 'scripts\win.ps1'
$fixture = Join-Path $PSScriptRoot 'cdp-fixture.js'
$node = (Get-Command node -ErrorAction Stop).Source

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

    # 使用独立 pwsh，保证每次退出码不被上一次调用残留。
    $wrong = @(& pwsh -NoProfile -File $win open 'notepad.exe' --cdp $port --dry 2>&1)
    $wrongExit = $LASTEXITCODE
    $right = @(& pwsh -NoProfile -File $win open 'node.exe' --cdp $port --dry 2>&1)
    $rightExit = $LASTEXITCODE

    if ($wrongExit -ne 2 -or (($wrong | Out-String) -notmatch '其它 CDP 占用')) {
        throw "错误目标没有拒绝：exit=$wrongExit output=$($wrong -join ' ')"
    }
    if ($rightExit -ne 0 -or (($right | Out-String) -notmatch '归属目标')) {
        throw "正确 owner 没有接受：exit=$rightExit output=$($right -join ' ')"
    }
    Write-Output "PASS: CDP owner mismatch=refused(2), owner match=accepted(0), port=$port pid=$($server.Id)"
} finally {
    if ($server -and -not $server.HasExited) {
        $server.Kill()
        $server.WaitForExit(3000) | Out-Null
    }
}
