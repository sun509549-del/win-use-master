$ErrorActionPreference = 'Stop'
Set-StrictMode -Version 2.0

$root = Split-Path -Parent $PSScriptRoot
$win = Join-Path $root 'scripts\win.ps1'
$core = Join-Path $root 'scripts\benchmark-core.ps1'
$benchmark = Join-Path $root 'scripts\benchmark.ps1'
$uiaFixture = Join-Path $root 'scripts\benchmark-uia-fixture.ps1'
$cdp = Join-Path $root 'scripts\cdp.js'
$pwsh = (Get-Command pwsh -CommandType Application -ErrorAction Stop).Source
. $core

function Assert-Contract([bool] $Condition, [string] $Message) {
    if (-not $Condition) { throw "benchmark contract: $Message" }
}

function Invoke-BenchmarkChild([string[]] $ChildArguments) {
    $startInfo = [Diagnostics.ProcessStartInfo]::new()
    $startInfo.FileName = $pwsh
    $startInfo.WorkingDirectory = $root
    $startInfo.UseShellExecute = $false
    $startInfo.RedirectStandardOutput = $true
    $startInfo.RedirectStandardError = $true
    $startInfo.StandardOutputEncoding = [Text.UTF8Encoding]::new($false)
    $startInfo.StandardErrorEncoding = [Text.UTF8Encoding]::new($false)
    $startInfo.CreateNoWindow = $true
    foreach ($argument in @('-NoProfile', '-File', $win, 'benchmark') + $ChildArguments) {
        $startInfo.ArgumentList.Add($argument)
    }
    $process = [Diagnostics.Process]::new()
    $process.StartInfo = $startInfo
    try {
        Assert-Contract $process.Start() '无法启动 benchmark 子进程'
        $stdoutTask = $process.StandardOutput.ReadToEndAsync()
        $stderrTask = $process.StandardError.ReadToEndAsync()
        Assert-Contract ($process.WaitForExit(60000)) 'benchmark 子进程超过 60 秒'
        return [pscustomobject]@{
            exitCode = $process.ExitCode
            stdout = $stdoutTask.GetAwaiter().GetResult()
            stderr = $stderrTask.GetAwaiter().GetResult()
        }
    } finally { $process.Dispose() }
}

function Get-RepositoryFingerprint {
    $rows = foreach ($file in Get-ChildItem -LiteralPath $root -Recurse -File | Where-Object { $_.FullName -notmatch '[\\/]\.git[\\/]' }) {
        $relative = [IO.Path]::GetRelativePath($root, $file.FullName).Replace('\', '/')
        $hash = (Get-FileHash -LiteralPath $file.FullName -Algorithm SHA256).Hash.ToLowerInvariant()
        "$relative|$($file.Length)|$($file.LastWriteTimeUtc.Ticks)|$hash"
    }
    return @($rows | Sort-Object)
}

$stats = Get-HuBenchmarkStatistics ([double[]](1..20))
Assert-Contract ($stats.samples -eq 20 -and $stats.minMs -eq 1 -and $stats.p50Ms -eq 10 -and $stats.p95Ms -eq 19 -and $stats.maxMs -eq 20) 'nearest-rank p50/p95 计算错误'
Assert-Contract (Test-HuBenchmarkStatistics $stats) '有效统计结果未通过顺序校验'
Assert-Contract (-not (Test-HuBenchmarkStatistics ([pscustomobject]@{ samples = 1; minMs = 2; p50Ms = 1; p95Ms = 3; maxMs = 4 }))) '乱序统计未被拒绝'

$winSource = Get-Content -LiteralPath $win -Raw -Encoding utf8
$benchmarkSource = Get-Content -LiteralPath $benchmark -Raw -Encoding utf8
$uiaSource = Get-Content -LiteralPath $uiaFixture -Raw -Encoding utf8
$cdpSource = Get-Content -LiteralPath $cdp -Raw -Encoding utf8
Assert-Contract ($winSource -match '\$script:UiaTimeoutMilliseconds\s*=\s*6000') 'UIA 生产超时不得为性能测试延长'
Assert-Contract ($cdpSource -match 'const HTTP_TIMEOUT_MS = 5000;' -and $cdpSource -match 'const CDP_REQUEST_TIMEOUT_MS = 6000;') 'CDP 生产超时不得为性能测试延长'
Assert-Contract ($uiaSource -match "FunctionDefinitionAst.*Get-UiaReadablePage" -and $uiaSource -match 'synthetic-provider-double') 'UIA 基线必须执行生产查询函数且不访问桌面'
Assert-Contract ($benchmarkSource -notmatch '(?i)SendInput|--allow-side-effects|eval-unsafe') '性能入口不得调用输入或任意页面写入'
Assert-Contract ($benchmarkSource -match 'writeCommandsBenchmarked = 0' -and $benchmarkSource -match 'realApplicationsStarted = 0') '性能报告必须显式声明零真实 app 启动/写命令'
Assert-Contract ($benchmarkSource -match 'WIN_USE_MASTER_REQUIRE_PREBUILT_HELPER' -and $winSource -match 'benchmark 不会现场编译') 'windows 基线必须拒绝损坏/过期 helper，不能回退编译'

$before = Get-RepositoryFingerprint
$run = Invoke-BenchmarkChild @('--quick', '--no-cdp', '--json', '--summary')
Assert-Contract ($run.exitCode -eq 0) "快速 benchmark 失败：$($run.stderr.Trim())"
Assert-Contract ([string]::IsNullOrWhiteSpace($run.stderr)) '成功 JSON benchmark 的 stderr 必须为空'
$report = $run.stdout | ConvertFrom-Json
Assert-Contract ([string]$report.schema -eq 'win-use-master/performance-report-v1' -and [string]$report.status -eq 'completed') '报告 schema/status 不匹配'
Assert-Contract ([string]$report.profile -eq 'quick' -and [string]$report.privacy.mode -eq 'summary') '快速/摘要模式未记录'
Assert-Contract (-not [bool]$report.privacy.rawSamplesIncluded -and -not [bool]$report.privacy.pathsIncluded -and -not [bool]$report.privacy.windowOrDocumentContentIncluded) '性能报告隐私声明失效'
Assert-Contract ([string]$report.results.windows.status -eq 'completed') 'windows 首次/重复进程基线失败'
Assert-Contract ($report.results.windows.firstProcess.samples -eq 1 -and $report.results.windows.repeatedProcess.samples -eq 2) 'windows quick 样本数漂移'
Assert-Contract (Test-HuBenchmarkStatistics $report.results.windows.firstProcess) 'windows 首次统计无效'
Assert-Contract (Test-HuBenchmarkStatistics $report.results.windows.repeatedProcess) 'windows 重复统计无效'
Assert-Contract ([string]$report.results.uia.status -eq 'completed') 'UIA 合成基线失败'
Assert-Contract ((@($report.results.uia.cases).elementCount -join ',') -eq '100,300,1000') 'UIA 元素规模必须固定为 100/300/1000'
foreach ($case in @($report.results.uia.cases)) {
    Assert-Contract ($case.timings.samples -eq 1 -and (Test-HuBenchmarkStatistics $case.timings)) "UIA $($case.elementCount) quick 统计无效"
    Assert-Contract ($case.timeoutBudgetMs -eq 6000 -and $case.budgetExceededCount -ge 0 -and $case.budgetExceededRate -ge 0) "UIA $($case.elementCount) 超时预算字段无效"
}
Assert-Contract ([string]$report.results.cdp.status -eq 'disabled' -and [string]$report.results.cdp.reason -eq 'requested-no-cdp') '--no-cdp 未形成显式 disabled 结果'
foreach ($field in @('desktopInputEvents', 'realApplicationsStarted', 'writeCommandsBenchmarked', 'headlessBrowserLaunches', 'ownedFixtureProcessesObserved', 'ownedFixtureProcessesRemaining', 'temporaryDirectoriesCreated', 'temporaryDirectoriesRemoved', 'reportFilesWritten')) {
    Assert-Contract ([int]$report.sideEffects.$field -eq 0) "--no-cdp 副作用计数 $field 必须为 0"
}
Assert-Contract ($report.sideEffects.windowMetadataReadRuns -eq 3 -and $report.sideEffects.windowTitlesReported -eq 0) 'windows quick 应记录 3 次摘要元数据读取且不报告标题'
$json = $run.stdout
Assert-Contract (-not $json.Contains($root, [StringComparison]::OrdinalIgnoreCase)) '报告泄露工作区绝对路径'
if ($env:USERPROFILE) { Assert-Contract (-not $json.Contains($env:USERPROFILE, [StringComparison]::OrdinalIgnoreCase)) '报告泄露用户目录' }
Assert-Contract ($json -notmatch 'private-marker|benchmarkProbe|selector') '报告泄露 fixture 内容或选择器'
$after = Get-RepositoryFingerprint
Assert-Contract (($before -join "`n") -ceq ($after -join "`n")) '快速只读 benchmark 修改了仓库文件'

$tempBefore = @(Get-ChildItem -LiteralPath ([IO.Path]::GetTempPath()) -Directory -Filter 'win-use-master-benchmark-*' -ErrorAction SilentlyContinue).Count
$refused = Invoke-BenchmarkChild @('--quick', '--quick', '--no-cdp')
$tempAfter = @(Get-ChildItem -LiteralPath ([IO.Path]::GetTempPath()) -Directory -Filter 'win-use-master-benchmark-*' -ErrorAction SilentlyContinue).Count
Assert-Contract ($refused.exitCode -eq 2 -and [string]::IsNullOrWhiteSpace($refused.stdout)) '重复参数必须在测量前退出 2 且不生成报告'
Assert-Contract ($tempAfter -eq $tempBefore) '参数拒绝路径创建了临时 benchmark 目录'

Write-Output 'PASS: performance-report-v1 statistics, windows/UIA quick fixtures, privacy, zero-write mode and timeout invariants'
