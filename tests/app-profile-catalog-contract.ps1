$ErrorActionPreference = 'Stop'
Set-StrictMode -Version 2.0

$root = Split-Path -Parent $PSScriptRoot
$catalogPath = Join-Path $root 'config/app-profiles.json'
$sourcePath = Join-Path $root 'references/app档案.md'
$matrixPath = Join-Path $root 'references/应用能力矩阵.generated.md'
$generatorPath = Join-Path $root 'scripts/generate-app-matrix.ps1'
$runnerPath = Join-Path $root 'tests/run-tests.ps1'

function Assert-Contract([bool] $Condition, [string] $Message) {
    if (-not $Condition) { throw "app profile catalog contract: $Message" }
}

function Has-Property([object] $Object, [string] $Name) {
    return $null -ne $Object.PSObject.Properties[$Name]
}

$raw = Get-Content -LiteralPath $catalogPath -Raw -Encoding utf8
$catalog = $raw | ConvertFrom-Json
$profiles = @($catalog.profiles)
$source = Get-Content -LiteralPath $sourcePath -Raw -Encoding utf8
$runner = Get-Content -LiteralPath $runnerPath -Raw -Encoding utf8

Assert-Contract ([string]$catalog.schema -eq 'win-use-master/app-profile-catalog-v1') 'schema 不匹配'
Assert-Contract ([string]$catalog.sourceDocument -eq 'references/app档案.md') '人工正文来源不匹配'
Assert-Contract ([int]$catalog.freshnessPolicy.maxAgeDays -eq 30) '档案保鲜期必须保持 30 天'
Assert-Contract ([bool]$catalog.freshnessPolicy.versionChangeInvalidates) '版本变化必须使档案失效'
Assert-Contract ([bool]$catalog.freshnessPolicy.identityChangeInvalidates) '进程/身份变化必须使档案失效'
Assert-Contract ($profiles.Count -eq 10) '目录应包含 9 个实测样本和 1 个未安装占位'

$statusValues = @('replayable', 'read-only-observation', 'not-installed')
$capabilityValues = @('verified-read', 'verified-reversible-write', 'verified-isolated-write', 'observed', 'unavailable-observed', 'provider-timeout', 'not-tested', 'not-installed')
$ids = @($profiles | ForEach-Object { [string]$_.appId })
$orders = @($profiles | ForEach-Object { [int]$_.order })
Assert-Contract (@($ids | Select-Object -Unique).Count -eq $profiles.Count) 'appId 必须唯一'
Assert-Contract (($orders -join ',') -eq '1,2,3,4,5,6,7,8,9,10') 'order 必须连续且稳定'

foreach ($profile in $profiles) {
    $id = [string]$profile.appId
    Assert-Contract ($id -match '^[a-z0-9]+(?:-[a-z0-9]+)*$') "appId 格式无效：$id"
    Assert-Contract (-not [string]::IsNullOrWhiteSpace([string]$profile.productName)) "$id 缺少产品名"
    Assert-Contract ([string]$profile.profileStatus -in $statusValues) "$id 的 profileStatus 无效"
    Assert-Contract (Has-Property $profile 'releaseDate') "$id 必须显式声明 releaseDate；未知时为 null"
    Assert-Contract (Has-Property $profile 'observedVersion') "$id 必须显式声明 observedVersion"
    Assert-Contract (Has-Property $profile 'verifiedDate') "$id 必须显式声明 verifiedDate"
    $parsedDate = [datetime]::MinValue
    Assert-Contract ([datetime]::TryParseExact([string]$profile.verifiedDate, 'yyyy-MM-dd', [Globalization.CultureInfo]::InvariantCulture, [Globalization.DateTimeStyles]::None, [ref]$parsedDate)) "$id 的 verifiedDate 不是 YYYY-MM-DD"
    Assert-Contract (-not [string]::IsNullOrWhiteSpace([string]$profile.installKind)) "$id 缺少安装形态"
    Assert-Contract (-not [string]::IsNullOrWhiteSpace([string]$profile.architecture)) "$id 缺少架构"
    Assert-Contract (@($profile.processIdentity.executables).Count -ge 1) "$id 缺少进程身份"
    foreach ($executable in @($profile.processIdentity.executables)) {
        Assert-Contract ([string]$executable -match '^[^\\/:*?"<>|]+\.exe$') "$id 的 executable 必须是脱敏 basename：$executable"
    }
    Assert-Contract (-not [string]::IsNullOrWhiteSpace([string]$profile.processIdentity.hostRelationship)) "$id 缺少宿主关系"
    foreach ($layer in @('L0', 'L1', 'L2', 'L3')) {
        Assert-Contract (Has-Property $profile.capabilities $layer) "$id 缺少 $layer"
        Assert-Contract ([string]$profile.capabilities.$layer -in $capabilityValues) "$id 的 $layer 状态无效"
    }
    Assert-Contract (@($profile.verifiedTasks).Count -ge 1) "$id 缺少已验证任务"
    Assert-Contract (-not [string]::IsNullOrWhiteSpace([string]$profile.reversibleStrategy)) "$id 缺少可逆/隔离策略"
    Assert-Contract (@($profile.stopLines).Count -ge 1) "$id 缺少停手线"
    Assert-Contract (@($profile.fragileAssumptions).Count -ge 1) "$id 缺少易腐假设"
    Assert-Contract (@($profile.revalidateOn).Count -ge 1) "$id 缺少复验条件"
    Assert-Contract (-not [bool]$profile.evidence.rawEvidenceCommitted) "$id 不得提交原始证据"
    Assert-Contract (-not [bool]$profile.evidence.publicMetadataContainsSensitiveData) "$id 的公开元数据不得含敏感数据"
    Assert-Contract ([string]$profile.evidence.policy -eq 'derived-metadata-only') "$id 必须只提交派生元数据"
    Assert-Contract ($source.Contains([string]$profile.productName, [StringComparison]::Ordinal)) "$id 的产品名未出现在人工档案"

    if ($profile.profileStatus -eq 'not-installed') {
        Assert-Contract ($null -eq $profile.observedVersion) "$id 未安装时不得伪造版本"
        Assert-Contract ($null -eq $profile.testPath) "$id 未安装时不得声称有可重放测试"
        Assert-Contract (@($profile.capabilities.PSObject.Properties.Value | Where-Object { [string]$_ -ne 'not-installed' }).Count -eq 0) "$id 未安装时四层能力都应为 not-installed"
        Assert-Contract (@($profile.revalidateOn) -contains 'installation-change') "$id 必须在安装状态变化后复验"
    } else {
        Assert-Contract (-not [string]::IsNullOrWhiteSpace([string]$profile.observedVersion)) "$id 已观察档案必须有版本"
        Assert-Contract ($source.Contains([string]$profile.observedVersion, [StringComparison]::Ordinal)) "$id 的版本未出现在人工档案"
        Assert-Contract (@($profile.windowClasses).Count -ge 1) "$id 已观察档案必须记录窗口类"
        Assert-Contract (@($profile.revalidateOn) -contains 'version-change') "$id 必须在版本变化后复验"
    }

    if ($profile.profileStatus -eq 'replayable') {
        Assert-Contract (-not [string]::IsNullOrWhiteSpace([string]$profile.testPath)) "$id 可重放档案缺少测试路径"
        Assert-Contract (Test-Path -LiteralPath (Join-Path $root ([string]$profile.testPath)) -PathType Leaf) "$id 的测试文件不存在"
        Assert-Contract ($runner.Contains([string]$profile.testPath, [StringComparison]::Ordinal)) "$id 的测试未注册到分层调度器"
        Assert-Contract ([string]$profile.lastResult -eq 'passed') "$id 可重放档案的最后结果必须是 passed"
    } else {
        Assert-Contract ($null -eq $profile.testPath) "$id 非可重放档案不得挂接测试路径"
    }
}

$replayable = @($profiles | Where-Object { $_.profileStatus -eq 'replayable' }).Count
$readOnly = @($profiles | Where-Object { $_.profileStatus -eq 'read-only-observation' }).Count
$notInstalled = @($profiles | Where-Object { $_.profileStatus -eq 'not-installed' }).Count
Assert-Contract ($replayable -eq 6 -and $readOnly -eq 3 -and $notInstalled -eq 1) '6/3/1 档案分类漂移'
Assert-Contract (@($profiles | Where-Object { $_.profileStatus -ne 'not-installed' }).Count -eq 9) '已实测样本必须保持 9 个'

Assert-Contract ($raw -notmatch '(?i)[A-Z]:\\|%APPDATA%|\\Users\\|/Users/') '机器目录不得含绝对安装路径或用户目录'
Assert-Contract ($raw -notmatch '(?i)"(?:pid|hwnd|port|elementRef)"\s*:') '机器目录不得固化 PID/HWND/端口/短期元素引用字段'
Assert-Contract (Test-Path -LiteralPath $matrixPath -PathType Leaf) '缺少生成的能力矩阵'
& pwsh -NoProfile -File $generatorPath -Check
Assert-Contract ($LASTEXITCODE -eq 0) '能力矩阵与目录不一致'

$matrix = Get-Content -LiteralPath $matrixPath -Raw -Encoding utf8
Assert-Contract ($matrix -match '已实测样本 \*\*9\*\* 个：可重放 \*\*6\*\* 个，只读观察 \*\*3\*\* 个；另有未安装占位 \*\*1\*\* 个') '矩阵分类摘要不匹配'
Assert-Contract ($matrix -notmatch '(?i)[A-Z]:\\|%APPDATA%|\\Users\\|/Users/') '生成矩阵不得泄露绝对安装路径或用户目录'

Write-Output 'PASS: 10 catalog entries, 9 observed samples, 6 replayable, deterministic matrix, privacy and freshness policy'
