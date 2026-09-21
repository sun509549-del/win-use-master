[CmdletBinding(PositionalBinding = $false)]
param(
    [switch] $Check
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version 2.0

$root = Split-Path -Parent $PSScriptRoot
$sourcePath = Join-Path $root 'config/public-cases.json'
$catalogPath = Join-Path $root 'config/app-profiles.json'
$outputPath = Join-Path $root 'references/脱敏真实案例.generated.md'

function Escape-Markdown([AllowNull()][string] $Value) {
    if ($null -eq $Value) { return '—' }
    return $Value.Replace('|', '\|').Replace("`r", ' ').Replace("`n", ' ')
}

function Get-CategoryLabel([string] $Category) {
    switch ($Category) {
        'uia' { return 'UIA' }
        'cdp' { return 'CDP' }
        'com' { return 'COM' }
        default { return $Category.ToUpperInvariant() }
    }
}

$manifest = Get-Content -LiteralPath $sourcePath -Raw -Encoding utf8 | ConvertFrom-Json
$catalog = Get-Content -LiteralPath $catalogPath -Raw -Encoding utf8 | ConvertFrom-Json
$cases = @($manifest.cases | Sort-Object { [int]$_.order })
$visualCount = @($cases | Where-Object { $_.visual.status -eq 'included-reviewed-redacted' }).Count

$lines = [Collections.Generic.List[string]]::new()
$lines.Add('# 脱敏真实案例（自动生成）')
$lines.Add('')
$lines.Add('> 本文件由 `scripts/generate-public-cases.ps1` 从 `config/public-cases.json` 确定性生成。案例来自真实应用档案的已验证结论，但只保留经规则审查的派生事实；不是原始日志、收据、截图或逐字操作记录。')
$lines.Add('')
$lines.Add("当前包含 **$($cases.Count)** 个文字案例（UIA/CDP/COM 各一个），经人工复核并发布的视觉素材 **$visualCount** 个。没有视觉素材时明确留空，不使用 fixture、示意图或重建画面冒充真实应用证据。")
$lines.Add('')

foreach ($case in $cases) {
    $profile = @($catalog.profiles | Where-Object { [string]$_.appId -ceq [string]$case.appId })
    if ($profile.Count -ne 1) { throw "案例 $($case.caseId) 的 appId=$($case.appId) 在应用目录中命中 $($profile.Count) 条。" }
    $version = if ($null -eq $profile[0].observedVersion) { '—' } else { [string]$profile[0].observedVersion }
    $lines.Add("## $($case.order). $($case.title)")
    $lines.Add('')
    $lines.Add('| 字段 | 值 |')
    $lines.Add('|---|---|')
    $lines.Add("| 类别 | $(Escape-Markdown (Get-CategoryLabel ([string]$case.category))) |")
    $lines.Add("| 应用目录 ID | ``$(Escape-Markdown ([string]$case.appId))`` |")
    $lines.Add("| 实测版本 | $(Escape-Markdown $version) |")
    $lines.Add("| 控制层 | ``$(Escape-Markdown ([string]$case.controlLayer))`` |")
    $lines.Add("| 验证日期 | $(Escape-Markdown ([string]$case.verifiedDate)) |")
    $lines.Add("| 可重放来源 | ``$(Escape-Markdown ([string]$case.sourceTest))`` |")
    $lines.Add('')
    $lines.Add('1. **探测**：' + [string]$case.flow.discovery)
    $lines.Add('2. **选择控制面**：' + [string]$case.flow.selection)
    $lines.Add('3. **动作**：' + [string]$case.flow.action)
    $lines.Add('4. **独立验证**：' + [string]$case.flow.verification)
    $lines.Add('5. **撤回与清理**：' + [string]$case.flow.cleanup)
    $lines.Add('')
    $metricPairs = @($case.metrics.PSObject.Properties | ForEach-Object { "``$($_.Name)=$($_.Value)``" })
    $lines.Add('公开指标：' + ($metricPairs -join '、') + '。')
    $lines.Add('')
    $lines.Add('独立信号：' + (@($case.independentSignals | ForEach-Object { Escape-Markdown ([string]$_) }) -join '；') + '。')
    $lines.Add('')
    $lines.Add('停手线：' + (@($case.stopLines | ForEach-Object { "``$(Escape-Markdown ([string]$_))``" }) -join '、') + '。')
    $lines.Add('')
    $lines.Add("视觉素材：**未包含**。$($case.visual.reason) fixtureUsed=false。")
    $lines.Add('')
}

$lines.Add('## 公开边界')
$lines.Add('')
$lines.Add('- 三个案例均不包含输入正文、账号、设备名、安装绝对路径、窗口标题正文、PID、HWND、动态端口、CDP target URL/query、临时元素 ref 或原始证据文件。')
$lines.Add('- `externalFinalAction=false` 只描述这些已验证任务没有发送、分享、覆盖用户文件等最终动作；它不是对任意后续操作的授权。')
$lines.Add('- 视觉素材只有在来源是真实应用、完成逐项人工脱敏并通过隐私复核后才能把 manifest 状态改为 `included-reviewed-redacted`。')
$content = (($lines -join "`n") + "`n")

if ($Check) {
    if (-not (Test-Path -LiteralPath $outputPath -PathType Leaf)) { throw "生成文件不存在：$outputPath" }
    $existing = [IO.File]::ReadAllText($outputPath, [Text.Encoding]::UTF8).Replace("`r`n", "`n")
    if (-not $existing.Equals($content, [StringComparison]::Ordinal)) {
        throw '脱敏真实案例与 config/public-cases.json 不一致；请重新运行 scripts/generate-public-cases.ps1。'
    }
    Write-Output 'PASS: generated public cases are current'
    exit 0
}

[IO.File]::WriteAllText($outputPath, $content, [Text.UTF8Encoding]::new($false))
Write-Output "generated: $outputPath"
