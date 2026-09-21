[CmdletBinding(PositionalBinding = $false)]
param(
    [switch] $Check
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version 2.0

$root = Split-Path -Parent $PSScriptRoot
$catalogPath = Join-Path $root 'config/app-profiles.json'
$outputPath = Join-Path $root 'references/应用能力矩阵.generated.md'

function Escape-MarkdownCell([AllowNull()][string] $Value) {
    if ($null -eq $Value) { return '—' }
    return $Value.Replace('|', '\|').Replace("`r", ' ').Replace("`n", ' ')
}

function Get-StatusLabel([string] $Status) {
    switch ($Status) {
        'replayable' { return '可重放' }
        'read-only-observation' { return '只读观察' }
        'not-installed' { return '未安装占位' }
        default { return $Status }
    }
}

function Get-CapabilityLabel([string] $Capability) {
    switch ($Capability) {
        'verified-read' { return '已验证只读' }
        'verified-reversible-write' { return '已验证可逆写' }
        'verified-isolated-write' { return '已验证隔离写' }
        'observed' { return '仅观察' }
        'unavailable-observed' { return '实测不可用' }
        'provider-timeout' { return 'Provider 超时' }
        'not-tested' { return '未测' }
        'not-installed' { return '未安装' }
        default { return $Capability }
    }
}

$catalog = Get-Content -LiteralPath $catalogPath -Raw -Encoding utf8 | ConvertFrom-Json
$profiles = @($catalog.profiles | Sort-Object { [int]$_.order })
$replayableCount = @($profiles | Where-Object { $_.profileStatus -eq 'replayable' }).Count
$readOnlyCount = @($profiles | Where-Object { $_.profileStatus -eq 'read-only-observation' }).Count
$notInstalledCount = @($profiles | Where-Object { $_.profileStatus -eq 'not-installed' }).Count
$sampleCount = $profiles.Count - $notInstalledCount

$lines = [Collections.Generic.List[string]]::new()
$lines.Add('# 应用能力矩阵（自动生成）')
$lines.Add('')
$lines.Add('> 本文件由 `scripts/generate-app-matrix.ps1` 从 `config/app-profiles.json` 确定性生成。请勿手工编辑；人工经验正文仍维护在 `references/app档案.md`。')
$lines.Add('')
$lines.Add("已实测样本 **$sampleCount** 个：可重放 **$replayableCount** 个，只读观察 **$readOnlyCount** 个；另有未安装占位 **$notInstalledCount** 个。")
$lines.Add('')
$lines.Add('| 应用 | 实测版本 | 最后验证 | 档案状态 | L0 | L1 | L2 | L3 | 可重放测试 |')
$lines.Add('|---|---|---:|---|---|---|---|---|---|')
foreach ($profile in $profiles) {
    $testLabel = if ($profile.testPath) { "``$($profile.testPath)``" } else { '—' }
    $version = if ($profile.observedVersion) { [string]$profile.observedVersion } else { '—' }
    $cells = @(
        Escape-MarkdownCell ([string]$profile.productName)
        Escape-MarkdownCell $version
        Escape-MarkdownCell ([string]$profile.verifiedDate)
        Escape-MarkdownCell (Get-StatusLabel ([string]$profile.profileStatus))
        Escape-MarkdownCell (Get-CapabilityLabel ([string]$profile.capabilities.L0))
        Escape-MarkdownCell (Get-CapabilityLabel ([string]$profile.capabilities.L1))
        Escape-MarkdownCell (Get-CapabilityLabel ([string]$profile.capabilities.L2))
        Escape-MarkdownCell (Get-CapabilityLabel ([string]$profile.capabilities.L3))
        $testLabel
    )
    $lines.Add('| ' + ($cells -join ' | ') + ' |')
}
$lines.Add('')
$lines.Add('能力标签只陈述对应版本和日期的实测事实：`仅观察` 不等于可安全操作，`实测不可用` 不等于未来版本永远不可用，`未测` 不能降级解释为坐标路径可用。任何版本、进程身份、窗口类或语义定位变化都会使档案失效，必须重新探测。')
$lines.Add('')
$lines.Add('目录仅提交脱敏派生元数据，不提交截图、UIA/CDP 原始快照、账号、设备名、文档正文、绝对安装路径、PID、HWND、动态端口或短期元素引用。')
$content = (($lines -join "`n") + "`n")

if ($Check) {
    if (-not (Test-Path -LiteralPath $outputPath -PathType Leaf)) {
        throw "生成文件不存在：$outputPath"
    }
    $existing = [IO.File]::ReadAllText($outputPath, [Text.Encoding]::UTF8).Replace("`r`n", "`n")
    if (-not $existing.Equals($content, [StringComparison]::Ordinal)) {
        throw '应用能力矩阵与 config/app-profiles.json 不一致；请重新运行 scripts/generate-app-matrix.ps1。'
    }
    Write-Output 'PASS: generated app capability matrix is current'
    exit 0
}

[IO.File]::WriteAllText($outputPath, $content, [Text.UTF8Encoding]::new($false))
Write-Output "generated: $outputPath"
