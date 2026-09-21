$ErrorActionPreference = 'Stop'
Set-StrictMode -Version 2.0

$root = Split-Path -Parent $PSScriptRoot
$policyPath = Join-Path $root 'config\risk-actions.json'
$powerShellCore = Join-Path $root 'scripts\risk-policy-core.ps1'
$javaScriptCore = Join-Path $root 'scripts\risk-policy.js'

function Assert-Contract([bool] $Condition, [string] $Message) {
    if (-not $Condition) { throw "risk policy contract: $Message" }
}

function Copy-JsonObject($Value) {
    return $Value | ConvertTo-Json -Depth 20 | ConvertFrom-Json
}

function Assert-PolicyRejected($Policy, [string] $Message) {
    $rejected = $false
    try { [void](Assert-WinUseRiskPolicy $Policy) }
    catch { $rejected = $true }
    Assert-Contract $rejected $Message
}

. $powerShellCore
$policy = Import-WinUseRiskPolicy $policyPath
Assert-Contract ([string]$policy.schema -eq 'win-use-master/risk-actions-v1') 'schema 不匹配'
Assert-Contract ((@($policy.normalization) -join ',') -ceq 'unicode-nfkc,camel-case-boundary,separator-to-space,collapse-whitespace,trim') '规范化流水线漂移'

$positive = @(
    [pscustomobject]@{ text = '发送'; expectedRule = 'zh-communication' },
    [pscustomobject]@{ text = '确认支付'; expectedRule = 'zh-financial' },
    [pscustomobject]@{ text = '永久删除'; expectedRule = 'zh-destructive' },
    [pscustomobject]@{ text = '授予权限'; expectedRule = 'zh-consent-save-close' },
    [pscustomobject]@{ text = 'Ｓｅｎｄ'; expectedRule = 'en-communication' },
    [pscustomobject]@{ text = 'transferFunds'; expectedRule = 'en-financial' },
    [pscustomobject]@{ text = 'empty_trash'; expectedRule = 'en-destructive' },
    [pscustomobject]@{ text = 'grantAccess'; expectedRule = 'en-consent-save-close' },
    [pscustomobject]@{ text = 'publish-now'; expectedRule = 'en-communication' },
    [pscustomobject]@{ text = 'confirmPayment'; expectedRule = 'en-financial' },
    [pscustomobject]@{ text = 'delete-account'; expectedRule = 'en-destructive' },
    [pscustomobject]@{ text = 'saveAndClose'; expectedRule = 'en-consent-save-close' }
)
$negative = @(
    'Apply', 'Continue', 'Postpone', 'installation guide', 'Saved search', 'Payment methods',
    'Order history', 'Sender settings', 'Publishers list', 'Submission guidelines',
    'Authorization status', 'Agreeable terms', 'Saving preferences', 'Clearance report', 'Posting schedule'
) | ForEach-Object { [pscustomobject]@{ text = $_; expectedRule = $null } }
$cases = @($positive + $negative)

$powerShellResults = @()
foreach ($case in $cases) {
    $powerShellResults += [pscustomobject]@{
        normalized = ConvertTo-WinUseRiskText $case.text
        ruleId = Find-WinUseBlockedTextRule $policy $case.text
    }
}

$node = Get-Command node -CommandType Application -ErrorAction Stop | Select-Object -First 1
$nodeProgram = @'
const fs = require('node:fs');
const core = require(process.argv[1]);
const policy = core.loadRiskPolicy(process.argv[2]);
const items = JSON.parse(fs.readFileSync(0, 'utf8'));
function rejected(mutator) {
  const copy = JSON.parse(JSON.stringify(policy));
  delete copy.compiledTextPatterns;
  mutator(copy);
  try { core.validateRiskPolicy(copy); return false; } catch (_) { return true; }
}
const results = items.map(item => ({
  normalized: core.normalizeRiskText(item.text),
  ruleId: core.findBlockedTextRule(policy, item.text),
}));
const invalidRejected = [
  rejected(copy => { delete copy.normalization; }),
  rejected(copy => { copy.blockedTextPatterns.push({...copy.blockedTextPatterns[0]}); }),
  rejected(copy => { copy.blockedTextPatterns[0].flags = 'm'; }),
];
process.stdout.write(JSON.stringify({results, invalidRejected}));
'@
$caseJson = @($cases | ForEach-Object { [pscustomobject]@{ text = $_.text } }) | ConvertTo-Json -Compress
$nodeOutput = @($caseJson | & $node.Source -e $nodeProgram $javaScriptCore $policyPath 2>&1 | ForEach-Object { [string]$_ })
Assert-Contract ($LASTEXITCODE -eq 0) 'Node 风险解释器执行失败'
$nodeResult = ($nodeOutput -join "`n") | ConvertFrom-Json
Assert-Contract (@($nodeResult.results).Count -eq $cases.Count) 'Node 结果数量不匹配'
Assert-Contract (@($nodeResult.invalidRejected | Where-Object { -not [bool]$_ }).Count -eq 0) 'Node 未拒绝缺规范化、重复 ID 或非法 flags'

for ($index = 0; $index -lt $cases.Count; $index++) {
    $expected = [string]$cases[$index].expectedRule
    $powerShellRule = [string]$powerShellResults[$index].ruleId
    $nodeRule = [string]$nodeResult.results[$index].ruleId
    Assert-Contract ($powerShellRule -ceq $expected) "PowerShell 规则结果不匹配，case=$index"
    Assert-Contract ($nodeRule -ceq $expected) "Node 规则结果不匹配，case=$index"
    Assert-Contract ([string]$nodeResult.results[$index].normalized -ceq [string]$powerShellResults[$index].normalized) "跨运行时规范化不一致，case=$index"
}

$coveredRuleIds = @($positive.expectedRule | Sort-Object -Unique)
$policyRuleIds = @($policy.blockedTextPatterns | ForEach-Object { [string]$_.id } | Sort-Object -Unique)
Assert-Contract (($coveredRuleIds -join ',') -ceq ($policyRuleIds -join ',')) '每条风险规则必须至少有一个正例'

$missingNormalization = Copy-JsonObject $policy
$missingNormalization.PSObject.Properties.Remove('normalization')
Assert-PolicyRejected $missingNormalization 'PowerShell 未拒绝缺失 normalization 的规则'
$duplicateId = Copy-JsonObject $policy
$duplicateId.blockedTextPatterns = @($duplicateId.blockedTextPatterns) + @(Copy-JsonObject $duplicateId.blockedTextPatterns[0])
Assert-PolicyRejected $duplicateId 'PowerShell 未拒绝重复规则 ID'
$badFlags = Copy-JsonObject $policy
$badFlags.blockedTextPatterns[0].flags = 'm'
Assert-PolicyRejected $badFlags 'PowerShell 未拒绝跨运行时不支持的 flags'

$winSource = Get-Content -LiteralPath (Join-Path $root 'scripts\win.ps1') -Raw -Encoding utf8
$workerSource = Get-Content -LiteralPath (Join-Path $root 'scripts\uia-worker.ps1') -Raw -Encoding utf8
$cdpSource = Get-Content -LiteralPath (Join-Path $root 'scripts\cdp.js') -Raw -Encoding utf8
Assert-Contract ($winSource -match 'risk-policy-core\.ps1' -and $winSource -match 'Find-WinUseBlockedTextRule') 'L1/L2 主入口未使用共享 PowerShell 解释器'
Assert-Contract ($workerSource -match 'risk-policy-core\.ps1' -and $workerSource -match 'Find-WinUseBlockedTextRule') 'UIA action worker 未使用共享 PowerShell 解释器'
Assert-Contract ($winSource -notmatch 'NormalizationForm' -and $workerSource -notmatch 'NormalizationForm') 'PowerShell consumer 不得复制规范化实现'
Assert-Contract ($cdpSource -match "require\('./risk-policy\.js'\)" -and $cdpSource -match 'riskPolicyCore\.findBlockedTextRule') 'CDP 未使用共享 Node 解释器'
Assert-Contract ($cdpSource -notmatch 'compiledTextPatterns\.map') 'CDP consumer 不得复制规则编译实现'

Write-Output "PASS: risk policy cross-runtime normalization positives=$($positive.Count) negatives=$($negative.Count) rules=$($policyRuleIds.Count)"
