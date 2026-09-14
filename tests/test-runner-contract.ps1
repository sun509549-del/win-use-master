$ErrorActionPreference = 'Stop'
Set-StrictMode -Version 2.0

$root = Split-Path -Parent $PSScriptRoot
$runner = Join-Path $PSScriptRoot 'run-tests.ps1'
$tempRoot = [IO.Path]::GetFullPath([IO.Path]::GetTempPath())
$tempDir = Join-Path $tempRoot ("win-use-master-runner-contract-" + [Guid]::NewGuid().ToString('N'))

function Assert-Contract([bool] $Condition, [string] $Message) {
    if (-not $Condition) { throw "test runner contract: $Message" }
}

function Invoke-Runner([string[]] $Arguments) {
    $output = @(& pwsh -NoProfile -File $runner @Arguments 2>&1)
    return [pscustomobject]@{ output = @($output | ForEach-Object { [string]$_ }); exitCode = $LASTEXITCODE }
}

New-Item -ItemType Directory -Path $tempDir -ErrorAction Stop | Out-Null
try {
    $list = Invoke-Runner @('-List')
    Assert-Contract ($list.exitCode -eq 0) '-List 应成功且不得执行测试'
    Assert-Contract (($list.output -join "`n") -match 'coordinate-smoke') '-List 缺少 Coordinate 层'
    Assert-Contract (($list.output -join "`n") -match 'profile-settings') '-List 缺少真实档案层'

    $contractPath = Join-Path $tempDir 'contract.json'
    $dry = Invoke-Runner @('-Tier', 'Contract', '-DryRun', '-ReportPath', $contractPath)
    Assert-Contract ($dry.exitCode -eq 0) 'Contract dry-run 应成功'
    Assert-Contract (Test-Path -LiteralPath $contractPath -PathType Leaf) 'Contract dry-run 未生成报告'
    $contract = Get-Content -LiteralPath $contractPath -Raw -Encoding utf8 | ConvertFrom-Json
    Assert-Contract ([string]$contract.schema -eq 'win-use-master/test-report-v1') '报告 schema 不匹配'
    Assert-Contract ([string]$contract.tier -eq 'Contract' -and [bool]$contract.dryRun) '报告 tier/dryRun 不匹配'
    Assert-Contract ([int]$contract.summary.executed -eq 0) 'dry-run 不得执行测试'
    Assert-Contract ([int]$contract.summary.planned -eq 9) 'Contract 层计划数量漂移'
    Assert-Contract (@($contract.tests | Where-Object { $_.status -ne 'planned' }).Count -eq 0) 'dry-run 状态必须全部为 planned'
    $contractRaw = Get-Content -LiteralPath $contractPath -Raw -Encoding utf8
    Assert-Contract (-not $contractRaw.Contains($root, [StringComparison]::OrdinalIgnoreCase)) '报告不得包含工作区绝对路径'
    Assert-Contract (-not $contractRaw.Contains($tempDir, [StringComparison]::OrdinalIgnoreCase)) '报告不得包含报告目录绝对路径'

    $subsetPath = Join-Path $tempDir 'subset.json'
    $subset = Invoke-Runner @('-Tier', 'Contract', '-TestId', 'parse,static', '-DryRun', '-ReportPath', $subsetPath)
    Assert-Contract ($subset.exitCode -eq 0) 'TestId 子集 dry-run 应成功'
    $subsetReport = Get-Content -LiteralPath $subsetPath -Raw -Encoding utf8 | ConvertFrom-Json
    $subsetIds = @($subsetReport.tests | ForEach-Object { [string]$_.id } | Sort-Object)
    Assert-Contract (($subsetIds -join ',') -eq 'parse,static') 'TestId 必须只选择当前 tier 的显式测试'

    $actualPath = Join-Path $tempDir 'actual.json'
    $actual = Invoke-Runner @('-Tier', 'Contract', '-TestId', 'parse', '-ReportPath', $actualPath)
    Assert-Contract ($actual.exitCode -eq 0) '精确选择的实际测试应成功'
    $actualReport = Get-Content -LiteralPath $actualPath -Raw -Encoding utf8 | ConvertFrom-Json
    Assert-Contract ([int]$actualReport.summary.executed -eq 1 -and [int]$actualReport.summary.passed -eq 1) '实际执行摘要不匹配'
    Assert-Contract ([string]$actualReport.tests[0].status -eq 'passed') '实际测试状态应为 passed'
    Assert-Contract ([string]$actualReport.tests[0].outputSha256 -match '^[0-9a-f]{64}$') '实际输出应只保留 SHA-256，不嵌入原始日志'

    $profilesPath = Join-Path $tempDir 'profiles.json'
    $profiles = Invoke-Runner @('-Tier', 'Profiles', '-Profile', 'calculator,settings', '-DryRun', '-ReportPath', $profilesPath)
    Assert-Contract ($profiles.exitCode -eq 0) '显式 profile dry-run 应成功'
    $profileReport = Get-Content -LiteralPath $profilesPath -Raw -Encoding utf8 | ConvertFrom-Json
    $profileIds = @($profileReport.tests | ForEach-Object { [string]$_.id } | Sort-Object)
    Assert-Contract ($profileIds.Count -eq 2) '只应选择两个显式 profile'
    Assert-Contract (($profileIds -join ',') -eq 'profile-calculator,profile-settings') 'profile 选择结果不匹配'

    $missingProfile = Invoke-Runner @('-Tier', 'Profiles', '-DryRun')
    Assert-Contract ($missingProfile.exitCode -ne 0) 'Profiles 层不得隐式执行全部真实应用'

    $refuseOverwrite = Invoke-Runner @('-Tier', 'Contract', '-DryRun', '-ReportPath', $contractPath)
    Assert-Contract ($refuseOverwrite.exitCode -ne 0) '已存在报告必须默认拒绝覆盖'
    $forceOverwrite = Invoke-Runner @('-Tier', 'Contract', '-DryRun', '-ReportPath', $contractPath, '-ForceReport')
    Assert-Contract ($forceOverwrite.exitCode -eq 0) '-ForceReport 应仅允许覆盖明确报告文件'

    Write-Output 'PASS: tier selection, explicit profiles, dry-run report privacy and overwrite guard'
} finally {
    $resolved = [IO.Path]::GetFullPath($tempDir)
    $leaf = Split-Path -Leaf $resolved
    if ($resolved.StartsWith($tempRoot, [StringComparison]::OrdinalIgnoreCase) -and $leaf -like 'win-use-master-runner-contract-*') {
        Remove-Item -LiteralPath $resolved -Recurse -Force -ErrorAction Stop
        if (Test-Path -LiteralPath $resolved) { throw "测试目录清理后仍存在：$resolved" }
    } else {
        throw "拒绝清理未通过边界检查的测试目录：$resolved"
    }
}
