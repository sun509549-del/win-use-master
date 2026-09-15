# Read-only environment diagnostics. This script never builds the helper,
# starts target applications, writes files, deletes artifacts, or repairs state.
param(
    [Parameter(Position = 0, ValueFromRemainingArguments = $true)]
    [string[]] $Options = @()
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version 2.0

$root = Split-Path -Parent $PSScriptRoot
$isWindowsRuntime = if (Get-Variable IsWindows -ErrorAction SilentlyContinue) { [bool]$IsWindows } else { $env:OS -eq 'Windows_NT' }
$json = $Options -contains '--json'
$summary = $Options -contains '--summary'
$unknown = @($Options | Where-Object { $_ -notin @('--json', '--summary') })
if ($unknown.Count) {
    [Console]::Error.WriteLine("doctor 只支持 --json 与 --summary；未知选项: $($unknown -join ', ')")
    exit 2
}
if ($json -and $summary) {
    [Console]::Error.WriteLine('doctor 的 --json 与 --summary 不能同时使用。')
    exit 2
}

. (Join-Path $PSScriptRoot 'doctor-core.ps1')

function Get-NodeFact {
    $command = Get-Command node -CommandType Application -ErrorAction SilentlyContinue | Select-Object -First 1
    if (-not $command) {
        return [pscustomobject][ordered]@{ installed = $false; version = 'unavailable'; major = 0; supported = $false }
    }
    $version = 'unknown'
    try {
        $raw = [string](Get-Item -LiteralPath $command.Source -ErrorAction Stop).VersionInfo.ProductVersion
        if ($raw -match '(?<version>\d+\.\d+\.\d+)') { $version = $Matches.version }
    } catch { }
    $major = 0
    if ($version -match '^(?<major>\d+)\.') { $major = [int]$Matches.major }
    [pscustomobject][ordered]@{ installed = $true; version = $version; major = $major; supported = ($major -ge 22) }
}

function Get-BrowserFact {
    $candidates = [Collections.Generic.List[object]]::new()
    $seen = [Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
    function Add-BrowserCandidate([string] $Name, [string] $Path, [string] $Source) {
        if ([string]::IsNullOrWhiteSpace($Path)) { return }
        try { $full = [IO.Path]::GetFullPath($Path) } catch { return }
        if (-not (Test-Path -LiteralPath $full -PathType Leaf) -or -not $seen.Add($full)) { return }
        $version = 'unknown'
        try {
            $raw = [string](Get-Item -LiteralPath $full -ErrorAction Stop).VersionInfo.ProductVersion
            if ($raw -match '(?<version>\d+(?:\.\d+){1,3})') { $version = $Matches.version }
        } catch { }
        $candidates.Add([pscustomobject][ordered]@{ name = $Name; source = $Source; version = $version })
    }

    foreach ($name in @('msedge.exe', 'chrome.exe', 'chromium.exe')) {
        $command = Get-Command $name -CommandType Application -ErrorAction SilentlyContinue | Select-Object -First 1
        if ($command) { Add-BrowserCandidate ([IO.Path]::GetFileNameWithoutExtension($name)) $command.Source 'PATH' }
    }
    foreach ($entry in @(
        @{ Name = 'edge'; Key = 'Registry::HKEY_LOCAL_MACHINE\SOFTWARE\Microsoft\Windows\CurrentVersion\App Paths\msedge.exe'; Source = 'HKLM-AppPaths' },
        @{ Name = 'edge'; Key = 'Registry::HKEY_CURRENT_USER\SOFTWARE\Microsoft\Windows\CurrentVersion\App Paths\msedge.exe'; Source = 'HKCU-AppPaths' },
        @{ Name = 'chrome'; Key = 'Registry::HKEY_LOCAL_MACHINE\SOFTWARE\Microsoft\Windows\CurrentVersion\App Paths\chrome.exe'; Source = 'HKLM-AppPaths' },
        @{ Name = 'chrome'; Key = 'Registry::HKEY_CURRENT_USER\SOFTWARE\Microsoft\Windows\CurrentVersion\App Paths\chrome.exe'; Source = 'HKCU-AppPaths' }
    )) {
        try { Add-BrowserCandidate $entry.Name ([string](Get-ItemProperty -LiteralPath $entry.Key -ErrorAction Stop).'(default)') $entry.Source } catch { }
    }
    foreach ($entry in @(
        @{ Name = 'edge'; Base = [Environment]::GetFolderPath('ProgramFilesX86'); Relative = 'Microsoft\Edge\Application\msedge.exe'; Source = 'ProgramFilesX86' },
        @{ Name = 'edge'; Base = [Environment]::GetFolderPath('ProgramFiles'); Relative = 'Microsoft\Edge\Application\msedge.exe'; Source = 'ProgramFiles' },
        @{ Name = 'chrome'; Base = [Environment]::GetFolderPath('ProgramFiles'); Relative = 'Google\Chrome\Application\chrome.exe'; Source = 'ProgramFiles' },
        @{ Name = 'chrome'; Base = [Environment]::GetFolderPath('LocalApplicationData'); Relative = 'Google\Chrome\Application\chrome.exe'; Source = 'LocalAppData' }
    )) {
        if ($entry.Base) { Add-BrowserCandidate $entry.Name (Join-Path $entry.Base $entry.Relative) $entry.Source }
    }
    [pscustomobject][ordered]@{ discovered = @($candidates) }
}

function Get-HelperFact {
    $source = Join-Path $PSScriptRoot 'HuWin.cs'
    $dll = Join-Path $PSScriptRoot 'HuWin.dll'
    $sourceExists = Test-Path -LiteralPath $source -PathType Leaf
    $dllExists = Test-Path -LiteralPath $dll -PathType Leaf
    $stale = $false
    if ($sourceExists -and $dllExists) {
        $stale = (Get-Item -LiteralPath $dll).LastWriteTimeUtc -lt (Get-Item -LiteralPath $source).LastWriteTimeUtc
    }

    $refDirectory = Join-Path $PSHOME 'ref'
    $compilerAvailable = [bool](Get-Command Add-Type -ErrorAction SilentlyContinue) -and
        ((Test-Path -LiteralPath $refDirectory -PathType Container) -or $PSVersionTable.PSEdition -eq 'Desktop')
    $loadable = $false
    $loadError = 'not-attempted'
    if ($dllExists -and -not $stale) {
        try {
            if (-not ('HuWin' -as [type])) { Add-Type -Path $dll -ErrorAction Stop }
            $loadable = [bool]('HuWin' -as [type])
            $loadError = if ($loadable) { 'none' } else { 'type-unavailable' }
        } catch { $loadError = 'load-failed' }
    }
    $status = if (-not $sourceExists) { 'source-missing' } elseif (-not $dllExists) { 'build-required' } elseif ($stale) { 'stale' } elseif (-not $loadable) { 'load-failed' } else { 'ready' }
    [pscustomobject][ordered]@{
        sourceExists = $sourceExists
        dllExists = $dllExists
        stale = $stale
        loadable = $loadable
        loadError = $loadError
        compilerAvailable = $compilerAvailable
        ready = ($status -eq 'ready')
        status = $status
    }
}

function Get-ContractFact {
    $riskPath = Join-Path $root 'config\risk-actions.json'
    $riskValid = $false
    $riskSchema = 'unavailable'
    try {
        $policy = Get-Content -LiteralPath $riskPath -Raw -Encoding utf8 | ConvertFrom-Json
        $riskSchema = [string]$policy.schema
        $riskValid = $riskSchema -eq 'win-use-master/risk-actions-v1' -and
            @($policy.blockedTextPatterns).Count -gt 0 -and
            @($policy.blockedKeyChords) -contains 'Enter' -and
            @($policy.blockedDomSemantics) -contains 'form-submit'
        if ($riskValid) {
            foreach ($rule in @($policy.blockedTextPatterns)) { [void][regex]::new([string]$rule.pattern) }
        }
    } catch { $riskValid = $false }

    $schemaSources = [ordered]@{
        'win-use-master/receipt-v1'        = @('scripts/win.ps1', 'scripts/cdp.js')
        'win-use-master/action-receipt-v1' = @('scripts/cdp.js')
        'win-use-master/uia-map-v1'        = @('scripts/win.ps1')
        'win-use-master/cdp-session-v1'    = @('scripts/win.ps1', 'scripts/cdp.js')
        'win-use-master/test-report-v1'    = @('tests/run-tests.ps1')
    }
    $readable = $true
    foreach ($schema in $schemaSources.Keys) {
        foreach ($relative in $schemaSources[$schema]) {
            $path = Join-Path $root $relative
            try {
                $content = Get-Content -LiteralPath $path -Raw -Encoding utf8
                if (-not $content.Contains($schema)) { $readable = $false }
            } catch { $readable = $false }
        }
    }
    [pscustomobject][ordered]@{
        riskPolicyValid = $riskValid
        riskPolicySchema = $riskSchema
        receiptSchemasReadable = $readable
        receiptSchemas = @($schemaSources.Keys)
    }
}

function Get-DesktopFact($Helper) {
    if (-not $Helper.ready -or -not ('HuWin' -as [type])) {
        return [pscustomobject][ordered]@{ inputDesktop = 'unknown'; lockedOrSecure = $null; integrityRid = 0; integrityName = 'unknown' }
    }
    try {
        $locked = [bool][HuWin]::ScreenLocked()
        $rid = [uint32][HuWin]::SelfIntegrity()
        $integrity = if ($rid) { [string][HuWin]::IntegrityName($rid) } else { 'unknown' }
        [pscustomobject][ordered]@{
            inputDesktop = $(if ($locked) { 'secure-or-unavailable' } else { 'interactive' })
            lockedOrSecure = $locked
            integrityRid = [int64]$rid
            integrityName = $integrity
        }
    } catch {
        [pscustomobject][ordered]@{ inputDesktop = 'unknown'; lockedOrSecure = $null; integrityRid = 0; integrityName = 'unknown' }
    }
}

function Get-TemporaryStorageFact {
    $temp = [IO.Path]::GetTempPath()
    $exists = Test-Path -LiteralPath $temp -PathType Container
    $historical = 0
    $validManifests = 0
    $expiredSessions = 0
    if ($exists) {
        $cutoff = [DateTime]::UtcNow.AddDays(-1)
        foreach ($candidate in @(Get-ChildItem -LiteralPath $temp -Force -ErrorAction SilentlyContinue | Where-Object { $_.Name -like 'win-use-master*' -and $_.Name -ne 'win-use-master.synthetic.trail' })) {
            if ($candidate.LastWriteTimeUtc -lt $cutoff) { $historical++ }
            if ($candidate.PSIsContainer -and $candidate.Name -cmatch '^win-use-master-[a-z0-9][a-z0-9._-]{0,126}$' -and
                ($candidate.Attributes -band [IO.FileAttributes]::ReparsePoint) -eq 0) {
                foreach ($manifestName in @('manifest.json', '.win-use-master-manifest.json')) {
                    $manifestPath = Join-Path $candidate.FullName $manifestName
                    if (-not (Test-Path -LiteralPath $manifestPath -PathType Leaf)) { continue }
                    try {
                        $manifestItem = Get-Item -LiteralPath $manifestPath -Force
                        if (($manifestItem.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0 -or $manifestItem.Length -gt 64KB) { continue }
                        $manifest = Get-Content -LiteralPath $manifestPath -Raw -Encoding utf8 | ConvertFrom-Json
                        $createdAt = [DateTimeOffset]::Parse([string]$manifest.createdAt)
                        $expiresAt = [DateTimeOffset]::Parse([string]$manifest.expiresAt)
                        $ownerStartedAt = [DateTimeOffset]::Parse([string]$manifest.owner.startTimeUtc)
                        if ([string]$manifest.schema -eq 'win-use-master/temp-artifact-v1' -and
                            [string]$manifest.artifactId -ceq $candidate.Name -and
                            [int]$manifest.owner.pid -gt 0 -and $createdAt -le [DateTimeOffset]::UtcNow -and
                            $ownerStartedAt -le $createdAt.AddMinutes(5) -and $expiresAt -gt $createdAt -and
                            $expiresAt -le $createdAt.AddDays(30) -and $candidate.LastWriteTimeUtc -lt $cutoff) {
                            $validManifests++
                            break
                        }
                    } catch { }
                }
            }
        }
    }

    $local = [Environment]::GetFolderPath('LocalApplicationData')
    if ($local) {
        $sessionRoot = Join-Path $local 'win-use-master\sessions'
        foreach ($session in @(Get-ChildItem -LiteralPath $sessionRoot -Filter 'cdp-*.json' -File -ErrorAction SilentlyContinue)) {
            try {
                $manifest = Get-Content -LiteralPath $session.FullName -Raw -Encoding utf8 | ConvertFrom-Json
                $expires = [DateTimeOffset]::Parse([string]$manifest.expiresAt)
                if ([string]$manifest.schema -eq 'win-use-master/cdp-session-v1' -and $expires -lt [DateTimeOffset]::UtcNow) { $expiredSessions++ }
            } catch { }
        }
    }
    [pscustomobject][ordered]@{
        directoryExists = $exists
        writeStatus = 'unknown'
        writeProbePerformed = $false
        historicalCandidates = $historical
        validManifestHistorical = $validManifests
        expiredSessions = $expiredSessions
    }
}

try {
    $helper = Get-HelperFact
    $facts = [pscustomobject][ordered]@{
        platform = [pscustomobject][ordered]@{ isWindows = $isWindowsRuntime; name = $(if ($isWindowsRuntime) { 'Windows' } else { 'non-Windows' }) }
        powershell = [pscustomobject][ordered]@{
            version = $PSVersionTable.PSVersion.ToString()
            major = $PSVersionTable.PSVersion.Major
            edition = $PSVersionTable.PSEdition
            executionPolicy = [string](Get-ExecutionPolicy)
        }
        helper = $helper
        node = Get-NodeFact
        browser = Get-BrowserFact
        contracts = Get-ContractFact
        desktop = Get-DesktopFact $helper
        temporaryStorage = Get-TemporaryStorageFact
    }
    $report = New-WinDoctorReport -Facts $facts
    if ($json) { $report | ConvertTo-Json -Depth 10 -Compress }
    else { Format-WinDoctorReport -Report $report -Summary:$summary }
    exit ([int]$report.exitCode)
} catch {
    [Console]::Error.WriteLine("doctor 诊断失败（未执行修复）: $($_.Exception.Message)")
    exit 1
}
