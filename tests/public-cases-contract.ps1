$ErrorActionPreference = 'Stop'
Set-StrictMode -Version 2.0

$root = Split-Path -Parent $PSScriptRoot
$manifestPath = Join-Path $root 'config/public-cases.json'
$catalogPath = Join-Path $root 'config/app-profiles.json'
$outputPath = Join-Path $root 'references/脱敏真实案例.generated.md'
$generatorPath = Join-Path $root 'scripts/generate-public-cases.ps1'

function Assert-Contract([bool] $Condition, [string] $Message) {
    if (-not $Condition) { throw "public cases contract: $Message" }
}

function Has-Property([object] $Object, [string] $Name) {
    return $null -ne $Object.PSObject.Properties[$Name]
}

$raw = Get-Content -LiteralPath $manifestPath -Raw -Encoding utf8
$manifest = $raw | ConvertFrom-Json
$catalog = Get-Content -LiteralPath $catalogPath -Raw -Encoding utf8 | ConvertFrom-Json
$cases = @($manifest.cases)

Assert-Contract ([string]$manifest.schema -eq 'win-use-master/public-cases-v1') 'schema 不匹配'
Assert-Contract ([string]$manifest.generatedDocument -eq 'references/脱敏真实案例.generated.md') '生成文档路径不匹配'
Assert-Contract ([bool]$manifest.policy.derivedOnly) '公开案例必须只包含派生事实'
Assert-Contract (-not [bool]$manifest.policy.rawEvidenceCommitted) '不得提交原始证据'
Assert-Contract (-not [bool]$manifest.policy.fixtureSubstitutionAllowed) '不得用 fixture 冒充真实应用素材'
Assert-Contract ([string]$manifest.policy.visualAssetRequirement -eq 'reviewed-and-redacted-source-only') '视觉素材必须经过来源和脱敏复核'
Assert-Contract ($cases.Count -eq 3) '首版必须包含 UIA、CDP、COM 三类案例'
Assert-Contract ((@($cases | ForEach-Object { [int]$_.order }) -join ',') -eq '1,2,3') '案例顺序必须稳定'
Assert-Contract ((@($cases | ForEach-Object { [string]$_.category } | Sort-Object) -join ',') -eq 'cdp,com,uia') '案例类别必须恰好为 UIA/CDP/COM'
Assert-Contract (@($cases.caseId | Select-Object -Unique).Count -eq 3) 'caseId 必须唯一'

$expectedLayer = @{ uia = 'L1'; cdp = 'L0'; com = 'L0' }
$flowFields = @('discovery', 'selection', 'action', 'verification', 'cleanup')
foreach ($case in $cases) {
    $caseId = [string]$case.caseId
    Assert-Contract ($caseId -match '^[a-z0-9]+(?:-[a-z0-9]+)*$') "caseId 格式无效：$caseId"
    Assert-Contract ([string]$case.controlLayer -eq $expectedLayer[[string]$case.category]) "$caseId 控制层与案例类别不匹配"
    $profiles = @($catalog.profiles | Where-Object { [string]$_.appId -ceq [string]$case.appId })
    Assert-Contract ($profiles.Count -eq 1) "$caseId 未绑定唯一应用目录条目"
    $profile = $profiles[0]
    Assert-Contract ([string]$profile.profileStatus -eq 'replayable') "$caseId 必须来自可重放真实档案"
    Assert-Contract ([string]$profile.testPath -eq [string]$case.sourceTest) "$caseId 的 sourceTest 与应用目录不一致"
    Assert-Contract ([string]$profile.verifiedDate -eq [string]$case.verifiedDate) "$caseId 的验证日期与应用目录不一致"
    Assert-Contract (Test-Path -LiteralPath (Join-Path $root ([string]$case.sourceTest)) -PathType Leaf) "$caseId 的来源测试不存在"
    foreach ($field in $flowFields) {
        Assert-Contract (Has-Property $case.flow $field) "$caseId 缺少 $field 阶段"
        Assert-Contract (-not [string]::IsNullOrWhiteSpace([string]$case.flow.$field)) "$caseId 的 $field 为空"
    }
    Assert-Contract (@($case.independentSignals).Count -ge 2) "$caseId 至少需要两个独立验证信号"
    Assert-Contract (@($case.stopLines).Count -ge 1) "$caseId 缺少停手线"
    Assert-Contract (-not [bool]$case.sideEffects.externalFinalAction) "$caseId 不得声称执行外部最终动作"
    Assert-Contract (-not [bool]$case.sideEffects.persistentUserData) "$caseId 不得保留用户数据"
    Assert-Contract ([bool]$case.sideEffects.temporaryArtifactCreated) "$caseId 必须如实声明真实回归创建过临时对象"
    Assert-Contract ([string]$case.visual.status -eq 'not-included-pending-reviewed-source') "$caseId 不得把未复核视觉素材写成已发布"
    Assert-Contract (-not [bool]$case.visual.fixtureUsed) "$caseId 不得用 fixture 代替真实应用视觉素材"
    Assert-Contract (-not [bool]$case.privacy.rawEvidenceCommitted) "$caseId 不得提交原始证据"
    Assert-Contract (-not [bool]$case.privacy.rawInputIncluded) "$caseId 不得包含测试输入正文"
    Assert-Contract (-not [bool]$case.privacy.absolutePathsIncluded) "$caseId 不得包含绝对路径"
    Assert-Contract (-not [bool]$case.privacy.dynamicIdentifiersIncluded) "$caseId 不得包含动态标识"
}

$notepadSource = Get-Content -LiteralPath (Join-Path $root 'tests/notepad-profile.ps1') -Raw -Encoding utf8
$notepadPattern = @'
(?m)^\s*\$text = '([^']+)'$
'@.Trim()
$notepadMatch = [regex]::Match($notepadSource, $notepadPattern)
Assert-Contract ($notepadMatch.Success -and $notepadMatch.Groups[1].Value.Length -eq [int]$cases[0].metrics.inputLength) 'UIA 案例输入长度与真实测试不一致'
Assert-Contract ([int]$cases[0].metrics.restoredLength -eq 0 -and $notepadSource -match '0 个字符') 'UIA 案例回滚指标与真实测试不一致'

$cdpSource = Get-Content -LiteralPath (Join-Path $root 'tests/workbuddy-cdp-profile.ps1') -Raw -Encoding utf8
$cdpPattern = @'
(?m)^\s*\$probeText = '([^']+)'$
'@.Trim()
$cdpMatch = [regex]::Match($cdpSource, $cdpPattern)
Assert-Contract ($cdpMatch.Success -and $cdpMatch.Groups[1].Value.Length -eq [int]$cases[1].metrics.inputLength) 'CDP 案例输入长度与真实测试不一致'
Assert-Contract ([int]$cases[1].metrics.completedSteps -eq 6 -and $cdpSource -match 'stepsCompleted -ne 6') 'CDP 案例步骤数与真实测试不一致'
Assert-Contract ($cdpSource -match 'receiptRaw\.Contains\(\$probeText\)' -and $cdpSource -match 'target\.url -match ''\\\?''') 'CDP 来源测试缺少正文和 URL query 脱敏断言'

$excelSource = Get-Content -LiteralPath (Join-Path $root 'tests/excel-com-profile.ps1') -Raw -Encoding utf8
Assert-Contract ([int]$cases[2].metrics.dataRows -eq 3 -and $excelSource -match '\$rows = @\(@\(') 'COM 案例行数与真实测试不一致'
Assert-Contract ([string]$cases[2].metrics.formula -eq 'SUM(D2:D4)' -and $excelSource -match [regex]::Escape("Formula = '=SUM(D2:D4)'") ) 'COM 案例公式与真实测试不一致'
Assert-Contract ([int]$cases[2].metrics.verifiedTotal -eq 3640 -and $excelSource -match 'cached=3640') 'COM 案例合计与脱离宿主验证不一致'

Assert-Contract (-not $raw.Contains($notepadMatch.Groups[1].Value, [StringComparison]::Ordinal)) 'manifest 泄露 UIA 合成输入正文'
Assert-Contract (-not $raw.Contains($cdpMatch.Groups[1].Value, [StringComparison]::Ordinal)) 'manifest 泄露 CDP 合成输入正文'
Assert-Contract ($raw -notmatch '(?i)[A-Z]:\\|%APPDATA%|\\Users\\|/Users/|https?://|[A-Z0-9._%+-]+@[A-Z0-9.-]+\.[A-Z]{2,}') 'manifest 含绝对路径、URL 或邮箱'
Assert-Contract ($raw -notmatch '(?i)"(?:pid|hwnd|port|targetUrl|elementRef|rawInput)"\s*:') 'manifest 固化了动态标识或原始输入字段'

& pwsh -NoProfile -File $generatorPath -Check
Assert-Contract ($LASTEXITCODE -eq 0) '生成案例与 manifest 不一致'
$generated = Get-Content -LiteralPath $outputPath -Raw -Encoding utf8
Assert-Contract ($generated -match '当前包含 \*\*3\*\* 个文字案例.*视觉素材 \*\*0\*\* 个') '生成文档没有如实声明 3 个文字案例和 0 个视觉素材'
Assert-Contract (-not $generated.Contains($notepadMatch.Groups[1].Value, [StringComparison]::Ordinal)) '生成文档泄露 UIA 合成输入正文'
Assert-Contract (-not $generated.Contains($cdpMatch.Groups[1].Value, [StringComparison]::Ordinal)) '生成文档泄露 CDP 合成输入正文'
Assert-Contract ($generated -notmatch '(?i)[A-Z]:\\|%APPDATA%|\\Users\\|/Users/|https?://|[A-Z0-9._%+-]+@[A-Z0-9.-]+\.[A-Z]{2,}') '生成文档含绝对路径、URL 或邮箱'
Assert-Contract ($generated -notmatch '!\[[^\]]*\]\([^)]+\)') '未复核视觉素材时生成文档不得嵌入图片'

Write-Output 'PASS: 3 derived UIA/CDP/COM cases, catalog/source-test consistency, deterministic generation, no raw input or visual substitution'
