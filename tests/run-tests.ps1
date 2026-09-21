[CmdletBinding(PositionalBinding = $false)]
param(
    [ValidateSet('Contract', 'Desktop', 'Coordinate', 'Profiles')]
    [string] $Tier = 'Contract',

    [string[]] $Profile,

    [switch] $List,
    [switch] $DryRun,
    [string] $ReportPath,
    [switch] $ForceReport,
    [switch] $FailFast,
    [string[]] $TestId
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version 2.0

$root = Split-Path -Parent $PSScriptRoot
$invocationDirectory = (Get-Location).Path

function New-TestDefinition(
    [string] $Id,
    [string] $TestTier,
    [string] $RelativePath,
    [string[]] $Arguments,
    [bool] $RequiresDesktop,
    [bool] $WritesInput,
    [int] $TimeoutSeconds,
    [string] $ProfileName = ''
) {
    [pscustomobject][ordered]@{
        id              = $Id
        tier            = $TestTier
        path            = $RelativePath
        arguments       = @($Arguments)
        requiresDesktop = $RequiresDesktop
        writesInput     = $WritesInput
        timeoutSeconds  = $TimeoutSeconds
        profile         = $ProfileName
    }
}

$catalog = @(
    New-TestDefinition 'parse' 'Contract' 'tests/parse-contract.ps1' @() $false $false 30
    New-TestDefinition 'build' 'Contract' 'scripts/build.ps1' @() $false $false 60
    New-TestDefinition 'doctor' 'Contract' 'tests/doctor-contract.ps1' @() $false $false 45
    New-TestDefinition 'static' 'Contract' 'tests/static-contract.ps1' @() $false $false 30
    New-TestDefinition 'risk-policy' 'Contract' 'tests/risk-policy-contract.ps1' @() $false $false 30
    New-TestDefinition 'app-profile-catalog' 'Contract' 'tests/app-profile-catalog-contract.ps1' @() $false $false 30
    New-TestDefinition 'profile-template' 'Contract' 'tests/profile-template-contract.ps1' @() $false $false 30
    New-TestDefinition 'public-cases' 'Contract' 'tests/public-cases-contract.ps1' @() $false $false 30
    New-TestDefinition 'release' 'Contract' 'tests/release-contract.ps1' @() $false $false 30
    New-TestDefinition 'governance' 'Contract' 'tests/governance-contract.ps1' @() $false $false 30
    New-TestDefinition 'hygiene' 'Contract' 'tests/repository-hygiene-contract.ps1' @() $false $false 30
    New-TestDefinition 'ci' 'Contract' 'tests/ci-contract.ps1' @() $false $false 30
    New-TestDefinition 'json-output' 'Contract' 'tests/json-output-contract.ps1' @() $false $false 45
    New-TestDefinition 'capability-cache' 'Contract' 'tests/capability-cache-contract.ps1' @() $false $false 45
    New-TestDefinition 'cleanup' 'Contract' 'tests/cleanup-contract.ps1' @() $false $false 30
    New-TestDefinition 'benchmark' 'Contract' 'tests/benchmark-contract.ps1' @() $false $false 75
    New-TestDefinition 'uia-read' 'Contract' 'tests/uia-read-contract.ps1' @() $false $false 45
    New-TestDefinition 'window-state' 'Contract' 'tests/window-state-contract.ps1' @() $false $false 30
    New-TestDefinition 'cdp-ownership' 'Contract' 'tests/cdp-ownership.ps1' @() $false $false 45
    New-TestDefinition 'cdp-action-receipt' 'Contract' 'tests/cdp-action-receipt.ps1' @() $false $false 120
    New-TestDefinition 'uia-timeout' 'Contract' 'tests/uia-timeout.ps1' @() $false $false 45
    New-TestDefinition 'capture-recovery' 'Desktop' 'tests/capture-recovery.ps1' @() $true $false 90
    New-TestDefinition 'smoke' 'Desktop' 'tests/smoke.ps1' @() $true $true 240
    New-TestDefinition 'coordinate-smoke' 'Coordinate' 'tests/smoke.ps1' @('-RequireCoordinate') $true $true 240
    New-TestDefinition 'profile-calculator' 'Profiles' 'tests/calculator-profile.ps1' @() $true $true 180 'calculator'
    New-TestDefinition 'profile-notepad' 'Profiles' 'tests/notepad-profile.ps1' @() $true $true 180 'notepad'
    New-TestDefinition 'profile-settings' 'Profiles' 'tests/settings-profile.ps1' @() $true $false 180 'settings'
    New-TestDefinition 'profile-workbuddy' 'Profiles' 'tests/workbuddy-cdp-profile.ps1' @() $true $true 180 'workbuddy'
    New-TestDefinition 'profile-excel' 'Profiles' 'tests/excel-com-profile.ps1' @() $true $true 180 'excel'
    New-TestDefinition 'profile-wps' 'Profiles' 'tests/wps-et-com-profile.ps1' @() $true $true 180 'wps'
)

function Get-SelectedTests {
    if ($Tier -ne 'Profiles') {
        if ($Profile -and $Profile.Count) { throw '-Profile 只能与 -Tier Profiles 一起使用。' }
        $tierTests = @($catalog | Where-Object { $_.tier -eq $Tier })
    } else {
        $normalizedProfiles = @(
            $Profile |
                ForEach-Object { @([string]$_ -split ',') } |
                ForEach-Object { $_.Trim().ToLowerInvariant() } |
                Where-Object { $_ }
        )
        if (-not $normalizedProfiles.Count) {
            throw '-Tier Profiles 必须显式提供 -Profile；多个名称用逗号连接，使用 -Profile all 才会选择全部真实应用档案。'
        }
        $allowedProfiles = @('calculator', 'notepad', 'settings', 'workbuddy', 'excel', 'wps', 'all')
        $invalidProfiles = @($normalizedProfiles | Where-Object { $_ -notin $allowedProfiles } | Select-Object -Unique)
        if ($invalidProfiles.Count) {
            throw "未知 profile：$($invalidProfiles -join ', ')。可用值：$($allowedProfiles -join ', ')"
        }
        if ($normalizedProfiles -contains 'all' -and $normalizedProfiles.Count -ne 1) {
            throw '-Profile all 不能与其它 profile 同时使用。'
        }

        $requested = if ($normalizedProfiles -contains 'all') {
            @('calculator', 'notepad', 'settings', 'workbuddy', 'excel', 'wps')
        } else {
            @($normalizedProfiles | Select-Object -Unique)
        }
        $tierTests = @($catalog | Where-Object { $_.tier -eq 'Profiles' -and $_.profile -in $requested })
    }

    $normalizedTestIds = @(
        $TestId |
            ForEach-Object { @([string]$_ -split ',') } |
            ForEach-Object { $_.Trim().ToLowerInvariant() } |
            Where-Object { $_ }
    )
    if ($normalizedTestIds.Count) {
        $validIds = @($tierTests | ForEach-Object { [string]$_.id })
        $invalidIds = @($normalizedTestIds | Where-Object { $_ -notin $validIds } | Select-Object -Unique)
        if ($invalidIds.Count) {
            throw "TestId 不属于 Tier=$Tier：$($invalidIds -join ', ')。本层可用值：$($validIds -join ', ')"
        }
        $tierTests = @($tierTests | Where-Object { $_.id -in $normalizedTestIds })
    }
    return @($tierTests)
}

function Get-GitMetadata {
    $commit = 'unavailable'
    $clean = $false
    Push-Location $root
    try {
        if (Get-Command git -ErrorAction SilentlyContinue) {
            $rawCommit = @(& git rev-parse --verify HEAD 2>$null)
            if ($LASTEXITCODE -eq 0 -and $rawCommit.Count) { $commit = [string]$rawCommit[0] }
            $changes = @(& git status --porcelain=v1 --untracked-files=all 2>$null)
            if ($LASTEXITCODE -eq 0) { $clean = ($changes.Count -eq 0) }
        }
    } finally {
        Pop-Location
    }
    return [pscustomobject]@{ commit = $commit; workingTreeClean = $clean }
}

function Get-NodeVersion {
    $node = Get-Command node -CommandType Application -ErrorAction SilentlyContinue | Select-Object -First 1
    if (-not $node) { return 'unavailable' }
    $version = @(& $node.Source --version 2>$null)
    if ($LASTEXITCODE -ne 0 -or -not $version.Count) { return 'unavailable' }
    return ([string]$version[0]).Trim()
}

function Get-TextSha256([string] $Text) {
    $algorithm = [Security.Cryptography.SHA256]::Create()
    try {
        $bytes = [Text.Encoding]::UTF8.GetBytes($Text)
        return ([BitConverter]::ToString($algorithm.ComputeHash($bytes)) -replace '-', '').ToLowerInvariant()
    } finally {
        $algorithm.Dispose()
    }
}

function Write-Report([object] $Report) {
    if (-not $ReportPath) { return }

    $target = if ([IO.Path]::IsPathRooted($ReportPath)) {
        [IO.Path]::GetFullPath($ReportPath)
    } else {
        [IO.Path]::GetFullPath((Join-Path $invocationDirectory $ReportPath))
    }
    $parent = Split-Path -Parent $target
    if (-not (Test-Path -LiteralPath $parent -PathType Container)) {
        throw "报告目录不存在：$parent"
    }
    if ((Test-Path -LiteralPath $target) -and -not $ForceReport) {
        throw "报告已存在；如确认覆盖，仅对该报告使用 -ForceReport：$target"
    }

    $json = $Report | ConvertTo-Json -Depth 8
    Set-Content -LiteralPath $target -Value $json -Encoding utf8 -NoNewline
    Write-Output "report: $target"
}

function Invoke-TestDefinition([object] $Definition) {
    $fullPath = Join-Path $root $Definition.path
    if (-not (Test-Path -LiteralPath $fullPath -PathType Leaf)) {
        return [pscustomobject][ordered]@{
            id = $Definition.id; path = $Definition.path; arguments = @($Definition.arguments)
            requiresDesktop = $Definition.requiresDesktop; writesInput = $Definition.writesInput
            status = 'failed'; exitCode = 1; durationMs = 0; timedOut = $false
            outputLineCount = 0; outputSha256 = Get-TextSha256 "missing:$($Definition.path)"
        }
    }

    Write-Host "RUN $($Definition.id) timeout=$($Definition.timeoutSeconds)s"
    $startInfo = [Diagnostics.ProcessStartInfo]::new()
    $startInfo.FileName = (Get-Command pwsh -CommandType Application -ErrorAction Stop | Select-Object -First 1).Source
    $startInfo.WorkingDirectory = $root
    $startInfo.UseShellExecute = $false
    $startInfo.RedirectStandardOutput = $true
    $startInfo.RedirectStandardError = $true
    $startInfo.StandardOutputEncoding = [Text.UTF8Encoding]::new($false)
    $startInfo.StandardErrorEncoding = [Text.UTF8Encoding]::new($false)
    $startInfo.CreateNoWindow = $true
    $startInfo.Environment['WIN_USE_MASTER_RUNNER_TEST_PATH'] = $fullPath
    $startInfo.Environment['WIN_USE_MASTER_RUNNER_ARGUMENTS_JSON'] = (@($Definition.arguments) | ConvertTo-Json -Compress)
    $startInfo.ArgumentList.Add('-NoProfile')
    $startInfo.ArgumentList.Add('-Command')
    $startInfo.ArgumentList.Add(@'
[Console]::OutputEncoding = [Text.UTF8Encoding]::new($false)
$invokeArguments = @()
if ($env:WIN_USE_MASTER_RUNNER_ARGUMENTS_JSON) {
    $invokeArguments = @(ConvertFrom-Json -InputObject $env:WIN_USE_MASTER_RUNNER_ARGUMENTS_JSON)
}
& $env:WIN_USE_MASTER_RUNNER_TEST_PATH @invokeArguments
$childExit = if ($?) { 0 } else { 1 }
exit $childExit
'@)

    $process = [Diagnostics.Process]::new()
    $process.StartInfo = $startInfo
    $stopwatch = [Diagnostics.Stopwatch]::StartNew()
    $timedOut = $false
    try {
        if (-not $process.Start()) { throw "无法启动测试 $($Definition.id)" }
        $stdoutTask = $process.StandardOutput.ReadToEndAsync()
        $stderrTask = $process.StandardError.ReadToEndAsync()
        if (-not $process.WaitForExit($Definition.timeoutSeconds * 1000)) {
            $timedOut = $true
            try { $process.Kill($true) } catch { Write-Warning "终止超时测试失败：$($_.Exception.Message)" }
            $process.WaitForExit()
        }
        $stdout = $stdoutTask.GetAwaiter().GetResult()
        $stderr = $stderrTask.GetAwaiter().GetResult()
        $exitCode = if ($timedOut) { 1 } else { $process.ExitCode }
    } finally {
        $stopwatch.Stop()
        $process.Dispose()
    }

    if ($stdout) { Write-Host $stdout.TrimEnd() }
    if ($stderr) { Write-Warning $stderr.TrimEnd() }
    $combined = "$stdout`n$stderr"
    $lineCount = if ($combined.Length) { @($combined -split '\r?\n').Count } else { 0 }
    $status = if ($timedOut) { 'timed-out' } elseif ($exitCode -eq 0) { 'passed' } elseif ($exitCode -eq 2) { 'safe-refusal' } else { 'failed' }
    Write-Host "END $($Definition.id) status=$status exit=$exitCode duration=$($stopwatch.ElapsedMilliseconds)ms"

    return [pscustomobject][ordered]@{
        id              = $Definition.id
        path            = $Definition.path
        arguments       = @($Definition.arguments)
        requiresDesktop = $Definition.requiresDesktop
        writesInput     = $Definition.writesInput
        status          = $status
        exitCode        = $exitCode
        durationMs      = $stopwatch.ElapsedMilliseconds
        timedOut        = $timedOut
        outputLineCount = $lineCount
        outputSha256    = Get-TextSha256 $combined
    }
}

$selected = @(Get-SelectedTests)
if (-not $selected.Count) { throw "没有找到 Tier=$Tier 对应的测试。" }

if ($List) {
    $catalog |
        Select-Object id, tier, profile, requiresDesktop, writesInput, timeoutSeconds, path |
        Format-Table -AutoSize
    exit 0
}

foreach ($definition in $selected) {
    $fullPath = Join-Path $root $definition.path
    if (-not (Test-Path -LiteralPath $fullPath -PathType Leaf)) {
        throw "测试文件不存在：$($definition.path)"
    }
}

$git = Get-GitMetadata
$results = [Collections.Generic.List[object]]::new()
$startedUtc = [DateTimeOffset]::UtcNow
if ($DryRun) {
    foreach ($definition in $selected) {
        $results.Add([pscustomobject][ordered]@{
            id = $definition.id; path = $definition.path; arguments = @($definition.arguments)
            requiresDesktop = $definition.requiresDesktop; writesInput = $definition.writesInput
            status = 'planned'; exitCode = $null; durationMs = 0; timedOut = $false
            outputLineCount = 0; outputSha256 = $null
        })
    }
} else {
    foreach ($definition in $selected) {
        $result = Invoke-TestDefinition $definition
        $results.Add($result)
        if ($FailFast -and $result.exitCode -ne 0) { break }
    }
}

$completedUtc = [DateTimeOffset]::UtcNow
$summary = [ordered]@{
    selected      = $selected.Count
    executed      = @($results | Where-Object { $_.status -ne 'planned' }).Count
    planned       = @($results | Where-Object { $_.status -eq 'planned' }).Count
    passed        = @($results | Where-Object { $_.status -eq 'passed' }).Count
    safeRefusal   = @($results | Where-Object { $_.status -eq 'safe-refusal' }).Count
    failed        = @($results | Where-Object { $_.status -in @('failed', 'timed-out') }).Count
}
$report = [pscustomobject][ordered]@{
    schema       = 'win-use-master/test-report-v1'
    createdUtc   = $completedUtc.ToString('o')
    startedUtc   = $startedUtc.ToString('o')
    tier         = $Tier
    dryRun       = [bool]$DryRun
    environment  = [ordered]@{
        commit           = $git.commit
        workingTreeClean = $git.workingTreeClean
        windowsVersion   = [Environment]::OSVersion.Version.ToString()
        powerShellVersion = $PSVersionTable.PSVersion.ToString()
        nodeVersion      = Get-NodeVersion
    }
    summary      = $summary
    tests        = @($results)
}

Write-Output "SUMMARY tier=$Tier selected=$($summary.selected) executed=$($summary.executed) passed=$($summary.passed) safe-refusal=$($summary.safeRefusal) failed=$($summary.failed)"
Write-Report $report

if ($summary.failed -gt 0) { exit 1 }
if ($summary.safeRefusal -gt 0) { exit 2 }
exit 0
