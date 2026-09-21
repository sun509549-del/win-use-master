$ErrorActionPreference = 'Stop'
Set-StrictMode -Version 2.0

$root = Split-Path -Parent $PSScriptRoot

function Assert-Contract([bool] $Condition, [string] $Message) {
    if (-not $Condition) { throw "static contract: $Message" }
}

$requiredFiles = @(
    '.gitattributes', 'README.md', 'SKILL.md', 'HANDOFF.md', 'PROJECT_STATUS.md', 'IMPLEMENTATION_PLAN.md', 'THREAT_MODEL.md',
    'VERSION', 'CHANGELOG.md', 'RELEASE_NOTES.md',
    'CONTRIBUTING.md', 'SECURITY.md', 'CODE_OF_CONDUCT.md', 'SUPPLY_CHAIN.md', 'LICENSE', 'cdp.js',
    '.github/ISSUE_TEMPLATE/bug.yml', '.github/ISSUE_TEMPLATE/app-profile.yml', '.github/ISSUE_TEMPLATE/security-contact.yml',
    '.github/ISSUE_TEMPLATE/config.yml', '.github/pull_request_template.md',
    'config/risk-actions.json', 'config/app-profiles.json', 'config/public-cases.json', 'config/release.json', 'assets/architecture.svg', 'references/机器可读输出.md', 'references/能力缓存.md', 'references/临时数据治理.md',
    'references/安装升级与卸载.md', 'references/性能基线.md', 'references/应用能力矩阵.generated.md', 'references/应用档案测试模板.md',
    'references/脱敏真实案例.generated.md', 'references/版本与发布.md', 'references/回滚与恢复.md',
    'scripts/win.ps1', 'scripts/doctor.ps1', 'scripts/doctor-core.ps1', 'scripts/capability-cache.ps1', 'scripts/capability-cache-core.ps1',
    'scripts/cleanup.ps1', 'scripts/cleanup-core.ps1', 'scripts/benchmark.ps1', 'scripts/benchmark-core.ps1', 'scripts/benchmark-uia-fixture.ps1',
    'scripts/uia-worker.ps1', 'scripts/risk-policy-core.ps1', 'scripts/risk-policy.js', 'scripts/generate-app-matrix.ps1', 'scripts/generate-public-cases.ps1', 'scripts/release-check.ps1', 'scripts/cdp.js', 'scripts/HuWin.cs',
    'tests/parse-contract.ps1', 'tests/run-tests.ps1', 'tests/test-runner-contract.ps1', 'tests/ci-contract.ps1',
    'tests/governance-contract.ps1', 'tests/repository-hygiene-contract.ps1', 'tests/risk-policy-contract.ps1', 'tests/app-profile-catalog-contract.ps1',
    'tests/profile-test-template.ps1', 'tests/profile-template-contract.ps1',
    'tests/public-cases-contract.ps1',
    'tests/release-contract.ps1',
    'tests/doctor-contract.ps1', 'tests/json-output-contract.ps1', 'tests/capability-cache-contract.ps1', 'tests/cleanup-contract.ps1', 'tests/benchmark-contract.ps1',
    'tests/fixtures/doctor/ready.json', 'tests/fixtures/doctor/missing-node.json',
    'tests/fixtures/doctor/stale-helper.json', 'tests/fixtures/doctor/secure-desktop.json',
    'tests/fixtures/doctor/historical-leftovers.json',
    'tests/settings-profile.ps1', 'tests/uia-read-contract.ps1', 'tests/window-state-contract.ps1'
)
foreach ($relative in $requiredFiles) {
    Assert-Contract (Test-Path -LiteralPath (Join-Path $root $relative) -PathType Leaf) "缺少发布文件 $relative"
}

$skill = Get-Content -LiteralPath (Join-Path $root 'SKILL.md') -Raw -Encoding utf8
Assert-Contract ($skill -match '(?s)\A---\s*\r?\nname:\s*win-use-master\s*\r?\ndescription:') 'SKILL.md frontmatter 缺失或名称不正确'
Assert-Contract ($skill.Length -le 6000) "SKILL.md 超过 6000 字符（当前 $($skill.Length)）"
Assert-Contract ($skill -match '2 绝不能当成功') 'SKILL.md 丢失退出码 2 的安全约定'
Assert-Contract ($skill -match 'see <hwnd>.*--summary') 'SKILL.md 丢失敏感窗口的 see --summary 约定'
Assert-Contract ($skill -match 'uia/uiaread --summary') 'SKILL.md 丢失敏感 UIA 读取的摘要约定'
Assert-Contract ($skill -match 'probe\.ps1.*--json.*--summary') 'SKILL.md 丢失 probe 机器可读入口'

$winEntrypoint = Get-Content -LiteralPath (Join-Path $root 'scripts/win.ps1') -Raw -Encoding utf8
$probeEntrypoint = Get-Content -LiteralPath (Join-Path $root 'scripts/probe.ps1') -Raw -Encoding utf8
$cdpEntrypoint = Get-Content -LiteralPath (Join-Path $root 'scripts/cdp.js') -Raw -Encoding utf8
Assert-Contract ($winEntrypoint -match 'win-use-master/window-state-result-v1') '窗口状态结果 schema 未进入生产入口'
Assert-Contract ($probeEntrypoint -match 'win-use-master/probe-report-v1') 'probe 结果 schema 未进入生产入口'
Assert-Contract ($winEntrypoint -match "Command -iin @\('doctor','cache','cleanup','benchmark'\)") 'doctor/cache/cleanup/benchmark 必须在桌面 helper 加载前独立分发'
Assert-Contract ($cdpEntrypoint -match 'win-use-master/cdp-targets-result-v1' -and $cdpEntrypoint -match 'win-use-master/cdp-inspect-result-v1') 'CDP list/inspect schema 未进入生产入口'
$cacheCore = Get-Content -LiteralPath (Join-Path $root 'scripts/capability-cache-core.ps1') -Raw -Encoding utf8
Assert-Contract ($cacheCore -match 'trustedForAuthorization = \$false' -and $cacheCore -match 'CapabilityCacheRetentionDays = 30') '能力缓存必须明确不可信且 30 天失效'
Assert-Contract ($cdpEntrypoint -notmatch 'capability-cache|CapabilityCache') 'CDP 写入口不得读取能力缓存'
$cleanupEntrypoint = Get-Content -LiteralPath (Join-Path $root 'scripts/cleanup.ps1') -Raw -Encoding utf8
$cleanupCore = Get-Content -LiteralPath (Join-Path $root 'scripts/cleanup-core.ps1') -Raw -Encoding utf8
Assert-Contract (($cleanupEntrypoint + $cleanupCore) -match 'win-use-master/cleanup-plan-v1') 'cleanup dry-run schema 未进入生产入口'
Assert-Contract (($cleanupEntrypoint + $cleanupCore) -notmatch '(?i)\b(Remove-Item|Directory\]::Delete|File\]::Delete)\b') 'cleanup 首版生产代码不得包含删除 primitive'
$benchmarkEntrypoint = Get-Content -LiteralPath (Join-Path $root 'scripts/benchmark.ps1') -Raw -Encoding utf8
Assert-Contract ($benchmarkEntrypoint -match 'win-use-master/performance-report-v1') '性能报告 schema 未进入生产入口'
Assert-Contract ($benchmarkEntrypoint -match 'writeCommandsBenchmarked = 0' -and $benchmarkEntrypoint -match 'realApplicationsStarted = 0' -and $benchmarkEntrypoint -notmatch '(?i)SendInput|--allow-side-effects|eval-unsafe') '性能入口不得绕过安全闸或执行写基线'

foreach ($scriptFile in Get-ChildItem -LiteralPath (Join-Path $root 'scripts'), (Join-Path $root 'tests') -Filter '*.ps1' -File) {
    foreach ($line in Get-Content -LiteralPath $scriptFile.FullName -Encoding utf8) {
        if ($line -match 'Get-Command\s+(?:pwsh|node)\b') {
            Assert-Contract ($line -match 'Select-Object\s+-First\s+1') "$($scriptFile.Name) 的运行时解析必须显式选择首个 Application，避免多 PATH 结果拼接"
        }
    }
}

$compat = Get-Content -LiteralPath (Join-Path $root 'cdp.js') -Raw -Encoding utf8
Assert-Contract ($compat.Length -le 512) '根目录 cdp.js 应保持轻量兼容入口'
Assert-Contract ($compat -match 'require\([''"]\./scripts/cdp\.js[''"]\)') '根目录 cdp.js 未转发到 scripts/cdp.js'

$policyPath = Join-Path $root 'config/risk-actions.json'
$policy = Get-Content -LiteralPath $policyPath -Raw -Encoding utf8 | ConvertFrom-Json
Assert-Contract ([string]$policy.schema -eq 'win-use-master/risk-actions-v1') '风险规则 schema 不匹配'
Assert-Contract ((@($policy.normalization) -join ',') -ceq 'unicode-nfkc,camel-case-boundary,separator-to-space,collapse-whitespace,trim') '风险规则规范化约定不匹配'
Assert-Contract (@($policy.blockedTextPatterns).Count -ge 8) '风险文本分类规则不足'
foreach ($chord in @('Enter','Ctrl+S','Ctrl+Shift+S','Alt+F4')) {
    Assert-Contract (@($policy.blockedKeyChords) -contains $chord) "风险规则缺少按键 $chord"
}
Assert-Contract (@($policy.blockedDomSemantics) -contains 'form-submit') '风险规则缺少 form-submit'

foreach ($rule in @($policy.blockedTextPatterns)) {
    Assert-Contract ([string]$rule.flags -in @('', 'i')) "规则 $($rule.id) 使用了跨运行时未约定的 flags"
    [void][regex]::new([string]$rule.pattern)
}

foreach ($profilePath in @('tests/excel-com-profile.ps1', 'tests/wps-et-com-profile.ps1')) {
    $profileSource = Get-Content -LiteralPath (Join-Path $root $profilePath) -Raw -Encoding utf8
    Assert-Contract ($profileSource -match '(?s)Write-Output\s+"PASS:.*?\r?\n\}\s*finally\s*\{\s*# Outer privacy boundary:.*?\[IO\.Directory\]::Exists\(\$full\).*?StartsWith\(\$tempRoot,\s*\[StringComparison\]::OrdinalIgnoreCase\).*?Remove-Item\s+-LiteralPath\s+\$full\s+-Recurse') "$profilePath 必须在最外层 finally 中按 temp 根和命名空间边界清理证据"
}
$wpsProfile = Get-Content -LiteralPath (Join-Path $root 'tests/wps-et-com-profile.ps1') -Raw -Encoding utf8
Assert-Contract ($wpsProfile -match '(?s)\$quit2Requested\s*=\s*\$false.*?finally\s*\{\s*if\s*\(\$app2\s+-and\s+-not\s+\$quit2Requested\).*?\$app2\.Quit\(\)') 'WPS 第二私有实例失败路径必须先尝试关闭自己的工作簿并 Quit'

$svgPath = Join-Path $root 'assets/architecture.svg'
$svgRaw = Get-Content -LiteralPath $svgPath -Raw -Encoding utf8
$svg = [xml]$svgRaw
Assert-Contract ($svg.DocumentElement.LocalName -eq 'svg') '架构图不是有效 SVG 根元素'
Assert-Contract ($null -ne $svg.SelectSingleNode("//*[local-name()='title']")) '架构图缺少可访问 title'
Assert-Contract ($null -ne $svg.SelectSingleNode("//*[local-name()='desc']")) '架构图缺少可访问 desc'
Assert-Contract ($null -eq $svg.SelectSingleNode("//*[local-name()='script']")) '架构图不得包含脚本'
Assert-Contract ($svgRaw -notmatch '(?i)(?:href|src)\s*=\s*["'']\s*(?:https?:)?//') '架构图不得引用远程资源'

$readmePath = Join-Path $root 'README.md'
$readme = Get-Content -LiteralPath $readmePath -Raw -Encoding utf8
Assert-Contract ($readme -match '!\[[^\]]*\]\(assets/architecture\.svg\)') 'README 未嵌入架构图'
$relativeLinks = [regex]::Matches($readme, '\]\((?<path>[^)#]+)(?:#[^)]*)?\)')
foreach ($match in $relativeLinks) {
    $target = [Uri]::UnescapeDataString($match.Groups['path'].Value.Trim())
    if (-not $target -or $target -match '^(?i:https?://|mailto:)' -or $target.StartsWith('#')) { continue }
    Assert-Contract (Test-Path -LiteralPath (Join-Path $root $target)) "README 相对链接失效：$target"
}

$ignore = Get-Content -LiteralPath (Join-Path $root '.gitignore') -Raw -Encoding utf8
Assert-Contract ($ignore -match '(?m)^scripts/HuWin\.dll\r?$') '.gitignore 未排除生成的 HuWin.dll'
Assert-Contract ($ignore -match '(?m)^\.last-update-check\r?$') '.gitignore 未排除本地版本检查状态'
$attributes = Get-Content -LiteralPath (Join-Path $root '.gitattributes') -Raw -Encoding utf8
Assert-Contract ($attributes -match '(?m)^\* text=auto eol=lf\r?$') '仓库必须固定文本为 LF，避免 Windows checkout 改变 Skill 体积和契约结果'

Write-Output "PASS: static publish contract files/risk-policy/svg/README-links/SKILL-size=$($skill.Length)"
