# Pure, read-only planning helpers for temporary artifact governance.
# This module intentionally contains no delete or write primitive.

$script:CleanupManifestSchema = 'win-use-master/temp-artifact-v1'
$script:CleanupPlanSchema = 'win-use-master/cleanup-plan-v1'
$script:CleanupManifestMaximumBytes = 64KB
$script:CleanupEntryLimit = 10000
$script:CleanupMaximumLifetimeDays = 30
$script:CleanupCandidatePattern = '^win-use-master-[a-z0-9][a-z0-9._-]{0,126}$'

function Get-CleanupScanRoot {
    $override = [string]$env:WIN_USE_MASTER_CLEANUP_ROOT
    if ($override) {
        if ([string]$env:WIN_USE_MASTER_CLEANUP_TEST -ne '1') {
            throw '自定义 cleanup 根只允许隔离测试使用。'
        }
        $full = [IO.Path]::GetFullPath($override).TrimEnd('\')
        $parent = [IO.Path]::GetDirectoryName($full)
        $parentParent = [IO.Path]::GetDirectoryName($parent).TrimEnd('\')
        $parentLeaf = [IO.Path]::GetFileName($parent)
        if ([IO.Path]::GetFileName($full) -cne 'scan-root' -or
            $parentParent -ine [IO.Path]::GetFullPath([IO.Path]::GetTempPath()).TrimEnd('\') -or
            $parentLeaf -notmatch '^win-use-master-cleanup-contract-[0-9a-f]{32}$') {
            throw '隔离 cleanup 根不在经过验证的临时测试目录。'
        }
        return $full
    }
    return [IO.Path]::GetFullPath([IO.Path]::GetTempPath()).TrimEnd('\')
}

function Assert-CleanupScanRoot([string] $Root) {
    if (-not $Root -or -not [IO.Path]::IsPathFullyQualified($Root)) { throw 'cleanup 根必须是绝对路径。' }
    $actual = [IO.Path]::GetFullPath($Root).TrimEnd('\')
    $expected = (Get-CleanupScanRoot).TrimEnd('\')
    if (-not $actual.Equals($expected, [StringComparison]::OrdinalIgnoreCase)) { throw 'cleanup 根与当前已验证目标不一致。' }
    if (-not [IO.Directory]::Exists($actual)) { throw 'cleanup 根不存在。' }
    $item = Get-Item -LiteralPath $actual -Force
    if (($item.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) { throw 'cleanup 根是 reparse point，拒绝扫描。' }
    return $actual
}

function Test-CleanupCandidateName([string] $Name) {
    return -not [string]::IsNullOrWhiteSpace($Name) -and $Name -cmatch $script:CleanupCandidatePattern
}

function Get-CleanupTreeInspection([string] $CandidatePath) {
    $count = 0; $bytes = 0L
    $stack = [Collections.Generic.Stack[string]]::new()
    $stack.Push($CandidatePath)
    try {
        while ($stack.Count) {
            $directory = $stack.Pop()
            foreach ($child in [IO.Directory]::EnumerateFileSystemEntries($directory)) {
                $count++
                if ($count -gt $script:CleanupEntryLimit) {
                    return [pscustomobject][ordered]@{ status = 'refused'; reason = 'entry-limit-exceeded'; entries = $count; bytes = $null }
                }
                $attributes = [IO.File]::GetAttributes($child)
                if (($attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) {
                    return [pscustomobject][ordered]@{ status = 'refused'; reason = 'nested-reparse-point'; entries = $count; bytes = $null }
                }
                if (($attributes -band [IO.FileAttributes]::Directory) -ne 0) { $stack.Push($child) }
                else { $bytes += [IO.FileInfo]::new($child).Length }
            }
        }
        return [pscustomobject][ordered]@{ status = 'safe'; reason = 'none'; entries = $count; bytes = $bytes }
    }
    catch {
        return [pscustomobject][ordered]@{ status = 'refused'; reason = 'tree-unreadable'; entries = $count; bytes = $null }
    }
}

function Get-CleanupOwnerState([int] $OwnerPid, [DateTimeOffset] $OwnerStartedAt) {
    try { $process = Get-Process -Id $OwnerPid -ErrorAction Stop }
    catch {
        return [pscustomobject][ordered]@{ status = 'stopped'; activeOriginalOwner = $false }
    }
    try { $actual = [DateTimeOffset]$process.StartTime.ToUniversalTime() }
    catch { return [pscustomobject][ordered]@{ status = 'unknown'; activeOriginalOwner = $null } }
    $same = [Math]::Abs(($actual - $OwnerStartedAt.ToUniversalTime()).TotalSeconds) -le 2
    return [pscustomobject][ordered]@{
        status = $(if ($same) { 'active' } else { 'pid-reused' })
        activeOriginalOwner = $same
    }
}

function Read-CleanupManifest([string] $CandidatePath, [string] $CandidateName, [DateTimeOffset] $Now) {
    $manifestPaths = @(
        @('manifest.json', '.win-use-master-manifest.json') | ForEach-Object { Join-Path $CandidatePath $_ } |
            Where-Object { Test-Path -LiteralPath $_ -PathType Leaf }
    )
    if (-not $manifestPaths.Count) { return [pscustomobject][ordered]@{ status = 'invalid'; reason = 'manifest-missing'; manifest = $null } }
    if ($manifestPaths.Count -ne 1) { return [pscustomobject][ordered]@{ status = 'invalid'; reason = 'manifest-ambiguous'; manifest = $null } }
    try {
        $item = Get-Item -LiteralPath $manifestPaths[0] -Force
        if (($item.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) { throw 'reparse' }
        if ($item.Length -gt $script:CleanupManifestMaximumBytes) { throw 'oversize' }
        $raw = Get-Content -LiteralPath $manifestPaths[0] -Raw -Encoding utf8
        $parsed = $raw | ConvertFrom-Json
        $created = [DateTimeOffset]::MinValue; $expires = [DateTimeOffset]::MinValue; $ownerStarted = [DateTimeOffset]::MinValue
        if ([string]$parsed.schema -ne $script:CleanupManifestSchema -or
            [string]$parsed.artifactId -cne $CandidateName -or
            -not [DateTimeOffset]::TryParse([string]$parsed.createdAt, [ref]$created) -or
            -not [DateTimeOffset]::TryParse([string]$parsed.expiresAt, [ref]$expires) -or
            -not [DateTimeOffset]::TryParse([string]$parsed.owner.startTimeUtc, [ref]$ownerStarted)) { throw 'schema' }
        $ownerPid = 0
        if (-not [int]::TryParse([string]$parsed.owner.pid, [ref]$ownerPid) -or $ownerPid -le 0) { throw 'owner' }
        if ($created -gt $Now.AddMinutes(5) -or $ownerStarted -gt $created.AddMinutes(5) -or
            $expires -le $created -or $expires -gt $created.AddDays($script:CleanupMaximumLifetimeDays)) { throw 'time' }
        return [pscustomobject][ordered]@{
            status = 'valid'; reason = 'none'
            manifest = [pscustomobject][ordered]@{
                artifactId = $CandidateName; createdAt = $created; expiresAt = $expires
                ownerPid = $ownerPid; ownerStartedAt = $ownerStarted
            }
        }
    }
    catch { return [pscustomobject][ordered]@{ status = 'invalid'; reason = 'manifest-invalid'; manifest = $null } }
}

function Get-CleanupPlan([string] $Root, [DateTimeOffset] $Now = [DateTimeOffset]::Now, [switch] $Summary) {
    $resolvedRoot = Assert-CleanupScanRoot $Root
    $rows = [Collections.Generic.List[object]]::new()
    $candidateCount = 0; $eligibleCount = 0; $refusedCount = 0
    foreach ($candidatePath in [IO.Directory]::EnumerateDirectories($resolvedRoot, 'win-use-master-*', [IO.SearchOption]::TopDirectoryOnly)) {
        $candidateName = [IO.Path]::GetFileName($candidatePath)
        if (-not (Test-CleanupCandidateName $candidateName)) { continue }
        $candidateCount++
        $reasons = [Collections.Generic.List[string]]::new()
        $candidateItem = Get-Item -LiteralPath $candidatePath -Force
        if (($candidateItem.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) { $reasons.Add('candidate-reparse-point') }

        $manifestResult = if ($reasons.Count) { $null } else { Read-CleanupManifest $candidatePath $candidateName $Now }
        $manifest = if ($manifestResult -and $manifestResult.status -eq 'valid') { $manifestResult.manifest } else { $null }
        if ($manifestResult -and $manifestResult.status -ne 'valid') { $reasons.Add([string]$manifestResult.reason) }

        $owner = [pscustomobject][ordered]@{ status = 'not-checked'; activeOriginalOwner = $null }
        if ($manifest) {
            if ($manifest.expiresAt -gt $Now) { $reasons.Add('not-expired') }
            $owner = Get-CleanupOwnerState $manifest.ownerPid $manifest.ownerStartedAt
            if ($owner.status -eq 'active') { $reasons.Add('active-owner') }
            elseif ($owner.status -eq 'unknown') { $reasons.Add('owner-unknown') }
        }

        $tree = if ($reasons -contains 'candidate-reparse-point') {
            [pscustomobject][ordered]@{ status = 'refused'; reason = 'candidate-reparse-point'; entries = 0; bytes = $null }
        } else { Get-CleanupTreeInspection $candidatePath }
        if ($tree.status -ne 'safe' -and -not $reasons.Contains([string]$tree.reason)) { $reasons.Add([string]$tree.reason) }

        $eligible = $reasons.Count -eq 0
        if ($eligible) { $eligibleCount++ } else { $refusedCount++ }
        if (-not $Summary) {
            $rows.Add([pscustomobject][ordered]@{
                candidate = $candidateName; kind = 'directory'
                decision = $(if ($eligible) { 'eligible' } else { 'refused' })
                reasons = @($reasons)
                createdAt = $(if ($manifest) { $manifest.createdAt.ToString('o') } else { $null })
                expiresAt = $(if ($manifest) { $manifest.expiresAt.ToString('o') } else { $null })
                owner = $owner
                entries = $(if ($tree.status -eq 'safe') { [int]$tree.entries } else { $null })
                bytes = $(if ($tree.status -eq 'safe') { [int64]$tree.bytes } else { $null })
            })
        }
    }
    $status = if (-not $candidateCount) { 'empty' } elseif ($eligibleCount) { 'ready' } else { 'review' }
    return [pscustomobject][ordered]@{
        schema = $script:CleanupPlanSchema; observedAt = $Now.ToString('o'); status = $status
        mode = 'dry-run'; applyAvailable = $false
        scope = [pscustomobject][ordered]@{
            root = 'system-temp'; rootPathIncluded = $false; directChildrenOnly = $true
            candidatePattern = 'win-use-master-*'; manifestRequired = $true
        }
        policy = [pscustomobject][ordered]@{
            manifestSchema = $script:CleanupManifestSchema; expiredRequired = $true
            inactiveOriginalOwnerRequired = $true; reparsePointsAllowed = $false
            maximumLifetimeDays = $script:CleanupMaximumLifetimeDays; entryInspectionLimit = $script:CleanupEntryLimit
        }
        counts = [pscustomobject][ordered]@{ candidates = $candidateCount; eligible = $eligibleCount; refused = $refusedCount }
        privacy = [pscustomobject][ordered]@{
            mode = $(if ($Summary) { 'summary' } else { 'full' }); absolutePathsIncluded = $false
            manifestUnknownFieldsIncluded = $false; itemsIncluded = -not [bool]$Summary
        }
        sideEffects = [pscustomobject][ordered]@{ filesWritten = 0; filesDeleted = 0; directoriesDeleted = 0; processesStopped = 0 }
        items = @($rows)
    }
}
