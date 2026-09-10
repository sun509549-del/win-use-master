$ErrorActionPreference = 'Stop'
Set-StrictMode -Version 2.0

$root = Split-Path -Parent $PSScriptRoot

function Assert-Contract([bool] $Condition, [string] $Message) {
    if (-not $Condition) { throw "static contract: $Message" }
}

$requiredFiles = @(
    'README.md', 'SKILL.md', 'HANDOFF.md', 'LICENSE', 'cdp.js',
    'config/risk-actions.json', 'assets/architecture.svg',
    'scripts/win.ps1', 'scripts/uia-worker.ps1', 'scripts/cdp.js', 'scripts/HuWin.cs'
)
foreach ($relative in $requiredFiles) {
    Assert-Contract (Test-Path -LiteralPath (Join-Path $root $relative) -PathType Leaf) "缺少发布文件 $relative"
}

$skill = Get-Content -LiteralPath (Join-Path $root 'SKILL.md') -Raw -Encoding utf8
Assert-Contract ($skill -match '(?s)\A---\s*\r?\nname:\s*win-use-master\s*\r?\ndescription:') 'SKILL.md frontmatter 缺失或名称不正确'
Assert-Contract ($skill.Length -le 6000) "SKILL.md 超过 6000 字符（当前 $($skill.Length)）"
Assert-Contract ($skill -match '2 绝不能当成功') 'SKILL.md 丢失退出码 2 的安全约定'

$compat = Get-Content -LiteralPath (Join-Path $root 'cdp.js') -Raw -Encoding utf8
Assert-Contract ($compat.Length -le 512) '根目录 cdp.js 应保持轻量兼容入口'
Assert-Contract ($compat -match 'require\([''"]\./scripts/cdp\.js[''"]\)') '根目录 cdp.js 未转发到 scripts/cdp.js'

$policyPath = Join-Path $root 'config/risk-actions.json'
$policy = Get-Content -LiteralPath $policyPath -Raw -Encoding utf8 | ConvertFrom-Json
Assert-Contract ([string]$policy.schema -eq 'win-use-master/risk-actions-v1') '风险规则 schema 不匹配'
Assert-Contract (@($policy.blockedTextPatterns).Count -ge 2) '风险文本规则不足'
foreach ($chord in @('Enter','Ctrl+S','Ctrl+Shift+S','Alt+F4')) {
    Assert-Contract (@($policy.blockedKeyChords) -contains $chord) "风险规则缺少按键 $chord"
}
Assert-Contract (@($policy.blockedDomSemantics) -contains 'form-submit') '风险规则缺少 form-submit'

function Test-RiskText([string] $Text) {
    $normalized = $Text.Normalize([Text.NormalizationForm]::FormKC)
    $normalized = [regex]::Replace($normalized, '([a-z0-9])([A-Z])', '$1 $2') -replace '[_-]+', ' '
    foreach ($rule in @($policy.blockedTextPatterns)) {
        Assert-Contract ([string]$rule.flags -in @('', 'i')) "规则 $($rule.id) 使用了跨运行时未约定的 flags"
        if ([regex]::IsMatch($normalized, [string]$rule.pattern, [Text.RegularExpressions.RegexOptions]::IgnoreCase)) { return $true }
    }
    return $false
}

foreach ($sample in @('发送','确认支付','Send','delete account','sendButton','transferFunds')) {
    Assert-Contract (Test-RiskText $sample) "风险正例未命中：$sample"
}
foreach ($sample in @('Apply','Continue','Postpone','installation guide','Saved search')) {
    Assert-Contract (-not (Test-RiskText $sample)) "风险负例被误判：$sample"
}

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

Write-Output "PASS: static publish contract files/risk-policy/svg/README-links/SKILL-size=$($skill.Length)"
