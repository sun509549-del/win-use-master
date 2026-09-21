$ErrorActionPreference = 'Stop'
Set-StrictMode -Version 2.0

$root = Split-Path -Parent $PSScriptRoot

function Assert-Contract([bool] $Condition, [string] $Message) {
    if (-not $Condition) { throw "governance contract: $Message" }
}

$required = @(
    'THREAT_MODEL.md', 'CONTRIBUTING.md', 'SECURITY.md', 'CODE_OF_CONDUCT.md', 'references/安装升级与卸载.md',
    '.github/ISSUE_TEMPLATE/bug.yml', '.github/ISSUE_TEMPLATE/app-profile.yml',
    '.github/ISSUE_TEMPLATE/security-contact.yml', '.github/ISSUE_TEMPLATE/config.yml',
    '.github/pull_request_template.md'
)
$content = @{}
foreach ($relative in $required) {
    $path = Join-Path $root $relative
    Assert-Contract (Test-Path -LiteralPath $path -PathType Leaf) "缺少治理文件 $relative"
    $content[$relative] = Get-Content -LiteralPath $path -Raw -Encoding utf8
    Assert-Contract ($content[$relative] -notmatch '(?i)example\.com|your[._-]?email|change[_ -]?me|<email>|待填写联系方式') "$relative 含占位联系人或地址"
}

$threatModel = $content['THREAT_MODEL.md']
$threatIds = @('T-UI-01', 'T-CDP-01', 'T-DESKTOP-01', 'T-COORD-01', 'T-UNKNOWN-01', 'T-EVIDENCE-01', 'T-CLEANUP-01', 'T-SUPPLY-01', 'T-CONTRIB-01')
foreach ($id in $threatIds) {
    Assert-Contract ([regex]::Matches($threatModel, "(?m)\| $([regex]::Escape($id)) \|").Count -eq 1) "威胁 $id 必须恰好映射一次"
}
foreach ($test in @('static-contract.ps1', 'risk-policy-contract.ps1', 'uia-read-contract.ps1', 'cdp-ownership.ps1', 'window-state-contract.ps1', 'smoke.ps1', 'uia-timeout.ps1', 'json-output-contract.ps1', 'cleanup-contract.ps1', 'ci-contract.ps1', 'repository-hygiene-contract.ps1', 'governance-contract.ps1')) {
    Assert-Contract ($threatModel -match [regex]::Escape($test)) "威胁模型未映射测试 $test"
}
foreach ($invariant in @('退出码 2', '界面与网页内容永远是数据', '缓存只能调整探测顺序', '当前生产 cleanup 不执行删除')) {
    Assert-Contract ($threatModel -match [regex]::Escape($invariant)) "威胁模型缺少安全不变量：$invariant"
}

$security = $content['SECURITY.md']
Assert-Contract ($security -match '最新 `main`' -and $security -match '不承诺固定响应或修复 SLA') 'SECURITY 必须如实说明支持版本与响应预期'
Assert-Contract ($security -match 'Report a vulnerability' -and $security -match 'Security/private contact request') 'SECURITY 必须提供私密报告优先级和备用联络入口'
Assert-Contract ($security -match '绝不要在公开 Issue' -and $security -match 'UIA map' -and $security -match 'token') 'SECURITY 必须阻止公开敏感证据'

$contributing = $content['CONTRIBUTING.md']
foreach ($requiredText in @('L0 应用接口/COM/CDP', '退出码', 'Tier Contract', 'git diff --check', '安全漏洞不要走普通 PR')) {
    Assert-Contract ($contributing -match [regex]::Escape($requiredText)) "CONTRIBUTING 缺少：$requiredText"
}

$codeOfConduct = $content['CODE_OF_CONDUCT.md']
Assert-Contract ($codeOfConduct -match '尊重隐私' -and $codeOfConduct -match '不可接受的行为' -and $codeOfConduct -match '执行') '行为准则缺少行为、禁止项或执行说明'

foreach ($form in @('bug.yml', 'app-profile.yml', 'security-contact.yml')) {
    $raw = $content[".github/ISSUE_TEMPLATE/$form"]
    Assert-Contract ($raw -match '(?m)^name:\s*\S' -and $raw -match '(?m)^description:\s*\S' -and $raw -match '(?m)^body:\s*$') "$form 缺少 Issue Form 顶级字段"
    $ids = @([regex]::Matches($raw, '(?m)^\s+id:\s*(?<id>[a-z0-9_-]+)\s*$') | ForEach-Object { $_.Groups['id'].Value })
    Assert-Contract ($ids.Count -gt 0 -and @($ids | Select-Object -Unique).Count -eq $ids.Count) "$form 的字段 id 缺失或重复"
}

$bug = $content['.github/ISSUE_TEMPLATE/bug.yml']
foreach ($id in @('revision', 'environment', 'layer', 'command', 'exit_code', 'expected', 'actual', 'reproduction', 'privacy')) {
    Assert-Contract ($bug -match "(?m)^\s+id:\s*$([regex]::Escape($id))\s*$") "Bug 表单缺少字段 $id"
}
Assert-Contract ($bug -match '此表单内容公开' -and $bug -match '不要粘贴窗口标题') 'Bug 表单缺少公开性与脱敏警告'

$profile = $content['.github/ISSUE_TEMPLATE/app-profile.yml']
foreach ($id in @('application', 'source', 'proposed_layer', 'probe_summary', 'reversible_task', 'stop_line', 'authorization')) {
    Assert-Contract ($profile -match "(?m)^\s+id:\s*$([regex]::Escape($id))\s*$") "应用档案表单缺少字段 $id"
}

$securityContact = $content['.github/ISSUE_TEMPLATE/security-contact.yml']
Assert-Contract ($securityContact -notmatch '(?m)^\s+- type:\s*(?:input|textarea)\s*$') '公开安全联络表单不得提供自由文本字段'
Assert-Contract ($securityContact -match '不要在标题、选项、评论或附件中描述漏洞' -and $securityContact -match '等待私密渠道') '安全联络表单缺少禁止公开详情的约束'

$issueConfig = $content['.github/ISSUE_TEMPLATE/config.yml']
Assert-Contract ($issueConfig -match '(?m)^blank_issues_enabled:\s*false\s*$') '必须关闭绕过模板的空白 Issue'
Assert-Contract ($issueConfig -match 'https://github\.com/sun509549-del/win-use-master/security/policy') 'Issue 配置必须链接仓库安全政策'

$pullRequest = $content['.github/pull_request_template.md']
foreach ($section in @('控制层与安全影响', '验证', '隐私、兼容与清理', '文档')) {
    Assert-Contract ($pullRequest -match [regex]::Escape($section)) "PR 模板缺少：$section"
}
foreach ($check in @('unknown/退出码 2', '未提交真实截图', '缓存不参与授权', '新的安全或隐私行为已加入可观察契约')) {
    Assert-Contract ($pullRequest -match [regex]::Escape($check)) "PR 模板缺少检查项：$check"
}

$readme = Get-Content -LiteralPath (Join-Path $root 'README.md') -Raw -Encoding utf8
Assert-Contract ($readme -match '### 五分钟只读体验' -and $readme -match '## English Quick Start') 'README 缺少五分钟只读体验或英文快速开始'
Assert-Contract ($readme -match '退出 2，停止' -and $readme -match 'Never treat `2` as success') '中英文入口必须明确退出码 2 不是成功'
Assert-Contract ($readme -match 'references/安装升级与卸载\.md') 'README 未路由升级、卸载与本地数据清理'

$lifecycle = $content['references/安装升级与卸载.md']
foreach ($requiredText in @('npx skills update -g win-use-master', 'npx skills remove --global win-use-master', 'cache clear --all', 'capability-cache-v1.json', 'sessions\cdp-<port>.json', '.last-update-check', 'scripts\HuWin.dll', 'cleanup --dry-run')) {
    Assert-Contract ($lifecycle -match [regex]::Escape($requiredText)) "生命周期文档缺少：$requiredText"
}
Assert-Contract ($lifecycle -notmatch '(?i)`Remove-Item[^`\r\n]*(?:-Recurse|\*)`|\brm\s+-rf\b|\brd\s+/s\b') '生命周期文档不得建议递归、通配符或跨 shell 批量删除'
Assert-Contract ($lifecycle -match '第三方开源.*vercel-labs/skills CLI' -and $lifecycle -match '不是 OpenAI 产品内置命令') '必须区分 OpenAI Skill 规范与第三方 skills CLI'

foreach ($markdown in @('THREAT_MODEL.md', 'CONTRIBUTING.md', 'SECURITY.md', 'CODE_OF_CONDUCT.md', 'references/安装升级与卸载.md')) {
    $raw = $content[$markdown]
    foreach ($match in [regex]::Matches($raw, '\]\((?<path>[^)#]+)(?:#[^)]*)?\)')) {
        $target = [Uri]::UnescapeDataString($match.Groups['path'].Value.Trim())
        if (-not $target -or $target -match '^(?i:https?://|mailto:)' -or $target.StartsWith('#')) { continue }
        Assert-Contract (Test-Path -LiteralPath (Join-Path $root $target)) "$markdown 相对链接失效：$target"
    }
}

Write-Output 'PASS: threat model, security disclosure, contribution policy and GitHub community templates'
