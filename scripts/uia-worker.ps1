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

function Get-RiskPolicy {
    $path = Join-Path (Split-Path -Parent $PSScriptRoot) 'config\risk-actions.json'
    if (-not (Test-Path -LiteralPath $path -PathType Leaf)) {
        Complete-Worker @{ ok = $false; refused = $true; error = 'risk policy unavailable' } 2
    }
    try {
        $policy = Get-Content -LiteralPath $path -Raw -Encoding utf8 | ConvertFrom-Json
    } catch {
        Complete-Worker @{ ok = $false; refused = $true; error = 'risk policy invalid' } 2
    }
    if ([string]$policy.schema -ne 'win-use-master/risk-actions-v1' -or
        -not @($policy.blockedTextPatterns).Count -or
        @($policy.blockedKeyChords) -notcontains 'Enter' -or
        @($policy.blockedDomSemantics) -notcontains 'form-submit') {
        Complete-Worker @{ ok = $false; refused = $true; error = 'risk policy schema mismatch' } 2
    }
    return $policy
}

function Find-BlockedActionRule($Policy, [string] $Text) {
    $normalized = if ($null -eq $Text) { '' } else { $Text.Normalize([Text.NormalizationForm]::FormKC) }
    $normalized = [regex]::Replace($normalized, '([a-z0-9])([A-Z])', '$1 $2') -replace '[_-]+', ' '
    foreach ($rule in @($Policy.blockedTextPatterns)) {
        try {
            if ([regex]::IsMatch($normalized, [string]$rule.pattern, [Text.RegularExpressions.RegexOptions]::IgnoreCase)) {
                return [string]$rule.id
            }
        } catch {
            Complete-Worker @{ ok = $false; refused = $true; error = 'risk policy pattern invalid' } 2
        }
    }
    return $null
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
