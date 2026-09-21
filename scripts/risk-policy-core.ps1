# Shared fail-closed risk-policy parser and text matcher for win.ps1 and the
# isolated UIA worker. This file never performs a UI action or writes state.

function Get-WinUseRiskPolicySchema {
    return 'win-use-master/risk-actions-v1'
}

function Get-WinUseRiskNormalization {
    return @('unicode-nfkc', 'camel-case-boundary', 'separator-to-space', 'collapse-whitespace', 'trim')
}

function Assert-WinUseRiskPolicy($Policy) {
    if ($null -eq $Policy) { throw 'risk policy is empty' }
    if ([string]$Policy.schema -ne (Get-WinUseRiskPolicySchema)) { throw 'risk policy schema mismatch' }

    $normalizationProperty = $Policy.PSObject.Properties['normalization']
    if ($null -eq $normalizationProperty) { throw 'risk policy normalization missing' }
    $normalization = @($normalizationProperty.Value | ForEach-Object { [string]$_ })
    $expectedNormalization = @(Get-WinUseRiskNormalization)
    if ($normalization.Count -ne $expectedNormalization.Count -or
        ($normalization -join "`n") -cne ($expectedNormalization -join "`n")) {
        throw 'risk policy normalization mismatch'
    }

    $textPatterns = @($Policy.blockedTextPatterns)
    if (-not $textPatterns.Count) { throw 'risk policy text patterns missing' }
    $ids = [Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
    foreach ($rule in $textPatterns) {
        $id = [string]$rule.id
        $pattern = [string]$rule.pattern
        $flags = [string]$rule.flags
        if ([string]::IsNullOrWhiteSpace($id) -or [string]::IsNullOrWhiteSpace($pattern)) {
            throw 'risk policy rule id or pattern missing'
        }
        if (-not $ids.Add($id)) { throw 'risk policy rule id duplicated' }
        if ($flags -notin @('', 'i')) { throw 'risk policy rule flags unsupported' }
        $options = if ($flags -eq 'i') { [Text.RegularExpressions.RegexOptions]::IgnoreCase } else { [Text.RegularExpressions.RegexOptions]::None }
        [void][regex]::new($pattern, $options)
    }

    if (@($Policy.blockedKeyChords) -notcontains 'Enter') { throw 'risk policy Enter guard missing' }
    if (@($Policy.blockedDomSemantics) -notcontains 'form-submit') { throw 'risk policy form-submit guard missing' }
    return $Policy
}

function Import-WinUseRiskPolicy([string] $Path) {
    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) { throw 'risk policy unavailable' }
    try { $policy = Get-Content -LiteralPath $Path -Raw -Encoding utf8 | ConvertFrom-Json }
    catch { throw 'risk policy invalid JSON' }
    return Assert-WinUseRiskPolicy $policy
}

function ConvertTo-WinUseRiskText([AllowNull()][string] $Text) {
    $normalized = if ($null -eq $Text) { '' } else { $Text.Normalize([Text.NormalizationForm]::FormKC) }
    $normalized = [regex]::Replace($normalized, '([a-z0-9])([A-Z])', '$1 $2')
    $normalized = [regex]::Replace($normalized, '[_-]+', ' ')
    $normalized = [regex]::Replace($normalized, '\s+', ' ')
    return $normalized.Trim()
}

function Find-WinUseBlockedTextRule($Policy, [AllowNull()][string] $Text) {
    $normalized = ConvertTo-WinUseRiskText $Text
    foreach ($rule in @($Policy.blockedTextPatterns)) {
        $flags = [string]$rule.flags
        $options = if ($flags -eq 'i') { [Text.RegularExpressions.RegexOptions]::IgnoreCase } else { [Text.RegularExpressions.RegexOptions]::None }
        if ([regex]::IsMatch($normalized, [string]$rule.pattern, $options)) { return [string]$rule.id }
    }
    return $null
}
