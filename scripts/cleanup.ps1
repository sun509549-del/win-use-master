# Read-only temporary artifact cleanup planner. Deletion is not implemented.

[CmdletBinding(PositionalBinding = $false)]
param(
    [Parameter(Position = 0, ValueFromRemainingArguments = $true)]
    [string[]] $Options = @()
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version 2.0

function Stop-Cleanup([string] $Message, [int] $Code = 1) {
    [Console]::Error.WriteLine($Message)
    exit $Code
}

$tokens = @($Options | ForEach-Object { [string]$_ })
if ($tokens -contains '--apply') {
    Stop-Cleanup 'cleanup --apply 尚未开放；本阶段只有零写入 dry-run 计划，没有删除任何内容。' 2
}
$unknown = @($tokens | Where-Object { $_ -notin @('--dry-run','--json','--summary') })
if ($unknown.Count) { Stop-Cleanup 'cleanup 只支持 --dry-run、--json 与 --summary；未知或位置参数已拒绝。' 2 }
foreach ($option in @('--dry-run','--json','--summary')) {
    if (@($tokens | Where-Object { $_ -eq $option }).Count -gt 1) { Stop-Cleanup "cleanup 的 $option 不能重复。" 2 }
}
$json = $tokens -contains '--json'
$summary = $tokens -contains '--summary'

$core = Join-Path $PSScriptRoot 'cleanup-core.ps1'
if (-not (Test-Path -LiteralPath $core -PathType Leaf)) { Stop-Cleanup 'cleanup 规划核心缺失；没有扫描或删除。' 1 }
try {
    . $core
    $scanRoot = Get-CleanupScanRoot
    $report = Get-CleanupPlan $scanRoot ([DateTimeOffset]::Now) -Summary:$summary
}
catch { Stop-Cleanup 'cleanup dry-run 的扫描根或候选未通过边界校验；没有写入或删除。' 2 }

if ($json) { Write-Output ($report | ConvertTo-Json -Depth 12); exit 0 }
if ($summary) {
    Write-Output ("cleanup dry-run: status={0} candidates={1} eligible={2} refused={3} deleted=0 apply=false" -f
        $report.status, $report.counts.candidates, $report.counts.eligible, $report.counts.refused)
    exit 0
}

Write-Output 'win-use-master cleanup（只读计划；apply 尚未开放）'
Write-Output ("候选={0} 可清理={1} 拒绝={2}；files-written=0 files-deleted=0 directories-deleted=0" -f
    $report.counts.candidates, $report.counts.eligible, $report.counts.refused)
foreach ($item in @($report.items)) {
    $reason = if (@($item.reasons).Count) { @($item.reasons) -join ',' } else { 'expired+owner-stopped+manifest-valid' }
    $size = if ($null -ne $item.bytes) { [string]$item.bytes } else { 'unknown' }
    Write-Output ("  {0} decision={1} reason={2} bytes={3} owner={4}" -f $item.candidate, $item.decision, $reason, $size, $item.owner.status)
}
Write-Output '下一步：人工复核计划。本版本不会接受 --apply，也不会删除任何对象。'
exit 0
