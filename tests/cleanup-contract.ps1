$ErrorActionPreference = 'Stop'
Set-StrictMode -Version 2.0

$root = Split-Path -Parent $PSScriptRoot
$win = Join-Path $root 'scripts\win.ps1'
$cleanupSourcePath = Join-Path $root 'scripts\cleanup.ps1'
$cleanupCorePath = Join-Path $root 'scripts\cleanup-core.ps1'
$tempBase = [IO.Path]::GetFullPath([IO.Path]::GetTempPath()).TrimEnd('\')
$fixtureParent = Join-Path $tempBase ('win-use-master-cleanup-contract-' + [Guid]::NewGuid().ToString('N'))
$scanRoot = Join-Path $fixtureParent 'scan-root'
$privateMarker = 'private-cleanup-marker-f51e86'
$pwsh = (Get-Command pwsh -CommandType Application -ErrorAction Stop | Select-Object -First 1).Source

function Assert-Contract([bool] $Condition, [string] $Message) {
    if (-not $Condition) { throw "cleanup contract: $Message" }
}

function Invoke-Win([string[]] $Arguments) {
    $start = [Diagnostics.ProcessStartInfo]::new()
    $start.FileName = $pwsh; $start.WorkingDirectory = $root
    $start.UseShellExecute = $false; $start.CreateNoWindow = $true
    $start.RedirectStandardOutput = $true; $start.RedirectStandardError = $true
    $start.StandardOutputEncoding = [Text.UTF8Encoding]::new($false)
    $start.StandardErrorEncoding = [Text.UTF8Encoding]::new($false)
    foreach ($argument in @('-NoProfile','-File',$win) + $Arguments) { [void]$start.ArgumentList.Add($argument) }
    $process = [Diagnostics.Process]::new(); $process.StartInfo = $start
    try {
        Assert-Contract $process.Start() '无法启动 cleanup 子进程'
        $stdoutTask = $process.StandardOutput.ReadToEndAsync(); $stderrTask = $process.StandardError.ReadToEndAsync()
        if (-not $process.WaitForExit(30000)) { try { $process.Kill($true) } catch { }; throw 'cleanup 子进程超时' }
        return [pscustomobject]@{
            exitCode = $process.ExitCode
            stdout = $stdoutTask.GetAwaiter().GetResult().Trim()
            stderr = $stderrTask.GetAwaiter().GetResult().Trim()
        }
    } finally { $process.Dispose() }
}

function Write-Manifest([string] $Directory, [DateTimeOffset] $CreatedAt, [DateTimeOffset] $ExpiresAt, [int] $OwnerPid, [DateTimeOffset] $OwnerStartedAt, [string] $ArtifactId = '') {
    $leaf = [IO.Path]::GetFileName($Directory)
    $manifest = [pscustomobject][ordered]@{
        schema = 'win-use-master/temp-artifact-v1'
        artifactId = $(if ($ArtifactId) { $ArtifactId } else { $leaf })
        createdAt = $CreatedAt.ToString('o'); expiresAt = $ExpiresAt.ToString('o')
        owner = [pscustomobject][ordered]@{ pid = $OwnerPid; startTimeUtc = $OwnerStartedAt.ToUniversalTime().ToString('o') }
        ignoredPath = "C:\Users\$privateMarker\secret.png"; ignoredContent = $privateMarker
    }
    [IO.File]::WriteAllText((Join-Path $Directory '.win-use-master-manifest.json'), ($manifest | ConvertTo-Json -Depth 6), [Text.UTF8Encoding]::new($false))
}

function New-Candidate([string] $Name) {
    $path = Join-Path $scanRoot $Name
    [IO.Directory]::CreateDirectory($path) | Out-Null
    [IO.File]::WriteAllText((Join-Path $path 'payload.bin'), $privateMarker, [Text.UTF8Encoding]::new($false))
    return $path
}

function Get-FixtureFingerprint {
    $rows = @([IO.Directory]::EnumerateFiles($scanRoot, '*', [IO.SearchOption]::AllDirectories) | Sort-Object | ForEach-Object {
        $item = [IO.FileInfo]::new($_)
        $relative = [IO.Path]::GetRelativePath($scanRoot, $item.FullName)
        "$relative|$($item.Length)|$($item.LastWriteTimeUtc.Ticks)|$((Get-FileHash -LiteralPath $item.FullName -Algorithm SHA256).Hash)"
    })
    return $rows -join "`n"
}

$savedTest = [string]$env:WIN_USE_MASTER_CLEANUP_TEST
$savedRoot = [string]$env:WIN_USE_MASTER_CLEANUP_ROOT
[IO.Directory]::CreateDirectory($scanRoot) | Out-Null
try {
    $env:WIN_USE_MASTER_CLEANUP_TEST = '1'
    $env:WIN_USE_MASTER_CLEANUP_ROOT = $scanRoot
    $now = [DateTimeOffset]::Now
    $stoppedPid = [int]::MaxValue

    $eligible = New-Candidate 'win-use-master-eligible-a1'
    Write-Manifest $eligible $now.AddDays(-2) $now.AddDays(-1) $stoppedPid $now.AddDays(-3)

    $active = New-Candidate 'win-use-master-active-a2'
    $selfStart = [DateTimeOffset](Get-Process -Id $PID -ErrorAction Stop).StartTime.ToUniversalTime()
    Write-Manifest $active $now.AddMinutes(-2) $now.AddMinutes(-1) $PID $selfStart

    [void](New-Candidate 'win-use-master-missing-a3')

    $invalid = New-Candidate 'win-use-master-invalid-a4'
    [IO.File]::WriteAllText((Join-Path $invalid 'manifest.json'), '{"schema":"wrong"}', [Text.UTF8Encoding]::new($false))

    $fresh = New-Candidate 'win-use-master-fresh-a5'
    Write-Manifest $fresh $now.AddMinutes(-1) $now.AddDays(1) $stoppedPid $now.AddDays(-1)

    $mismatch = New-Candidate 'win-use-master-mismatch-a6'
    Write-Manifest $mismatch $now.AddDays(-2) $now.AddDays(-1) $stoppedPid $now.AddDays(-3) 'win-use-master-someone-else'

    $ignored = Join-Path $scanRoot 'another-project-private'
    [IO.Directory]::CreateDirectory($ignored) | Out-Null
    [IO.File]::WriteAllText((Join-Path $ignored 'keep.txt'), $privateMarker, [Text.UTF8Encoding]::new($false))

    $before = Get-FixtureFingerprint
    $full = Invoke-Win @('cleanup','--dry-run','--json')
    Assert-Contract ($full.exitCode -eq 0 -and -not $full.stderr) "full dry-run 应成功且 stderr 为空（exit=$($full.exitCode), stderr=$($full.stderr)）"
    $report = $full.stdout | ConvertFrom-Json
    Assert-Contract ([string]$report.schema -eq 'win-use-master/cleanup-plan-v1' -and [string]$report.mode -eq 'dry-run' -and -not [bool]$report.applyAvailable) 'cleanup schema/mode/apply 边界不匹配'
    Assert-Contract ([int]$report.counts.candidates -eq 6 -and [int]$report.counts.eligible -eq 1 -and [int]$report.counts.refused -eq 5) '候选/可清理/拒绝计数不匹配'
    Assert-Contract (@($report.items).Count -eq 6 -and -not [bool]$report.privacy.absolutePathsIncluded) 'full 应列六个候选但不含绝对路径'
    Assert-Contract (-not $full.stdout.Contains($privateMarker, [StringComparison]::OrdinalIgnoreCase) -and -not $full.stdout.Contains($scanRoot, [StringComparison]::OrdinalIgnoreCase)) '输出不得包含 payload/manifest 私密字段或扫描绝对路径'
    $eligibleRow = $report.items | Where-Object candidate -CEQ 'win-use-master-eligible-a1' | Select-Object -First 1
    $activeRow = $report.items | Where-Object candidate -CEQ 'win-use-master-active-a2' | Select-Object -First 1
    $freshRow = $report.items | Where-Object candidate -CEQ 'win-use-master-fresh-a5' | Select-Object -First 1
    Assert-Contract ([string]$eligibleRow.decision -eq 'eligible' -and [string]$eligibleRow.owner.status -eq 'stopped' -and [int64]$eligibleRow.bytes -gt 0) '过期+owner 停止+有效 manifest 才可列为 eligible'
    Assert-Contract ([string]$activeRow.decision -eq 'refused' -and @($activeRow.reasons) -contains 'active-owner') '活跃原 owner 必须拒绝'
    Assert-Contract ([string]$freshRow.decision -eq 'refused' -and @($freshRow.reasons) -contains 'not-expired') '未过期候选必须拒绝'
    Assert-Contract (@($report.items | Where-Object { $_.candidate -eq 'another-project-private' }).Count -eq 0) '非项目命名空间必须忽略'

    $summary = Invoke-Win @('cleanup','--json','--summary')
    Assert-Contract ($summary.exitCode -eq 0 -and -not $summary.stderr) 'summary dry-run 应成功'
    $summaryReport = $summary.stdout | ConvertFrom-Json
    Assert-Contract (@($summaryReport.items).Count -eq 0 -and -not [bool]$summaryReport.privacy.itemsIncluded -and [int]$summaryReport.counts.eligible -eq 1) 'summary 必须清空 items 但保留计数'

    $textSummary = Invoke-Win @('cleanup','--summary')
    Assert-Contract ($textSummary.exitCode -eq 0 -and $textSummary.stdout -match 'deleted=0 apply=false' -and -not $textSummary.stdout.Contains($privateMarker)) '文本摘要必须明确零删除且不泄露内容'
    $afterReads = Get-FixtureFingerprint
    Assert-Contract ($afterReads -ceq $before) '所有 dry-run 查看必须零写入'

    $apply = Invoke-Win @('cleanup','--apply','--json','--summary')
    Assert-Contract ($apply.exitCode -eq 2) '--apply 必须在扫描/删除前安全拒绝'
    Assert-Contract ((Get-FixtureFingerprint) -ceq $before) '--apply 拒绝不得修改任何候选'

    $cleanupSource = Get-Content -LiteralPath $cleanupSourcePath -Raw -Encoding utf8
    $cleanupCore = Get-Content -LiteralPath $cleanupCorePath -Raw -Encoding utf8
    Assert-Contract (($cleanupSource + $cleanupCore) -notmatch '(?i)\b(Remove-Item|Directory\]::Delete|File\]::Delete|rm\s|del\s)\b') 'cleanup 首版生产代码不得含删除 primitive'

    Remove-Item Env:\WIN_USE_MASTER_CLEANUP_TEST -ErrorAction SilentlyContinue
    $env:WIN_USE_MASTER_CLEANUP_ROOT = $scanRoot
    $unsafe = Invoke-Win @('cleanup','--json','--summary')
    Assert-Contract ($unsafe.exitCode -eq 2 -and (Get-FixtureFingerprint) -ceq $before) '测试开关缺失时自定义根必须拒绝且零修改'

    Write-Output 'PASS: cleanup dry-run namespace/manifest/expiry/owner/reparse policy, privacy, zero writes and unavailable apply'
}
finally {
    if ($savedTest) { $env:WIN_USE_MASTER_CLEANUP_TEST = $savedTest } else { Remove-Item Env:\WIN_USE_MASTER_CLEANUP_TEST -ErrorAction SilentlyContinue }
    if ($savedRoot) { $env:WIN_USE_MASTER_CLEANUP_ROOT = $savedRoot } else { Remove-Item Env:\WIN_USE_MASTER_CLEANUP_ROOT -ErrorAction SilentlyContinue }
    $resolved = [IO.Path]::GetFullPath($fixtureParent)
    $parent = [IO.Path]::GetDirectoryName($resolved).TrimEnd('\')
    $leaf = [IO.Path]::GetFileName($resolved)
    if ($parent -ieq $tempBase -and $leaf -match '^win-use-master-cleanup-contract-[0-9a-f]{32}$') {
        if ([IO.Directory]::Exists($resolved)) { [IO.Directory]::Delete($resolved, $true) }
    } else { throw "拒绝清理未通过边界检查的 fixture：$resolved" }
}
