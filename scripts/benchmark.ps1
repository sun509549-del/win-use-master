[CmdletBinding(PositionalBinding = $false)]
param(
    [Parameter(ValueFromRemainingArguments = $true)]
    [string[]] $Arguments = @()
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version 2.0
$root = Split-Path -Parent $PSScriptRoot
. (Join-Path $PSScriptRoot 'benchmark-core.ps1')

function Stop-Benchmark([string] $Message, [int] $Code = 1) {
    [Console]::Error.WriteLine($Message)
    exit $Code
}

$allowed = @('--json', '--summary', '--quick', '--no-cdp')
$unknown = @($Arguments | Where-Object { $_ -notin $allowed })
$duplicates = @($allowed | Where-Object {
    $allowedArgument = $_
    @($Arguments | Where-Object { $_ -eq $allowedArgument }).Count -gt 1
})
if ($unknown.Count -or $duplicates.Count) {
    Stop-Benchmark 'benchmark 只支持 --json/--summary/--quick/--no-cdp；未知或重复参数已拒绝。' 2
}
$jsonOutput = $Arguments -contains '--json'
$summaryOutput = $Arguments -contains '--summary'
$quick = $Arguments -contains '--quick'
$skipCdp = $Arguments -contains '--no-cdp'
$repeatIterations = if ($quick) { 2 } else { 5 }
$uiaIterations = if ($quick) { 1 } else { 5 }
$cdpIterations = if ($quick) { 2 } else { 5 }

function Invoke-BenchmarkProcess([string] $FileName, [string[]] $ProcessArguments, [int] $TimeoutMilliseconds,
    [hashtable] $Environment = @{}) {
    $startInfo = [Diagnostics.ProcessStartInfo]::new()
    $startInfo.FileName = $FileName
    $startInfo.WorkingDirectory = $root
    $startInfo.UseShellExecute = $false
    $startInfo.RedirectStandardOutput = $true
    $startInfo.RedirectStandardError = $true
    $startInfo.StandardOutputEncoding = [Text.UTF8Encoding]::new($false)
    $startInfo.StandardErrorEncoding = [Text.UTF8Encoding]::new($false)
    $startInfo.CreateNoWindow = $true
    foreach ($name in $Environment.Keys) { $startInfo.Environment[[string]$name] = [string]$Environment[$name] }
    foreach ($argument in $ProcessArguments) { $startInfo.ArgumentList.Add($argument) }

    $process = [Diagnostics.Process]::new()
    $process.StartInfo = $startInfo
    $clock = [Diagnostics.Stopwatch]::StartNew()
    $timedOut = $false
    try {
        if (-not $process.Start()) { throw 'benchmark child process did not start' }
        $stdoutTask = $process.StandardOutput.ReadToEndAsync()
        $stderrTask = $process.StandardError.ReadToEndAsync()
        if (-not $process.WaitForExit($TimeoutMilliseconds)) {
            $timedOut = $true
            try { $process.Kill($true) } catch { }
            $process.WaitForExit()
        }
        $stdout = $stdoutTask.GetAwaiter().GetResult()
        $stderr = $stderrTask.GetAwaiter().GetResult()
        $exitCode = if ($timedOut) { 2 } else { $process.ExitCode }
    } finally {
        $clock.Stop()
        $process.Dispose()
    }
    return [pscustomobject]@{
        exitCode = $exitCode
        timedOut = $timedOut
        stdout = $stdout
        stderr = $stderr
        durationMs = [double]$clock.Elapsed.TotalMilliseconds
    }
}

function Invoke-WindowsBenchmark([string] $Pwsh) {
    $helperPath = Join-Path $PSScriptRoot 'HuWin.dll'
    $sourcePath = Join-Path $PSScriptRoot 'HuWin.cs'
    if (-not (Test-Path -LiteralPath $helperPath -PathType Leaf) -or
        (Get-Item -LiteralPath $helperPath).LastWriteTimeUtc -lt (Get-Item -LiteralPath $sourcePath).LastWriteTimeUtc) {
        return [pscustomobject][ordered]@{
            status = 'failed'; reason = 'helper-not-built'; firstProcess = $null; repeatedProcess = $null; failedRuns = 1
        }
    }

    $prebuiltEnvironment = @{ WIN_USE_MASTER_REQUIRE_PREBUILT_HELPER = '1' }
    $first = Invoke-BenchmarkProcess $Pwsh @('-NoProfile', '-File', (Join-Path $PSScriptRoot 'win.ps1'), 'windows', '--json', '--summary') 20000 $prebuiltEnvironment
    $firstValid = $false
    if ($first.exitCode -eq 0 -and -not [string]::IsNullOrWhiteSpace($first.stdout)) {
        try {
            $firstReport = $first.stdout | ConvertFrom-Json
            $firstValid = [string]$firstReport.schema -eq 'win-use-master/windows-result-v1'
        } catch { $firstValid = $false }
    }
    $repeatSamples = [Collections.Generic.List[double]]::new()
    $failedRuns = if ($firstValid) { 0 } else { 1 }
    for ($iteration = 0; $iteration -lt $repeatIterations; $iteration++) {
        $run = Invoke-BenchmarkProcess $Pwsh @('-NoProfile', '-File', (Join-Path $PSScriptRoot 'win.ps1'), 'windows', '--json', '--summary') 20000 $prebuiltEnvironment
        $valid = $false
        if ($run.exitCode -eq 0 -and -not [string]::IsNullOrWhiteSpace($run.stdout)) {
            try {
                $report = $run.stdout | ConvertFrom-Json
                $valid = [string]$report.schema -eq 'win-use-master/windows-result-v1'
            } catch { $valid = $false }
        }
        if ($valid) { $repeatSamples.Add($run.durationMs) } else { $failedRuns++ }
    }
    return [pscustomobject][ordered]@{
        status = if ($failedRuns) { 'failed' } else { 'completed' }
        reason = if ($failedRuns) { 'child-read-failed' } else { $null }
        firstProcess = if ($firstValid) { Get-HuBenchmarkStatistics @($first.durationMs) } else { $null }
        repeatedProcess = if ($repeatSamples.Count) { Get-HuBenchmarkStatistics $repeatSamples.ToArray() } else { $null }
        failedRuns = $failedRuns
    }
}

function Find-BenchmarkEdge {
    $candidates = [Collections.Generic.List[string]]::new()
    $command = Get-Command msedge.exe -CommandType Application -ErrorAction SilentlyContinue | Select-Object -First 1
    if ($command) { $candidates.Add([string]$command.Source) }
    foreach ($candidate in @(
        'C:\Program Files (x86)\Microsoft\Edge\Application\msedge.exe',
        'C:\Program Files\Microsoft\Edge\Application\msedge.exe'
    )) { $candidates.Add($candidate) }
    return $candidates | Where-Object { Test-Path -LiteralPath $_ -PathType Leaf } | Select-Object -First 1
}

function Get-BenchmarkFreePort {
    $listener = [Net.Sockets.TcpListener]::new([Net.IPAddress]::Loopback, 0)
    try {
        $listener.Start()
        return [int]$listener.LocalEndpoint.Port
    } finally { $listener.Stop() }
}

function Invoke-CdpInspectBenchmark([string] $Node) {
    $edgeExe = Find-BenchmarkEdge
    if (-not $edgeExe) {
        return [pscustomobject][ordered]@{
            status = 'skipped'; reason = 'edge-unavailable'; inspect = $null
            headlessBrowserLaunches = 0; ownedFixtureProcessesObserved = 0; ownedFixtureProcessesRemaining = 0
            temporaryDirectoriesCreated = 0; temporaryDirectoriesRemoved = 0
        }
    }

    $benchmarkTempRoot = Join-Path ([IO.Path]::GetTempPath()) ('win-use-master-benchmark-' + [Guid]::NewGuid().ToString('N'))
    $profile = Join-Path $benchmarkTempRoot 'edge-profile'
    [IO.Directory]::CreateDirectory($profile) | Out-Null
    $port = Get-BenchmarkFreePort
    $edge = $null
    $result = [ordered]@{
        status = 'failed'; reason = 'fixture-start-failed'; inspect = $null
        headlessBrowserLaunches = 0; ownedFixtureProcessesObserved = 0; ownedFixtureProcessesRemaining = 0
        temporaryDirectoriesCreated = 1; temporaryDirectoriesRemoved = 0
    }
    $fixtureStage = 'launch'
    try {
        $edgeArgs = @(
            '--headless=new', "--remote-debugging-port=$port", "--user-data-dir=$profile",
            '--no-first-run', '--no-default-browser-check', '--disable-background-networking',
            '--disable-extensions', '--remote-allow-origins=*', 'about:blank'
        )
        $edge = Start-Process -FilePath $edgeExe -ArgumentList $edgeArgs -WindowStyle Hidden -PassThru
        $result.headlessBrowserLaunches = 1
        $fixtureStage = 'ready'
        $targetCandidates = @()
        $deadline = [DateTime]::UtcNow.AddSeconds(30)
        do {
            try {
                $targets = @(Invoke-RestMethod -Uri "http://127.0.0.1:$port/json/list" -TimeoutSec 1 -Proxy $null)
                $targetCandidates = @($targets | Where-Object { $_.type -eq 'page' -and $_.id })
            } catch { $targetCandidates = @() }
            if ($targetCandidates.Count) { break }
            Start-Sleep -Milliseconds 100
        } while ([DateTime]::UtcNow -lt $deadline)
        if (-not $targetCandidates.Count) { throw 'headless CDP fixture was not ready' }
        $observedOwned = @(Get-CimInstance Win32_Process -Filter "Name = 'msedge.exe'" -ErrorAction SilentlyContinue |
            Where-Object { $_.CommandLine -and $_.CommandLine.Contains($profile) }).Count
        $result.ownedFixtureProcessesObserved = [Math]::Max(1, $observedOwned)

        $cdpPath = Join-Path $PSScriptRoot 'cdp.js'
        $fixtureStage = 'warmup'
        $target = $null
        $commandArgs = $null
        $warmupDeadline = [DateTime]::UtcNow.AddSeconds(10)
        do {
            $candidateArgs = @($cdpPath, [string]$port, 'inspect', 'auto', 'body', '--json', '--summary')
            $warmup = Invoke-BenchmarkProcess $Node $candidateArgs 15000
            if ($warmup.exitCode -eq 0) {
                try { $warmupReport = $warmup.stdout | ConvertFrom-Json } catch { $warmupReport = $null }
                if ([string]$warmupReport.schema -eq 'win-use-master/cdp-inspect-result-v1' -and [string]$warmupReport.status -eq 'found') {
                    $target = 'auto'
                    $commandArgs = $candidateArgs
                }
            }
            if ($target) { break }
            Start-Sleep -Milliseconds 100
        } while ([DateTime]::UtcNow -lt $warmupDeadline)
        if (-not $target) {
            throw 'headless CDP warmup returned no matching fixture target'
        }

        $samples = [Collections.Generic.List[double]]::new()
        $fixtureStage = 'inspect'
        for ($iteration = 0; $iteration -lt $cdpIterations; $iteration++) {
            $run = Invoke-BenchmarkProcess $Node $commandArgs 15000
            if ($run.exitCode -ne 0) { throw 'headless CDP inspect failed' }
            $report = $run.stdout | ConvertFrom-Json
            if ([string]$report.schema -ne 'win-use-master/cdp-inspect-result-v1' -or [string]$report.status -ne 'found') {
                throw 'headless CDP inspect returned an unexpected report'
            }
            $samples.Add($run.durationMs)
        }
        $result.status = 'completed'
        $result.reason = $null
        $result.inspect = Get-HuBenchmarkStatistics $samples.ToArray()
    } catch {
        $result.status = 'failed'
        $result.reason = "isolated-fixture-$fixtureStage-failed"
        $result.inspect = $null
    } finally {
        if ($edge) {
            try { if (-not $edge.HasExited) { $edge.Kill($true); $edge.WaitForExit(5000) | Out-Null } } catch { }
        }
        $processDeadline = [DateTime]::UtcNow.AddSeconds(8)
        do {
            $owned = @(Get-CimInstance Win32_Process -Filter "Name = 'msedge.exe'" -ErrorAction SilentlyContinue |
                Where-Object { $_.CommandLine -and $_.CommandLine.Contains($profile) })
            foreach ($processRow in $owned) { Stop-Process -Id $processRow.ProcessId -Force -ErrorAction SilentlyContinue }
            if (-not $owned.Count) { break }
            Start-Sleep -Milliseconds 150
        } while ([DateTime]::UtcNow -lt $processDeadline)

        $owned = @(Get-CimInstance Win32_Process -Filter "Name = 'msedge.exe'" -ErrorAction SilentlyContinue |
            Where-Object { $_.CommandLine -and $_.CommandLine.Contains($profile) })
        $result.ownedFixtureProcessesRemaining = $owned.Count
        $tempBase = [IO.Path]::GetFullPath([IO.Path]::GetTempPath()).TrimEnd('\') + '\'
        $resolvedTemp = [IO.Path]::GetFullPath($benchmarkTempRoot)
        $safeTemp = $resolvedTemp.StartsWith($tempBase, [StringComparison]::OrdinalIgnoreCase) -and
            [IO.Path]::GetFileName($resolvedTemp).StartsWith('win-use-master-benchmark-', [StringComparison]::Ordinal)
        if (-not $owned.Count -and $safeTemp) {
            for ($attempt = 0; $attempt -lt 8 -and (Test-Path -LiteralPath $resolvedTemp); $attempt++) {
                try { Remove-Item -LiteralPath $resolvedTemp -Recurse -Force -ErrorAction Stop } catch { Start-Sleep -Milliseconds 250 }
            }
        }
        if ($safeTemp -and -not (Test-Path -LiteralPath $resolvedTemp)) { $result.temporaryDirectoriesRemoved = 1 }
        else {
            $result.status = 'failed'
            $result.reason = 'fixture-cleanup-failed'
        }
        if ($edge) { $edge.Dispose() }
    }
    return [pscustomobject]$result
}

$pwsh = (Get-Command pwsh -CommandType Application -ErrorAction SilentlyContinue | Select-Object -First 1)
if (-not $pwsh) { Stop-Benchmark 'benchmark 需要 PowerShell 7。' 1 }
$nodeCommand = Get-Command node -CommandType Application -ErrorAction SilentlyContinue | Select-Object -First 1

$windowsResult = Invoke-WindowsBenchmark $pwsh.Source
$uiaRun = Invoke-BenchmarkProcess $pwsh.Source @('-NoProfile', '-File', (Join-Path $PSScriptRoot 'benchmark-uia-fixture.ps1'), '-Iterations', [string]$uiaIterations) 60000
$uiaResult = $null
if ($uiaRun.exitCode -eq 0) {
    try {
        $uiaResult = $uiaRun.stdout | ConvertFrom-Json
        if ([string]$uiaResult.schema -ne 'win-use-master/uia-synthetic-benchmark-v1') { $uiaResult = $null }
    } catch { $uiaResult = $null }
}
if (-not $uiaResult) {
    $uiaResult = [pscustomobject][ordered]@{ status = 'failed'; provider = 'synthetic-provider-double'; cases = @() }
}

$cdpResult = if ($skipCdp) {
    [pscustomobject][ordered]@{
        status = 'disabled'; reason = 'requested-no-cdp'; inspect = $null
        headlessBrowserLaunches = 0; ownedFixtureProcessesObserved = 0; ownedFixtureProcessesRemaining = 0
        temporaryDirectoriesCreated = 0; temporaryDirectoriesRemoved = 0
    }
} elseif (-not $nodeCommand) {
    [pscustomobject][ordered]@{
        status = 'skipped'; reason = 'node-unavailable'; inspect = $null
        headlessBrowserLaunches = 0; ownedFixtureProcessesObserved = 0; ownedFixtureProcessesRemaining = 0
        temporaryDirectoriesCreated = 0; temporaryDirectoriesRemoved = 0
    }
} else { Invoke-CdpInspectBenchmark $nodeCommand.Source }

$requiredFailed = [string]$windowsResult.status -ne 'completed' -or [string]$uiaResult.status -ne 'completed' -or
    [string]$cdpResult.status -eq 'failed'
$optionalIncomplete = -not $skipCdp -and [string]$cdpResult.status -eq 'skipped'
$overallStatus = if ($requiredFailed) { 'failed' } elseif ($optionalIncomplete) { 'partial' } else { 'completed' }
$nodeVersion = if ($nodeCommand) { ((& $nodeCommand.Source --version 2>$null) -join '').Trim() } else { 'unavailable' }
$report = [pscustomobject][ordered]@{
    schema = 'win-use-master/performance-report-v1'
    observedAt = [DateTime]::UtcNow.ToString('o')
    status = $overallStatus
    profile = if ($quick) { 'quick' } else { 'standard' }
    privacy = [pscustomobject][ordered]@{
        mode = if ($summaryOutput) { 'summary' } else { 'aggregate-only' }
        rawSamplesIncluded = $false
        pathsIncluded = $false
        windowOrDocumentContentIncluded = $false
    }
    environment = [pscustomobject][ordered]@{
        windowsVersion = [Environment]::OSVersion.Version.ToString()
        powershellVersion = $PSVersionTable.PSVersion.ToString()
        nodeVersion = $nodeVersion
        processArchitecture = [Runtime.InteropServices.RuntimeInformation]::ProcessArchitecture.ToString()
    }
    methodology = [pscustomobject][ordered]@{
        windowsFirst = 'first fresh pwsh process after helper precondition check'
        windowsRepeated = 'subsequent fresh pwsh processes; OS cache may be warm'
        uia = 'production Get-UiaReadablePage with synthetic provider; one unmeasured warmup per size'
        cdp = if ($skipCdp) { 'disabled by request' } else { 'read-only inspect against owned temporary headless Edge fixture' }
        regressionThreshold = 'compare same fixture and profile; p95 warning above 20 percent'
    }
    results = [pscustomobject][ordered]@{
        windows = $windowsResult
        uia = $uiaResult
        cdp = $cdpResult
    }
    sideEffects = [pscustomobject][ordered]@{
        desktopInputEvents = 0
        realApplicationsStarted = 0
        windowMetadataReadRuns = 1 + $repeatIterations
        windowTitlesReported = 0
        writeCommandsBenchmarked = 0
        headlessBrowserLaunches = [int]$cdpResult.headlessBrowserLaunches
        ownedFixtureProcessesObserved = [int]$cdpResult.ownedFixtureProcessesObserved
        ownedFixtureProcessesRemaining = [int]$cdpResult.ownedFixtureProcessesRemaining
        temporaryDirectoriesCreated = [int]$cdpResult.temporaryDirectoriesCreated
        temporaryDirectoriesRemoved = [int]$cdpResult.temporaryDirectoriesRemoved
        reportFilesWritten = 0
    }
    deferred = @('PrintWindow requires a dedicated idle desktop', 'CDP insert/press require a separately authorized isolated write benchmark')
}

if ($jsonOutput) {
    Write-Output ($report | ConvertTo-Json -Depth 10)
} else {
    Write-Output "performance baseline: status=$overallStatus profile=$($report.profile)"
    if ($windowsResult.firstProcess) {
        Write-Output "windows first: p50=$($windowsResult.firstProcess.p50Ms)ms; repeated p50=$($windowsResult.repeatedProcess.p50Ms)ms p95=$($windowsResult.repeatedProcess.p95Ms)ms"
    } else { Write-Output "windows: $($windowsResult.status) reason=$($windowsResult.reason)" }
    foreach ($case in @($uiaResult.cases)) {
        Write-Output "UIA synthetic $($case.elementCount): p50=$($case.timings.p50Ms)ms p95=$($case.timings.p95Ms)ms budget-exceeded=$($case.budgetExceededCount)/$($case.timings.samples)"
    }
    if ($cdpResult.inspect) { Write-Output "CDP inspect: p50=$($cdpResult.inspect.p50Ms)ms p95=$($cdpResult.inspect.p95Ms)ms" }
    else { Write-Output "CDP inspect: $($cdpResult.status) reason=$($cdpResult.reason)" }
    Write-Output 'writes: 0; PrintWindow and CDP insert/press remain deferred'
}

if ($requiredFailed) { exit 1 }
exit 0
