[CmdletBinding(PositionalBinding = $false)]
param(
    [ValidateRange(1, 20)]
    [int] $Iterations = 5
)

# This benchmark never attaches to a desktop or application. It executes the
# production structured-query function against deterministic provider doubles.
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version 2.0
Add-Type -AssemblyName UIAutomationClient, UIAutomationTypes

$root = Split-Path -Parent $PSScriptRoot
. (Join-Path $PSScriptRoot 'benchmark-core.ps1')

$tokens = $null
$errors = $null
$workerPath = Join-Path $PSScriptRoot 'uia-worker.ps1'
$ast = [Management.Automation.Language.Parser]::ParseFile($workerPath, [ref]$tokens, [ref]$errors)
if ($errors.Count) { throw 'cannot parse production UIA worker' }
$definitions = @($ast.FindAll({ param($node)
    $node -is [Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -eq 'Get-UiaReadablePage'
}, $true))
if ($definitions.Count -ne 1) { throw 'expected one production Get-UiaReadablePage definition' }
. ([scriptblock]::Create($definitions[0].Extent.Text))

function Complete-Worker($Payload, [int] $Code = 0) {
    throw "synthetic UIA provider refused with exit $Code`: $([string]$Payload.error)"
}

$script:benchmarkRuntimeSeed = 10000
function New-BenchmarkElement([int] $Index) {
    $script:benchmarkRuntimeSeed++
    $id = 'row-{0:d5}' -f $Index
    $element = [pscustomobject]@{
        Id = $id
        Type = [Windows.Automation.ControlType]::Text
        ProviderName = 'Synthetic row'
        RuntimeId = @(91, $script:benchmarkRuntimeSeed)
        Info = [pscustomobject]@{
            AutomationId = $id
            Name = 'Synthetic row'
            IsPassword = $false
            IsOffscreen = $false
            ControlType = [Windows.Automation.ControlType]::Text
        }
        Pattern = [pscustomobject]@{ Current = [pscustomobject]@{ Value = 'synthetic-value' } }
    }
    $element | Add-Member ScriptProperty Current { return $this.Info }
    $element | Add-Member ScriptMethod TryGetCurrentPattern {
        param($PatternId, $Result)
        $Result.Value = $this.Pattern
        return $true
    }
    $element | Add-Member ScriptMethod GetRuntimeId { return @($this.RuntimeId) }
    return $element
}

function Test-BenchmarkCondition($Element, $Condition) {
    if ($Condition -is [Windows.Automation.PropertyCondition]) {
        if ($Condition.Property.Id -eq [Windows.Automation.AutomationElement]::AutomationIdProperty.Id) {
            return $Element.Id -ceq $Condition.Value
        }
        if ($Condition.Property.Id -eq [Windows.Automation.AutomationElement]::ControlTypeProperty.Id) {
            return $Element.Type.Id -eq $Condition.Value
        }
        if ($Condition.Property.Id -eq [Windows.Automation.AutomationElement]::NameProperty.Id) {
            return $Element.ProviderName -ceq $Condition.Value
        }
        throw 'unexpected synthetic UIA property condition'
    }
    $results = @($Condition.GetConditions() | ForEach-Object { Test-BenchmarkCondition $Element $_ })
    if ($Condition -is [Windows.Automation.AndCondition]) { return $results -notcontains $false }
    if ($Condition -is [Windows.Automation.OrCondition]) { return $results -contains $true }
    throw 'unexpected synthetic UIA compound condition'
}

function New-BenchmarkRoot([object[]] $Elements) {
    $provider = [pscustomobject]@{ Elements = @($Elements) }
    $provider | Add-Member ScriptMethod FindAll {
        param($Scope, $Condition)
        if ($Scope -ne [Windows.Automation.TreeScope]::Descendants) { throw 'unexpected synthetic UIA scope' }
        $items = @($this.Elements | Where-Object { Test-BenchmarkCondition $_ $Condition })
        $collection = [pscustomobject]@{ Items = $items; Count = $items.Count }
        $collection | Add-Member ScriptMethod Item { param($Index) return $this.Items[$Index] }
        return $collection
    }
    return $provider
}

$query = [pscustomobject]@{
    idExact = ''
    idPrefix = 'row-'
    controlType = 'Text'
    nameExact = ''
    namePrefix = ''
    withinId = ''
}
$timeoutBudgetMs = 6000
$cases = [Collections.Generic.List[object]]::new()
foreach ($elementCount in @(100, 300, 1000)) {
    $elements = @(1..$elementCount | ForEach-Object { New-BenchmarkElement $_ })
    $provider = New-BenchmarkRoot $elements

    # One unmeasured pass removes first-call JIT/module noise from query timings.
    $warmup = Get-UiaReadablePage $provider 50 $query '' 'synthetic-target' $true
    if ($warmup.page.matched -ne $elementCount) { throw 'synthetic UIA warmup returned an unexpected match count' }

    $samples = [Collections.Generic.List[double]]::new()
    $budgetExceeded = 0
    for ($iteration = 0; $iteration -lt $Iterations; $iteration++) {
        $clock = [Diagnostics.Stopwatch]::StartNew()
        $page = Get-UiaReadablePage $provider 50 $query '' 'synthetic-target' $true
        $clock.Stop()
        if ($page.page.matched -ne $elementCount -or $page.page.returned -ne [Math]::Min(50, $elementCount)) {
            throw 'synthetic UIA query returned an unexpected page'
        }
        $elapsed = [double]$clock.Elapsed.TotalMilliseconds
        $samples.Add($elapsed)
        if ($elapsed -gt $timeoutBudgetMs) { $budgetExceeded++ }
    }
    $cases.Add([pscustomobject][ordered]@{
        elementCount = $elementCount
        pageLimit = 50
        timeoutBudgetMs = $timeoutBudgetMs
        budgetExceededCount = $budgetExceeded
        budgetExceededRate = [Math]::Round(($budgetExceeded / [double]$Iterations), 4)
        timings = Get-HuBenchmarkStatistics $samples.ToArray()
    })
}

[pscustomobject][ordered]@{
    schema = 'win-use-master/uia-synthetic-benchmark-v1'
    status = 'completed'
    provider = 'synthetic-provider-double'
    productionFunction = 'Get-UiaReadablePage'
    cases = @($cases)
} | ConvertTo-Json -Depth 8 -Compress
