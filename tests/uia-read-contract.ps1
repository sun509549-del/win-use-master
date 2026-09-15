# No desktop/app is used. Run the production functions against provider doubles
# accepting real UIA Conditions, with counters for every metadata/pattern read.
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version 2.0
Add-Type -AssemblyName UIAutomationClient, UIAutomationTypes
$root = Split-Path -Parent $PSScriptRoot
$workerSource = Get-Content -LiteralPath (Join-Path $root 'scripts/uia-worker.ps1') -Raw -Encoding utf8
$winSource = Get-Content -LiteralPath (Join-Path $root 'scripts/win.ps1') -Raw -Encoding utf8
foreach ($source in @(
    @{ Path = 'scripts/uia-worker.ps1'; Function = 'Get-ReadableElements' },
    @{ Path = 'scripts/uia-worker.ps1'; Function = 'Get-UiaReadablePage' },
    @{ Path = 'scripts/win.ps1'; Function = 'Get-UiaReadOptions' }
)) {
    $tokens = $null; $errors = $null
    $ast = [Management.Automation.Language.Parser]::ParseFile((Join-Path $root $source.Path), [ref]$tokens, [ref]$errors)
    if ($errors.Count) { throw "Cannot parse $($source.Path)" }
    $definitions = @($ast.FindAll({ param($node)
        $node -is [Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -eq $source.Function
    }, $true))
    if ($definitions.Count -ne 1) { throw "Expected one $($source.Function) definition" }
    . ([scriptblock]::Create($definitions[0].Extent.Text))
}

function Assert-Test([bool] $Condition, [string] $Message) {
    if (-not $Condition) { throw $Message }
}
function Complete-Worker($Payload, [int] $Code = 0) {
    $script:refusal = @{ Payload = $Payload; Code = $Code }
    throw 'TEST_WORKER_EXIT'
}
function Stop-Hu([string] $Message, [int] $Code = 1) {
    $script:refusal = @{ Payload = @{ error = $Message }; Code = $Code }
    throw 'TEST_CLI_EXIT'
}
function Assert-Refused([scriptblock] $Action, [string] $Label) {
    $script:refusal = $null
    try { & $Action | Out-Null } catch {
        if ($_.Exception.Message -notmatch 'TEST_(WORKER|CLI)_EXIT') { throw }
    }
    Assert-Test ($null -ne $script:refusal -and $script:refusal.Code -eq 2) "$Label must exit 2"
    Assert-Test (-not $script:refusal.Payload.error.Contains('private-marker')) "$Label leaked input/provider text"
}
Assert-Test ($workerSource.Contains('win-use-master/uia-query-result-v1') -and
    $workerSource.Contains('$targetKey = "hwnd=$($request.hwnd);pid=$targetPid;start=$targetStarted"')) 'Worker query result/target binding is not wired'
Assert-Test ($winSource.Contains('processStartTicks = $processStartTicks') -and
    $winSource.Contains('-Mode read -Limit $Limit -Query $Query -Continuation $Continuation')) 'Parent query/start-time binding is not wired'
function ConvertFrom-TestContinuation([string] $Token) {
    $padded = $Token.Replace('-', '+').Replace('_', '/')
    switch ($padded.Length % 4) {
        0 { }
        2 { $padded += '==' }
        3 { $padded += '=' }
        default { throw 'Invalid test continuation' }
    }
    return [Text.Encoding]::UTF8.GetString([Convert]::FromBase64String($padded)) | ConvertFrom-Json
}
function ConvertTo-TestContinuation($Payload) {
    $json = $Payload | ConvertTo-Json -Compress
    return [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($json)).TrimEnd('=').Replace('+', '-').Replace('/', '_')
}
$script:runtimeSeed = 1000
function New-ReadElement([string] $Id, [string] $Name = 'fixture', [string] $Value = 'synthetic-value',
    [string] $Type = 'Edit', [bool] $Password = $false, [bool] $Stale = $false, [object[]] $Children = @()) {
    $script:runtimeSeed++
    $element = [pscustomobject]@{
        Id = $Id; Type = [Windows.Automation.ControlType]::$Type
        MetadataReads = 0; PatternReads = 0; Stale = $Stale
        ProviderName = $Name; RuntimeId = @(42, $script:runtimeSeed); Children = @($Children)
        Info = [pscustomobject]@{
            AutomationId = $Id; Name = $Name; IsPassword = $Password; IsOffscreen = $false
            ControlType = [Windows.Automation.ControlType]::$Type
        }
        Pattern = [pscustomobject]@{ Current = [pscustomobject]@{ Value = $Value } }
    }
    $element | Add-Member ScriptProperty Current {
        $this.MetadataReads++
        if ($this.Stale) { throw 'private-marker stale provider' }
        return $this.Info
    }
    $element | Add-Member ScriptMethod TryGetCurrentPattern {
        param($PatternId, $Result)
        $this.PatternReads++
        $Result.Value = $this.Pattern
        return $true
    }
    $element | Add-Member ScriptMethod GetRuntimeId { return @($this.RuntimeId) }
    $element | Add-Member ScriptMethod FindAll {
        param($Scope, $Condition)
        Assert-Test ($Scope -eq [Windows.Automation.TreeScope]::Descendants) 'Unexpected nested query scope'
        $items = @($this.Children | Where-Object { Test-UiaCondition $_ $Condition })
        $collection = [pscustomobject]@{ Items = $items; Count = $items.Count }
        $collection | Add-Member ScriptMethod Item { param($Index) return $this.Items[$Index] }
        return $collection
    }
    return $element
}
function Test-UiaCondition($Element, $Condition) {
    if ($Condition -is [Windows.Automation.PropertyCondition]) {
        if ($Condition.Property.Id -eq [Windows.Automation.AutomationElement]::AutomationIdProperty.Id) {
            # UIA PropertyCondition defaults to case-sensitive string matching.
            Assert-Test ($Condition.Flags -eq [Windows.Automation.PropertyConditionFlags]::None) 'ID condition must be exact'
            return $Element.Id -ceq $Condition.Value
        }
        if ($Condition.Property.Id -eq [Windows.Automation.AutomationElement]::ControlTypeProperty.Id) {
            return $Element.Type.Id -eq $Condition.Value
        }
        if ($Condition.Property.Id -eq [Windows.Automation.AutomationElement]::NameProperty.Id) {
            return $Element.ProviderName -ceq $Condition.Value
        }
        throw 'Unexpected property condition'
    }
    $results = @($Condition.GetConditions() | ForEach-Object { Test-UiaCondition $Element $_ })
    if ($Condition -is [Windows.Automation.AndCondition]) { return $results -notcontains $false }
    if ($Condition -is [Windows.Automation.OrCondition]) { return $results -contains $true }
    throw 'Unexpected compound condition'
}
function New-ReadRoot([object[]] $Elements, [bool] $Broken = $false) {
    $provider = [pscustomobject]@{ Elements = $Elements; Broken = $Broken }
    $provider | Add-Member ScriptMethod FindAll {
        param($Scope, $Condition)
        if ($this.Broken) { throw 'private-marker provider query failure' }
        Assert-Test ($Scope -eq [Windows.Automation.TreeScope]::Descendants) 'Unexpected query scope'
        $items = @($this.Elements | Where-Object { Test-UiaCondition $_ $Condition })
        $collection = [pscustomobject]@{ Items = $items; Count = $items.Count }
        $collection | Add-Member ScriptMethod Item { param($Index) return $this.Items[$Index] }
        return $collection
    }
    return $provider
}

# A late exact match must be selected before the normal output limit, not after
# reading unrelated values or matching an ID substring/Name/Value collision.
$noise = @(1..305 | ForEach-Object { New-ReadElement "other$_" 'target' 'target' })
$prefix = New-ReadElement 'target-extra'
$target = New-ReadElement 'target' 'chosen' ('x' * 600)
$provider = New-ReadRoot ($noise + @($prefix, $target))
$items = @(Get-ReadableElements $provider 300 -ExactId 'target')
Assert-Test ($items.Count -eq 1 -and $items[0].automationId -ceq 'target' -and $items[0].value.Length -eq 500) 'Late exact read/truncation failed'
Assert-Test ($target.MetadataReads -eq 1 -and $target.PatternReads -eq 1) 'Target must be read once'
Assert-Test (@(($noise + @($prefix)) | Where-Object { $_.MetadataReads -or $_.PatternReads }).Count -eq 0) 'Exact read accessed unrelated content'
Write-Output 'exact selection: late ID, substring/name/value collisions and content isolation PASS'

$duplicate = @(New-ReadElement 'private-marker'; New-ReadElement 'private-marker')
Assert-Refused { Get-ReadableElements (New-ReadRoot $duplicate) 1 -ExactId 'private-marker' } 'Duplicate ID before output limit'
Assert-Test (@($duplicate | Where-Object { $_.MetadataReads -or $_.PatternReads }).Count -eq 0) 'Duplicate refusal read candidate content'
Assert-Refused { Get-ReadableElements $provider 300 -ExactId 'TARGET' } 'Case-sensitive missing ID'
Assert-Refused { Get-ReadableElements (New-ReadRoot @((New-ReadElement 'button' -Type Button))) 300 -ExactId 'button' } 'Non-readable control'
Assert-Refused { Get-ReadableElements (New-ReadRoot @() -Broken $true) 300 -ExactId 'private-marker' } 'Provider query error'
Assert-Refused { Get-ReadableElements (New-ReadRoot @((New-ReadElement 'stale' -Stale $true))) 300 -ExactId 'stale' } 'Stale target'
$changed = New-ReadElement 'target'
$changed.Info.AutomationId = 'private-marker'
Assert-Refused { Get-ReadableElements (New-ReadRoot @($changed)) 300 -ExactId 'target' } 'Identity changed after selection'
Assert-Test ($changed.PatternReads -eq 0) 'Changed identity read a value'
Assert-Refused { Get-ReadableElements (New-ReadRoot @((New-ReadElement 'empty' '' ''))) 300 -ExactId 'empty' } 'Empty content'
$password = New-ReadElement 'password' -Password $true
$items = @(Get-ReadableElements (New-ReadRoot @($password)) 300 -ExactId 'password')
Assert-Test ($items.Count -eq 1 -and $items[0].isPassword -and $items[0].value -eq '' -and $password.PatternReads -eq 0) 'Password value accessed'
Write-Output 'exact refusal: duplicate/missing/type/provider/stale/empty + password protection PASS'

$legacy = @(1..4 | ForEach-Object { New-ReadElement "legacy$_" })
$items = @(Get-ReadableElements (New-ReadRoot $legacy) 2)
Assert-Test ($items.Count -eq 2 -and $legacy[2].MetadataReads -eq 0 -and $legacy[3].MetadataReads -eq 0) 'Legacy read limit regressed'
$options = Get-UiaReadOptions @('0x123', '--id', 'target', '--summary')
Assert-Test ($options.Target -eq '0x123' -and $options.ExactId -ceq 'target' -and $options.Summary -and -not $options.Filter -and -not $options.Structured) 'Existing exact-ID CLI mode must stay compatible'
$options = Get-UiaReadOptions @('--summary', '0x123', 'legacy-filter')
Assert-Test ($options.Summary -and $options.Filter -eq 'legacy-filter' -and -not $options.ExactId -and -not $options.Structured) 'Legacy filter options failed'

# Structured combinations use provider-side exact conditions, then prefix
# metadata filters, before any ValuePattern read.
$query = [pscustomobject]@{ idExact = 'shared'; idPrefix = ''; controlType = 'Edit'; nameExact = 'chosen'; namePrefix = ''; withinId = '' }
$wrongType = New-ReadElement 'shared' 'chosen' 'private-marker-wrong-type' -Type Text
$wrongName = New-ReadElement 'shared' 'other' 'private-marker-wrong-name'
$chosen = New-ReadElement 'shared' 'chosen' 'selected-value'
$combined = Get-UiaReadablePage (New-ReadRoot @($wrongType, $wrongName, $chosen)) 10 $query '' '0x123'
Assert-Test ($combined.items.Count -eq 1 -and $combined.items[0].value -eq 'selected-value') 'Exact ID/type/name combination failed'
Assert-Test ($wrongType.PatternReads -eq 0 -and $wrongName.PatternReads -eq 0 -and $chosen.PatternReads -eq 1) 'Exact combination read unrelated ValuePattern content'
$duplicateQuery = [pscustomobject]@{ idExact = 'private-marker'; idPrefix = ''; controlType = ''; nameExact = ''; namePrefix = ''; withinId = '' }
$structuredDuplicate = @(New-ReadElement 'private-marker'; New-ReadElement 'private-marker')
Assert-Refused { Get-UiaReadablePage (New-ReadRoot $structuredDuplicate) 10 $duplicateQuery '' '0x123' } 'Structured duplicate exact ID'
Assert-Test (@($structuredDuplicate | Where-Object { $_.MetadataReads -or $_.PatternReads }).Count -eq 0) 'Structured duplicate ID read candidate content'
$structuredEmptyQuery = [pscustomobject]@{ idExact = 'structured-empty'; idPrefix = ''; controlType = 'Edit'; nameExact = ''; namePrefix = ''; withinId = '' }
$structuredEmpty = New-ReadElement 'structured-empty' '' ''
Assert-Refused { Get-UiaReadablePage (New-ReadRoot @($structuredEmpty)) 10 $structuredEmptyQuery '' '0x123' } 'Structured exact empty content'
$offscreenFlip = New-ReadElement 'offscreen-flip' 'fixture' 'private-marker-value'
$offscreenFlip | Add-Member ScriptProperty Current {
    $this.MetadataReads++
    if ($this.MetadataReads -ge 2) { $this.Info.IsOffscreen = $true }
    return $this.Info
} -Force
$offscreenQuery = [pscustomobject]@{ idExact = 'offscreen-flip'; idPrefix = ''; controlType = 'Edit'; nameExact = ''; namePrefix = ''; withinId = '' }
Assert-Refused { Get-UiaReadablePage (New-ReadRoot @($offscreenFlip)) 10 $offscreenQuery '' '0x123' } 'Selected offscreen state changed'
Assert-Test ($offscreenFlip.PatternReads -eq 0) 'Changed offscreen state read element value'

$prefixQuery = [pscustomobject]@{ idExact = ''; idPrefix = 'row-'; controlType = 'Text'; nameExact = ''; namePrefix = 'Alpha'; withinId = '' }
$prefixElements = @(
    New-ReadElement 'row-1' 'Alpha one' 'value-1' -Type Text
    New-ReadElement 'row-2' 'Beta two' 'private-marker-beta' -Type Text
    New-ReadElement 'other-3' 'Alpha three' 'private-marker-other' -Type Text
)
$prefixPage = Get-UiaReadablePage (New-ReadRoot $prefixElements) 10 $prefixQuery '' '0x123'
Assert-Test ($prefixPage.items.Count -eq 1 -and $prefixPage.items[0].automationId -eq 'row-1') 'Prefix combination failed'
Assert-Test ($prefixElements[1].PatternReads -eq 0 -and $prefixElements[2].PatternReads -eq 0) 'Prefix query read values before metadata filtering'

# within-id must resolve one scope, and no outside element may have its metadata
# or ValuePattern read after the provider narrows that scope.
$childA = New-ReadElement 'item-a' 'Scoped A' 'inside-a' -Type Text
$childB = New-ReadElement 'item-b' 'Scoped B' 'inside-b' -Type Text
$container = New-ReadElement 'scope-root' 'container' '' -Children @($childA, $childB)
$outside = New-ReadElement 'item-outside' 'Scoped outside' 'private-marker-outside' -Type Text
$scopeQuery = [pscustomobject]@{ idExact = ''; idPrefix = 'item-'; controlType = 'Text'; nameExact = ''; namePrefix = ''; withinId = 'scope-root' }
$scopePage = Get-UiaReadablePage (New-ReadRoot @($container, $outside)) 10 $scopeQuery '' '0x123'
Assert-Test ($scopePage.items.Count -eq 2 -and $outside.MetadataReads -eq 0 -and $outside.PatternReads -eq 0) 'within-id escaped its unique subtree'
$duplicateScopes = @(New-ReadElement 'scope-root' -Children @($childA); New-ReadElement 'scope-root' -Children @($childB))
Assert-Refused { Get-UiaReadablePage (New-ReadRoot $duplicateScopes) 10 $scopeQuery '' '0x123' } 'Duplicate within-id'
Assert-Test ($childA.PatternReads -eq 1 -and $childB.PatternReads -eq 1) 'Duplicate scope performed an additional content read'
$scopedPageChildren = @(1..3 | ForEach-Object { New-ReadElement ("scoped-page-{0}" -f $_) -Type Text })
$scopedPageQuery = [pscustomobject]@{ idExact = ''; idPrefix = 'scoped-page-'; controlType = 'Text'; nameExact = ''; namePrefix = ''; withinId = 'paged-scope' }
$originalScope = New-ReadElement 'paged-scope' -Children $scopedPageChildren
$scopedFirstPage = Get-UiaReadablePage (New-ReadRoot @($originalScope)) 1 $scopedPageQuery '' '0x124'
$replacementScope = New-ReadElement 'paged-scope' -Children $scopedPageChildren
Assert-Refused { Get-UiaReadablePage (New-ReadRoot @($replacementScope)) 1 $scopedPageQuery $scopedFirstPage.page.continuation '0x124' } 'Replaced within-id scope'
Assert-Test ($scopedPageChildren[1].PatternReads -eq 0) 'Replaced scope read next-page content before refusal'

# Pagination tokens contain hashes/offset only. Repeating the exact query gets
# the next page; any matching-tree or target change invalidates the token before
# reading page-two values.
$pagedElements = @(1..5 | ForEach-Object { New-ReadElement ("page-{0}" -f $_) ("Page {0}" -f $_) ("value-{0}" -f $_) -Type Text })
$pageQuery = [pscustomobject]@{ idExact = ''; idPrefix = 'page-'; controlType = 'Text'; nameExact = ''; namePrefix = ''; withinId = '' }
$pageOne = Get-UiaReadablePage (New-ReadRoot $pagedElements) 2 $pageQuery '' '0x777'
Assert-Test ($pageOne.page.schema -eq 'win-use-master/uia-page-v1' -and $pageOne.page.matched -eq 5 -and $pageOne.page.returned -eq 2 -and $pageOne.page.hasMore) 'First page metadata is incorrect'
Assert-Test ($pageOne.page.continuation -match '^[A-Za-z0-9_-]+$' -and -not $pageOne.page.continuation.Contains('page-')) 'Continuation is not opaque/base64url'
$tokenPayload = ConvertFrom-TestContinuation $pageOne.page.continuation
$tokenJson = $tokenPayload | ConvertTo-Json -Compress
Assert-Test ($tokenPayload.schema -eq 'win-use-master/uia-continuation-v1' -and $tokenPayload.offset -eq 2) 'Continuation schema/offset is incorrect'
Assert-Test ($tokenJson -notmatch 'page-|Page |value-' -and $tokenJson -match 'queryHash' -and $tokenJson -match 'treeHash') 'Continuation contains UIA labels or values'
Assert-Test ($pagedElements[0].PatternReads -eq 1 -and $pagedElements[1].PatternReads -eq 1 -and @($pagedElements[2..4] | Where-Object PatternReads -gt 0).Count -eq 0) 'First page read values outside its limit'
$pageTwo = Get-UiaReadablePage (New-ReadRoot $pagedElements) 2 $pageQuery $pageOne.page.continuation '0x777'
Assert-Test (($pageTwo.items.automationId -join ',') -eq 'page-3,page-4' -and $pageTwo.page.offset -eq 2 -and $pageTwo.page.hasMore) 'Continuation did not advance deterministically'

$tamperedPayload = ConvertFrom-TestContinuation $pageOne.page.continuation
$tamperedPayload.offset = 999
$tamperedToken = ConvertTo-TestContinuation $tamperedPayload
Assert-Refused { Get-UiaReadablePage (New-ReadRoot $pagedElements) 2 $pageQuery $tamperedToken '0x777' } 'Tampered continuation offset'
$fractionalPayload = ConvertFrom-TestContinuation $pageOne.page.continuation
$fractionalPayload.offset = 1.5
Assert-Refused { Get-UiaReadablePage (New-ReadRoot $pagedElements) 2 $pageQuery (ConvertTo-TestContinuation $fractionalPayload) '0x777' } 'Fractional continuation offset'
$extraPayload = ConvertFrom-TestContinuation $pageOne.page.continuation
$extraPayload | Add-Member NoteProperty extra 'private-marker'
Assert-Refused { Get-UiaReadablePage (New-ReadRoot $pagedElements) 2 $pageQuery (ConvertTo-TestContinuation $extraPayload) '0x777' } 'Continuation with extra fields'
$invalidTokenElements = @(1..3 | ForEach-Object { New-ReadElement ("invalid-{0}" -f $_) -Type Text })
$invalidTokenQuery = [pscustomobject]@{ idExact = ''; idPrefix = 'invalid-'; controlType = 'Text'; nameExact = ''; namePrefix = ''; withinId = '' }
Assert-Refused { Get-UiaReadablePage (New-ReadRoot $invalidTokenElements) 1 $invalidTokenQuery 'abc' '0x779' } 'Malformed continuation payload'
Assert-Test (@($invalidTokenElements | Where-Object PatternReads -gt 0).Count -eq 0) 'Malformed continuation read element values'

$mutatedElements = @(1..5 | ForEach-Object { New-ReadElement ("mut-{0}" -f $_) ("Mutation {0}" -f $_) ("mut-value-{0}" -f $_) -Type Text })
$mutationQuery = [pscustomobject]@{ idExact = ''; idPrefix = 'mut-'; controlType = 'Text'; nameExact = ''; namePrefix = ''; withinId = '' }
$mutationPage = Get-UiaReadablePage (New-ReadRoot $mutatedElements) 2 $mutationQuery '' '0x888'
$mutatedElements[3].Info.Name = 'Mutation changed'
Assert-Refused { Get-UiaReadablePage (New-ReadRoot $mutatedElements) 2 $mutationQuery $mutationPage.page.continuation '0x888' } 'Changed tree continuation'
Assert-Test ($mutatedElements[2].PatternReads -eq 0 -and $mutatedElements[3].PatternReads -eq 0) 'Changed tree read next-page values before refusal'
Assert-Refused { Get-UiaReadablePage (New-ReadRoot $pagedElements) 2 $pageQuery $pageOne.page.continuation '0x778' } 'Continuation target mismatch'

$reorderedElements = @(1..4 | ForEach-Object { New-ReadElement ("order-{0}" -f $_) -Type Text })
$reorderQuery = [pscustomobject]@{ idExact = ''; idPrefix = 'order-'; controlType = 'Text'; nameExact = ''; namePrefix = ''; withinId = '' }
$reorderPage = Get-UiaReadablePage (New-ReadRoot $reorderedElements) 2 $reorderQuery '' '0x889'
$reorderedRoot = New-ReadRoot @($reorderedElements[1], $reorderedElements[0], $reorderedElements[2], $reorderedElements[3])
Assert-Refused { Get-UiaReadablePage $reorderedRoot 2 $reorderQuery $reorderPage.page.continuation '0x889' } 'Reordered tree continuation'
Assert-Test ($reorderedElements[2].PatternReads -eq 0 -and $reorderedElements[3].PatternReads -eq 0) 'Reordered tree read next-page values before refusal'

$unstableIdentity = @(New-ReadElement 'runtime-1' -Type Text; New-ReadElement 'runtime-2' -Type Text)
$unstableIdentity[1].RuntimeId = @()
$runtimeQuery = [pscustomobject]@{ idExact = ''; idPrefix = 'runtime-'; controlType = 'Text'; nameExact = ''; namePrefix = ''; withinId = '' }
Assert-Refused { Get-UiaReadablePage (New-ReadRoot $unstableIdentity) 1 $runtimeQuery '' '0x890' } 'Missing runtime identity for pagination'
Assert-Test ($unstableIdentity[0].PatternReads -eq 1 -and $unstableIdentity[1].PatternReads -eq 0) 'Missing runtime identity read outside the requested page'
$unstableTarget = @(New-ReadElement 'target-stable-1' -Type Text; New-ReadElement 'target-stable-2' -Type Text)
$unstableTargetQuery = [pscustomobject]@{ idExact = ''; idPrefix = 'target-stable-'; controlType = 'Text'; nameExact = ''; namePrefix = ''; withinId = '' }
Assert-Refused { Get-UiaReadablePage (New-ReadRoot $unstableTarget) 1 $unstableTargetQuery '' '0x891' $false } 'Missing target process identity for pagination'
Assert-Test ($unstableTarget[0].PatternReads -eq 1 -and $unstableTarget[1].PatternReads -eq 0) 'Missing target identity read outside the requested page'

$structuredOptions = Get-UiaReadOptions @('--summary', '--json', '0x123', '--id-prefix', 'row-', '--type', 'edit', '--name-prefix', 'Alpha', '--within-id', 'panel', '--limit', '25')
Assert-Test ($structuredOptions.Structured -and $structuredOptions.Json -and $structuredOptions.Limit -eq 25 -and $structuredOptions.Query.controlType -eq 'Edit' -and $structuredOptions.Query.idPrefix -eq 'row-' -and $structuredOptions.Query.withinId -eq 'panel') 'Structured CLI options failed'
foreach ($invalid in @(
    @{ Args = @() }, @{ Args = @('0x123', '--id') }, @{ Args = @('0x123', '--id', '') },
    @{ Args = @('0x123', '--id', '--summary') }, @{ Args = @('0x123', '--id', 'private-marker', '--id', 'other') },
    @{ Args = @('0x123', 'private-marker', '--id', 'target') }, @{ Args = @('0x123', '--private-marker') },
    @{ Args = @('0x123', 'private-marker', 'extra') },
    @{ Args = @('0x123', '--id', 'a', '--id-prefix', 'a') }, @{ Args = @('0x123', '--name', 'a', '--name-prefix', 'a') },
    @{ Args = @('0x123', '--type', 'Button') }, @{ Args = @('0x123', '--limit', '0') }, @{ Args = @('0x123', '--limit', '501') },
    @{ Args = @('0x123', '--limit', 'private-marker') }, @{ Args = @('0x123', '--continuation', 'not+base64url') }
)) {
    Assert-Refused { Get-UiaReadOptions $invalid.Args } 'Invalid CLI arguments'
}
Write-Output 'structured query: exact/prefix/type/within-id metadata-first filtering PASS'
Write-Output 'pagination: opaque payload, stable advance, invalid/stale/tree/order/target/runtime refusal PASS'
Write-Output 'CLI options and legacy compatibility PASS'
Write-Output 'UIA read contract PASS (provider doubles; real-app integration is separate)'
