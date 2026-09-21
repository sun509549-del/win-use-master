$ErrorActionPreference = 'Stop'
Set-StrictMode -Version 2.0

$root = Split-Path -Parent $PSScriptRoot
$manifestPath = Join-Path $root 'config/release.json'
$versionPath = Join-Path $root 'VERSION'
$changelogPath = Join-Path $root 'CHANGELOG.md'
$notesPath = Join-Path $root 'RELEASE_NOTES.md'
$policyPath = Join-Path $root 'references/版本与发布.md'
$rollbackPath = Join-Path $root 'references/回滚与恢复.md'
$checkerPath = Join-Path $root 'scripts/release-check.ps1'
$pwsh = (Get-Command pwsh -CommandType Application -ErrorAction Stop | Select-Object -First 1).Source

function Assert-Contract([bool] $Condition, [string] $Message) {
    if (-not $Condition) { throw "release contract: $Message" }
}

function Invoke-Checker([string[]] $Arguments) {
    $output = @(& $pwsh -NoProfile -File $checkerPath @Arguments 2>&1 | ForEach-Object { [string]$_ })
    return [pscustomobject]@{ output = $output; text = ($output -join "`n"); exitCode = $LASTEXITCODE }
}

function Get-RepositoryFingerprint {
    $items = [Collections.Generic.List[string]]::new()
    foreach ($relative in @(git -C $root ls-files --cached --others --exclude-standard | Sort-Object)) {
        $path = Join-Path $root ([string]$relative)
        if (-not (Test-Path -LiteralPath $path -PathType Leaf)) { continue }
        $items.Add("$relative`t$((Get-FileHash -LiteralPath $path -Algorithm SHA256).Hash.ToLowerInvariant())")
    }
    return ($items -join "`n")
}

$manifestRaw = Get-Content -LiteralPath $manifestPath -Raw -Encoding utf8
$manifest = $manifestRaw | ConvertFrom-Json
$versionRaw = [IO.File]::ReadAllText($versionPath, [Text.Encoding]::UTF8)
$versionBytes = [IO.File]::ReadAllBytes($versionPath)
$changelog = Get-Content -LiteralPath $changelogPath -Raw -Encoding utf8
$notes = Get-Content -LiteralPath $notesPath -Raw -Encoding utf8
$policy = Get-Content -LiteralPath $policyPath -Raw -Encoding utf8
$rollback = Get-Content -LiteralPath $rollbackPath -Raw -Encoding utf8

Assert-Contract ([string]$manifest.schema -eq 'win-use-master/release-manifest-v1') 'release manifest schema 不匹配'
Assert-Contract ([string]$manifest.projectName -eq 'win-use-master') '项目名不匹配'
Assert-Contract ([string]$manifest.version -match '^(0|[1-9]\d*)\.(0|[1-9]\d*)\.(0|[1-9]\d*)(?:-[0-9A-Za-z-]+(?:\.[0-9A-Za-z-]+)*)?(?:\+[0-9A-Za-z-]+(?:\.[0-9A-Za-z-]+)*)?$') '版本不是合法 SemVer'
Assert-Contract ($versionRaw -ceq "$($manifest.version)`n") 'VERSION 必须是与 manifest 相同的单行 LF 文本'
Assert-Contract (-not ($versionBytes.Length -ge 3 -and $versionBytes[0] -eq 0xEF -and $versionBytes[1] -eq 0xBB -and $versionBytes[2] -eq 0xBF)) 'VERSION 不得包含 BOM'
Assert-Contract ([string]$manifest.channel -eq 'beta' -and [string]$manifest.status -eq 'unreleased') '当前候选必须如实保持 beta/unreleased'
Assert-Contract ($null -eq $manifest.releaseDate -and $null -eq $manifest.releaseTag -and $null -eq $manifest.publishedCommit) '未发布候选不得伪造日期、tag 或 commit'
Assert-Contract ($null -eq $manifest.previousStable.version -and $null -eq $manifest.previousStable.tag) '首个正式发布前不得伪造 previous stable'

$gateIds = @($manifest.readiness | ForEach-Object { [string]$_.id })
$expectedGates = @('contract-local', 'desktop-twice', 'coordinate-twice', 'profile-matrix', 'clean-clone', 'privacy-review', 'remote-ci-candidate-sha', 'release-tag-and-checksum')
Assert-Contract (($gateIds -join ',') -eq ($expectedGates -join ',')) '发布门 ID 或顺序漂移'
Assert-Contract (@($gateIds | Select-Object -Unique).Count -eq $gateIds.Count) '发布门 ID 重复'
foreach ($gate in @($manifest.readiness)) {
    Assert-Contract ([bool]$gate.required) "发布门 $($gate.id) 必须是强制项"
    Assert-Contract ([string]$gate.status -in @('pass', 'passed-local', 'pending', 'blocked', 'fail', 'unknown')) "发布门 $($gate.id) 状态无效"
}
Assert-Contract (@($manifest.readiness | Where-Object { $_.status -ne 'pass' }).Count -gt 0) '当前候选不得伪装成全部发布门通过'

Assert-Contract ($changelog -match '(?m)^## \[Unreleased\]\s*$' -and $changelog.Contains("``$($manifest.version)``", [StringComparison]::Ordinal)) 'Changelog 缺少 Unreleased 或候选版本'
Assert-Contract ($changelog -notmatch '(?m)^## \[0\.1\.0-beta\.1\]\s+-\s+\d{4}-\d{2}-\d{2}\s*$') '未发布候选不得写成已发布版本标题'
Assert-Contract ($notes.Contains([string]$manifest.version, [StringComparison]::Ordinal) -and $notes -match '草案，未发布' -and $notes -match '发布阻塞项') 'Release Notes 缺少候选版本、未发布状态或阻塞项'
Assert-Contract ($policy -match 'config/release\.json.*真相源' -and $policy -match '发布动作是外部状态变更') '版本策略缺少真相源或外部发布授权边界'
Assert-Contract ($rollback -match 'previousStable\.version/tag.*null' -and $rollback -match '不能声称存在一键稳定回滚') '回滚文档没有如实说明缺少上一稳定版本'

foreach ($document in @($notesPath, $policyPath, $rollbackPath)) {
    $raw = Get-Content -LiteralPath $document -Raw -Encoding utf8
    foreach ($match in [regex]::Matches($raw, '\]\((?<path>[^)#]+)(?:#[^)]*)?\)')) {
        $target = [Uri]::UnescapeDataString($match.Groups['path'].Value.Trim())
        if (-not $target -or $target -match '^(?i:https?://|mailto:)' -or $target.StartsWith('#')) { continue }
        Assert-Contract (Test-Path -LiteralPath (Join-Path $root $target)) "$(Split-Path -Leaf $document) 相对链接失效：$target"
    }
}

$rollbackCode = @([regex]::Matches($rollback, '(?s)```[^\r\n]*\r?\n(?<code>.*?)```') | ForEach-Object { $_.Groups['code'].Value }) -join "`n"
Assert-Contract ($rollbackCode -notmatch '(?i)git\s+reset\s+--hard|git\s+checkout\s+-f|Remove-Item[^\r\n]*-Recurse|\brm\s+-rf\b|\brd\s+/s\b') '回滚命令块不得覆盖工作区或递归删除目录'

$checkerSource = Get-Content -LiteralPath $checkerPath -Raw -Encoding utf8
Assert-Contract ($checkerSource -notmatch '(?i)\b(?:Set-Content|Add-Content|Out-File|WriteAllText|Remove-Item|Directory\]::Delete|File\]::Delete)\b') 'release-check 必须零文件写入'
Assert-Contract ($checkerSource -notmatch '(?i)&\s*git[^\r\n]*(?:\bpush\b|\bcommit\b|\btag\s+(?:-a|-s|-f))') 'release-check 不得创建 Git 外部状态'

$before = Get-RepositoryFingerprint
$fullRun = Invoke-Checker @('-Json')
Assert-Contract ($fullRun.exitCode -eq 2) '未满足发布门时 release-check 必须退出 2'
Assert-Contract ($fullRun.output.Count -eq 1) 'JSON 输出必须只有一个文档'
$report = $fullRun.text | ConvertFrom-Json
Assert-Contract ([string]$report.schema -eq 'win-use-master/release-readiness-v1') 'readiness schema 不匹配'
Assert-Contract ([string]$report.status -eq 'blocked' -and -not [bool]$report.ready -and [bool]$report.advisoryOnly) '当前报告必须是 blocked/advisory-only'
Assert-Contract ([string]$report.candidate.version -eq [string]$manifest.version -and [string]$report.candidate.releaseStatus -eq 'unreleased') '报告候选身份不匹配'
Assert-Contract ([int]$report.counts.requiredBlocking -gt 0 -and @($report.checks).Count -eq [int]$report.counts.total) '报告阻塞计数或 full checks 不匹配'
Assert-Contract (-not $fullRun.text.Contains($root, [StringComparison]::OrdinalIgnoreCase)) '报告不得泄露工作区绝对路径'
foreach ($property in $report.sideEffects.PSObject.Properties) { Assert-Contract ([int]$property.Value -eq 0) "报告不得产生副作用：$($property.Name)" }

$summaryRun = Invoke-Checker @('-Json', '-Summary')
Assert-Contract ($summaryRun.exitCode -eq 2) '摘要也必须保留 blocked 退出码 2'
$summary = $summaryRun.text | ConvertFrom-Json
Assert-Contract ([string]$summary.privacy.mode -eq 'summary' -and @($summary.checks).Count -eq 0 -and @($summary.privacy.redactedFields) -contains 'checks[].evidence') '摘要必须隐藏逐项 evidence'

$textRun = Invoke-Checker @('-Summary')
Assert-Contract ($textRun.exitCode -eq 2 -and $textRun.text -match 'ready=False' -and $textRun.text -match 'side-effects: files=0 commits=0 tags=0 releases=0 network=0') '文本摘要必须明确阻塞和零副作用'
$after = Get-RepositoryFingerprint
Assert-Contract ($after -ceq $before) 'release-check 前后仓库文件指纹发生变化'

Write-Output 'PASS: unreleased SemVer manifest, changelog/notes sync, safe rollback, blocked read-only release report and zero side effects'
