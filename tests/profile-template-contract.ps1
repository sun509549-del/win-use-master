$ErrorActionPreference = 'Stop'
Set-StrictMode -Version 2.0

$root = Split-Path -Parent $PSScriptRoot
$templatePath = Join-Path $PSScriptRoot 'profile-test-template.ps1'
$pwsh = (Get-Command pwsh -CommandType Application -ErrorAction Stop | Select-Object -First 1).Source

function Assert-Contract([bool] $Condition, [string] $Message) {
    if (-not $Condition) { throw "profile template contract: $Message" }
}

function Invoke-Template([string[]] $Arguments) {
    $output = @(& $pwsh -NoProfile -File $templatePath @Arguments 2>&1 | ForEach-Object { [string]$_ })
    return [pscustomobject]@{ output = $output; text = ($output -join "`n"); exitCode = $LASTEXITCODE }
}

function Get-RepositoryFingerprint {
    $items = [Collections.Generic.List[string]]::new()
    foreach ($relative in @(git -C $root ls-files --cached --others --exclude-standard | Sort-Object)) {
        $path = Join-Path $root ([string]$relative)
        if (-not (Test-Path -LiteralPath $path -PathType Leaf)) { continue }
        $hash = (Get-FileHash -LiteralPath $path -Algorithm SHA256).Hash.ToLowerInvariant()
        $items.Add("$relative`t$hash")
    }
    return ($items -join "`n")
}

$source = Get-Content -LiteralPath $templatePath -Raw -Encoding utf8
foreach ($forbidden in @('Start-Process', 'New-Object -ComObject', 'Invoke-RestMethod', 'Add-Type', 'Remove-Item', 'Directory]::Delete', 'File]::Delete', 'Set-Content', 'WriteAllText', 'CreateDirectory', 'scripts\win.ps1', 'scripts\cdp.js')) {
    Assert-Contract (-not $source.Contains($forbidden, [StringComparison]::OrdinalIgnoreCase)) "只读计划模板不得包含执行或写入 primitive：$forbidden"
}

$before = Get-RepositoryFingerprint

$defaultRefusal = Invoke-Template @('-AppId', 'windows-calculator')
Assert-Contract ($defaultRefusal.exitCode -eq 2) '未显式 -Plan 必须安全拒绝并退出 2'
Assert-Contract ($defaultRefusal.text -match '^refused:' -and $defaultRefusal.text -match '只生成计划') '默认拒绝说明不明确'

$unknown = Invoke-Template @('-AppId', 'catalog-entry-that-does-not-exist', '-Plan', '-Json')
Assert-Contract ($unknown.exitCode -eq 2) '未知 appId 必须在任何动作前安全拒绝'
Assert-Contract ($unknown.text -notmatch '^\{') '拒绝路径不得伪装成成功 JSON'

$conflict = Invoke-Template @('-AppId', 'windows-calculator', '-Plan', '-Json', '-Summary')
Assert-Contract ($conflict.exitCode -eq 2) '冲突输出格式必须安全拒绝'

$jsonRun = Invoke-Template @('-AppId', 'windows-calculator', '-Plan', '-Json')
Assert-Contract ($jsonRun.exitCode -eq 0) '显式 JSON 计划应成功'
Assert-Contract ($jsonRun.output.Count -eq 1) 'JSON 成功 stdout 必须只有一个文档'
$plan = $jsonRun.text | ConvertFrom-Json
Assert-Contract ([string]$plan.schema -eq 'win-use-master/profile-test-plan-v1') '计划 schema 不匹配'
Assert-Contract ([string]$plan.status -eq 'planned') '计划 status 必须为 planned'
$observedAt = [DateTimeOffset]::MinValue
Assert-Contract ([DateTimeOffset]::TryParse([string]$plan.observedAt, [ref]$observedAt)) '计划 observedAt 必须是带时区时间'
Assert-Contract ([string]$plan.privacy.mode -eq 'full' -and [string]$plan.privacy.collection -eq 'catalog-derived-only') '计划隐私声明不匹配'
Assert-Contract (@($plan.privacy.redactedFields) -contains 'rawEvidence') '计划必须明确不采集原始证据'
Assert-Contract ([bool]$plan.templateOnly) '计划必须明确 templateOnly'
Assert-Contract ([string]$plan.appId -eq 'windows-calculator') '计划未绑定请求 appId'
Assert-Contract (@($plan.phases).Count -eq 10) '计划必须包含十阶段档案流程'
Assert-Contract ((@($plan.phases | ForEach-Object { [int]$_.order }) -join ',') -eq '1,2,3,4,5,6,7,8,9,10') '阶段顺序必须稳定'
$expectedIds = @(
    'record-version-and-install-source', 'run-read-only-probe', 'bind-exact-identity', 'select-lowest-control-layer',
    'capture-before-evidence', 'perform-reversible-or-isolated-action', 'verify-through-independent-channel',
    'rollback-and-close-owned-target', 'remove-sensitive-temporary-evidence', 'promote-shared-lessons'
)
Assert-Contract ((@($plan.phases | ForEach-Object { [string]$_.id }) -join ',') -eq ($expectedIds -join ',')) '阶段 ID 漂移'
Assert-Contract ([bool]$plan.invariants.refuseExistingUserInstanceOrState) '缺少用户实例拒绝不变量'
Assert-Contract ([bool]$plan.invariants.exactTargetBindingRequired) '缺少精确目标绑定不变量'
Assert-Contract ([bool]$plan.invariants.unverifiedCoordinateFallbackForbidden) '不得把未验证坐标当通用降级'
Assert-Contract ([bool]$plan.invariants.independentReadbackRequired) '缺少独立读回不变量'
Assert-Contract ([bool]$plan.invariants.rollbackOrIsolationRequired) '缺少回滚或隔离不变量'
Assert-Contract ([bool]$plan.invariants.cleanupInFinallyRequired) '缺少 finally 清理不变量'
Assert-Contract ([int]$plan.invariants.refusalOrUnknownExitCode -eq 2) '拒绝/unknown 必须退出 2'
foreach ($property in $plan.sideEffects.PSObject.Properties) {
    Assert-Contract ([int]$property.Value -eq 0) "计划模板不得产生副作用：$($property.Name)"
}
Assert-Contract (-not $jsonRun.text.Contains($root, [StringComparison]::OrdinalIgnoreCase)) 'JSON 计划不得泄露工作区绝对路径'

$summary = Invoke-Template @('-AppId', 'workbuddy-ai', '-Plan', '-Summary')
Assert-Contract ($summary.exitCode -eq 0) '摘要计划应成功'
Assert-Contract ($summary.output.Count -eq 2 -and $summary.text -match 'phases=10' -and $summary.text -match 'side-effects: applications=0 writes=0 evidence=0 repository-files=0') '摘要必须保持聚合且明确零副作用'

$after = Get-RepositoryFingerprint
Assert-Contract ($after -ceq $before) '模板预演前后仓库文件指纹发生变化'

$machineOutputGuide = Get-Content -LiteralPath (Join-Path $root 'references/机器可读输出.md') -Raw -Encoding utf8
Assert-Contract ($machineOutputGuide -match 'win-use-master/profile-test-plan-v1') '机器可读输出文档缺少计划 schema'
Assert-Contract ($machineOutputGuide -match 'win-use-master/app-profile-catalog-v1') '机器可读输出文档缺少应用目录 schema'

Write-Output 'PASS: profile test template default refusal, catalog binding, 10 phases, safety invariants, privacy and zero side effects'
