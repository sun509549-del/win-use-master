param([switch] $Force)

$ErrorActionPreference = 'Stop'
$source = Join-Path $PSScriptRoot 'HuWin.cs'
$output = Join-Path $PSScriptRoot 'HuWin.dll'

if (-not (Test-Path -LiteralPath $source)) { throw "找不到源码: $source" }
if (-not $IsWindows -and $PSVersionTable.PSEdition -eq 'Core') { throw 'HuWin 只能在 Windows 上编译。' }

if (-not $Force -and (Test-Path -LiteralPath $output) -and
    (Get-Item -LiteralPath $output).LastWriteTimeUtc -ge (Get-Item -LiteralPath $source).LastWriteTimeUtc) {
    Write-Output "已是最新: $output"
    exit 0
}

Add-Type -AssemblyName System.Drawing.Common -ErrorAction SilentlyContinue
Add-Type -AssemblyName System.Drawing -ErrorAction SilentlyContinue
Add-Type -AssemblyName System.Windows.Forms -ErrorAction SilentlyContinue

$refs = @()
$refDir = Join-Path $PSHOME 'ref'
if (Test-Path -LiteralPath $refDir) {
    $refs += @(Get-ChildItem -LiteralPath $refDir -Filter '*.dll' | Select-Object -ExpandProperty FullName)
}
foreach ($candidate in @(
    (Join-Path $PSHOME 'System.Drawing.Common.dll'),
    (Join-Path $PSHOME 'System.Windows.Forms.dll'),
    (Join-Path $PSHOME 'System.Windows.Forms.Primitives.dll'),
    (Join-Path $PSHOME 'System.Private.Windows.Core.dll'),
    (Join-Path $PSHOME 'System.Private.Windows.GdiPlus.dll')
)) { if (Test-Path -LiteralPath $candidate) { $refs += $candidate } }
if (-not $refs.Count -and $PSVersionTable.PSEdition -eq 'Desktop') {
    $refs = @('mscorlib.dll', 'System.dll', 'System.Core.dll', 'System.Drawing.dll', 'System.Windows.Forms.dll')
}

$temp = Join-Path $PSScriptRoot ("HuWin.$PID.$([Guid]::NewGuid().ToString('N')).tmp.dll")
try {
    if ($refs.Count) { Add-Type -Path $source -ReferencedAssemblies $refs -OutputAssembly $temp }
    else { Add-Type -Path $source -OutputAssembly $temp }
    if (-not (Test-Path -LiteralPath $temp) -or (Get-Item -LiteralPath $temp).Length -eq 0) {
        throw '编译器没有产出有效 DLL。'
    }
    [IO.File]::Copy($temp, $output, $true)
    Write-Output "built: $output ($((Get-Item -LiteralPath $output).Length) bytes)"
} finally {
    if (Test-Path -LiteralPath $temp) { [IO.File]::Delete($temp) }
}
