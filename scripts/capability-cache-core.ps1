# Pure validation and persistence helpers for the advisory capability cache.
# This module is intentionally not loaded by any UIA/CDP/SendInput write path.

$script:CapabilityCacheSchema = 'win-use-master/capability-cache-v1'
$script:CapabilityCacheEntryLimit = 100
$script:CapabilityCacheRetentionDays = 30
$script:CapabilityCacheMaximumBytes = 1MB

function Test-CapabilityCacheEnabled {
    return [string]$env:WIN_USE_MASTER_CAPABILITY_CACHE -ne '0'
}

function Get-CapabilityCachePath {
    $override = [string]$env:WIN_USE_MASTER_CAPABILITY_CACHE_PATH
    if ($override) {
        if ([string]$env:WIN_USE_MASTER_CAPABILITY_CACHE_TEST -ne '1') {
            throw '自定义 capability cache 路径只允许隔离测试使用。'
        }
        $full = [IO.Path]::GetFullPath($override)
        $parent = [IO.Path]::GetDirectoryName($full)
        $temp = [IO.Path]::GetFullPath([IO.Path]::GetTempPath()).TrimEnd('\')
        $parentParent = [IO.Path]::GetDirectoryName($parent).TrimEnd('\')
        $parentLeaf = [IO.Path]::GetFileName($parent)
        if ($parentParent -ine $temp -or $parentLeaf -notmatch '^win-use-master-capability-cache-test-[0-9a-f]{32}$' -or
            [IO.Path]::GetFileName($full) -cne 'capability-cache-v1.json') {
            throw '隔离测试 cache 路径不在经过验证的临时测试目录。'
        }
        return $full
    }

    $local = [Environment]::GetFolderPath([Environment+SpecialFolder]::LocalApplicationData)
    if (-not $local) { $local = [string]$env:LOCALAPPDATA }
    if (-not $local) { throw '无法确定 LocalApplicationData，capability cache 不可用。' }
    return [IO.Path]::GetFullPath((Join-Path $local 'win-use-master\capability-cache-v1.json'))
}

function Assert-CapabilityCachePath([string] $Path) {
    if (-not $Path -or -not [IO.Path]::IsPathFullyQualified($Path)) { throw 'capability cache 路径必须是绝对路径。' }
    $actual = [IO.Path]::GetFullPath($Path)
    $expected = Get-CapabilityCachePath
    if (-not $actual.Equals($expected, [StringComparison]::OrdinalIgnoreCase)) {
        throw 'capability cache 路径与当前已验证目标不一致。'
    }
    $parent = [IO.Path]::GetDirectoryName($actual)
    if (Test-Path -LiteralPath $parent -PathType Container) {
        $parentItem = Get-Item -LiteralPath $parent -Force
        if (($parentItem.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) {
            throw 'capability cache 目录是 reparse point，拒绝读写或删除。'
        }
    }
    if (Test-Path -LiteralPath $actual -PathType Leaf) {
        $item = Get-Item -LiteralPath $actual -Force
        if (($item.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) {
            throw 'capability cache 文件是 reparse point，拒绝读写或删除。'
        }
    }
    return $actual
}

function Get-CapabilityIdentityKey([string] $ProductName, [string] $ExecutableName) {
    $product = ([string]$ProductName).Trim().ToLowerInvariant()
    $exe = ([string]$ExecutableName).Trim().ToLowerInvariant()
    if (-not $product -and -not $exe) { throw 'capability cache 身份缺少产品名和 exe 名。' }
    $bytes = [Text.Encoding]::UTF8.GetBytes("$product|$exe")
    $hash = [Security.Cryptography.SHA256]::HashData($bytes)
    return ([Convert]::ToHexString($hash).ToLowerInvariant())
}

function Get-CapabilityIdentityFromProbeReport($Report) {
    if ($null -eq $Report -or [string]$Report.schema -ne 'win-use-master/probe-report-v1' -or [string]$Report.status -ne 'resolved') {
        throw '只接受 resolved 的 win-use-master/probe-report-v1。'
    }
    $product = ([string]$Report.target.displayName).Trim()
    $exePath = [string]$Report.target.executablePath
    $exe = if ($exePath) { [IO.Path]::GetFileName($exePath) } else { '' }
    $version = @($Report.target.versions | Where-Object { -not [string]::IsNullOrWhiteSpace([string]$_) } | Select-Object -First 1)
    $versionText = if ($version.Count) { ([string]$version[0]).Trim() } else { '' }
    if (-not $product -and -not $exe) { throw 'probe report 是摘要或缺少可缓存身份。请用 full JSON。' }
    if (-not $versionText) { throw 'probe report 没有版本，保守缓存不会记录无法做版本失效判断的观察。' }
    if ($product.Length -gt 160 -or $exe.Length -gt 160 -or $versionText.Length -gt 120) { throw 'probe report 身份字段过长。' }
    return [pscustomobject][ordered]@{
        key = Get-CapabilityIdentityKey $product $exe
        productName = $product
        executableName = $exe
        productVersion = $versionText
    }
}

function ConvertTo-NormalizedCapabilityEntry($Entry, [DateTimeOffset] $Now = [DateTimeOffset]::Now) {
    if ($null -eq $Entry -or [string]$Entry.key -notmatch '^[0-9a-f]{64}$') { throw 'entry key 无效。' }
    $observedAt = [DateTimeOffset]::MinValue; $expiresAt = [DateTimeOffset]::MinValue
    if (-not [DateTimeOffset]::TryParse([string]$Entry.observedAt, [ref]$observedAt) -or
        -not [DateTimeOffset]::TryParse([string]$Entry.expiresAt, [ref]$expiresAt)) { throw 'entry 时间无效。' }
    if ($observedAt -gt $Now.AddMinutes(5)) { throw 'entry observedAt 位于未来。' }
    $expectedExpiry = $observedAt.AddDays($script:CapabilityCacheRetentionDays)
    if ([Math]::Abs(($expiresAt - $expectedExpiry).TotalSeconds) -gt 1) { throw 'entry expiresAt 不符合固定 30 天保留期。' }
    $product = ([string]$Entry.identity.productName).Trim()
    $exe = ([string]$Entry.identity.executableName).Trim()
    $version = ([string]$Entry.identity.productVersion).Trim()
    if ((Get-CapabilityIdentityKey $product $exe) -ne [string]$Entry.key -or -not $version) { throw 'entry 身份或版本无效。' }
    if ($product.Length -gt 160 -or $exe.Length -gt 160 -or $version.Length -gt 120) { throw 'entry 身份字段过长。' }
    $classes = @($Entry.identity.windowClasses | ForEach-Object { ([string]$_).Trim() } |
        Where-Object { $_ -and $_.Length -le 160 } | Select-Object -Unique -First 32)
    $frameworks = @($Entry.observations.frameworks | ForEach-Object { ([string]$_).Trim() } |
        Where-Object { $_ -and $_.Length -le 80 } | Select-Object -Unique -First 16)
    $cdp = [string]$Entry.observations.cdp
    $com = [string]$Entry.observations.com
    $uia = [string]$Entry.observations.uia
    if ($cdp -notin @('available','unavailable','unknown') -or
        $com -notin @('candidate','unavailable','unknown') -or
        $uia -notin @('available','unavailable','unknown')) { throw 'entry 能力枚举无效。' }
    return [pscustomobject][ordered]@{
        key = [string]$Entry.key
        observedAt = $observedAt.ToString('o')
        expiresAt = $expectedExpiry.ToString('o')
        identity = [pscustomobject][ordered]@{
            productName = $product; executableName = $exe; productVersion = $version; windowClasses = $classes
        }
        observations = [pscustomobject][ordered]@{
            frameworks = $frameworks; cdp = $cdp; com = $com; uia = $uia
            uiaProviderTimedOut = [bool]$Entry.observations.uiaProviderTimedOut
        }
        provenance = [pscustomobject][ordered]@{ sourceSchema = 'win-use-master/probe-report-v1'; advisoryOnly = $true }
    }
}

function New-CapabilityEntryFromProbeReport($Report, [DateTimeOffset] $Now = [DateTimeOffset]::Now) {
    $identity = Get-CapabilityIdentityFromProbeReport $Report
    $observed = [DateTimeOffset]::MinValue
    if (-not [DateTimeOffset]::TryParse([string]$Report.observedAt, [ref]$observed)) { throw 'probe report observedAt 无效。' }
    if ($observed -gt $Now.AddMinutes(5)) { throw 'probe report observedAt 位于未来，拒绝缓存。' }
    $expires = $observed.AddDays($script:CapabilityCacheRetentionDays)
    if ($expires -le $Now) { throw 'probe report 已超过 30 天，拒绝缓存。' }
    $classes = @($Report.windows.items | ForEach-Object { ([string]$_.className).Trim() } |
        Where-Object { $_ -and $_.Length -le 160 } | Select-Object -Unique -First 32)
    $frameworks = @($Report.frameworks.families | ForEach-Object { ([string]$_.name).Trim() } |
        Where-Object { $_ -and $_.Length -le 80 } | Select-Object -Unique -First 16)
    $candidate = [pscustomobject][ordered]@{
        key = $identity.key; observedAt = $observed.ToString('o'); expiresAt = $expires.ToString('o')
        identity = [pscustomobject][ordered]@{
            productName = $identity.productName; executableName = $identity.executableName
            productVersion = $identity.productVersion; windowClasses = $classes
        }
        observations = [pscustomobject][ordered]@{
            frameworks = $frameworks
            cdp = $(if ([string]$Report.interfaces.cdp.status -in @('available','unavailable')) { [string]$Report.interfaces.cdp.status } else { 'unknown' })
            com = $(if ([string]$Report.interfaces.com.status -in @('candidate','unavailable')) { [string]$Report.interfaces.com.status } else { 'unknown' })
            uia = $(if ([string]$Report.uia.status -in @('available','unavailable')) { [string]$Report.uia.status } else { 'unknown' })
            uiaProviderTimedOut = [bool]$Report.uia.timedOut
        }
    }
    return ConvertTo-NormalizedCapabilityEntry $candidate
}

function New-EmptyCapabilityCache([DateTimeOffset] $Now = [DateTimeOffset]::Now) {
    return [pscustomobject][ordered]@{
        schema = $script:CapabilityCacheSchema
        updatedAt = $Now.ToString('o')
        retentionDays = $script:CapabilityCacheRetentionDays
        authorization = [pscustomobject][ordered]@{ participates = $false; trusted = $false }
        entries = @()
    }
}

function Read-CapabilityCacheDocument([string] $Path) {
    $resolved = Assert-CapabilityCachePath $Path
    if (-not (Test-Path -LiteralPath $resolved -PathType Leaf)) {
        return [pscustomobject][ordered]@{ status = 'missing'; invalidEntries = 0; cache = New-EmptyCapabilityCache }
    }
    try {
        $item = Get-Item -LiteralPath $resolved -Force
        if ($item.Length -gt $script:CapabilityCacheMaximumBytes) { throw 'cache 文件超过 1 MiB 上限。' }
        $raw = Get-Content -LiteralPath $resolved -Raw -Encoding utf8
        $parsed = $raw | ConvertFrom-Json
        if ([string]$parsed.schema -ne $script:CapabilityCacheSchema -or [int]$parsed.retentionDays -ne $script:CapabilityCacheRetentionDays) {
            throw 'cache schema 或保留期不匹配。'
        }
        if (@($parsed.entries).Count -gt $script:CapabilityCacheEntryLimit) { throw 'cache entry 超过 100 项上限。' }
        $valid = [System.Collections.Generic.List[object]]::new(); $invalid = 0
        foreach ($entry in @($parsed.entries)) {
            try { $valid.Add((ConvertTo-NormalizedCapabilityEntry $entry)) }
            catch { $invalid++ }
        }
        $cache = New-EmptyCapabilityCache
        $cache.updatedAt = [string]$parsed.updatedAt
        $cache.entries = @($valid)
        return [pscustomobject][ordered]@{
            status = $(if ($invalid) { 'valid-with-invalid-entries' } else { 'valid' })
            invalidEntries = $invalid; cache = $cache
        }
    }
    catch {
        return [pscustomobject][ordered]@{ status = 'invalid'; invalidEntries = 0; cache = $null; errorCode = 'invalid-cache' }
    }
}

function Test-CapabilityEntryFreshness($Entry, $CurrentIdentity = $null, [DateTimeOffset] $Now = [DateTimeOffset]::Now) {
    $expires = [DateTimeOffset]::MinValue
    if (-not [DateTimeOffset]::TryParse([string]$Entry.expiresAt, [ref]$expires)) { return 'invalid' }
    if ($expires -le $Now) { return 'expired' }
    if ($null -eq $CurrentIdentity) { return 'fresh' }
    if ([string]$Entry.key -ne [string]$CurrentIdentity.key) { return 'no-match' }
    if (-not [string]$CurrentIdentity.productVersion -or -not [string]$Entry.identity.productVersion) { return 'unknown-version' }
    if (-not ([string]$Entry.identity.productVersion).Equals([string]$CurrentIdentity.productVersion, [StringComparison]::OrdinalIgnoreCase)) {
        return 'version-changed'
    }
    return 'fresh'
}

function Get-CapabilityCacheHint($ReadResult, $ProbeReport, [DateTimeOffset] $Now = [DateTimeOffset]::Now) {
    $base = [ordered]@{
        status = [string]$ReadResult.status; used = $false; trustedForAuthorization = $false
        observedAt = $null; expiresAt = $null; advisoryOrder = @(); observations = $null
    }
    if ([string]$ReadResult.status -notin @('valid','valid-with-invalid-entries')) { return [pscustomobject]$base }
    try { $identity = Get-CapabilityIdentityFromProbeReport $ProbeReport }
    catch { $base.status = 'not-applicable'; return [pscustomobject]$base }
    $entry = @($ReadResult.cache.entries | Where-Object key -EQ $identity.key | Select-Object -First 1)
    if (-not $entry.Count) { $base.status = 'no-match'; return [pscustomobject]$base }
    $freshness = Test-CapabilityEntryFreshness $entry[0] $identity $Now
    $base.status = $freshness
    if ($freshness -ne 'fresh') { return [pscustomobject]$base }
    $order = [System.Collections.Generic.List[string]]::new()
    if ($entry[0].observations.cdp -eq 'available') { $order.Add('cdp') }
    if ($entry[0].observations.com -eq 'candidate') { $order.Add('com') }
    if ($entry[0].observations.uia -eq 'available') { $order.Add('uia') }
    $base.used = $true
    $base.observedAt = [string]$entry[0].observedAt
    $base.expiresAt = [string]$entry[0].expiresAt
    $base.advisoryOrder = @($order)
    $base.observations = $entry[0].observations
    return [pscustomobject]$base
}

function Write-CapabilityCacheDocument([string] $Path, $Cache, [DateTimeOffset] $Now = [DateTimeOffset]::Now) {
    $resolved = Assert-CapabilityCachePath $Path
    $normalized = New-EmptyCapabilityCache $Now
    $entries = @($Cache.entries | ForEach-Object { ConvertTo-NormalizedCapabilityEntry $_ } |
        Sort-Object observedAt -Descending | Select-Object -First $script:CapabilityCacheEntryLimit)
    $normalized.entries = $entries
    $parent = [IO.Path]::GetDirectoryName($resolved)
    if (-not (Test-Path -LiteralPath $parent -PathType Container)) { [IO.Directory]::CreateDirectory($parent) | Out-Null }
    $temp = Join-Path $parent ('.capability-cache-' + [Guid]::NewGuid().ToString('N') + '.tmp')
    try {
        $json = $normalized | ConvertTo-Json -Depth 10
        if ([Text.Encoding]::UTF8.GetByteCount($json) -gt $script:CapabilityCacheMaximumBytes) { throw 'cache 序列化后超过 1 MiB 上限。' }
        [IO.File]::WriteAllText($temp, $json + "`n", [Text.UTF8Encoding]::new($false))
        [IO.File]::Move($temp, $resolved, $true)
    }
    finally { if ([IO.File]::Exists($temp)) { [IO.File]::Delete($temp) } }
    return $normalized
}

function Remove-CapabilityCacheFile([string] $Path) {
    $resolved = Assert-CapabilityCachePath $Path
    if (-not [IO.File]::Exists($resolved)) { return $false }
    [IO.File]::Delete($resolved)
    return $true
}
