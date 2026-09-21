[CmdletBinding(PositionalBinding = $false)]
param(
    [Parameter(Mandatory = $true)]
    [ValidatePattern('^[a-z0-9]+(?:-[a-z0-9]+)*$')]
    [string] $AppId,

    [switch] $Plan,
    [switch] $Json,
    [switch] $Summary
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version 2.0

$root = Split-Path -Parent $PSScriptRoot
$catalogPath = Join-Path $root 'config/app-profiles.json'

function Stop-Safely([string] $Message) {
    Write-Output "refused: $Message"
    exit 2
}

if (-not $Plan) {
    Stop-Safely 'profile-test-template 只生成计划，不执行应用测试；请显式使用 -Plan。'
}
if ($Json -and $Summary) {
    Stop-Safely '-Json 与 -Summary 不能同时使用。'
}

$catalog = Get-Content -LiteralPath $catalogPath -Raw -Encoding utf8 | ConvertFrom-Json
$matches = @($catalog.profiles | Where-Object { [string]$_.appId -ceq $AppId })
if ($matches.Count -ne 1) {
    Stop-Safely "目录中 appId=$AppId 命中 $($matches.Count) 条；先建立唯一的机器档案再编写真实测试。"
}
$profile = $matches[0]

$phases = @(
    [pscustomobject][ordered]@{ order = 1; id = 'record-version-and-install-source'; mode = 'read-only'; completion = 'version, install kind and verification date are recorded' }
    [pscustomobject][ordered]@{ order = 2; id = 'run-read-only-probe'; mode = 'read-only'; completion = 'discovery does not start, close or restart the app' }
    [pscustomobject][ordered]@{ order = 3; id = 'bind-exact-identity'; mode = 'read-only'; completion = 'PID, executable identity, host relationship, window class and integrity are unambiguous' }
    [pscustomobject][ordered]@{ order = 4; id = 'select-lowest-control-layer'; mode = 'read-only'; completion = 'L0 is preferred before L1, L2 and L3; unknown remains unknown' }
    [pscustomobject][ordered]@{ order = 5; id = 'capture-before-evidence'; mode = 'read-only'; completion = 'before evidence is bound to the exact target and stored only in a unique temporary directory' }
    [pscustomobject][ordered]@{ order = 6; id = 'perform-reversible-or-isolated-action'; mode = 'implementation-required'; completion = 'the action uses an isolated object or has a tested rollback and does not cross a stop line' }
    [pscustomobject][ordered]@{ order = 7; id = 'verify-through-independent-channel'; mode = 'implementation-required'; completion = 'state, semantic readback or a business artifact proves the effect independently of the action return value' }
    [pscustomobject][ordered]@{ order = 8; id = 'rollback-and-close-owned-target'; mode = 'implementation-required'; completion = 'only the test-created state and exact owned target are restored or closed' }
    [pscustomobject][ordered]@{ order = 9; id = 'remove-sensitive-temporary-evidence'; mode = 'implementation-required'; completion = 'cleanup is in finally and boundary-checks every exact target before removal' }
    [pscustomobject][ordered]@{ order = 10; id = 'promote-shared-lessons'; mode = 'review'; completion = 'general lessons become code or contracts; version-specific facts remain in the app profile' }
)

$result = [pscustomobject][ordered]@{
    schema = 'win-use-master/profile-test-plan-v1'
    observedAt = [DateTimeOffset]::UtcNow.ToString('o')
    status = 'planned'
    privacy = [pscustomobject][ordered]@{
        mode = 'full'
        collection = 'catalog-derived-only'
        redactedFields = @('absoluteInstallPath', 'accountContent', 'dynamicPidHwndPort', 'temporaryElementReference', 'rawEvidence')
    }
    templateOnly = $true
    appId = [string]$profile.appId
    productName = [string]$profile.productName
    observedVersion = if ($null -eq $profile.observedVersion) { $null } else { [string]$profile.observedVersion }
    profileStatus = [string]$profile.profileStatus
    currentTestPath = if ($null -eq $profile.testPath) { $null } else { [string]$profile.testPath }
    phases = $phases
    invariants = [pscustomobject][ordered]@{
        refuseExistingUserInstanceOrState = $true
        exactTargetBindingRequired = $true
        lowestReliableLayerRequired = $true
        unverifiedCoordinateFallbackForbidden = $true
        independentReadbackRequired = $true
        rollbackOrIsolationRequired = $true
        cleanupInFinallyRequired = $true
        rawEvidenceCommitForbidden = $true
        refusalOrUnknownExitCode = 2
    }
    sideEffects = [pscustomobject][ordered]@{
        realApplicationsStarted = 0
        writeCommandsExecuted = 0
        evidenceFilesCreated = 0
        repositoryFilesModified = 0
    }
}

if ($Json) {
    $result | ConvertTo-Json -Depth 6 -Compress
    exit 0
}

Write-Output "profile-test-plan appId=$($result.appId) status=$($result.profileStatus) phases=$($phases.Count) template-only=true"
if (-not $Summary) {
    foreach ($phase in $phases) {
        Write-Output ("{0}. {1} [{2}]" -f $phase.order, $phase.id, $phase.mode)
    }
}
Write-Output 'side-effects: applications=0 writes=0 evidence=0 repository-files=0'
