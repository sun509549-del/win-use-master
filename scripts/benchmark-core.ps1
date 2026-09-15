$ErrorActionPreference = 'Stop'
Set-StrictMode -Version 2.0

function Get-HuBenchmarkStatistics([double[]] $Milliseconds) {
    $values = @($Milliseconds | ForEach-Object { [double]$_ } | Sort-Object)
    if (-not $values.Count) { throw 'benchmark statistics require at least one sample' }

    function Get-NearestRank([double[]] $Sorted, [double] $Percentile) {
        $rank = [Math]::Max(1, [Math]::Ceiling($Percentile * $Sorted.Count))
        return [double]$Sorted[$rank - 1]
    }

    $sum = 0.0
    foreach ($value in $values) { $sum += $value }
    return [pscustomobject][ordered]@{
        samples = $values.Count
        minMs = [Math]::Round([double]$values[0], 3)
        p50Ms = [Math]::Round((Get-NearestRank $values 0.50), 3)
        p95Ms = [Math]::Round((Get-NearestRank $values 0.95), 3)
        maxMs = [Math]::Round([double]$values[-1], 3)
        meanMs = [Math]::Round(($sum / $values.Count), 3)
    }
}

function Test-HuBenchmarkStatistics($Statistics) {
    if ($null -eq $Statistics -or [int]$Statistics.samples -lt 1) { return $false }
    $ordered = @(
        [double]$Statistics.minMs,
        [double]$Statistics.p50Ms,
        [double]$Statistics.p95Ms,
        [double]$Statistics.maxMs
    )
    if (@($ordered | Where-Object { $_ -lt 0 }).Count) { return $false }
    return $ordered[0] -le $ordered[1] -and $ordered[1] -le $ordered[2] -and $ordered[2] -le $ordered[3]
}
