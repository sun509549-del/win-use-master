$ErrorActionPreference = 'Stop'
Set-StrictMode -Version 2.0

$root = Split-Path -Parent $PSScriptRoot

function Assert-Contract([bool] $Condition, [string] $Message) {
    if (-not $Condition) { throw "repository hygiene contract: $Message" }
}

Push-Location $root
try {
    $tracked = @(& git -c core.quotepath=false ls-files)
    Assert-Contract ($LASTEXITCODE -eq 0) '无法读取 tracked 文件清单'
    $untracked = @(& git -c core.quotepath=false ls-files --others --exclude-standard)
    Assert-Contract ($LASTEXITCODE -eq 0) '无法读取未忽略的 untracked 文件清单'
} finally {
    Pop-Location
}
$files = @($tracked + $untracked | Where-Object { $_ } | Select-Object -Unique)

$forbiddenBinary = @('.dll', '.exe', '.pdb', '.zip', '.7z', '.rar')
$forbiddenMedia = @('.png', '.jpg', '.jpeg', '.gif', '.bmp', '.webp')
foreach ($relative in $files) {
    $normalized = $relative.Replace('\', '/')
    $extension = [IO.Path]::GetExtension($normalized).ToLowerInvariant()
    Assert-Contract ($extension -notin $forbiddenBinary) "不得提交生成二进制或归档：$normalized"
    if ($extension -in $forbiddenMedia) {
        Assert-Contract ($normalized.StartsWith('assets/public/', [StringComparison]::OrdinalIgnoreCase)) "公开媒体必须进入受审查的 assets/public/：$normalized"
    }
}

$packageManifests = @(
    'package.json', 'package-lock.json', 'npm-shrinkwrap.json', 'pnpm-lock.yaml', 'yarn.lock',
    'requirements.txt', 'Pipfile', 'Pipfile.lock', 'poetry.lock', 'pyproject.toml',
    'packages.lock.json', 'go.mod', 'go.sum', 'Cargo.toml', 'Cargo.lock', 'Gemfile', 'Gemfile.lock'
)
$unexpectedManifests = @($files | Where-Object {
    $leaf = [IO.Path]::GetFileName($_)
    $extension = [IO.Path]::GetExtension($_)
    $leaf -in $packageManifests -or $extension -eq '.csproj'
})
Assert-Contract ($unexpectedManifests.Count -eq 0) "发现未登记包管理依赖：$($unexpectedManifests -join ', ')"

$textExtensions = @('.md', '.ps1', '.js', '.json', '.yml', '.yaml', '.cs', '.svg', '.txt')
$secretRules = @(
    [pscustomobject]@{ id = 'private-key'; pattern = ('-----BEGIN ' + '(?:RSA |OPENSSH |EC |DSA )?' + 'PRIVATE KEY-----') },
    [pscustomobject]@{ id = 'github-token'; pattern = ('gh' + '[pousr]_[A-Za-z0-9_]{30,}') },
    [pscustomobject]@{ id = 'github-pat'; pattern = ('github_' + 'pat_[A-Za-z0-9_]{20,}') },
    [pscustomobject]@{ id = 'aws-access-key'; pattern = ('AK' + 'IA[0-9A-Z]{16}') },
    [pscustomobject]@{ id = 'slack-token'; pattern = ('xo' + 'x[abprs]-[A-Za-z0-9-]{20,}') },
    [pscustomobject]@{ id = 'google-api-key'; pattern = ('AI' + 'za[A-Za-z0-9_-]{30,}') },
    [pscustomobject]@{ id = 'openai-style-key'; pattern = ('sk' + '-[A-Za-z0-9_-]{40,}') },
    [pscustomobject]@{ id = 'assigned-secret'; pattern = '(?i)(?:api[_-]?key|client[_-]?secret|access[_-]?token|password)\s*[:=]\s*["''][^"''\r\n]{16,}["'']' }
)
foreach ($relative in $files) {
    $extension = [IO.Path]::GetExtension($relative).ToLowerInvariant()
    if ($extension -notin $textExtensions -and [IO.Path]::GetFileName($relative) -notin @('LICENSE', '.gitattributes', '.gitignore')) { continue }
    $path = Join-Path $root $relative
    Assert-Contract (Test-Path -LiteralPath $path -PathType Leaf) "源文件清单含不可读路径：$relative"
    $raw = Get-Content -LiteralPath $path -Raw -Encoding utf8
    foreach ($rule in $secretRules) {
        Assert-Contract ($raw -notmatch $rule.pattern) "疑似 $($rule.id) 出现在 $relative；不要输出匹配内容"
    }
}

$workflowFiles = @($files | Where-Object { $_.Replace('\', '/') -match '^\.github/workflows/[^/]+\.ya?ml$' })
Assert-Contract ($workflowFiles.Count -gt 0) '缺少 GitHub Actions workflow'
$allowedActions = @(
    'actions/checkout@3d3c42e5aac5ba805825da76410c181273ba90b1',
    'actions/setup-node@820762786026740c76f36085b0efc47a31fe5020'
)
foreach ($relative in $workflowFiles) {
    $raw = Get-Content -LiteralPath (Join-Path $root $relative) -Raw -Encoding utf8
    $uses = @([regex]::Matches($raw, '(?m)^\s*uses:\s*(?<action>\S+)') | ForEach-Object { $_.Groups['action'].Value })
    foreach ($action in $uses) {
        Assert-Contract ($action -in $allowedActions) "workflow 使用未审查或未固定的 Action：$action"
        Assert-Contract ($action -match '@[0-9a-f]{40}$') "Action 必须固定完整 commit：$action"
    }
    Assert-Contract ($raw -notmatch '(?im)^\s*(?:run:\s*)?.*\b(?:npm|pnpm|yarn|pip|pip3)\s+(?:install|add)\b') 'CI 不得隐式安装包管理依赖'
    Assert-Contract ($raw -notmatch '(?im)^\s*(?:run:\s*)?.*\b(?:Install-Module|dotnet\s+restore|choco\s+install|winget\s+install)\b') 'CI 不得隐式安装 PowerShell/.NET/系统包'
}

$supplyChain = Get-Content -LiteralPath (Join-Path $root 'SUPPLY_CHAIN.md') -Raw -Encoding utf8
foreach ($action in $allowedActions) {
    Assert-Contract ($supplyChain -match [regex]::Escape($action)) "供应链清单缺少 $action"
}
Assert-Contract ($supplyChain -match '没有 `package\.json`' -and $supplyChain -match '没有 vendored 第三方源码') '供应链清单必须记录零包依赖与零 vendored 依赖'
$license = Get-Content -LiteralPath (Join-Path $root 'LICENSE') -Raw -Encoding utf8
Assert-Contract ($license -match '\AMIT License' -and $license -match 'Copyright \(c\) 2026 Huashu') 'LICENSE 必须保留 MIT 和上游署名'

Write-Output "PASS: repository hygiene files=$($files.Count) secrets=0 package-manifests=0 actions=$($allowedActions.Count)"
