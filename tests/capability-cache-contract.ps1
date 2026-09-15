$ErrorActionPreference = 'Stop'
Set-StrictMode -Version 2.0

$root = Split-Path -Parent $PSScriptRoot
$core = Join-Path $root 'scripts\capability-cache-core.ps1'
$win = Join-Path $root 'scripts\win.ps1'
$probeScript = Join-Path $root 'scripts\probe.ps1'
$cdp = Join-Path $root 'scripts\cdp.js'
$tempBase = [IO.Path]::GetFullPath([IO.Path]::GetTempPath()).TrimEnd('\')
$tempDir = Join-Path $tempBase ('win-use-master-capability-cache-test-' + [Guid]::NewGuid().ToString('N'))
$cachePath = Join-Path $tempDir 'capability-cache-v1.json'
$probePath = Join-Path $tempDir 'probe-report.json'

function Assert-Contract([bool] $Condition, [string] $Message) {
    if (-not $Condition) { throw "capability cache contract: $Message" }
}

function Invoke-Process([string] $FileName, [string[]] $Arguments) {
    $start = [Diagnostics.ProcessStartInfo]::new()
    $start.FileName = $FileName; $start.WorkingDirectory = $root
    $start.UseShellExecute = $false; $start.CreateNoWindow = $true
    $start.RedirectStandardOutput = $true; $start.RedirectStandardError = $true
    $start.StandardOutputEncoding = [Text.UTF8Encoding]::new($false)
    $start.StandardErrorEncoding = [Text.UTF8Encoding]::new($false)
    foreach ($argument in $Arguments) { [void]$start.ArgumentList.Add($argument) }
    $process = [Diagnostics.Process]::new(); $process.StartInfo = $start
    try {
        Assert-Contract $process.Start() "无法启动 $FileName"
        $stdoutTask = $process.StandardOutput.ReadToEndAsync(); $stderrTask = $process.StandardError.ReadToEndAsync()
        if (-not $process.WaitForExit(30000)) { try { $process.Kill($true) } catch { }; throw "$FileName 超时" }
        return [pscustomobject]@{
            exitCode = $process.ExitCode
            stdout = $stdoutTask.GetAwaiter().GetResult().Trim()
            stderr = $stderrTask.GetAwaiter().GetResult().Trim()
        }
    } finally { $process.Dispose() }
}

function Invoke-Win([string[]] $Arguments) {
    return Invoke-Process (Get-Command pwsh -ErrorAction Stop).Source (@('-NoProfile','-File',$win) + $Arguments)
}

[IO.Directory]::CreateDirectory($tempDir) | Out-Null
$savedTest = [string]$env:WIN_USE_MASTER_CAPABILITY_CACHE_TEST
$savedPath = [string]$env:WIN_USE_MASTER_CAPABILITY_CACHE_PATH
$savedEnabled = [string]$env:WIN_USE_MASTER_CAPABILITY_CACHE
$savedSession = [string]$env:WIN_USE_MASTER_CDP_SESSION
try {
    $env:WIN_USE_MASTER_CAPABILITY_CACHE_TEST = '1'
    $env:WIN_USE_MASTER_CAPABILITY_CACHE_PATH = $cachePath
    Remove-Item Env:\WIN_USE_MASTER_CAPABILITY_CACHE -ErrorAction SilentlyContinue
    . $core

    $privateMarker = 'private-marker-7d830fc2'
    $now = [DateTimeOffset]::Now
    $probe = [pscustomobject][ordered]@{
        schema = 'win-use-master/probe-report-v1'; observedAt = $now.ToString('o'); status = 'resolved'
        target = [pscustomobject][ordered]@{
            displayName = 'FixtureApp'; executablePath = "C:\Users\$privateMarker\Fixture.exe"
            versions = @('1.2.3'); installRoot = "C:\Users\$privateMarker"
        }
        runtime = [pscustomobject][ordered]@{ primaryPids = @(111); relatedPids = @(111,222); commandLine = "--token=$privateMarker" }
        frameworks = [pscustomobject][ordered]@{
            families = @([pscustomobject]@{ name = 'Electron'; count = 1 })
            signals = @([pscustomobject]@{ evidence = "DOM $privateMarker" })
        }
        interfaces = [pscustomobject][ordered]@{
            cdp = [pscustomobject]@{ status = 'available'; endpoints = @([pscustomobject]@{ port = 9222; pid = 111 }) }
            com = [pscustomobject]@{ status = 'candidate'; servers = @([pscustomobject]@{ secret = $privateMarker }) }
        }
        windows = [pscustomobject][ordered]@{
            items = @([pscustomobject]@{ className = 'FixtureClass'; title = "Document $privateMarker"; pid = 111 })
        }
        uia = [pscustomobject][ordered]@{ status = 'available'; timedOut = $false; name = $privateMarker; value = $privateMarker }
        capabilities = [pscustomobject][ordered]@{ l0 = 'cdp'; l1 = 'available'; l2 = 'eligible'; l3 = 'available' }
        authorization = [pscustomobject][ordered]@{ trusted = $true; allowWrite = $true }
    }

    $entry = New-CapabilityEntryFromProbeReport $probe $now
    $entryRaw = $entry | ConvertTo-Json -Depth 12
    Assert-Contract (-not $entryRaw.Contains($privateMarker, [StringComparison]::OrdinalIgnoreCase)) '不得保留路径、标题、UIA/DOM 内容标记'
    Assert-Contract ($entryRaw -notmatch '(?i)\b(pid|port|title|commandLine|installRoot|executablePath|l2|allowWrite)\b') '不得保留 PID、端口、路径或授权字段'
    Assert-Contract ([string]$entry.identity.executableName -eq 'Fixture.exe') '只应从路径提取 exe 文件名'
    Assert-Contract (@($entry.identity.windowClasses) -contains 'FixtureClass') '应保留低敏感窗口类观察'
    Assert-Contract ([string]$entry.observations.cdp -eq 'available' -and [string]$entry.observations.com -eq 'candidate') '应保留接口可用性观察'

    $expiredProbe = $probe | ConvertTo-Json -Depth 12 | ConvertFrom-Json
    $expiredProbe.observedAt = $now.AddDays(-31).ToString('o')
    $expiredRejected = $false
    try { [void](New-CapabilityEntryFromProbeReport $expiredProbe $now) } catch { $expiredRejected = $true }
    Assert-Contract $expiredRejected '超过 30 天的 probe 报告必须拒绝记录'
    $futureProbe = $probe | ConvertTo-Json -Depth 12 | ConvertFrom-Json
    $futureProbe.observedAt = $now.AddMinutes(6).ToString('o')
    $futureRejected = $false
    try { [void](New-CapabilityEntryFromProbeReport $futureProbe $now) } catch { $futureRejected = $true }
    Assert-Contract $futureRejected '未来时间戳的 probe 报告必须拒绝记录'

    $cache = New-EmptyCapabilityCache $now; $cache.entries = @($entry)
    [void](Write-CapabilityCacheDocument $cachePath $cache $now)
    $read = Read-CapabilityCacheDocument $cachePath
    Assert-Contract ([string]$read.status -eq 'valid' -and @($read.cache.entries).Count -eq 1) '正常 cache 应写入并规范化读回'
    $sameVersion = Get-CapabilityCacheHint $read $probe $now
    Assert-Contract ([string]$sameVersion.status -eq 'fresh' -and [bool]$sameVersion.used) '相同版本应提供建议性 hint'
    Assert-Contract (-not [bool]$sameVersion.trustedForAuthorization) 'hint 永远不得成为授权'
    Assert-Contract ((@($sameVersion.advisoryOrder) -join ',') -eq 'cdp,com,uia') '建议顺序应只来自已观察能力'
    $changedProbe = $probe | ConvertTo-Json -Depth 12 | ConvertFrom-Json
    $changedProbe.target.versions = @('2.0.0')
    $changed = Get-CapabilityCacheHint $read $changedProbe $now
    Assert-Contract ([string]$changed.status -eq 'version-changed' -and -not [bool]$changed.used) '版本变化必须立即失效'

    $forged = $read.cache | ConvertTo-Json -Depth 12 | ConvertFrom-Json
    $forged.authorization.participates = $true; $forged.authorization.trusted = $true
    $forged.entries[0] | Add-Member -NotePropertyName authorization -NotePropertyValue ([pscustomobject]@{ allowWrite = $true })
    $forged.entries[0] | Add-Member -NotePropertyName l2 -NotePropertyValue 'eligible'
    $forged.entries[0].observations | Add-Member -NotePropertyName domText -NotePropertyValue $privateMarker
    $forged.entries += [pscustomobject]@{ key = 'bad'; secret = $privateMarker }
    [IO.File]::WriteAllText($cachePath, ($forged | ConvertTo-Json -Depth 12), [Text.UTF8Encoding]::new($false))
    $normalized = Read-CapabilityCacheDocument $cachePath
    $normalizedRaw = $normalized | ConvertTo-Json -Depth 12
    Assert-Contract ([string]$normalized.status -eq 'valid-with-invalid-entries' -and [int]$normalized.invalidEntries -eq 1) '无效 entry 应被忽略并计数'
    Assert-Contract (-not [bool]$normalized.cache.authorization.participates -and -not [bool]$normalized.cache.authorization.trusted) '伪造根授权必须被重置'
    Assert-Contract (-not $normalizedRaw.Contains($privateMarker, [StringComparison]::OrdinalIgnoreCase) -and $normalizedRaw -notmatch 'allowWrite|"l2"|domText') '规范化读不得传播未知或敏感字段'

    $extendedExpiry = $read.cache | ConvertTo-Json -Depth 12 | ConvertFrom-Json
    $extendedExpiry.entries[0].expiresAt = $now.AddYears(5).ToString('o')
    [IO.File]::WriteAllText($cachePath, ($extendedExpiry | ConvertTo-Json -Depth 12), [Text.UTF8Encoding]::new($false))
    $extendedRead = Read-CapabilityCacheDocument $cachePath
    Assert-Contract ([string]$extendedRead.status -eq 'valid-with-invalid-entries' -and @($extendedRead.cache.entries).Count -eq 0) '伪造远期 expiresAt 不得延长 30 天保留期'

    $futureEntry = $read.cache | ConvertTo-Json -Depth 12 | ConvertFrom-Json
    $futureEntry.entries[0].observedAt = $now.AddMinutes(6).ToString('o')
    $futureEntry.entries[0].expiresAt = $now.AddDays(30).AddMinutes(6).ToString('o')
    [IO.File]::WriteAllText($cachePath, ($futureEntry | ConvertTo-Json -Depth 12), [Text.UTF8Encoding]::new($false))
    $futureRead = Read-CapabilityCacheDocument $cachePath
    Assert-Contract ([string]$futureRead.status -eq 'valid-with-invalid-entries' -and @($futureRead.cache.entries).Count -eq 0) '未来 observedAt 的磁盘 entry 必须被忽略'

    [void](Remove-CapabilityCacheFile $cachePath)
    [IO.File]::WriteAllText($probePath, ($probe | ConvertTo-Json -Depth 12), [Text.UTF8Encoding]::new($false))
    $record = Invoke-Win @('cache','record',$probePath,'--json','--summary')
    Assert-Contract ($record.exitCode -eq 0 -and -not $record.stderr) 'cache record 应成功且 stderr 为空'
    $recordReport = $record.stdout | ConvertFrom-Json
    Assert-Contract ([string]$recordReport.schema -eq 'win-use-master/capability-cache-operation-v1' -and [string]$recordReport.status -eq 'completed') 'record 操作 schema/status 不匹配'
    Assert-Contract ($null -eq $recordReport.key -and -not $record.stdout.Contains($privateMarker, [StringComparison]::OrdinalIgnoreCase)) 'record summary 不得回显 key 或输入隐私'

    $beforeHash = (Get-FileHash -LiteralPath $cachePath -Algorithm SHA256).Hash
    $beforeWrite = (Get-Item -LiteralPath $cachePath).LastWriteTimeUtc
    Start-Sleep -Milliseconds 50
    $show = Invoke-Win @('cache','show','--json','--summary')
    Assert-Contract ($show.exitCode -eq 0 -and -not $show.stderr) 'cache show summary 应成功'
    $showReport = $show.stdout | ConvertFrom-Json
    Assert-Contract ([string]$showReport.schema -eq 'win-use-master/capability-cache-view-v1' -and [int]$showReport.counts.fresh -eq 1) 'show view schema/count 不匹配'
    Assert-Contract (@($showReport.entries).Count -eq 0 -and -not [bool]$showReport.privacy.identityIncluded) 'summary 不得包含 entry 身份'
    Assert-Contract (-not [bool]$showReport.authorization.participates -and -not [bool]$showReport.authorization.trusted) 'view 必须明确不参与授权'
    Assert-Contract ((Get-FileHash -LiteralPath $cachePath -Algorithm SHA256).Hash -eq $beforeHash -and (Get-Item -LiteralPath $cachePath).LastWriteTimeUtc -eq $beforeWrite) 'show 必须零写入'

    $env:WIN_USE_MASTER_CAPABILITY_CACHE = '0'
    $disabled = Invoke-Win @('cache','show','--json','--summary')
    Assert-Contract ($disabled.exitCode -eq 0 -and [string](($disabled.stdout | ConvertFrom-Json).status) -eq 'disabled') '环境变量应完全禁用 cache 读取'
    $disabledRecord = Invoke-Win @('cache','record',$probePath,'--json','--summary')
    Assert-Contract ($disabledRecord.exitCode -eq 2) '禁用时 record 必须安全拒绝'
    Assert-Contract ((Get-FileHash -LiteralPath $cachePath -Algorithm SHA256).Hash -eq $beforeHash) '禁用时不得修改 cache'
    Remove-Item Env:\WIN_USE_MASTER_CAPABILITY_CACHE -ErrorAction SilentlyContinue

    $env:WIN_USE_MASTER_CDP_SESSION = Join-Path $tempDir 'missing-session.json'
    $cdpWrite = Invoke-Process (Get-Command node -ErrorAction Stop).Source @($cdp,'65534','click','fixture-target','#safe')
    Assert-Contract ($cdpWrite.exitCode -eq 2 -and $cdpWrite.stderr -match '有效授权会话') '伪造 capability cache 不得绕过 CDP session 授权'
    $cdpSource = Get-Content -LiteralPath $cdp -Raw -Encoding utf8
    Assert-Contract ($cdpSource -notmatch 'capability-cache|CapabilityCache') 'CDP 写入口不得加载能力缓存'

    $unknownKey = '0' * 64
    $unknown = Invoke-Win @('cache','clear',$unknownKey,'--json','--summary')
    Assert-Contract ($unknown.exitCode -eq 1 -and (Test-Path -LiteralPath $cachePath -PathType Leaf)) '未知 key 不得删除 cache'
    $clear = Invoke-Win @('cache','clear','--all','--json','--summary')
    Assert-Contract ($clear.exitCode -eq 0 -and -not (Test-Path -LiteralPath $cachePath)) 'clear --all 应只删除精确 cache 文件'

    $victim = Join-Path $tempDir 'unsafe.json'
    [IO.File]::WriteAllText($victim, 'keep', [Text.UTF8Encoding]::new($false))
    Remove-Item Env:\WIN_USE_MASTER_CAPABILITY_CACHE_TEST -ErrorAction SilentlyContinue
    $env:WIN_USE_MASTER_CAPABILITY_CACHE_PATH = $victim
    $unsafe = Invoke-Win @('cache','clear','--all')
    Assert-Contract ($unsafe.exitCode -eq 2 -and [IO.File]::Exists($victim)) '未启用测试边界时自定义删除路径必须拒绝且保留文件'

    $noCacheProbe = Invoke-Process (Get-Command pwsh -ErrorAction Stop).Source @(
        '-NoProfile','-File',$probeScript,(Get-Command pwsh -ErrorAction Stop).Source,'--json','--summary','--no-cache'
    )
    Assert-Contract ($noCacheProbe.exitCode -eq 0 -and -not $noCacheProbe.stderr) 'probe --no-cache 应在不读取无效 override 的情况下成功'
    $noCacheReport = $noCacheProbe.stdout | ConvertFrom-Json
    Assert-Contract ([string]$noCacheReport.status -eq 'resolved' -and [string]$noCacheReport.cache.status -eq 'disabled' -and -not [bool]$noCacheReport.cache.used) '--no-cache 必须保留实时 probe 并禁用缓存提示'

    Write-Output 'PASS: advisory cache privacy, TTL/version invalidation, explicit mutation, zero-write show and no authorization bypass'
}
finally {
    if ($savedTest) { $env:WIN_USE_MASTER_CAPABILITY_CACHE_TEST = $savedTest } else { Remove-Item Env:\WIN_USE_MASTER_CAPABILITY_CACHE_TEST -ErrorAction SilentlyContinue }
    if ($savedPath) { $env:WIN_USE_MASTER_CAPABILITY_CACHE_PATH = $savedPath } else { Remove-Item Env:\WIN_USE_MASTER_CAPABILITY_CACHE_PATH -ErrorAction SilentlyContinue }
    if ($savedEnabled) { $env:WIN_USE_MASTER_CAPABILITY_CACHE = $savedEnabled } else { Remove-Item Env:\WIN_USE_MASTER_CAPABILITY_CACHE -ErrorAction SilentlyContinue }
    if ($savedSession) { $env:WIN_USE_MASTER_CDP_SESSION = $savedSession } else { Remove-Item Env:\WIN_USE_MASTER_CDP_SESSION -ErrorAction SilentlyContinue }
    $resolved = [IO.Path]::GetFullPath($tempDir)
    $parent = [IO.Path]::GetDirectoryName($resolved).TrimEnd('\')
    $leaf = [IO.Path]::GetFileName($resolved)
    if ($parent -ieq $tempBase -and $leaf -match '^win-use-master-capability-cache-test-[0-9a-f]{32}$') {
        if ([IO.Directory]::Exists($resolved)) { [IO.Directory]::Delete($resolved, $true) }
    } else { throw "拒绝清理未通过边界检查的测试目录：$resolved" }
}
