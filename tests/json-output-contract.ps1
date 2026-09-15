# Machine-readable output contract. Pure report builders use synthetic objects;
# read-only dispatchers, fail-closed options, and local CDP HTTP discovery run end-to-end.
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version 2.0

$root = Split-Path -Parent $PSScriptRoot
$winPath = Join-Path $root 'scripts\win.ps1'
$tokens = $null; $errors = $null
$ast = [Management.Automation.Language.Parser]::ParseFile($winPath, [ref]$tokens, [ref]$errors)
if ($errors.Count) { throw 'Cannot parse scripts/win.ps1' }

foreach ($name in @(
    'Format-Hwnd', 'Get-HuWindowState', 'ConvertTo-HuWindowRecord', 'Format-HuWindowSummary',
    'Get-HuTypeCounts', 'New-HuWindowsReport', 'New-HuFrontmostReport', 'New-HuIdleReport',
    'ConvertTo-HuUiaActionRecord', 'ConvertTo-HuUiaReadableRecord',
    'New-HuUiaElementsReport', 'New-HuUiaReadReport', 'New-HuWindowStateReport', 'ConvertTo-HuJson'
)) {
    $definitions = @($ast.FindAll({ param($node)
        $node -is [Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -eq $name
    }, $true))
    if ($definitions.Count -ne 1) { throw "Expected one $name definition" }
    . ([scriptblock]::Create($definitions[0].Extent.Text))
}

$probePath = Join-Path $root 'scripts\probe.ps1'
$probeTokens = $null; $probeErrors = $null
$probeAst = [Management.Automation.Language.Parser]::ParseFile($probePath, [ref]$probeTokens, [ref]$probeErrors)
if ($probeErrors.Count) { throw 'Cannot parse scripts/probe.ps1' }
foreach ($name in @('New-ProbeCacheState', 'ConvertTo-ProbeWindowRecord', 'New-ProbeReport', 'ConvertTo-ProbeJson', 'Format-ProbeSummary')) {
    $definitions = @($probeAst.FindAll({ param($node)
        $node -is [Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -eq $name
    }, $true))
    if ($definitions.Count -ne 1) { throw "Expected one $name definition" }
    . ([scriptblock]::Create($definitions[0].Extent.Text))
}

$script:IdleThresholdSeconds = 2.0
$script:IdleWaitSeconds = 15.0
function Assert-Contract([bool] $Condition, [string] $Message) {
    if (-not $Condition) { throw "JSON output contract: $Message" }
}
function New-TestWindow([long] $Hwnd = 4660, [string] $Title = 'private-marker-window') {
    return [pscustomobject]@{
        Hwnd = $Hwnd; Pid = [uint32]4321; Owner = 'FixtureApp'; Title = $Title; Cls = 'FixtureClass'
        L = -20; T = 30; R = 780; B = 630; W = 800; H = 600
        Visible = $true; Iconic = $false; Zoomed = $false; Cloaked = $false; Tool = $false; Hung = $false
    }
}

$window = New-TestWindow
$fullWindows = New-HuWindowsReport @($window) 2 3 $true $false $false $false
$summaryWindows = New-HuWindowsReport @($window) 2 3 $true $false $false $true
$fullWindowsJson = ConvertTo-HuJson $fullWindows
$summaryWindowsJson = ConvertTo-HuJson $summaryWindows
Assert-Contract ($fullWindows.schema -eq 'win-use-master/windows-result-v1' -and $fullWindows.windows[0].title -eq 'private-marker-window') 'full windows schema/title missing'
Assert-Contract ($summaryWindows.windows[0].PSObject.Properties.Name -contains 'title' -and $summaryWindows.windows[0].title -eq $null -and -not $summaryWindowsJson.Contains('private-marker-window')) 'summary windows must retain a null title without leaking it'
Assert-Contract ($summaryWindows.query.filterApplied -and -not $summaryWindows.query.filterValueIncluded -and $summaryWindows.counts.hidden -eq 2) 'windows query/count metadata incorrect'

$resolved = New-HuFrontmostReport $window.Hwnd $window $true
$unlisted = New-HuFrontmostReport 9999 $null $true
$none = New-HuFrontmostReport 0 $null $true
Assert-Contract ($resolved.schema -eq 'win-use-master/frontmost-result-v1' -and $resolved.status -eq 'resolved' -and $resolved.window.title -eq $null) 'resolved frontmost summary incorrect'
Assert-Contract ($unlisted.status -eq 'unlisted' -and $null -eq $unlisted.window -and $unlisted.foregroundHwnd -eq '0x270F') 'unlisted frontmost must remain explicit'
Assert-Contract ($none.status -eq 'none' -and $null -eq $none.foregroundHwnd) 'zero foreground must be none/null'

$unknownIdle = New-HuIdleReport -1 -1 9999 $null $true
$presentIdle = New-HuIdleReport 0.5 0.5 $window.Hwnd $window $true
$syntheticIdle = New-HuIdleReport 3600 0.5 $window.Hwnd $window $true
Assert-Contract ($unknownIdle.status -eq 'unknown' -and $null -eq $unknownIdle.idle.seconds -and $unknownIdle.presence -eq 'unknown' -and $unknownIdle.coordinateGate.status -eq 'unknown') 'unknown idle was coerced to false/zero'
Assert-Contract ($unknownIdle.idle.PSObject.Properties.Name -contains 'seconds') 'unknown idle omitted its null seconds field'
Assert-Contract ($presentIdle.presence -eq 'present' -and $presentIdle.coordinateGate.status -eq 'wait') 'present-user gate mapping incorrect'
Assert-Contract ($syntheticIdle.idle.source -eq 'synthetic-input-trail' -and $syntheticIdle.presence -eq 'idle') 'synthetic trail mapping incorrect'

$stateFull = New-HuWindowStateReport 'minimize' $window $window 16 16 'unchanged' 'completed' $false $false
$stateSummary = New-HuWindowStateReport 'restore' $window $window $null $null 'not-observed' 'planned' $true $true
$statePartial = New-HuWindowStateReport 'restore' $window $window 16 $window.Hwnd 'unexpected-target' 'partial' $true $false
Assert-Contract ($stateFull.schema -eq 'win-use-master/window-state-result-v1' -and $stateFull.status -eq 'completed' -and $stateFull.effect -eq 'unchanged') 'window state completed result incorrect'
Assert-Contract ($stateSummary.status -eq 'planned' -and $stateSummary.effect -eq 'not-applied' -and $stateSummary.before.title -eq $null -and $stateSummary.focus.before -eq $null) 'window state dry summary incorrect'
Assert-Contract ($statePartial.status -eq 'partial' -and $statePartial.effect -eq 'partial' -and $statePartial.focus.transition -eq 'unexpected-target') 'window state partial result lost'

$probeFacts = [ordered]@{
    Warnings = @('private-marker-warning')
    Target = [pscustomobject]@{ Source = 'fixture'; DisplayName = 'private-marker-app'; PackageFamily = 'private-marker-package'; AppId = 'private-marker-appid' }
    InstallRoot = 'C:\Users\private-marker\App'; ExecutablePath = 'C:\Users\private-marker\App\fixture.exe'
    Versions = @('1.2.3'); Architecture = 'x64 (0x8664)'; PrimaryPids = @(4321); RelatedPids = @(4321)
    Processes = @([pscustomobject]@{ Pid = 4321; ParentPid = 1; Name = 'fixture.exe'; Path = 'C:\Users\private-marker\App\fixture.exe' })
    Signals = @([pscustomobject]@{ Family = 'Electron'; Strength = 'strong'; Evidence = 'private-marker-signal' })
    CdpResults = @([pscustomobject]@{
        PortInfo = [pscustomobject]@{ Address = '127.0.0.1'; Port = 9333; Pid = 4321 }
        Probe = [pscustomobject]@{ IsCdp = $true; HttpStatus = 200; Browser = 'private-marker-browser'; WebSocket = 'ws://private-marker/devtools' }
    })
    Protocols = @([pscustomobject]@{ Scheme = 'fixture'; Source = 'registry'; Detail = 'private-marker-protocol' })
    Com = [pscustomobject]@{
        Servers = @([pscustomobject]@{ ProgId = 'Fixture.App'; VersionIndependentProgId = ''; Clsid = '{fixture}'; Kind = 'LocalServer32'; Server = 'private-marker-server' })
        TypeLibs = @([pscustomobject]@{ Guid = '{typelib}'; Version = '1.0'; Description = 'fixture'; Platform = 'win64'; File = 'private-marker-typelib' })
    }
    Windows = @($window)
    Uia = [pscustomobject]@{ Available = $true; TimedOut = $false; Total = 5; Editable = 1; Actionable = 2; Focusable = 3; Offscreen = 0 }
    Capabilities = [ordered]@{ L0 = 'cdp'; L1 = 'available'; L2 = 'eligible'; L3 = 'available' }
}
$probeFull = New-ProbeReport $probeFacts $true $false
$probeSummary = New-ProbeReport $probeFacts $true $true
$probeSummaryJson = ConvertTo-ProbeJson $probeSummary
$probeMissing = New-ProbeReport ([ordered]@{ Warnings = @() }) $false $true
Assert-Contract ($probeFull.schema -eq 'win-use-master/probe-report-v1' -and $probeFull.status -eq 'resolved' -and $probeFull.target.displayName -eq 'private-marker-app') 'full probe report missing identity'
Assert-Contract ($probeSummary.target.displayName -eq $null -and $probeSummary.runtime.processes.Count -eq 0 -and $probeSummary.windows.items.Count -eq 0 -and $probeSummary.warnings.items.Count -eq 0) 'probe summary did not redact detail collections'
Assert-Contract (-not $probeSummaryJson.Contains('private-marker') -and $probeSummary.interfaces.cdp.status -eq 'available' -and $probeSummary.capabilities.l0 -eq 'cdp') 'probe summary leaked detail or lost capabilities'
Assert-Contract ($probeMissing.status -eq 'not-found' -and $probeMissing.target -eq $null -and $probeMissing.runtime.status -eq 'unknown') 'not-found probe must preserve null/unknown'

$actionElement = [pscustomobject]@{
    Ref = 'e1'; ControlType = 'Edit'; Name = 'private-marker-action-name'; AutomationId = 'private-marker-action-id'
    ClassName = 'EditClass'; Value = 'private-marker-action-value'; X = 10; Y = 20; Width = 100; Height = 30
    Cx = 60; Cy = 35; Enabled = $true; Offscreen = $false; IsPassword = $false; Patterns = @('ValuePattern')
}
$uiaFull = New-HuUiaElementsReport $window @($actionElement) 1 $false
$uiaSummary = New-HuUiaElementsReport $window @($actionElement) 1 $true
Assert-Contract ($uiaFull.schema -eq 'win-use-master/uia-elements-result-v1' -and $uiaFull.items[0].value -eq 'private-marker-action-value') 'full UIA item missing'
Assert-Contract ($uiaSummary.items.Count -eq 0 -and $uiaSummary.counts.returned -eq 1 -and $uiaSummary.typeCounts[0].controlType -eq 'Edit') 'summary UIA counts/types incorrect'
$uiaSummaryJson = ConvertTo-HuJson $uiaSummary
Assert-Contract (-not $uiaSummaryJson.Contains('private-marker') -and $uiaSummaryJson -match '"items"\s*:\s*\[\]') 'summary UIA must serialize items as an empty array without leaking content'

$readElement = [pscustomobject]@{
    ControlType = 'Text'; Name = 'private-marker-read-name'; AutomationId = 'private-marker-read-id'
    Value = 'private-marker-read-value'; IsPassword = $false; Offscreen = $false
}
$options = [pscustomobject]@{
    Structured = $true; ExactId = ''; Filter = ''; Limit = 2; LimitExplicit = $true
    Continuation = 'opaque-cursor'
    Query = [pscustomobject]@{
        idExact = ''; idPrefix = 'private-marker-query'; controlType = 'Text'
        nameExact = ''; namePrefix = ''; withinId = ''
    }
}
$page = [pscustomobject]@{
    schema = 'win-use-master/uia-page-v1'; offset = 2; nextOffset = 4; matched = 5
    returned = 2; hasMore = $true; continuation = 'next-opaque-cursor'
}
$readSummary = New-HuUiaReadReport $window @($readElement) $options $page $true
$readSummaryJson = ConvertTo-HuJson $readSummary
Assert-Contract ($readSummary.schema -eq 'win-use-master/uia-read-result-v1' -and $readSummary.query.mode -eq 'structured') 'UIA read schema/mode incorrect'
Assert-Contract ($readSummary.query.criteria.idPrefix -and -not $readSummary.query.valuesIncluded -and $readSummary.page.hasMore) 'UIA read query/page metadata incorrect'
Assert-Contract ($readSummary.items.Count -eq 0 -and -not $readSummaryJson.Contains('private-marker') -and $readSummaryJson -match '"items"\s*:\s*\[\]') 'UIA read summary leaked content or lost the empty-array contract'
Assert-Contract (($readSummaryJson | ConvertFrom-Json).page.continuation -eq 'next-opaque-cursor') 'JSON serialization lost continuation'

foreach ($case in @(
    @{ Name = 'windows'; Args = @('private-marker-filter', '--json', '--summary'); Schema = 'win-use-master/windows-result-v1' },
    @{ Name = 'frontmost'; Args = @('--json', '--summary'); Schema = 'win-use-master/frontmost-result-v1' },
    @{ Name = 'idle'; Args = @('--json', '--summary'); Schema = 'win-use-master/idle-result-v1' }
)) {
    $output = @(& pwsh -NoLogo -NoProfile -File $winPath $case.Name @($case.Args) 2>&1)
    if ($LASTEXITCODE -ne 0) { throw "$($case.Name) summary JSON failed: $($output -join ' ')" }
    $raw = $output -join "`n"
    try { $actual = $raw | ConvertFrom-Json } catch { throw "$($case.Name) did not emit one JSON document" }
    Assert-Contract ($actual.schema -eq $case.Schema) "$($case.Name) schema mismatch"
    Assert-Contract (-not $raw.Contains('private-marker')) "$($case.Name) echoed a title/filter in summary JSON"
    if ($case.Name -eq 'windows') {
        Assert-Contract ($actual.query.filterApplied -and -not $actual.query.filterValueIncluded) 'windows filter privacy flags missing'
        Assert-Contract ($raw -match '"windows"\s*:\s*\[\]') 'empty windows result must serialize as an array'
    }
}

foreach ($case in @(
    @{ Name = 'windows'; Args = @('--json', '--summmary') },
    @{ Name = 'frontmost'; Args = @('--json', '--summmary') },
    @{ Name = 'idle'; Args = @('--json', '--summmary') }
)) {
    $output = @(& pwsh -NoLogo -NoProfile -File $winPath $case.Name @($case.Args) 2>&1)
    Assert-Contract ($LASTEXITCODE -eq 2) "$($case.Name) misspelled summary must be refused"
    Assert-Contract (-not ($output -join "`n").Contains('private-marker-window')) "$($case.Name) refusal leaked fixture title"
}

$probeMarker = 'private-marker-probe-' + [Guid]::NewGuid().ToString('N')
$probeOutput = @(& pwsh -NoLogo -NoProfile -File $probePath $probeMarker --json --summary 2>&1)
Assert-Contract ($LASTEXITCODE -eq 1) 'not-found probe JSON must exit 1'
$probeRaw = $probeOutput -join "`n"
try { $probeActual = $probeRaw | ConvertFrom-Json } catch { throw 'probe did not emit one JSON document for not-found' }
Assert-Contract ($probeActual.schema -eq 'win-use-master/probe-report-v1' -and $probeActual.status -eq 'not-found' -and -not $probeRaw.Contains($probeMarker)) 'probe not-found schema/privacy incorrect'
$probeTypo = @(& pwsh -NoLogo -NoProfile -File $probePath 'private-marker-query' --json --summmary 2>&1)
Assert-Contract ($LASTEXITCODE -eq 2 -and -not (($probeTypo -join "`n").Contains('private-marker-query'))) 'probe misspelled summary must fail closed without echoing query'

$stateTypo = @(& pwsh -NoLogo -NoProfile -File $winPath restore 'private-marker-window' --json --summmary --dry 2>&1)
Assert-Contract ($LASTEXITCODE -eq 2 -and -not (($stateTypo -join "`n").Contains('private-marker-window'))) 'window state misspelled summary must fail before resolving target'

$node = (Get-Command node -ErrorAction Stop).Source
$cdpPath = Join-Path $root 'scripts\cdp.js'
$fixturePath = Join-Path $PSScriptRoot 'cdp-fixture.js'
$port = 49633
while ($port -le 65535 -and (Get-NetTCPConnection -State Listen -LocalPort $port -ErrorAction SilentlyContinue)) { $port++ }
if ($port -gt 65535) { throw 'No free port for CDP JSON fixture' }
$server = Start-Process -FilePath $node -ArgumentList @($fixturePath, [string]$port) -WindowStyle Hidden -PassThru
try {
    $deadline = [DateTime]::UtcNow.AddSeconds(8)
    while (-not (Get-NetTCPConnection -State Listen -LocalPort $port -ErrorAction SilentlyContinue) -and [DateTime]::UtcNow -lt $deadline) { Start-Sleep -Milliseconds 100 }
    if (-not (Get-NetTCPConnection -State Listen -LocalPort $port -ErrorAction SilentlyContinue)) { throw 'CDP JSON fixture did not listen' }
    $cdpSummaryOutput = @(& $node $cdpPath $port list --json --summary 2>&1)
    Assert-Contract ($LASTEXITCODE -eq 0) 'CDP list summary JSON failed'
    $cdpSummaryRaw = $cdpSummaryOutput -join "`n"
    try { $cdpSummary = $cdpSummaryRaw | ConvertFrom-Json } catch { throw 'CDP list summary was not one JSON document' }
    Assert-Contract ($cdpSummary.schema -eq 'win-use-master/cdp-targets-result-v1' -and $cdpSummary.counts.total -eq 1 -and $cdpSummary.targets.Count -eq 0) 'CDP list summary schema/counts incorrect'
    Assert-Contract (-not $cdpSummaryRaw.Contains('private-marker')) 'CDP list summary leaked title or URL detail'

    $cdpFullOutput = @(& $node $cdpPath $port list --json 2>&1)
    $cdpFullRaw = $cdpFullOutput -join "`n"
    $cdpFull = $cdpFullRaw | ConvertFrom-Json
    Assert-Contract ($LASTEXITCODE -eq 0 -and $cdpFull.targets[0].title -eq 'private-marker-cdp-title') 'CDP list full report lost target identity'
    Assert-Contract ($cdpFull.targets[0].url -eq 'https://example.invalid/probe' -and -not $cdpFullRaw.Contains('private-query-marker')) 'CDP list JSON must strip URL query/fragment even in full mode'

    $cdpTypo = @(& $node $cdpPath $port list --json --summmary 2>&1)
    Assert-Contract ($LASTEXITCODE -eq 2 -and -not (($cdpTypo -join "`n").Contains('private-marker'))) 'CDP list misspelled summary must fail closed before target output'
} finally {
    if ($server -and -not $server.HasExited) { $server.Kill(); $server.WaitForExit(3000) | Out-Null }
}

Write-Output 'PASS: probe/window-state/windows/frontmost/idle/UIA/CDP target JSON schemas, summary redaction, query privacy and unknown states'
