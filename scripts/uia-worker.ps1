# Isolated Windows UI Automation worker.
#
# The parent sends one JSON request through stdin and enforces the deadline by
# terminating this process.  Keeping request data off the command line avoids
# exposing text passed to ValuePattern in process listings.

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version 2.0
[Console]::InputEncoding = [Text.UTF8Encoding]::new($false)
[Console]::OutputEncoding = [Text.UTF8Encoding]::new($false)

function Complete-Worker($Payload, [int] $Code = 0) {
    [Console]::Out.WriteLine(($Payload | ConvertTo-Json -Depth 10 -Compress))
    exit $Code
}

$riskPolicyCorePath = Join-Path $PSScriptRoot 'risk-policy-core.ps1'
if (-not (Test-Path -LiteralPath $riskPolicyCorePath -PathType Leaf)) {
    Complete-Worker @{ ok = $false; refused = $true; error = 'risk policy interpreter unavailable' } 2
}
try { . $riskPolicyCorePath }
catch { Complete-Worker @{ ok = $false; refused = $true; error = 'risk policy interpreter invalid' } 2 }

function Get-RiskPolicy {
    $path = Join-Path (Split-Path -Parent $PSScriptRoot) 'config\risk-actions.json'
    try { return Import-WinUseRiskPolicy $path }
    catch { Complete-Worker @{ ok = $false; refused = $true; error = 'risk policy unavailable or invalid' } 2 }
}

function Find-BlockedActionRule($Policy, [string] $Text) {
    try { return Find-WinUseBlockedTextRule $Policy $Text }
    catch { Complete-Worker @{ ok = $false; refused = $true; error = 'risk policy match failed' } 2 }
}

function Public-Element($Item) {
    return [ordered]@{
        ref = $Item.Ref; name = $Item.Name; controlType = $Item.ControlType
        automationId = $Item.AutomationId; className = $Item.ClassName
        value = $Item.Value; x = $Item.X; y = $Item.Y
        width = $Item.Width; height = $Item.Height; cx = $Item.Cx; cy = $Item.Cy
        enabled = $Item.Enabled; offscreen = $Item.Offscreen
        isPassword = $Item.IsPassword; patterns = @($Item.Patterns)
    }
}

function Get-PatternNames($Element) {
    return @($Element.GetSupportedPatterns() | ForEach-Object {
        $_.ProgrammaticName -replace 'PatternIdentifiers\.Pattern$', 'Pattern'
    })
}

function Get-ActionElements($Root, $Bounds, [int] $Limit) {
    # Document is included because RichEdit/WinUI editors (Notepad 11, WordPad-
    # style controls) expose their text area as Document, not Edit, while still
    # offering ValuePattern. Chromium pages also appear as Document; SetValue on
    # them is refused later by the ValuePattern check, so listing them is safe.
    $types = @(
        [Windows.Automation.ControlType]::Button,
        [Windows.Automation.ControlType]::Edit,
        [Windows.Automation.ControlType]::Document,
        [Windows.Automation.ControlType]::CheckBox,
        [Windows.Automation.ControlType]::RadioButton,
        [Windows.Automation.ControlType]::ComboBox,
        [Windows.Automation.ControlType]::Hyperlink,
        [Windows.Automation.ControlType]::ListItem,
        [Windows.Automation.ControlType]::MenuItem,
        [Windows.Automation.ControlType]::TabItem,
        [Windows.Automation.ControlType]::Slider,
        [Windows.Automation.ControlType]::TreeItem,
        [Windows.Automation.ControlType]::DataItem
    )
    $conditions = [Collections.Generic.List[Windows.Automation.Condition]]::new()
    foreach ($type in $types) {
        $conditions.Add([Windows.Automation.PropertyCondition]::new(
            [Windows.Automation.AutomationElement]::ControlTypeProperty, $type))
    }
    $found = $Root.FindAll([Windows.Automation.TreeScope]::Descendants,
        [Windows.Automation.OrCondition]::new($conditions.ToArray()))
    $out = [Collections.Generic.List[object]]::new()
    $ref = 0
    for ($i = 0; $i -lt $found.Count -and $out.Count -lt $Limit; $i++) {
        $element = $found.Item($i)
        try {
            $current = $element.Current
            $rect = $current.BoundingRectangle
            if ($rect.IsEmpty -or $rect.Width -le 0 -or $rect.Height -le 0) { continue }
            if ($rect.Right -lt [double]$Bounds.l -or $rect.Left -gt [double]$Bounds.r -or
                $rect.Bottom -lt [double]$Bounds.t -or $rect.Top -gt [double]$Bounds.b) { continue }
            $ref++
            $isPassword = [bool]$current.IsPassword
            $value = ''
            if (-not $isPassword) {
                $pattern = $null
                if ($element.TryGetCurrentPattern([Windows.Automation.ValuePattern]::Pattern, [ref]$pattern)) {
                    $value = [string]$pattern.Current.Value
                } elseif ($element.TryGetCurrentPattern([Windows.Automation.TextPattern]::Pattern, [ref]$pattern)) {
                    $value = [string]$pattern.DocumentRange.GetText(200)
                }
            }
            if ($value.Length -gt 200) { $value = $value.Substring(0, 200) }
            $out.Add([pscustomobject]@{
                Ref = "e$ref"; Name = [string]$current.Name
                ControlType = ($current.ControlType.ProgrammaticName -replace '^ControlType\.', '')
                AutomationId = [string]$current.AutomationId; ClassName = [string]$current.ClassName
                Value = $value
                X = [Math]::Round($rect.X, 1); Y = [Math]::Round($rect.Y, 1)
                Width = [Math]::Round($rect.Width, 1); Height = [Math]::Round($rect.Height, 1)
                Cx = [Math]::Round($rect.X + $rect.Width / 2 - [double]$Bounds.l, 1)
                Cy = [Math]::Round($rect.Y + $rect.Height / 2 - [double]$Bounds.t, 1)
                Enabled = [bool]$current.IsEnabled; Offscreen = [bool]$current.IsOffscreen
                IsPassword = $isPassword; Patterns = @(Get-PatternNames $element)
                Element = $element
            })
        } catch { continue }
    }
    return @($out)
}

function Get-ReadableElements($Root, [int] $Limit, [string] $ExactId = '') {
    $types = @(
        [Windows.Automation.ControlType]::Text,
        [Windows.Automation.ControlType]::Document,
        [Windows.Automation.ControlType]::Edit,
        [Windows.Automation.ControlType]::StatusBar,
        [Windows.Automation.ControlType]::Header,
        [Windows.Automation.ControlType]::HeaderItem
    )
    $conditions = [Collections.Generic.List[Windows.Automation.Condition]]::new()
    foreach ($type in $types) {
        $conditions.Add([Windows.Automation.PropertyCondition]::new(
            [Windows.Automation.AutomationElement]::ControlTypeProperty, $type))
    }
    $condition = [Windows.Automation.OrCondition]::new($conditions.ToArray())
    if ($ExactId) {
        # Filter in the provider before truncating or reading Name/Value. An ID
        # must resolve to exactly one readable element, even beyond the usual
        # 300-item limit; duplicate IDs must not expose either candidate's text.
        $condition = [Windows.Automation.AndCondition]::new($condition,
            [Windows.Automation.PropertyCondition]::new(
                [Windows.Automation.AutomationElement]::AutomationIdProperty, $ExactId))
    }
    try {
        $found = $Root.FindAll([Windows.Automation.TreeScope]::Descendants, $condition)
    } catch {
        if ($ExactId) {
            Complete-Worker @{ ok = $false; refused = $true; error = 'exact UIA query unavailable; refresh the target' } 2
        }
        throw
    }
    if ($ExactId -and $found.Count -ne 1) {
        Complete-Worker @{ ok = $false; refused = $true; error = 'exact AutomationId must match one readable element' } 2
    }
    $out = [Collections.Generic.List[object]]::new()
    for ($i = 0; $i -lt $found.Count -and $out.Count -lt $Limit; $i++) {
        try {
            $element = $found.Item($i)
            $current = $element.Current
            if ($ExactId -and [string]$current.AutomationId -cne $ExactId) {
                throw 'exact UIA identity changed after selection'
            }
            $isPassword = [bool]$current.IsPassword
            $value = ''
            if (-not $isPassword) {
                $pattern = $null
                if ($element.TryGetCurrentPattern([Windows.Automation.ValuePattern]::Pattern, [ref]$pattern)) {
                    $value = [string]$pattern.Current.Value
                } elseif ($element.TryGetCurrentPattern([Windows.Automation.TextPattern]::Pattern, [ref]$pattern)) {
                    $value = [string]$pattern.DocumentRange.GetText(500)
                }
            }
            $name = [string]$current.Name
            if (-not $name -and -not $value -and -not $isPassword) { continue }
            if ($value.Length -gt 500) { $value = $value.Substring(0, 500) }
            $out.Add([ordered]@{
                controlType = ($current.ControlType.ProgrammaticName -replace '^ControlType\.', '')
                name = $name; automationId = [string]$current.AutomationId; value = $value
                isPassword = $isPassword; offscreen = [bool]$current.IsOffscreen
            })
        } catch {
            if ($ExactId) {
                Complete-Worker @{ ok = $false; refused = $true; error = 'exact UIA read unavailable; refresh the target' } 2
            }
            continue
        }
    }
    if ($ExactId -and $out.Count -ne 1) {
        Complete-Worker @{ ok = $false; refused = $true; error = 'exact UIA read returned no readable content' } 2
    }
    return @($out)
}

# Structured UIA reads enumerate metadata first, fingerprint the complete
# matching sequence, and only then read Value/Text for the requested page. The
# opaque continuation contains hashes and an offset, never UI text or IDs.
function Get-UiaReadablePage($Root, [int] $Limit, $Query, [string] $Continuation = '', [string] $TargetKey = '', [bool] $TargetStable = $true) {
    function Get-QueryValue([string] $Name) {
        $property = $Query.PSObject.Properties[$Name]
        if ($null -eq $property -or $null -eq $property.Value) { return '' }
        return [string]$property.Value
    }
    function Get-TextHash([string] $Text) {
        $algorithm = [Security.Cryptography.SHA256]::Create()
        try {
            $bytes = [Text.Encoding]::UTF8.GetBytes($Text)
            return ([BitConverter]::ToString($algorithm.ComputeHash($bytes)) -replace '-', '').ToLowerInvariant()
        } finally { $algorithm.Dispose() }
    }
    function ConvertTo-ContinuationToken([int] $Offset, [string] $QueryHash, [string] $TreeHash) {
        $payload = [ordered]@{
            schema = 'win-use-master/uia-continuation-v1'
            offset = $Offset
            queryHash = $QueryHash
            treeHash = $TreeHash
        }
        $bytes = [Text.Encoding]::UTF8.GetBytes(($payload | ConvertTo-Json -Compress))
        return [Convert]::ToBase64String($bytes).TrimEnd('=').Replace('+', '-').Replace('/', '_')
    }
    function ConvertFrom-ContinuationToken([string] $Token) {
        $decoded = $null
        $parsedOffset = 0
        $invalid = [string]::IsNullOrWhiteSpace($Token) -or $Token.Length -gt 2048 -or $Token -notmatch '^[A-Za-z0-9_-]+$'
        if (-not $invalid) {
            try {
                $base64 = $Token.Replace('-', '+').Replace('_', '/')
                switch ($base64.Length % 4) { 2 { $base64 += '==' } 3 { $base64 += '=' } 1 { throw 'invalid base64url length' } }
                $decoded = [Text.Encoding]::UTF8.GetString([Convert]::FromBase64String($base64)) | ConvertFrom-Json
                $properties = @($decoded.PSObject.Properties.Name)
                $invalid = $null -eq $decoded -or $decoded -is [Array] -or $properties.Count -ne 4 -or
                    @('schema', 'offset', 'queryHash', 'treeHash' | Where-Object { $_ -notin $properties }).Count -ne 0 -or
                    [string]$decoded.schema -ne 'win-use-master/uia-continuation-v1' -or
                    -not [int]::TryParse([string]$decoded.offset, [Globalization.NumberStyles]::None,
                        [Globalization.CultureInfo]::InvariantCulture, [ref]$parsedOffset) -or
                    [string]$decoded.queryHash -notmatch '^[0-9a-f]{64}$' -or
                    [string]$decoded.treeHash -notmatch '^[0-9a-f]{64}$'
            } catch { $invalid = $true }
        }
        if ($invalid) {
            Complete-Worker @{ ok = $false; refused = $true; error = 'UIA continuation is invalid; restart the query' } 2
        }
        $decoded.offset = $parsedOffset
        return $decoded
    }
    function Get-RuntimeKey($Element) {
        try {
            $runtimeId = @($Element.GetRuntimeId())
            if ($runtimeId.Count) { return $runtimeId -join ',' }
        } catch { }
        return ''
    }

    $idExact = Get-QueryValue 'idExact'
    $idPrefix = Get-QueryValue 'idPrefix'
    $controlType = Get-QueryValue 'controlType'
    $nameExact = Get-QueryValue 'nameExact'
    $namePrefix = Get-QueryValue 'namePrefix'
    $withinId = Get-QueryValue 'withinId'
    $readableTypes = [ordered]@{
        Text = [Windows.Automation.ControlType]::Text
        Document = [Windows.Automation.ControlType]::Document
        Edit = [Windows.Automation.ControlType]::Edit
        StatusBar = [Windows.Automation.ControlType]::StatusBar
        Header = [Windows.Automation.ControlType]::Header
        HeaderItem = [Windows.Automation.ControlType]::HeaderItem
    }
    if (($idExact -and $idPrefix) -or ($nameExact -and $namePrefix) -or
        ($controlType -and -not $readableTypes.Contains($controlType))) {
        Complete-Worker @{ ok = $false; refused = $true; error = 'invalid structured UIA query' } 2
    }

    $scopeRoot = $Root
    $scopeRuntimeKey = ''
    if ($withinId) {
        try {
            $withinCondition = [Windows.Automation.PropertyCondition]::new(
                [Windows.Automation.AutomationElement]::AutomationIdProperty, $withinId)
            $withinFound = $Root.FindAll([Windows.Automation.TreeScope]::Descendants, $withinCondition)
        } catch {
            Complete-Worker @{ ok = $false; refused = $true; error = 'UIA query scope unavailable; refresh the target' } 2
        }
        if ($withinFound.Count -ne 1) {
            Complete-Worker @{ ok = $false; refused = $true; error = 'within-id must match one container' } 2
        }
        try {
            $scopeRoot = $withinFound.Item(0)
            if ([string]$scopeRoot.Current.AutomationId -cne $withinId) { throw 'scope identity changed' }
            $scopeRuntimeKey = Get-RuntimeKey $scopeRoot
        } catch {
            Complete-Worker @{ ok = $false; refused = $true; error = 'UIA query scope changed; restart the query' } 2
        }
    }

    $typeConditions = [Collections.Generic.List[Windows.Automation.Condition]]::new()
    foreach ($entry in $readableTypes.GetEnumerator()) {
        $typeConditions.Add([Windows.Automation.PropertyCondition]::new(
            [Windows.Automation.AutomationElement]::ControlTypeProperty, $entry.Value))
    }
    [Windows.Automation.Condition]$condition = [Windows.Automation.OrCondition]::new($typeConditions.ToArray())
    if ($idExact) {
        $condition = [Windows.Automation.AndCondition]::new($condition,
            [Windows.Automation.PropertyCondition]::new(
                [Windows.Automation.AutomationElement]::AutomationIdProperty, $idExact))
    }
    if ($controlType) {
        $condition = [Windows.Automation.AndCondition]::new($condition,
            [Windows.Automation.PropertyCondition]::new(
                [Windows.Automation.AutomationElement]::ControlTypeProperty, $readableTypes[$controlType]))
    }
    if ($nameExact) {
        $condition = [Windows.Automation.AndCondition]::new($condition,
            [Windows.Automation.PropertyCondition]::new(
                [Windows.Automation.AutomationElement]::NameProperty, $nameExact))
    }
    try {
        $found = $scopeRoot.FindAll([Windows.Automation.TreeScope]::Descendants, $condition)
    } catch {
        Complete-Worker @{ ok = $false; refused = $true; error = 'structured UIA query unavailable; refresh the target' } 2
    }
    # With no prefix post-filter, every exact condition was evaluated by the
    # provider. Preserve --id's fail-before-content uniqueness contract.
    if ($idExact -and -not $idPrefix -and -not $namePrefix -and $found.Count -ne 1) {
        Complete-Worker @{ ok = $false; refused = $true; error = 'exact AutomationId query must match one readable element' } 2
    }

    $metadata = [Collections.Generic.List[object]]::new()
    for ($i = 0; $i -lt $found.Count; $i++) {
        try {
            $element = $found.Item($i)
            $current = $element.Current
            $itemType = $current.ControlType.ProgrammaticName -replace '^ControlType\.', ''
            $itemId = [string]$current.AutomationId
            if ($idExact -and $itemId -cne $idExact) { throw 'id identity changed' }
            if ($controlType -and $itemType -cne $controlType) { throw 'type identity changed' }
            if ($idPrefix -and -not $itemId.StartsWith($idPrefix, [StringComparison]::Ordinal)) { continue }
            # Apply the least sensitive prefix first so an AutomationId miss does
            # not require reading the accessible Name at all.
            $itemName = [string]$current.Name
            if ($nameExact -and $itemName -cne $nameExact) { throw 'name identity changed' }
            if ($namePrefix -and -not $itemName.StartsWith($namePrefix, [StringComparison]::Ordinal)) { continue }
            $metadata.Add([pscustomobject][ordered]@{
                Element = $element
                RuntimeKey = Get-RuntimeKey $element
                ControlType = $itemType
                AutomationId = $itemId
                Name = $itemName
                IsPassword = [bool]$current.IsPassword
                Offscreen = [bool]$current.IsOffscreen
            })
        } catch {
            Complete-Worker @{ ok = $false; refused = $true; error = 'UIA query metadata changed; restart the query' } 2
        }
    }
    if ($idExact -and $metadata.Count -ne 1) {
        Complete-Worker @{ ok = $false; refused = $true; error = 'exact AutomationId query must match one readable element' } 2
    }

    $queryCanonical = [ordered]@{
        target = $TargetKey; idExact = $idExact; idPrefix = $idPrefix; controlType = $controlType
        nameExact = $nameExact; namePrefix = $namePrefix; withinId = $withinId
    } | ConvertTo-Json -Compress
    $queryHash = Get-TextHash $queryCanonical
    $treeCanonical = @($metadata | ForEach-Object {
        "$($_.RuntimeKey.Length):$($_.RuntimeKey)|$($_.ControlType.Length):$($_.ControlType)|$($_.AutomationId.Length):$($_.AutomationId)|$($_.Name.Length):$($_.Name)|$($_.IsPassword)|$($_.Offscreen)"
    }) -join "`n"
    $treeHash = Get-TextHash ("scope=$scopeRuntimeKey`ncount=$($metadata.Count)`n$treeCanonical")
    $offset = 0
    if ($Continuation) {
        $token = ConvertFrom-ContinuationToken $Continuation
        if ([string]$token.queryHash -cne $queryHash) {
            Complete-Worker @{ ok = $false; refused = $true; error = 'UIA continuation belongs to another query; restart the query' } 2
        }
        if ([string]$token.treeHash -cne $treeHash) {
            Complete-Worker @{ ok = $false; refused = $true; error = 'UIA tree changed after the previous page; restart the query' } 2
        }
        $offset = [int]$token.offset
        if ($offset -lt 0 -or $offset -ge $metadata.Count) {
            Complete-Worker @{ ok = $false; refused = $true; error = 'UIA continuation offset is stale; restart the query' } 2
        }
    }

    $out = [Collections.Generic.List[object]]::new()
    $cursor = $offset
    while ($cursor -lt $metadata.Count -and $out.Count -lt $Limit) {
        $item = $metadata[$cursor]
        $cursor++
        try {
            $current = $item.Element.Current
            $runtimeKey = Get-RuntimeKey $item.Element
            $itemType = $current.ControlType.ProgrammaticName -replace '^ControlType\.', ''
            if (-not $runtimeKey -or $runtimeKey -cne $item.RuntimeKey -or
                $itemType -cne $item.ControlType -or
                [string]$current.AutomationId -cne $item.AutomationId -or
                [string]$current.Name -cne $item.Name -or
                [bool]$current.IsPassword -ne $item.IsPassword -or
                [bool]$current.IsOffscreen -ne $item.Offscreen) {
                throw 'selected identity changed'
            }
            $value = ''
            if (-not $item.IsPassword) {
                $pattern = $null
                if ($item.Element.TryGetCurrentPattern([Windows.Automation.ValuePattern]::Pattern, [ref]$pattern)) {
                    $value = [string]$pattern.Current.Value
                } elseif ($item.Element.TryGetCurrentPattern([Windows.Automation.TextPattern]::Pattern, [ref]$pattern)) {
                    $value = [string]$pattern.DocumentRange.GetText(500)
                }
            }
            if (-not $item.Name -and -not $value -and -not $item.IsPassword) { continue }
            if ($value.Length -gt 500) { $value = $value.Substring(0, 500) }
            $out.Add([ordered]@{
                controlType = $item.ControlType
                name = $item.Name
                automationId = $item.AutomationId
                value = $value
                isPassword = $item.IsPassword
                offscreen = $item.Offscreen
            })
        } catch {
            Complete-Worker @{ ok = $false; refused = $true; error = 'UIA selected element changed before reading; restart the query' } 2
        }
    }

    $hasMore = $cursor -lt $metadata.Count
    if (($Continuation -or $hasMore) -and -not $TargetStable) {
        Complete-Worker @{ ok = $false; refused = $true; error = 'stable target process identity unavailable; narrow or restart the query' } 2
    }
    if (($Continuation -or $hasMore) -and
        (($withinId -and -not $scopeRuntimeKey) -or @($metadata | Where-Object { -not $_.RuntimeKey }).Count)) {
        Complete-Worker @{ ok = $false; refused = $true; error = 'stable UIA runtime identity unavailable; narrow or restart the query' } 2
    }
    if ($idExact -and $out.Count -ne 1) {
        Complete-Worker @{ ok = $false; refused = $true; error = 'exact UIA read returned no readable content' } 2
    }
    $next = if ($hasMore) { ConvertTo-ContinuationToken $cursor $queryHash $treeHash } else { $null }
    return [pscustomobject][ordered]@{
        items = @($out)
        page = [pscustomobject][ordered]@{
            schema = 'win-use-master/uia-page-v1'
            offset = $offset
            nextOffset = $cursor
            matched = $metadata.Count
            returned = $out.Count
            hasMore = $hasMore
            continuation = $next
        }
    }
}

function Resolve-Element($Elements, [string] $Reference, $Spec) {
    if ($Reference -eq 'first') {
        # Prefer a real Edit; fall back to a Document that exposes ValuePattern so
        # single-document editors are writable without a hand-picked ref.
        $edit = @($Elements | Where-Object ControlType -EQ 'Edit' | Select-Object -First 1)
        if ($edit.Count) { return $edit }
        return @($Elements | Where-Object { $_.ControlType -eq 'Document' -and 'ValuePattern' -in $_.Patterns } | Select-Object -First 1)
    }
    if ($Reference -notmatch '^e\d+$') { return @() }
    if ($null -eq $Spec) { return @($Elements | Where-Object Ref -EQ $Reference | Select-Object -First 1) }
    $candidates = @(if ([string]$Spec.automationId) {
        $Elements | Where-Object AutomationId -EQ ([string]$Spec.automationId)
    } else {
        $Elements | Where-Object { $_.Name -eq [string]$Spec.name -and $_.ControlType -eq [string]$Spec.controlType }
    })
    if (-not $candidates.Count) { return @() }
    return @($candidates | Sort-Object @{ Expression = {
        [Math]::Pow($_.Cx - [double]$Spec.cx, 2) + [Math]::Pow($_.Cy - [double]$Spec.cy, 2)
    } } | Select-Object -First 1)
}

try {
    Add-Type -AssemblyName UIAutomationClient
    Add-Type -AssemblyName UIAutomationTypes
    $raw = [Console]::In.ReadToEnd()
    if ([string]::IsNullOrWhiteSpace($raw)) { Complete-Worker @{ ok = $false; error = 'empty request' } 1 }
    $request = $raw | ConvertFrom-Json
    # Deterministic regression hook. It is inert unless a test process sets the
    # exact mode name in its inherited environment.
    if ($env:HUASHU_UIA_WORKER_TEST_HANG -eq [string]$request.mode) {
        Start-Sleep -Seconds 60
    }
    $root = [Windows.Automation.AutomationElement]::FromHandle([IntPtr][long]$request.hwnd)
    if ($null -eq $root) { Complete-Worker @{ ok = $false; error = 'window UIA root unavailable' } 2 }
    $mode = [string]$request.mode
    $limit = if ($request.limit) { [Math]::Max(1, [Math]::Min(500, [int]$request.limit)) } else { 300 }

    if ($mode -eq 'read') {
        $exactId = if ($request.PSObject.Properties.Name -contains 'exactId') { [string]$request.exactId } else { '' }
        $query = if ($request.PSObject.Properties.Name -contains 'query') { $request.query } else { $null }
        if ($null -ne $query) {
            $continuation = if ($request.PSObject.Properties.Name -contains 'continuation') { [string]$request.continuation } else { '' }
            $targetPid = if ($request.window.PSObject.Properties.Name -contains 'pid') { [string]$request.window.pid } else { '' }
            $targetStarted = if ($request.window.PSObject.Properties.Name -contains 'processStartTicks') { [string]$request.window.processStartTicks } else { '' }
            $targetKey = "hwnd=$($request.hwnd);pid=$targetPid;start=$targetStarted"
            $targetStable = $targetPid -match '^[1-9][0-9]*$' -and $targetStarted -match '^[1-9][0-9]*$'
            $page = Get-UiaReadablePage $root $limit $query $continuation $targetKey $targetStable
            Complete-Worker @{ schema = 'win-use-master/uia-query-result-v1'; ok = $true; items = @($page.items); page = $page.page }
        }
        $items = @(Get-ReadableElements $root $limit -ExactId $exactId)
        Complete-Worker @{ ok = $true; items = $items }
    }

    $elements = @(Get-ActionElements $root $request.window $limit)
    if ($mode -eq 'list') {
        Complete-Worker @{ ok = $true; items = @($elements | ForEach-Object { Public-Element $_ }) }
    }

    $spec = if ($request.PSObject.Properties.Name -contains 'spec') { $request.spec } else { $null }
    $selected = @(Resolve-Element $elements ([string]$request.reference) $spec)
    if (-not $selected.Count) { Complete-Worker @{ ok = $false; refused = $true; error = 'UIA reference no longer resolves uniquely' } 2 }
    $item = $selected[0]
    if ($mode -eq 'resolve') { Complete-Worker @{ ok = $true; item = Public-Element $item } }

    if ($mode -eq 'set') {
        if ($item.IsPassword) { Complete-Worker @{ ok = $false; refused = $true; error = 'password/credential field refused' } 2 }
        $pattern = $null
        if (-not $item.Element.TryGetCurrentPattern([Windows.Automation.ValuePattern]::Pattern, [ref]$pattern)) {
            Complete-Worker @{ ok = $false; refused = $true; error = 'ValuePattern unavailable' } 2
        }
        $before = [string]$pattern.Current.Value
        $text = [string]$request.text
        $pattern.SetValue($text)
        Start-Sleep -Milliseconds 250
        $afterPattern = $null; $after = ''
        if ($item.Element.TryGetCurrentPattern([Windows.Automation.ValuePattern]::Pattern, [ref]$afterPattern)) {
            $after = [string]$afterPattern.Current.Value
        }
        Complete-Worker @{
            ok = $true; item = Public-Element $item; pattern = 'ValuePattern'
            beforeLength = $before.Length; afterLength = $after.Length
            changed = ($after -ne $before); matchesRequest = ($after -eq $text)
        }
    }

    if ($mode -eq 'invoke') {
        $riskPolicy = Get-RiskPolicy
        $semanticIdentity = @($item.Name, $item.AutomationId, $item.ClassName) -join ' '
        $blockedRule = Find-BlockedActionRule $riskPolicy $semanticIdentity
        if ($blockedRule) {
            Complete-Worker @{ ok = $false; refused = $true; error = "high-risk final action refused by $blockedRule" } 2
        }
        if ([string]::IsNullOrWhiteSpace([string]$item.Name) -and
            [string]$item.ControlType -in @('Button','Hyperlink','MenuItem')) {
            Complete-Worker @{ ok = $false; refused = $true; error = 'unlabeled action target refused' } 2
        }
        $pattern = $null; $used = ''
        if ($item.Element.TryGetCurrentPattern([Windows.Automation.InvokePattern]::Pattern, [ref]$pattern)) { $pattern.Invoke(); $used = 'InvokePattern' }
        elseif ($item.Element.TryGetCurrentPattern([Windows.Automation.TogglePattern]::Pattern, [ref]$pattern)) { $pattern.Toggle(); $used = 'TogglePattern' }
        elseif ($item.Element.TryGetCurrentPattern([Windows.Automation.SelectionItemPattern]::Pattern, [ref]$pattern)) { $pattern.Select(); $used = 'SelectionItemPattern' }
        elseif ($item.Element.TryGetCurrentPattern([Windows.Automation.ExpandCollapsePattern]::Pattern, [ref]$pattern)) { $pattern.Expand(); $used = 'ExpandCollapsePattern' }
        else { Complete-Worker @{ ok = $false; refused = $true; error = 'action pattern unavailable' } 2 }
        Complete-Worker @{ ok = $true; item = Public-Element $item; pattern = $used }
    }

    Complete-Worker @{ ok = $false; error = "unknown mode: $mode" } 1
} catch {
    Complete-Worker @{ ok = $false; error = $_.Exception.Message } 1
}
