$ErrorActionPreference = 'Stop'
Set-StrictMode -Version 2.0

$root = Split-Path -Parent $PSScriptRoot
$parseErrors = [Collections.Generic.List[object]]::new()
$powerShellFiles = @(
    Get-ChildItem -LiteralPath $root -Recurse -File -Filter '*.ps1' |
        Where-Object { $_.FullName -notmatch '[\\/](?:\.git|node_modules)[\\/]' }
)

foreach ($file in $powerShellFiles) {
    $tokens = $null
    $errors = $null
    [Management.Automation.Language.Parser]::ParseFile($file.FullName, [ref]$tokens, [ref]$errors) | Out-Null
    foreach ($parseError in $errors) { $parseErrors.Add($parseError) }
}

if ($parseErrors.Count) {
    foreach ($parseError in $parseErrors) {
        Write-Error "$($parseError.Extent.File):$($parseError.Extent.StartLineNumber): $($parseError.Message)"
    }
    throw "PowerShell parse failed with $($parseErrors.Count) error(s)."
}

$node = Get-Command node -CommandType Application -ErrorAction SilentlyContinue | Select-Object -First 1
if (-not $node) {
    Write-Error 'Node.js 22+ is required to parse the optional CDP JavaScript files.'
    exit 2
}

$javaScriptFiles = @(
    Get-ChildItem -LiteralPath $root -Recurse -File -Filter '*.js' |
        Where-Object { $_.FullName -notmatch '[\\/](?:\.git|node_modules)[\\/]' }
)
foreach ($file in $javaScriptFiles) {
    & $node.Source --check $file.FullName
    if ($LASTEXITCODE -ne 0) { throw "JavaScript parse failed: $($file.Name)" }
}

Write-Output "PASS: parse contract PowerShell=$($powerShellFiles.Count) JavaScript=$($javaScriptFiles.Count)"
