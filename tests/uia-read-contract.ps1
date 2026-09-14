# No desktop/app is used. Run the production functions against provider doubles
# accepting real UIA Conditions, with counters for every metadata/pattern read.
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version 2.0
Add-Type -AssemblyName UIAutomationClient, UIAutomationTypes
$root = Split-Path -Parent $PSScriptRoot
foreach ($source in @(
    @{ Path = 'scripts/uia-worker.ps1'; Function = 'Get-ReadableElements' },
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
function New-ReadElement([string] $Id, [string] $Name = 'fixture', [string] $Value = 'synthetic-value',
    [string] $Type = 'Edit', [bool] $Password = $false, [bool] $Stale = $false) {
    $element = [pscustomobject]@{
        Id = $Id; Type = [Windows.Automation.ControlType]::$Type
        MetadataReads = 0; PatternReads = 0; Stale = $Stale
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
Assert-Test ($options.Target -eq '0x123' -and $options.ExactId -ceq 'target' -and $options.Summary -and -not $options.Filter) 'Exact CLI options failed'
$options = Get-UiaReadOptions @('--summary', '0x123', 'legacy-filter')
Assert-Test ($options.Summary -and $options.Filter -eq 'legacy-filter' -and -not $options.ExactId) 'Legacy filter options failed'
foreach ($invalid in @(
    @{ Args = @() }, @{ Args = @('0x123', '--id') }, @{ Args = @('0x123', '--id', '') },
    @{ Args = @('0x123', '--id', '--summary') }, @{ Args = @('0x123', '--id', 'private-marker', '--id', 'other') },
    @{ Args = @('0x123', 'private-marker', '--id', 'target') }, @{ Args = @('0x123', '--private-marker') },
    @{ Args = @('0x123', 'private-marker', 'extra') }
)) {
    Assert-Refused { Get-UiaReadOptions $invalid.Args } 'Invalid CLI arguments'
}
Write-Output 'CLI options and legacy compatibility PASS'
Write-Output 'UIA read contract PASS (provider doubles; real-app integration is separate)'
