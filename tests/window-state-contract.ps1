# No window or desktop is touched. Load the production transition classifier and
# verify that an already-foreground minimized target is not confused with a new
# activation caused by restore.
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version 2.0
$root = Split-Path -Parent $PSScriptRoot
$path = Join-Path $root 'scripts\win.ps1'
$tokens = $null; $errors = $null
$ast = [Management.Automation.Language.Parser]::ParseFile($path, [ref]$tokens, [ref]$errors)
if ($errors.Count) { throw 'Cannot parse scripts/win.ps1' }
$definitions = @($ast.FindAll({ param($node)
    $node -is [Management.Automation.Language.FunctionDefinitionAst] -and
    $node.Name -eq 'Get-HuForegroundTransition'
}, $true))
if ($definitions.Count -ne 1) { throw 'Expected one Get-HuForegroundTransition definition' }
. ([scriptblock]::Create($definitions[0].Extent.Text))

$cases = @(
    @{ Before = 0x10; After = 0x10; Target = 0x20; Expected = 'unchanged' },
    @{ Before = 0x20; After = 0x20; Target = 0x20; Expected = 'target-already' },
    @{ Before = 0x20; After = 0x10; Target = 0x20; Expected = 'released-by-windows' },
    @{ Before = 0x10; After = 0x30; Target = 0x20; Expected = 'changed-external' },
    @{ Before = 0x10; After = 0x20; Target = 0x20; Expected = 'unexpected-target' }
)
foreach ($case in $cases) {
    $actual = Get-HuForegroundTransition $case.Before $case.After $case.Target
    if ($actual -ne $case.Expected) {
        throw "transition $($case.Before)->$($case.After) target=$($case.Target): expected $($case.Expected), got $actual"
    }
}
Write-Output 'PASS: foreground transition classifier distinguishes existing foreground from new activation'
