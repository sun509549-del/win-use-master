# Explicit management entrypoint for the advisory capability cache.
# `show` is read-only. `record` and `clear` are never called implicitly by probe.

[CmdletBinding(PositionalBinding = $false)]
param(
    [Parameter(Position = 0, ValueFromRemainingArguments = $true)]
    [string[]] $Arguments = @()
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version 2.0

function Stop-Cache([string] $Message, [int] $Code = 1) {
    [Console]::Error.WriteLine($Message)
    exit $Code
}

$core = Join-Path $PSScriptRoot 'capability-cache-core.ps1'
if (-not (Test-Path -LiteralPath $core -PathType Leaf)) { Stop-Cache 'capability cache 核心模块缺失。' 1 }
try { . $core } catch { Stop-Cache 'capability cache 核心模块无法加载。' 1 }

$tokens = @($Arguments | ForEach-Object { [string]$_ })
$json = $tokens -contains '--json'
$summary = $tokens -contains '--summary'
$all = $tokens -contains '--all'
$unknown = @($tokens | Where-Object { $_.StartsWith('--') -and $_ -notin @('--json','--summary','--all') })
if ($unknown.Count) { Stop-Cache 'cache 发现未知选项；只支持 --json、--summary 与 clear --all。' 2 }
$positionals = @($tokens | Where-Object { -not $_.StartsWith('--') })
$action = if ($positionals.Count) { $positionals[0].ToLowerInvariant() } else { 'show' }
$values = @($positionals | Select-Object -Skip 1)

function ConvertTo-CacheJson($Value) { return ($Value | ConvertTo-Json -Depth 12) }

function New-CachePrivacy([bool] $IdentityIncluded) {
    return [pscustomobject][ordered]@{
        mode = $(if ($IdentityIncluded) { 'full' } else { 'summary' })
        identityIncluded = $IdentityIncluded
        neverStored = @('window-title','uia-name','uia-value','dom-text','account','command-line','document-path','pid','port')
    }
}

function New-CacheAuthorization {
    return [pscustomobject][ordered]@{
        participates = $false
        trusted = $false
        statement = 'advisory-only; real-time ownership, permission, desktop, foreground and risk checks remain mandatory'
    }
}

function New-CacheViewReport($ReadResult, [bool] $SummaryOnly, [DateTimeOffset] $Now) {
    $rows = [Collections.Generic.List[object]]::new()
    $fresh = 0; $expired = 0
    if ($ReadResult.cache) {
        foreach ($entry in @($ReadResult.cache.entries)) {
            $state = Test-CapabilityEntryFreshness $entry $null $Now
            if ($state -eq 'fresh') { $fresh++ } else { $expired++ }
            if (-not $SummaryOnly) {
                $rows.Add([pscustomobject][ordered]@{
                    key = [string]$entry.key; freshness = $state
                    observedAt = [string]$entry.observedAt; expiresAt = [string]$entry.expiresAt
                    identity = $entry.identity; observations = $entry.observations
                    provenance = $entry.provenance
                })
            }
        }
    }
    $status = switch ([string]$ReadResult.status) {
        'missing' { 'empty' }
        'valid' { if ($fresh -or $expired) { 'available' } else { 'empty' } }
        'valid-with-invalid-entries' { 'available-with-invalid-entries' }
        default { 'invalid' }
    }
    return [pscustomobject][ordered]@{
        schema = 'win-use-master/capability-cache-view-v1'
        observedAt = $Now.ToString('o'); status = $status
        privacy = New-CachePrivacy (-not $SummaryOnly)
        authorization = New-CacheAuthorization
        retentionDays = $script:CapabilityCacheRetentionDays
        counts = [pscustomobject][ordered]@{
            total = $fresh + $expired; fresh = $fresh; expired = $expired
            invalid = [int]$ReadResult.invalidEntries
        }
        entries = @($rows)
    }
}

function New-CacheOperationReport([string] $Action, [string] $Status, [string] $Key, [int] $EntryCount, [bool] $SummaryOnly) {
    return [pscustomobject][ordered]@{
        schema = 'win-use-master/capability-cache-operation-v1'
        observedAt = [DateTimeOffset]::Now.ToString('o')
        status = $Status; action = $Action
        key = $(if ($SummaryOnly) { $null } else { $Key })
        entryCount = $EntryCount
        privacy = New-CachePrivacy (-not $SummaryOnly)
        authorization = New-CacheAuthorization
    }
}

function Write-CacheOperation($Report, [bool] $JsonOnly, [bool] $SummaryOnly) {
    if ($JsonOnly) { Write-Output (ConvertTo-CacheJson $Report); return }
    $keyText = if ($SummaryOnly -or -not $Report.key) { '<redacted>' } else { ([string]$Report.key).Substring(0, 12) }
    Write-Output ("cache {0}: status={1} key={2} entries={3} authorization=never" -f $Report.action, $Report.status, $keyText, $Report.entryCount)
}

if ($action -notin @('show','record','clear')) {
    Stop-Cache '用法: win.ps1 cache show | record <probe-report.json> | clear <key|--all> [--json] [--summary]' 2
}
if ($all -and $action -ne 'clear') { Stop-Cache '--all 只允许用于 cache clear。' 2 }

if (-not (Test-CapabilityCacheEnabled)) {
    if ($action -ne 'show') { Stop-Cache 'capability cache 已由 WIN_USE_MASTER_CAPABILITY_CACHE=0 禁用；没有写入或删除。' 2 }
    if ($values.Count -or $all) { Stop-Cache 'cache show 不接受位置参数或 --all。' 2 }
    $disabled = [pscustomobject][ordered]@{
        schema = 'win-use-master/capability-cache-view-v1'; observedAt = [DateTimeOffset]::Now.ToString('o')
        status = 'disabled'; privacy = New-CachePrivacy (-not $summary); authorization = New-CacheAuthorization
        retentionDays = $script:CapabilityCacheRetentionDays
        counts = [pscustomobject][ordered]@{ total = 0; fresh = 0; expired = 0; invalid = 0 }; entries = @()
    }
    if ($json) { Write-Output (ConvertTo-CacheJson $disabled) }
    else { Write-Output 'capability cache: status=disabled entries=0 authorization=never' }
    exit 0
}

try { $cachePath = Get-CapabilityCachePath }
catch { Stop-Cache 'capability cache 路径未通过边界校验；没有读取、写入或删除。' 2 }

switch ($action) {
    'show' {
        if ($values.Count -or $all) { Stop-Cache 'cache show 不接受位置参数或 --all。' 2 }
        try { $read = Read-CapabilityCacheDocument $cachePath }
        catch { Stop-Cache 'capability cache 路径或文件未通过安全校验。' 2 }
        $view = New-CacheViewReport $read ([bool]$summary) ([DateTimeOffset]::Now)
        if ($json) { Write-Output (ConvertTo-CacheJson $view) }
        elseif ($summary) {
            Write-Output ("capability cache: status={0} entries={1} fresh={2} expired={3} invalid={4} authorization=never" -f
                $view.status, $view.counts.total, $view.counts.fresh, $view.counts.expired, $view.counts.invalid)
        }
        else {
            Write-Output ("capability cache: status={0} retention=30d authorization=never" -f $view.status)
            foreach ($entry in @($view.entries)) {
                Write-Output ("  key={0} product={1} exe={2} version={3} freshness={4} observations=cdp:{5},com:{6},uia:{7}" -f
                    ([string]$entry.key).Substring(0,12), $entry.identity.productName, $entry.identity.executableName,
                    $entry.identity.productVersion, $entry.freshness, $entry.observations.cdp, $entry.observations.com, $entry.observations.uia)
            }
            if (-not $view.counts.total) { Write-Output '  （没有记录）' }
            if ($view.counts.invalid) { Write-Output "  已忽略 $($view.counts.invalid) 条无效记录；它们不会形成提示或授权。" }
        }
        if ($view.status -eq 'invalid') { exit 1 }
        exit 0
    }

    'record' {
        if ($all -or $values.Count -ne 1) { Stop-Cache '用法: win.ps1 cache record <probe-report.json> [--json] [--summary]' 2 }
        try {
            $inputPath = [IO.Path]::GetFullPath($values[0], (Get-Location).Path)
            if (-not (Test-Path -LiteralPath $inputPath -PathType Leaf)) { throw 'missing' }
            $item = Get-Item -LiteralPath $inputPath -Force
            if (($item.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0 -or $item.Length -gt 1MB) { throw 'unsafe' }
            $probe = Get-Content -LiteralPath $inputPath -Raw -Encoding utf8 | ConvertFrom-Json
            $entry = New-CapabilityEntryFromProbeReport $probe ([DateTimeOffset]::Now)
            $read = Read-CapabilityCacheDocument $cachePath
            if ($read.status -eq 'invalid') { throw 'invalid-cache' }
            $kept = @($read.cache.entries | Where-Object {
                $_.key -ne $entry.key -and (Test-CapabilityEntryFreshness $_ $null ([DateTimeOffset]::Now)) -eq 'fresh'
            })
            $cache = New-EmptyCapabilityCache
            $cache.entries = @($entry) + $kept
            $written = Write-CapabilityCacheDocument $cachePath $cache ([DateTimeOffset]::Now)
        }
        catch { Stop-Cache 'cache record 被拒绝：输入报告、现有 cache 或目标路径未通过校验；没有授权任何操作。' 2 }
        $report = New-CacheOperationReport 'record' 'completed' $entry.key @($written.entries).Count ([bool]$summary)
        Write-CacheOperation $report ([bool]$json) ([bool]$summary)
        exit 0
    }

    'clear' {
        if (($all -and $values.Count) -or (-not $all -and $values.Count -ne 1)) {
            Stop-Cache '用法: win.ps1 cache clear <64位key|--all> [--json] [--summary]' 2
        }
        if ($all) {
            try { $removed = Remove-CapabilityCacheFile $cachePath }
            catch { Stop-Cache 'cache clear --all 的精确目标未通过校验；没有删除。' 2 }
            $report = New-CacheOperationReport 'clear-all' $(if ($removed) { 'completed' } else { 'not-found' }) '' 0 ([bool]$summary)
            Write-CacheOperation $report ([bool]$json) ([bool]$summary)
            exit $(if ($removed) { 0 } else { 1 })
        }
        $key = [string]$values[0]
        if ($key -cnotmatch '^[0-9a-f]{64}$') { Stop-Cache 'cache key 必须是 64 位小写十六进制 SHA-256。' 2 }
        try { $read = Read-CapabilityCacheDocument $cachePath }
        catch { Stop-Cache 'capability cache 路径或文件未通过安全校验。' 2 }
        if ($read.status -eq 'invalid') { Stop-Cache '现有 capability cache 无效；请检查后显式 clear --all。' 2 }
        $remaining = @($read.cache.entries | Where-Object key -CNE $key)
        if ($remaining.Count -eq @($read.cache.entries).Count) {
            $report = New-CacheOperationReport 'clear' 'not-found' $key $remaining.Count ([bool]$summary)
            Write-CacheOperation $report ([bool]$json) ([bool]$summary)
            exit 1
        }
        try {
            if ($remaining.Count) {
                $cache = New-EmptyCapabilityCache; $cache.entries = $remaining
                $written = Write-CapabilityCacheDocument $cachePath $cache ([DateTimeOffset]::Now)
                $remainingCount = @($written.entries).Count
            } else {
                [void](Remove-CapabilityCacheFile $cachePath); $remainingCount = 0
            }
        }
        catch { Stop-Cache 'cache clear 的精确目标未通过校验；没有继续删除。' 2 }
        $report = New-CacheOperationReport 'clear' 'completed' $key $remainingCount ([bool]$summary)
        Write-CacheOperation $report ([bool]$json) ([bool]$summary)
        exit 0
    }
}
