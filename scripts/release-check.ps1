[CmdletBinding(PositionalBinding = $false)]
param(
    [switch] $Json,
    [switch] $Summary
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version 2.0

$root = Split-Path -Parent $PSScriptRoot
$manifestPath = Join-Path $root 'config/release.json'
$versionPath = Join-Path $root 'VERSION'
$changelogPath = Join-Path $root 'CHANGELOG.md'
$notesPath = Join-Path $root 'RELEASE_NOTES.md'
$checks = [Collections.Generic.List[object]]::new()

function Add-Check([string] $Id, [bool] $Required, [string] $Status, [AllowNull()][string] $Evidence) {
    $checks.Add([pscustomobject][ordered]@{
        id = $Id
        required = $Required
        status = $Status
        evidence = $Evidence
    })
}

$manifest = Get-Content -LiteralPath $manifestPath -Raw -Encoding utf8 | ConvertFrom-Json
$versionText = (Get-Content -LiteralPath $versionPath -Raw -Encoding utf8).Trim()
$changelog = Get-Content -LiteralPath $changelogPath -Raw -Encoding utf8
$notes = Get-Content -LiteralPath $notesPath -Raw -Encoding utf8
$semverPattern = '^(0|[1-9]\d*)\.(0|[1-9]\d*)\.(0|[1-9]\d*)(?:-[0-9A-Za-z-]+(?:\.[0-9A-Za-z-]+)*)?(?:\+[0-9A-Za-z-]+(?:\.[0-9A-Za-z-]+)*)?$'

$manifestValid = [string]$manifest.schema -eq 'win-use-master/release-manifest-v1' -and
    [string]$manifest.projectName -eq 'win-use-master' -and [string]$manifest.version -match $semverPattern
Add-Check 'manifest-valid' $true $(if ($manifestValid) { 'pass' } else { 'fail' }) $(if ($manifestValid) { 'schema/name/semver' } else { 'manifest-invalid' })

$versionSync = $versionText -ceq [string]$manifest.version
Add-Check 'version-sync' $true $(if ($versionSync) { 'pass' } else { 'fail' }) $(if ($versionSync) { 'VERSION matches manifest' } else { 'VERSION mismatch' })

$changelogSync = $changelog -match '(?m)^## \[Unreleased\]\s*$' -and $changelog.Contains("``$($manifest.version)``", [StringComparison]::Ordinal)
Add-Check 'changelog-sync' $true $(if ($changelogSync) { 'pass' } else { 'fail' }) $(if ($changelogSync) { 'unreleased candidate recorded' } else { 'candidate missing from changelog' })

$notesSync = $notes.Contains([string]$manifest.version, [StringComparison]::Ordinal) -and $notes -match '草案，未发布' -and [string]$manifest.status -eq 'unreleased'
Add-Check 'release-notes-sync' $true $(if ($notesSync) { 'pass' } else { 'fail' }) $(if ($notesSync) { 'draft and manifest agree' } else { 'release notes status/version mismatch' })

$releaseRecordValid = if ([string]$manifest.status -eq 'unreleased') {
    $null -eq $manifest.releaseDate -and $null -eq $manifest.releaseTag -and $null -eq $manifest.publishedCommit
} else {
    [string]$manifest.status -eq 'released' -and [string]$manifest.releaseTag -eq "v$($manifest.version)" -and
        [string]$manifest.releaseDate -match '^\d{4}-\d{2}-\d{2}$' -and [string]$manifest.publishedCommit -match '^[0-9a-f]{40}$'
}
Add-Check 'release-record' $true $(if ($releaseRecordValid) { 'pass' } else { 'fail' }) $(if ($releaseRecordValid) { [string]$manifest.status } else { 'release metadata inconsistent' })

$git = Get-Command git -CommandType Application -ErrorAction SilentlyContinue | Select-Object -First 1
$gitAvailable = $null -ne $git
$workingTreeClean = $null
if ($gitAvailable) {
    $statusLines = @(& $git.Source -C $root status --porcelain=v1 --untracked-files=all 2>$null)
    if ($LASTEXITCODE -eq 0) { $workingTreeClean = ($statusLines.Count -eq 0) }
}
$worktreeStatus = if ($workingTreeClean -eq $true) { 'pass' } elseif ($workingTreeClean -eq $false) { 'fail' } else { 'unknown' }
Add-Check 'working-tree-clean' $true $worktreeStatus $(if ($workingTreeClean -eq $true) { 'clean' } elseif ($workingTreeClean -eq $false) { 'changes-present' } else { 'git-status-unavailable' })

foreach ($gate in @($manifest.readiness)) {
    Add-Check ([string]$gate.id) ([bool]$gate.required) ([string]$gate.status) $(if ($null -eq $gate.evidence) { $null } else { [string]$gate.evidence })
}

$allowedStatuses = @('pass', 'passed-local', 'pending', 'blocked', 'fail', 'unknown')
foreach ($check in $checks) {
    if ([string]$check.status -notin $allowedStatuses) { throw "release check $($check.id) 使用了未知状态 $($check.status)" }
}
$requiredChecks = @($checks | Where-Object required)
$blocking = @($requiredChecks | Where-Object { $_.status -ne 'pass' })
$counts = [pscustomobject][ordered]@{
    total = $checks.Count
    required = $requiredChecks.Count
    pass = @($checks | Where-Object status -EQ 'pass').Count
    passedLocal = @($checks | Where-Object status -EQ 'passed-local').Count
    pending = @($checks | Where-Object status -EQ 'pending').Count
    blocked = @($checks | Where-Object status -EQ 'blocked').Count
    fail = @($checks | Where-Object status -EQ 'fail').Count
    unknown = @($checks | Where-Object status -EQ 'unknown').Count
    requiredBlocking = $blocking.Count
}
$ready = $blocking.Count -eq 0 -and [string]$manifest.status -eq 'released'
[object[]]$reportChecks = @()
if (-not $Summary) { $reportChecks = $checks.ToArray() }
[string[]]$redactedFields = @()
if ($Summary) { $redactedFields = @('checks[].evidence') }
$report = [pscustomobject][ordered]@{
    schema = 'win-use-master/release-readiness-v1'
    observedAt = [DateTimeOffset]::UtcNow.ToString('o')
    status = if ($ready) { 'ready' } else { 'blocked' }
    candidate = [pscustomobject][ordered]@{
        version = [string]$manifest.version
        channel = [string]$manifest.channel
        releaseStatus = [string]$manifest.status
        releaseTag = if ($null -eq $manifest.releaseTag) { $null } else { [string]$manifest.releaseTag }
        previousStableVersion = if ($null -eq $manifest.previousStable.version) { $null } else { [string]$manifest.previousStable.version }
    }
    ready = $ready
    advisoryOnly = $true
    counts = $counts
    checks = $reportChecks
    privacy = [pscustomobject][ordered]@{
        mode = if ($Summary) { 'summary' } else { 'full' }
        collection = 'repository-metadata-only'
        redactedFields = $redactedFields
        absolutePathsIncluded = $false
    }
    sideEffects = [pscustomobject][ordered]@{
        filesWritten = 0
        commitsCreated = 0
        tagsCreated = 0
        releasesCreated = 0
        networkRequests = 0
    }
}

if ($Json) {
    $report | ConvertTo-Json -Depth 7 -Compress
} else {
    Write-Output "release-check version=$($manifest.version) status=$($report.status) ready=$($report.ready) required-blocking=$($counts.requiredBlocking)"
    if (-not $Summary) {
        foreach ($check in $checks) { Write-Output "$($check.id): $($check.status)" }
    }
    Write-Output 'side-effects: files=0 commits=0 tags=0 releases=0 network=0'
}

if ($ready) { exit 0 }
exit 2
