Set-StrictMode -Version 2.0

function New-WinDoctorCheck(
    [string] $Id,
    [string] $Area,
    [bool] $Required,
    [string] $Status,
    [string] $Code,
    [string] $Summary
) {
    [pscustomobject][ordered]@{
        id       = $Id
        area     = $Area
        required = $Required
        status   = $Status
        code     = $Code
        summary  = $Summary
    }
}

function New-WinDoctorReport {
    param(
        [Parameter(Mandatory = $true)] $Facts,
        [datetime] $GeneratedAtUtc = [DateTime]::UtcNow
    )

    $checks = [Collections.Generic.List[object]]::new()
    $recommendations = [Collections.Generic.List[object]]::new()

    $platformReady = [bool]$Facts.platform.isWindows
    $checks.Add((New-WinDoctorCheck 'platform-windows' 'runtime' $true $(if ($platformReady) { 'pass' } else { 'fail' }) $(if ($platformReady) { 'windows' } else { 'windows-required' }) $(if ($platformReady) { 'Windows runtime detected' } else { 'Windows is required' })))

    $powerShellReady = [int]$Facts.powershell.major -ge 7
    $checks.Add((New-WinDoctorCheck 'powershell-version' 'runtime' $true $(if ($powerShellReady) { 'pass' } else { 'fail' }) $(if ($powerShellReady) { 'supported' } else { 'powershell-7-required' }) "PowerShell $($Facts.powershell.version) ($($Facts.powershell.edition))"))
    if (-not $powerShellReady) {
        $recommendations.Add([pscustomobject][ordered]@{ code = 'install-powershell-7'; text = '安装 PowerShell 7，并使用 pwsh 重新运行 doctor。' })
    }

    $policyBlocked = [string]$Facts.powershell.executionPolicy -eq 'Restricted'
    $checks.Add((New-WinDoctorCheck 'execution-policy' 'runtime' $true $(if ($policyBlocked) { 'fail' } else { 'pass' }) $(if ($policyBlocked) { 'execution-policy-restricted' } else { 'execution-policy-compatible' }) "Effective policy: $($Facts.powershell.executionPolicy)"))
    if ($policyBlocked) {
        $recommendations.Add([pscustomobject][ordered]@{ code = 'review-execution-policy'; text = '按组织策略设置允许本地或已签名脚本的 Execution Policy；不要全局关闭安全策略。' })
    }

    $sourceReady = [bool]$Facts.helper.sourceExists
    $checks.Add((New-WinDoctorCheck 'helper-source' 'helper' $true $(if ($sourceReady) { 'pass' } else { 'fail' }) $(if ($sourceReady) { 'source-readable' } else { 'helper-source-missing' }) $(if ($sourceReady) { 'HuWin.cs is readable' } else { 'HuWin.cs is missing' })))

    $helperReady = [bool]$Facts.helper.ready
    $helperStatus = [string]$Facts.helper.status
    $checks.Add((New-WinDoctorCheck 'helper-binary' 'helper' $true $(if ($helperReady) { 'pass' } else { 'fail' }) $helperStatus "Helper status: $helperStatus"))
    if (-not $helperReady -and $sourceReady) {
        $recommendations.Add([pscustomobject][ordered]@{ code = 'build-helper'; text = '运行：pwsh -NoProfile -File "$SKILL_DIR\scripts\build.ps1"' })
    }

    $compilerReady = [bool]$Facts.helper.compilerAvailable
    $compilerRequired = -not $helperReady
    $checks.Add((New-WinDoctorCheck 'helper-compiler' 'helper' $compilerRequired $(if ($compilerReady) { 'pass' } elseif ($compilerRequired) { 'fail' } else { 'warn' }) $(if ($compilerReady) { 'compiler-available' } else { 'compiler-unavailable' }) $(if ($compilerReady) { 'C# build prerequisites are discoverable' } else { 'C# build prerequisites were not found' })))

    $riskReady = [bool]$Facts.contracts.riskPolicyValid
    $checks.Add((New-WinDoctorCheck 'risk-policy' 'contracts' $true $(if ($riskReady) { 'pass' } else { 'fail' }) $(if ($riskReady) { 'risk-policy-valid' } else { 'risk-policy-invalid' }) "Risk policy: $($Facts.contracts.riskPolicySchema)"))

    $receiptsReady = [bool]$Facts.contracts.receiptSchemasReadable
    $checks.Add((New-WinDoctorCheck 'receipt-schemas' 'contracts' $true $(if ($receiptsReady) { 'pass' } else { 'fail' }) $(if ($receiptsReady) { 'receipt-schemas-readable' } else { 'receipt-schemas-unreadable' }) "Receipt schemas discovered: $(@($Facts.contracts.receiptSchemas).Count)"))

    $nodeReady = [bool]$Facts.node.supported
    $nodeStatus = if (-not [bool]$Facts.node.installed) { 'node-missing' } elseif (-not $nodeReady) { 'node-version-unsupported' } else { 'node-supported' }
    $checks.Add((New-WinDoctorCheck 'node-cdp' 'cdp' $false $(if ($nodeReady) { 'pass' } else { 'warn' }) $nodeStatus $(if ($Facts.node.installed) { "Node.js $($Facts.node.version)" } else { 'Node.js was not found' })))
    if (-not $nodeReady) {
        $recommendations.Add([pscustomobject][ordered]@{ code = 'install-node-22'; text = '仅在需要 CDP 时安装 Node.js 22 或更新版本。' })
    }

    $browserReady = @($Facts.browser.discovered).Count -gt 0
    $checks.Add((New-WinDoctorCheck 'chromium-cdp' 'cdp' $false $(if ($browserReady) { 'pass' } else { 'warn' }) $(if ($browserReady) { 'chromium-found' } else { 'chromium-not-found' }) "Chromium executables discovered: $(@($Facts.browser.discovered).Count)"))
    if (-not $browserReady) {
        $recommendations.Add([pscustomobject][ordered]@{ code = 'install-chromium'; text = '仅在需要浏览器 CDP 测试时安装 Edge、Chrome 或 Chromium。' })
    }

    $desktopState = [string]$Facts.desktop.inputDesktop
    $desktopReady = $desktopState -eq 'interactive'
    $desktopCheckStatus = if ($desktopReady) { 'pass' } elseif ($desktopState -eq 'unknown') { 'unknown' } else { 'blocked' }
    $checks.Add((New-WinDoctorCheck 'input-desktop' 'desktop' $false $desktopCheckStatus $desktopState "Input desktop: $desktopState"))

    $integrityKnown = [string]$Facts.desktop.integrityName -ne 'unknown'
    $checks.Add((New-WinDoctorCheck 'self-integrity' 'desktop' $false $(if ($integrityKnown) { 'pass' } else { 'unknown' }) $(if ($integrityKnown) { 'integrity-known' } else { 'integrity-unknown' }) "Current integrity: $($Facts.desktop.integrityName)"))
    if (-not $desktopReady) {
        $recommendations.Add([pscustomobject][ordered]@{ code = 'interactive-desktop-required'; text = '运行 UIA、截图或坐标测试前，先解锁 Windows 并切回活动交互桌面。' })
    }

    $tempExists = [bool]$Facts.temporaryStorage.directoryExists
    $tempStatus = [string]$Facts.temporaryStorage.writeStatus
    $checks.Add((New-WinDoctorCheck 'temporary-storage' 'storage' $false $(if (-not $tempExists) { 'warn' } elseif ($tempStatus -eq 'writable') { 'pass' } else { 'unknown' }) $(if (-not $tempExists) { 'temp-directory-missing' } elseif ($tempStatus -eq 'writable') { 'temp-writable' } else { 'temp-write-not-probed' }) $(if (-not $tempExists) { 'Temporary directory is unavailable' } else { 'Write access was not exercised by read-only doctor' })))

    $historicalCount = [int]$Facts.temporaryStorage.historicalCandidates
    $manifestCount = [int]$Facts.temporaryStorage.validManifestHistorical
    $expiredSessions = [int]$Facts.temporaryStorage.expiredSessions
    $leftoverStatus = if ($historicalCount -gt 0 -or $expiredSessions -gt 0) { 'warn' } else { 'pass' }
    $checks.Add((New-WinDoctorCheck 'historical-artifacts' 'storage' $false $leftoverStatus $(if ($leftoverStatus -eq 'warn') { 'historical-artifacts-found' } else { 'no-historical-artifacts' }) "Historical candidates: $historicalCount; valid manifests: $manifestCount; expired CDP sessions: $expiredSessions"))
    if ($leftoverStatus -eq 'warn') {
        $recommendations.Add([pscustomobject][ordered]@{ code = 'review-historical-artifacts'; text = '人工复核历史对象计数；doctor 不会删除任何内容，只有同名前缀也不能证明可安全清理。' })
    }

    $requiredFailures = @($checks | Where-Object { $_.required -and $_.status -eq 'fail' })
    $requiredUnknown = @($checks | Where-Object { $_.required -and $_.status -in @('unknown', 'blocked') })
    $coreReady = $requiredFailures.Count -eq 0 -and $requiredUnknown.Count -eq 0
    $exitCode = if ($requiredFailures.Count) { 1 } elseif ($requiredUnknown.Count) { 2 } else { 0 }
    $overallStatus = if ($coreReady) { 'ready' } elseif ($requiredFailures.Count) { 'limited' } else { 'unknown' }
    $cdpReady = $coreReady -and $nodeReady -and $browserReady

    $contractReady = $platformReady -and $powerShellReady -and -not $policyBlocked -and $sourceReady -and $compilerReady -and $riskReady -and $receiptsReady -and $nodeReady -and $browserReady
    $desktopTestReady = $coreReady -and $desktopReady
    $coordinateStatus = if (-not $desktopTestReady -or -not $integrityKnown) { 'blocked' } else { 'manual-required' }

    [pscustomobject][ordered]@{
        schema         = 'win-use-master/doctor-report-v1'
        generatedAt    = $GeneratedAtUtc.ToString('o')
        status         = $overallStatus
        exitCode       = $exitCode
        readOnly       = $true
        capabilities   = [pscustomobject][ordered]@{
            core       = $(if ($coreReady) { 'ready' } else { 'limited' })
            cdp        = $(if ($cdpReady) { 'ready' } else { 'unavailable' })
            desktopRead = $(if ($desktopTestReady) { 'ready' } else { 'blocked' })
            coordinateWrite = $coordinateStatus
        }
        environment    = [pscustomobject][ordered]@{
            platform = $Facts.platform
            powershell = $Facts.powershell
            helper = $Facts.helper
            node = $Facts.node
            browser = $Facts.browser
            contracts = $Facts.contracts
            desktop = $Facts.desktop
            temporaryStorage = $Facts.temporaryStorage
        }
        tests          = @(
            [pscustomobject][ordered]@{ tier = 'Contract'; status = $(if ($contractReady) { 'ready' } else { 'unavailable' }); writesInput = $false; requiresDesktop = $false }
            [pscustomobject][ordered]@{ tier = 'Desktop'; status = $(if ($desktopTestReady) { 'ready' } else { 'blocked' }); writesInput = $true; requiresDesktop = $true }
            [pscustomobject][ordered]@{ tier = 'Coordinate'; status = $coordinateStatus; writesInput = $true; requiresDesktop = $true }
            [pscustomobject][ordered]@{ tier = 'Profiles'; status = 'manual-required'; writesInput = $true; requiresDesktop = $true }
        )
        checks         = @($checks)
        recommendations = @($recommendations)
        privacy        = [pscustomobject][ordered]@{
            absolutePathsIncluded = $false
            windowTitlesIncluded  = $false
            contentIncluded       = $false
        }
        sideEffects    = [pscustomobject][ordered]@{
            applicationsStarted = 0
            filesWritten        = 0
            filesDeleted        = 0
            helperCompiled      = $false
            repairsApplied      = 0
        }
    }
}

function Format-WinDoctorReport {
    param(
        [Parameter(Mandatory = $true)] $Report,
        [switch] $Summary
    )

    $warningCount = @($Report.checks | Where-Object { $_.status -in @('warn', 'unknown', 'blocked') }).Count
    if ($Summary) {
        $tests = @($Report.tests | ForEach-Object { "$($_.tier.ToLowerInvariant())=$($_.status)" }) -join ','
        return "doctor: status=$($Report.status) exit=$($Report.exitCode) core=$($Report.capabilities.core) cdp=$($Report.capabilities.cdp) desktop=$($Report.environment.desktop.inputDesktop) helper=$($Report.environment.helper.status) tests($tests) warnings=$warningCount readOnly=true"
    }

    $browserText = if (@($Report.environment.browser.discovered).Count) {
        @($Report.environment.browser.discovered | ForEach-Object { "$($_.name)@$($_.source)" }) -join ', '
    } else { 'none' }
    $testText = @($Report.tests | ForEach-Object { "$($_.tier)=$($_.status)" }) -join ', '
    $lines = [Collections.Generic.List[string]]::new()
    $lines.Add('win-use-master doctor（只读）')
    $lines.Add("状态: $($Report.status)（exit=$($Report.exitCode)） core=$($Report.capabilities.core) cdp=$($Report.capabilities.cdp)")
    $lines.Add("PowerShell: $($Report.environment.powershell.version) $($Report.environment.powershell.edition)，policy=$($Report.environment.powershell.executionPolicy)")
    $lines.Add("Helper: $($Report.environment.helper.status)，compiler=$(if ($Report.environment.helper.compilerAvailable) { 'available' } else { 'unavailable' })，未自动编译")
    $lines.Add("Node/CDP: $(if ($Report.environment.node.installed) { $Report.environment.node.version } else { 'not-found (optional)' })；Chromium: $browserText")
    $lines.Add("Contracts: risk=$($Report.environment.contracts.riskPolicySchema)，receipt-schemas=$(@($Report.environment.contracts.receiptSchemas).Count)")
    $lines.Add("Desktop: $($Report.environment.desktop.inputDesktop)，integrity=$($Report.environment.desktop.integrityName)，coordinate=$($Report.capabilities.coordinateWrite)")
    $lines.Add("Temp: exists=$($Report.environment.temporaryStorage.directoryExists)，writable=$($Report.environment.temporaryStorage.writeStatus)（只读模式未写入探测），historical=$($Report.environment.temporaryStorage.historicalCandidates)，valid-manifest=$($Report.environment.temporaryStorage.validManifestHistorical)，expired-sessions=$($Report.environment.temporaryStorage.expiredSessions)")
    $lines.Add("Tests: $testText")
    foreach ($item in @($Report.recommendations)) { $lines.Add("建议[$($item.code)]: $($item.text)") }
    $lines.Add("边界: apps-started=0 files-written=0 files-deleted=0 helper-compiled=false；不输出绝对路径、窗口标题或内容。warnings=$warningCount")
    return $lines -join "`n"
}
