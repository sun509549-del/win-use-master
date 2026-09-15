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
foreach ($name in @('Format-Hwnd', 'Get-HuWindowState', 'ConvertTo-HuWindowRecord', 'Get-HuForegroundTransition', 'New-HuWindowStateReport', 'ConvertTo-HuJson')) {
    $definitions = @($ast.FindAll({ param($node)
        $node -is [Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -eq $name
    }, $true))
    if ($definitions.Count -ne 1) { throw "Expected one $name definition" }
    . ([scriptblock]::Create($definitions[0].Extent.Text))
}

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

$window = [pscustomobject]@{
    Hwnd = 0x20; Pid = [uint32]42; Owner = 'Fixture'; Title = 'private-marker-window-state'; Cls = 'FixtureClass'
    L = 10; T = 20; W = 800; H = 600; Visible = $true; Iconic = $false; Zoomed = $false
    Cloaked = $false; Tool = $false; Hung = $false
}
$summary = New-HuWindowStateReport 'restore' $window $window 0x10 0x20 'unexpected-target' 'partial' $true $false
$summaryRaw = ConvertTo-HuJson $summary
if ($summary.schema -ne 'win-use-master/window-state-result-v1' -or $summary.status -ne 'partial' -or
    $summary.effect -ne 'partial' -or $summary.focus.transition -ne 'unexpected-target' -or
    $summary.before.title -ne $null -or $summary.after.title -ne $null -or $summaryRaw.Contains('private-marker')) {
    throw 'Window state summary did not preserve partial semantics or redact titles.'
}
$dry = New-HuWindowStateReport 'minimize' $window $window $null $null 'not-observed' 'planned' $true $true
if ($dry.status -ne 'planned' -or $dry.effect -ne 'not-applied' -or -not $dry.dryRun -or $dry.focus.before -ne $null) {
    throw 'Window state dry-run contract is incorrect.'
}

$invalid = @(& pwsh -NoLogo -NoProfile -File $path restore 'private-marker-target' --json --summmary --dry 2>&1)
if ($LASTEXITCODE -ne 2 -or (($invalid -join "`n").Contains('private-marker-target'))) {
    throw 'Window state misspelled summary did not fail closed before target resolution.'
}

Write-Output 'PASS: foreground transitions and versioned window-state JSON preserve partial/dry semantics and summary privacy'
