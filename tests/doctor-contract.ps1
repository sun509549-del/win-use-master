$ErrorActionPreference = 'Stop'
Set-StrictMode -Version 2.0

$root = Split-Path -Parent $PSScriptRoot
$fixtureRoot = Join-Path $PSScriptRoot 'fixtures\doctor'
. (Join-Path $root 'scripts\doctor-core.ps1')

function Assert-Contract([bool] $Condition, [string] $Message) {
    if (-not $Condition) { throw "doctor contract: $Message" }
}

function Copy-Object($Value) {
    return (($Value | ConvertTo-Json -Depth 12) | ConvertFrom-Json)
}

function Merge-Object($Target, $Overlay) {
    foreach ($property in $Overlay.PSObject.Properties) {
        $existing = $Target.PSObject.Properties[$property.Name]
        $isObject = $null -ne $property.Value -and
            $property.Value -isnot [string] -and
            $property.Value -isnot [System.Collections.IEnumerable] -and
            @($property.Value.PSObject.Properties).Count -gt 0
        if ($existing -and $isObject) { Merge-Object $existing.Value $property.Value }
        elseif ($existing) { $existing.Value = $property.Value }
        else { $Target | Add-Member -NotePropertyName $property.Name -NotePropertyValue $property.Value }
    }
}

function Get-FixtureReport([string] $OverlayName = '') {
    $facts = Get-Content -LiteralPath (Join-Path $fixtureRoot 'ready.json') -Raw -Encoding utf8 | ConvertFrom-Json
    if ($OverlayName) {
        $overlay = Get-Content -LiteralPath (Join-Path $fixtureRoot $OverlayName) -Raw -Encoding utf8 | ConvertFrom-Json
        Merge-Object $facts $overlay
    }
    return New-WinDoctorReport -Facts $facts -GeneratedAtUtc ([datetime]'2026-09-14T00:00:00Z')
}

$ready = Get-FixtureReport
Assert-Contract ($ready.schema -eq 'win-use-master/doctor-report-v1') 'ready fixture schema 不匹配'
Assert-Contract ($ready.status -eq 'ready' -and $ready.exitCode -eq 0 -and $ready.capabilities.cdp -eq 'ready') 'ready fixture 未判定为完整可用'
Assert-Contract (($ready.tests | Where-Object tier -eq 'Contract').status -eq 'ready') 'ready fixture 的 Contract 层不可运行'
Assert-Contract ($ready.readOnly -and $ready.sideEffects.applicationsStarted -eq 0 -and $ready.sideEffects.filesWritten -eq 0 -and -not $ready.sideEffects.helperCompiled) '只读副作用声明不正确'

$summary = Format-WinDoctorReport -Report $ready -Summary
Assert-Contract ($summary -notmatch '(?i)[a-z]:\\|\\Users\\|/home/') 'summary 泄露了绝对用户路径'
Assert-Contract ($summary -match 'readOnly=true' -and $summary -match 'coordinate=manual-required') 'summary 缺少只读或坐标人工门信息'

$missingNode = Get-FixtureReport 'missing-node.json'
Assert-Contract ($missingNode.exitCode -eq 0 -and $missingNode.capabilities.core -eq 'ready') '缺少可选 Node 不应让核心能力失败'
Assert-Contract ($missingNode.capabilities.cdp -eq 'unavailable') '缺少 Node 时 CDP 未降级'
Assert-Contract (($missingNode.tests | Where-Object tier -eq 'Contract').status -eq 'unavailable') '缺少 Node 时完整 Contract 层仍被误报可运行'

$staleHelper = Get-FixtureReport 'stale-helper.json'
Assert-Contract ($staleHelper.status -eq 'limited' -and $staleHelper.exitCode -eq 1) '过期 helper 未产生确定的 limited/exit=1'
Assert-Contract ($staleHelper.capabilities.desktopRead -eq 'blocked') '过期 helper 时桌面读取未阻断'
Assert-Contract (@($staleHelper.recommendations | Where-Object code -eq 'build-helper').Count -eq 1) '过期 helper 缺少唯一构建建议'

$secureDesktop = Get-FixtureReport 'secure-desktop.json'
Assert-Contract ($secureDesktop.exitCode -eq 0 -and $secureDesktop.capabilities.core -eq 'ready') '安全桌面不应误伤 L0 核心诊断'
Assert-Contract ($secureDesktop.capabilities.desktopRead -eq 'blocked' -and $secureDesktop.capabilities.coordinateWrite -eq 'blocked') '安全桌面未阻断桌面/L2 测试'

$leftovers = Get-FixtureReport 'historical-leftovers.json'
$leftoverCheck = $leftovers.checks | Where-Object id -eq 'historical-artifacts'
Assert-Contract ($leftovers.exitCode -eq 0 -and $leftoverCheck.status -eq 'warn') '历史残留不应成为核心失败，但必须告警'
Assert-Contract ($leftovers.environment.temporaryStorage.validManifestHistorical -eq 1 -and $leftovers.environment.temporaryStorage.expiredSessions -eq 2) '历史残留计数不稳定'
Assert-Contract ($leftovers.sideEffects.filesDeleted -eq 0) 'doctor 不得删除历史残留'

$doctorSource = Get-Content -LiteralPath (Join-Path $root 'scripts\doctor.ps1') -Raw -Encoding utf8
$winSource = Get-Content -LiteralPath (Join-Path $root 'scripts\win.ps1') -Raw -Encoding utf8
Assert-Contract ($doctorSource -notmatch '(?i)Start-Process|\[Diagnostics\.Process\]::Start|\[IO\.File\]::(?:Write|Delete|Move|Copy)|\bSet-Content\b|\bRemove-Item\b|-OutputAssembly') 'doctor 源码出现启动、写入、删除或编译动作'
$doctorDispatch = $winSource.IndexOf("if (`$Command -iin @('doctor','cache','cleanup','benchmark'))", [StringComparison]::Ordinal)
$coreImport = $winSource.IndexOf('Import-HuCore', $doctorDispatch + 1, [StringComparison]::Ordinal)
Assert-Contract ($doctorDispatch -ge 0 -and $coreImport -gt $doctorDispatch) 'win.ps1 必须在 Import-HuCore 前分发 doctor'

$helperPath = Join-Path $root 'scripts\HuWin.dll'
$beforeExists = Test-Path -LiteralPath $helperPath -PathType Leaf
$beforeWriteTime = if ($beforeExists) { (Get-Item -LiteralPath $helperPath).LastWriteTimeUtc } else { $null }
$actualOutput = @(& pwsh -NoProfile -File (Join-Path $root 'scripts\win.ps1') doctor --json 2>&1)
$actualExit = $LASTEXITCODE
Assert-Contract ($actualExit -in @(0, 1, 2)) "实际 doctor 返回非法退出码 $actualExit"
$actual = ($actualOutput -join "`n") | ConvertFrom-Json
Assert-Contract ($actual.schema -eq 'win-use-master/doctor-report-v1' -and $actual.readOnly) '实际 doctor JSON 不符合 schema/只读契约'
Assert-Contract (($actualOutput -join "`n") -notmatch '(?i)[a-z]:\\|\\Users\\|/home/') '实际 doctor JSON 泄露绝对用户路径'
$afterExists = Test-Path -LiteralPath $helperPath -PathType Leaf
Assert-Contract ($afterExists -eq $beforeExists) '实际 doctor 改变了 helper 是否存在的状态'
if ($beforeExists) { Assert-Contract ((Get-Item -LiteralPath $helperPath).LastWriteTimeUtc -eq $beforeWriteTime) '实际 doctor 修改了 helper' }

$invalidOutput = @(& pwsh -NoProfile -File (Join-Path $root 'scripts\doctor.ps1') --json --summary 2>&1)
Assert-Contract ($LASTEXITCODE -eq 2 -and ($invalidOutput -join "`n") -match '不能同时使用') '冲突输出选项没有安全拒绝'

Write-Output 'PASS: doctor contract fixtures=5 json/summary/privacy/read-only/early-dispatch'
