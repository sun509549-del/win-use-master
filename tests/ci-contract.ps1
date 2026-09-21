$ErrorActionPreference = 'Stop'
Set-StrictMode -Version 2.0

$root = Split-Path -Parent $PSScriptRoot
$workflowPath = Join-Path $root '.github\workflows\ci.yml'
$workflow = Get-Content -LiteralPath $workflowPath -Raw -Encoding utf8

function Assert-Contract([bool] $Condition, [string] $Message) {
    if (-not $Condition) { throw "CI contract: $Message" }
}

Assert-Contract ($workflow -notmatch '(?m)^\s*pull_request_target\s*:') '不得使用会让 fork 代码接触基础仓库 token 的 pull_request_target'
Assert-Contract ($workflow -match '(?m)^permissions:\s*\r?\n\s+contents:\s*read\s*$') '默认权限必须保持 contents: read'
Assert-Contract ($workflow -match 'actions/checkout@3d3c42e5aac5ba805825da76410c181273ba90b1\s+#\s+v7\.0\.1') 'checkout 必须固定到已审查的 v7.0.1 commit'
Assert-Contract ($workflow -match 'actions/setup-node@820762786026740c76f36085b0efc47a31fe5020\s+#\s+v7\.0\.0') 'setup-node 必须固定到已审查的 v7.0.0 commit'
Assert-Contract ($workflow -match "node-version:\s*\['22',\s*'24'\]") 'CDP 矩阵必须覆盖 Node 22 与 24'
Assert-Contract ($workflow -match '(?s)strategy:\s*\r?\n\s+fail-fast:\s*false\s*\r?\n\s+matrix:') 'Node 矩阵必须保留所有版本结果，不能首项失败后取消'
Assert-Contract ([regex]::Matches($workflow, '(?m)^\s+package-manager-cache:\s*false\s*$').Count -ge 2) '无依赖安装的 job 必须关闭 setup-node 自动包缓存'
Assert-Contract ($workflow -match 'CDP contracts \(Node \$\{\{ matrix\.node-version \}\}\)') 'CDP 矩阵 job 应在名称中显示 Node 版本'
Assert-Contract ($workflow -match 'tests/ci-contract\.ps1') '核心 job 必须执行 CI 自身契约'
Assert-Contract ($workflow -match 'tests/governance-contract\.ps1') '核心 job 必须验证威胁模型、安全披露和社区模板'
Assert-Contract ($workflow -match 'tests/repository-hygiene-contract\.ps1') '核心 job 必须扫描凭据、证据文件、依赖清单和 Action 白名单'
Assert-Contract ($workflow -match 'tests/risk-policy-contract\.ps1') '核心 job 必须验证 UIA/L2/CDP 风险规则跨运行时一致性'
Assert-Contract ($workflow -match 'tests/app-profile-catalog-contract\.ps1') '核心 job 必须验证机器可读应用档案和生成矩阵'
Assert-Contract ($workflow -match 'tests/profile-template-contract\.ps1') '核心 job 必须验证真实应用测试模板的默认拒绝和零副作用'
Assert-Contract ($workflow -match 'tests/public-cases-contract\.ps1') '核心 job 必须验证脱敏真实案例、来源一致性和视觉素材边界'
Assert-Contract ($workflow -match 'tests/release-contract\.ps1') '核心 job 必须验证版本、Changelog、Release Notes、回滚和只读发布检查'
Assert-Contract ($workflow -match "'scripts/risk-policy\.js'") 'Node 22/24 job 必须解析共享风险解释器'
Assert-Contract ($workflow -match 'tests/doctor-contract\.ps1') '核心 job 必须验证只读 doctor 的 fixture、隐私与零副作用'
Assert-Contract ($workflow -match 'tests/json-output-contract\.ps1') '核心 job 必须验证机器可读 schema、unknown 与摘要隐私'
Assert-Contract ($workflow -match 'tests/capability-cache-contract\.ps1') '核心 job 必须验证建议性能力缓存的隐私、失效与非授权边界'
Assert-Contract ($workflow -match 'tests/cleanup-contract\.ps1') '核心 job 必须验证 cleanup dry-run 的边界、零写入与 apply 拒绝'
Assert-Contract ($workflow -match 'tests/benchmark-contract\.ps1') '核心 job 必须验证聚合性能基线、隐私和零写入模式'
Assert-Contract ($workflow -match 'tests/uia-timeout\.ps1') '核心 job 必须验证 UIA 截止时间和 unknown 语义'

Write-Output 'PASS: CI read-only permissions, pinned actions, Node 22/24 CDP matrix, governance and required contracts'
