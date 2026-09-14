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
Assert-Contract ($workflow -match 'tests/uia-timeout\.ps1') '核心 job 必须验证 UIA 截止时间和 unknown 语义'

Write-Output 'PASS: CI read-only permissions, pinned actions, Node 22/24 CDP matrix, cache and required contracts'
