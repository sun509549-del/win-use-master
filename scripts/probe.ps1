# probe.ps1 -- Windows app automation capability probe.
#
# This script is deliberately read-only with respect to the target app. It does
# not start, stop, activate, restore, resize, click, type into, or attach a
# debugger to the app. The only network requests it makes are local HTTP GETs to
# /json/version on listening ports already owned by the target process tree.
#
# Usage:
#   pwsh -File .\scripts\probe.ps1 "App display name"
#   pwsh -File .\scripts\probe.ps1 process-name
#   pwsh -File .\scripts\probe.ps1 "C:\Path\App.exe"

[CmdletBinding()]
param(
    [Parameter(Mandatory = $true, Position = 0, ValueFromRemainingArguments = $true)]
    [ValidateNotNullOrEmpty()]
    [string[]] $App
)

$ErrorActionPreference = 'Stop'
$ProbeQuery = (($App -join ' ').Trim().Trim('"'))
$ScriptDir = $PSScriptRoot
$ToolRoot = Split-Path -Parent $ScriptDir
$script:Warnings = [System.Collections.Generic.List[string]]::new()
$script:Candidates = [System.Collections.Generic.List[object]]::new()

function Write-Section([string] $Title) {
    Write-Output ''
    Write-Output ("════ {0} ════" -f $Title)
}

function Add-Warning([string] $Text) {
    if ($Text -and -not $script:Warnings.Contains($Text)) {
        $script:Warnings.Add($Text)
    }
}

function Get-NormalizedName([string] $Text) {
    if ([string]::IsNullOrWhiteSpace($Text)) { return '' }
    $name = $Text.Trim().Trim('"').ToLowerInvariant()
    $name = [IO.Path]::GetFileName($name)
    $name = $name -replace '\.(exe|lnk|appref-ms)$', ''
    return ($name -replace '[\s_\-\.（）()\[\]]+', '')
}

function Get-NameMatchScore([string] $Actual, [string] $Wanted) {
    $a = Get-NormalizedName $Actual
    $w = Get-NormalizedName $Wanted
    if (-not $a -or -not $w) { return 0 }
    if ($a -eq $w) { return 100 }
    if ($a.StartsWith($w) -or $w.StartsWith($a)) { return 72 }
    if ($w.Length -ge 2 -and ($a.Contains($w) -or $w.Contains($a))) { return 52 }
    return 0
}

function ConvertTo-ExecutablePath([string] $Raw) {
    if ([string]::IsNullOrWhiteSpace($Raw)) { return $null }
    $value = [Environment]::ExpandEnvironmentVariables($Raw.Trim())
    if ($value.StartsWith('@{')) { return $null }

    if ($value -match '^\s*"([^"\r\n]+\.(?:exe|lnk))"') {
        $value = $Matches[1]
    }
    elseif ($value -match '^\s*([^\r\n]+?\.(?:exe|lnk))(?:\s*,\s*-?\d+|\s+--?.*)?\s*$') {
        $value = $Matches[1].Trim().Trim('"')
    }
    else {
        $value = $value.Trim().Trim('"')
    }

    try {
        if (Test-Path -LiteralPath $value -PathType Leaf) {
            return [IO.Path]::GetFullPath((Get-Item -LiteralPath $value -Force).FullName)
        }
    }
    catch { }
    return $null
}

function Get-FileFacts([string] $Path) {
    $facts = [ordered]@{
        FileVersion = $null
        ProductVersion = $null
        ProductName = $null
        Description = $null
        Company = $null
        OriginalFilename = $null
    }
    if (-not $Path) { return [pscustomobject]$facts }
    try {
        $v = [Diagnostics.FileVersionInfo]::GetVersionInfo($Path)
        $facts.FileVersion = $v.FileVersion
        $facts.ProductVersion = $v.ProductVersion
        $facts.ProductName = $v.ProductName
        $facts.Description = $v.FileDescription
        $facts.Company = $v.CompanyName
        $facts.OriginalFilename = $v.OriginalFilename
    }
    catch { }
    return [pscustomobject]$facts
}

function Find-BestExecutable([string] $Directory, [string] $Wanted, [string] $DisplayName) {
    if (-not $Directory) { return $null }
    try {
        if (-not (Test-Path -LiteralPath $Directory -PathType Container)) { return $null }
        $root = (Get-Item -LiteralPath $Directory -Force).FullName
    }
    catch { return $null }

    # Two levels catch Squirrel's app-<version> layout without walking an entire
    # vendor tree. Cap the list so a broad path such as System32 remains cheap.
    $files = [System.Collections.Generic.List[IO.FileInfo]]::new()
    try {
        foreach ($f in @(Get-ChildItem -LiteralPath $root -File -Filter '*.exe' -Force -ErrorAction SilentlyContinue)) {
            if ($files.Count -lt 350) { $files.Add($f) }
        }
        foreach ($d in @(Get-ChildItem -LiteralPath $root -Directory -Force -ErrorAction SilentlyContinue)) {
            if ($files.Count -ge 350) { break }
            if ($d.Name -match '^(app[-_]|current$|bin$|x64$|x86$|win32$|win64$)' -or $d.Name -match '^\d+(?:\.\d+)+$') {
                foreach ($f in @(Get-ChildItem -LiteralPath $d.FullName -File -Filter '*.exe' -Force -ErrorAction SilentlyContinue)) {
                    if ($files.Count -lt 350) { $files.Add($f) }
                }
            }
        }
    }
    catch { }
    if ($files.Count -eq 0) { return $null }

    $ranked = foreach ($f in $files) {
        $score = Get-NameMatchScore $f.BaseName $Wanted
        $score = [Math]::Max($score, (Get-NameMatchScore $f.BaseName $DisplayName))
        if ($f.BaseName -match '(?i)unins|uninstall|setup|update|crash|report|helper|renderer|service|elevat') { $score -= 45 }
        if ($f.Length -gt 1MB) { $score += 3 }
        if ($score -lt 70) {
            $ff = Get-FileFacts $f.FullName
            $score = [Math]::Max($score, (Get-NameMatchScore $ff.ProductName $DisplayName))
            $score = [Math]::Max($score, (Get-NameMatchScore $ff.Description $DisplayName))
            $score = [Math]::Max($score, (Get-NameMatchScore $ff.ProductName $Wanted))
        }
        [pscustomobject]@{ Path = $f.FullName; Score = $score; Size = $f.Length }
    }
    return ($ranked | Sort-Object Score, Size -Descending | Select-Object -First 1).Path
}

function Add-Candidate {
    param(
        [string] $Path,
        [string] $InstallLocation,
        [string] $DisplayName,
        [string] $DisplayVersion,
        [string] $Source,
        [int] $Score,
        [Nullable[int]] $ProcessId = $null,
        [string] $PackageFamily,
        [string] $AppId
    )
    $resolved = ConvertTo-ExecutablePath $Path
    if (-not $resolved -and $InstallLocation) {
        $resolved = Find-BestExecutable $InstallLocation $ProbeQuery $DisplayName
    }
    $install = $InstallLocation
    if (-not $install -and $resolved) { $install = Split-Path -Parent $resolved }
    if ($install) {
        try {
            if (Test-Path -LiteralPath $install -PathType Container) {
                $install = (Get-Item -LiteralPath $install -Force).FullName
            }
        }
        catch { }
    }
    $script:Candidates.Add([pscustomobject]@{
        Path = $resolved
        InstallLocation = $install
        DisplayName = $DisplayName
        DisplayVersion = $DisplayVersion
        Source = $Source
        Score = $Score
        Pid = $ProcessId
        PackageFamily = $PackageFamily
        AppId = $AppId
    })
}

function Import-HuWin {
    if ('HuWin' -as [type]) { return $true }

    # HuWin references System.Drawing. Windows PowerShell resolves System.Drawing;
    # PowerShell 7 needs System.Drawing.Common loaded before the DLL/source.
    if ($PSVersionTable.PSEdition -eq 'Core') {
        try { Add-Type -AssemblyName System.Drawing.Common -ErrorAction Stop }
        catch {
            try { Add-Type -AssemblyName System.Drawing -ErrorAction Stop } catch { }
        }
    }
    else {
        try { Add-Type -AssemblyName System.Drawing -ErrorAction Stop } catch { }
    }

    $dll = Join-Path $ScriptDir 'HuWin.dll'
    $src = Join-Path $ScriptDir 'HuWin.cs'
    $dllFresh = (Test-Path -LiteralPath $dll -PathType Leaf) -and
        ((-not (Test-Path -LiteralPath $src -PathType Leaf)) -or
         (Get-Item -LiteralPath $dll).LastWriteTimeUtc -ge (Get-Item -LiteralPath $src).LastWriteTimeUtc)
    if ($dllFresh) {
        try { Add-Type -Path $dll -ErrorAction Stop }
        catch { Add-Warning ("HuWin.dll 加载失败，将尝试源码：{0}" -f $_.Exception.Message) }
    }
    if (-not ('HuWin' -as [type]) -and (Test-Path -LiteralPath $src -PathType Leaf)) {
        try {
            $refs = @()
            $refDir = Join-Path $PSHOME 'ref'
            if (Test-Path -LiteralPath $refDir) {
                $refs += @(Get-ChildItem -LiteralPath $refDir -Filter '*.dll' | Select-Object -ExpandProperty FullName)
            }
            foreach ($candidate in @(
                (Join-Path $PSHOME 'System.Drawing.Common.dll'),
                (Join-Path $PSHOME 'System.Windows.Forms.dll'),
                (Join-Path $PSHOME 'System.Windows.Forms.Primitives.dll'),
                (Join-Path $PSHOME 'System.Private.Windows.Core.dll'),
                (Join-Path $PSHOME 'System.Private.Windows.GdiPlus.dll')
            )) { if (Test-Path -LiteralPath $candidate) { $refs += $candidate } }
            if (-not $refs.Count -and $PSVersionTable.PSEdition -eq 'Desktop') {
                $refs = @('mscorlib.dll','System.dll','System.Core.dll','System.Drawing.dll','System.Windows.Forms.dll')
            }
            if ($refs.Count) { Add-Type -Path $src -ReferencedAssemblies $refs -ErrorAction Stop }
            else { Add-Type -Path $src -ErrorAction Stop }
        }
        catch { Add-Warning ("HuWin.cs 编译失败：{0}" -f $_.Exception.Message) }
    }
    return [bool]('HuWin' -as [type])
}

function Get-ProcessSnapshot {
    $result = [System.Collections.Generic.List[object]]::new()
    try {
        foreach ($p in @(Get-CimInstance -ClassName Win32_Process -Property ProcessId, ParentProcessId, Name, ExecutablePath, CommandLine -ErrorAction Stop)) {
            $result.Add([pscustomobject]@{
                Pid = [int]$p.ProcessId
                ParentPid = [int]$p.ParentProcessId
                Name = [string]$p.Name
                ProcessName = ([IO.Path]::GetFileNameWithoutExtension([string]$p.Name))
                Path = [string]$p.ExecutablePath
                CommandLine = [string]$p.CommandLine
            })
        }
    }
    catch {
        Add-Warning ("CIM 进程命令行不可用，动态架构信号会减少：{0}" -f $_.Exception.Message)
        foreach ($p in @(Get-Process -ErrorAction SilentlyContinue)) {
            $path = $null
            try { $path = $p.Path } catch { }
            $result.Add([pscustomobject]@{
                Pid = [int]$p.Id
                ParentPid = 0
                Name = ($p.ProcessName + '.exe')
                ProcessName = $p.ProcessName
                Path = $path
                CommandLine = $null
            })
        }
    }
    return @($result)
}

function Get-UninstallEntries {
    $entries = [System.Collections.Generic.List[object]]::new()
    $locations = @(
        @{ Hive = [Microsoft.Win32.RegistryHive]::CurrentUser; View = [Microsoft.Win32.RegistryView]::Default; Label = 'HKCU' },
        @{ Hive = [Microsoft.Win32.RegistryHive]::LocalMachine; View = [Microsoft.Win32.RegistryView]::Registry64; Label = 'HKLM64' },
        @{ Hive = [Microsoft.Win32.RegistryHive]::LocalMachine; View = [Microsoft.Win32.RegistryView]::Registry32; Label = 'HKLM32' }
    )
    foreach ($loc in $locations) {
        $base = $null; $root = $null
        try {
            $base = [Microsoft.Win32.RegistryKey]::OpenBaseKey($loc.Hive, $loc.View)
            $root = $base.OpenSubKey('SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall')
            if (-not $root) { continue }
            foreach ($subName in $root.GetSubKeyNames()) {
                $sub = $null
                try {
                    $sub = $root.OpenSubKey($subName)
                    if (-not $sub) { continue }
                    $display = [string]$sub.GetValue('DisplayName', '')
                    if (-not $display) { continue }
                    $match = Get-NameMatchScore $display $ProbeQuery
                    if ($match -eq 0) { continue }
                    $entries.Add([pscustomobject]@{
                        DisplayName = $display
                        DisplayVersion = [string]$sub.GetValue('DisplayVersion', '')
                        DisplayIcon = [string]$sub.GetValue('DisplayIcon', '')
                        InstallLocation = [Environment]::ExpandEnvironmentVariables([string]$sub.GetValue('InstallLocation', ''))
                        Source = ("卸载注册表/{0}" -f $loc.Label)
                        Match = $match
                    })
                }
                catch { }
                finally { if ($sub) { $sub.Dispose() } }
            }
        }
        catch { }
        finally {
            if ($root) { $root.Dispose() }
            if ($base) { $base.Dispose() }
        }
    }
    return @($entries)
}

function Get-AppPathMatches {
    $matches = [System.Collections.Generic.List[object]]::new()
    $locations = @(
        @{ Hive = [Microsoft.Win32.RegistryHive]::CurrentUser; View = [Microsoft.Win32.RegistryView]::Default; Label = 'HKCU' },
        @{ Hive = [Microsoft.Win32.RegistryHive]::LocalMachine; View = [Microsoft.Win32.RegistryView]::Registry64; Label = 'HKLM64' },
        @{ Hive = [Microsoft.Win32.RegistryHive]::LocalMachine; View = [Microsoft.Win32.RegistryView]::Registry32; Label = 'HKLM32' }
    )
    foreach ($loc in $locations) {
        $base = $null; $root = $null
        try {
            $base = [Microsoft.Win32.RegistryKey]::OpenBaseKey($loc.Hive, $loc.View)
            $root = $base.OpenSubKey('SOFTWARE\Microsoft\Windows\CurrentVersion\App Paths')
            if (-not $root) { continue }
            foreach ($subName in $root.GetSubKeyNames()) {
                $score = Get-NameMatchScore $subName $ProbeQuery
                if ($score -eq 0) { continue }
                $sub = $null
                try {
                    $sub = $root.OpenSubKey($subName)
                    $path = [string]$sub.GetValue('', '')
                    $matches.Add([pscustomobject]@{
                        Path = $path
                        DisplayName = [IO.Path]::GetFileNameWithoutExtension($subName)
                        Source = ("App Paths/{0}" -f $loc.Label)
                        Match = $score
                    })
                }
                catch { }
                finally { if ($sub) { $sub.Dispose() } }
            }
        }
        catch { }
        finally {
            if ($root) { $root.Dispose() }
            if ($base) { $base.Dispose() }
        }
    }
    return @($matches)
}

function Resolve-Shortcut([string] $Path) {
    $shell = $null; $shortcut = $null
    try {
        $shell = New-Object -ComObject WScript.Shell
        $shortcut = $shell.CreateShortcut($Path)
        return [pscustomobject]@{
            TargetPath = [Environment]::ExpandEnvironmentVariables([string]$shortcut.TargetPath)
            Arguments = [string]$shortcut.Arguments
            WorkingDirectory = [string]$shortcut.WorkingDirectory
        }
    }
    catch { return $null }
    finally {
        if ($shortcut -and [Runtime.InteropServices.Marshal]::IsComObject($shortcut)) {
            [void][Runtime.InteropServices.Marshal]::FinalReleaseComObject($shortcut)
        }
        if ($shell -and [Runtime.InteropServices.Marshal]::IsComObject($shell)) {
            [void][Runtime.InteropServices.Marshal]::FinalReleaseComObject($shell)
        }
    }
}

function Add-ShortcutCandidate([string] $ShortcutPath, [int] $BaseScore) {
    $link = Resolve-Shortcut $ShortcutPath
    if (-not $link) { return }
    $target = ConvertTo-ExecutablePath $link.TargetPath

    # Squirrel shortcuts target Update.exe and name the real exe in
    # --processStart. Prefer the real executable without running Update.exe.
    if ($link.Arguments -match '(?i)--processStart\s+(?:"([^"]+\.exe)"|([^\s]+\.exe))') {
        $leaf = if ($Matches[1]) { $Matches[1] } else { $Matches[2] }
        $baseDir = if ($target) { Split-Path -Parent $target } else { $link.WorkingDirectory }
        if ($baseDir) {
            $direct = Join-Path $baseDir $leaf
            if (Test-Path -LiteralPath $direct -PathType Leaf) { $target = $direct }
            else {
                $found = Get-ChildItem -LiteralPath $baseDir -Filter $leaf -File -Recurse -Depth 2 -ErrorAction SilentlyContinue | Select-Object -First 1
                if ($found) { $target = $found.FullName }
            }
        }
    }
    Add-Candidate -Path $target -DisplayName ([IO.Path]::GetFileNameWithoutExtension($ShortcutPath)) `
        -Source '开始菜单/快捷方式' -Score $BaseScore
}

function Get-PEArchitecture([string] $Path) {
    if (-not $Path) { return '未知' }
    $stream = $null; $reader = $null
    try {
        $stream = [IO.File]::Open($Path, [IO.FileMode]::Open, [IO.FileAccess]::Read, [IO.FileShare]::ReadWrite -bor [IO.FileShare]::Delete)
        $reader = [IO.BinaryReader]::new($stream)
        if ($reader.ReadUInt16() -ne 0x5A4D) { return '非 PE 文件' }
        $stream.Position = 0x3C
        $peOffset = $reader.ReadInt32()
        if ($peOffset -lt 0 -or $peOffset -gt ($stream.Length - 6)) { return 'PE 头损坏' }
        $stream.Position = $peOffset
        if ($reader.ReadUInt32() -ne 0x00004550) { return 'PE 签名无效' }
        $machine = $reader.ReadUInt16()
        $label = switch ($machine) {
            0x014C { 'x86' }
            0x8664 { 'x64' }
            0x01C0 { 'ARM' }
            0x01C4 { 'ARMv7' }
            0xAA64 { 'ARM64' }
            0xA641 { 'ARM64EC' }
            0xA64E { 'ARM64X' }
            0x0200 { 'IA64' }
            0x3A64 { 'CHPE x86' }
            default { '未知 machine' }
        }
        return ("{0} (0x{1:X4})" -f $label, $machine)
    }
    catch { return ("读取失败：{0}" -f $_.Exception.Message) }
    finally {
        if ($reader) { $reader.Dispose() }
        elseif ($stream) { $stream.Dispose() }
    }
}

function Test-SpecificInstallRoot([string] $Path) {
    if (-not $Path) { return $false }
    try { $full = [IO.Path]::GetFullPath($Path).TrimEnd('\') } catch { return $false }
    try {
        $driveRoot = [IO.Path]::GetPathRoot($full).TrimEnd('\')
        if ($full -ieq $driveRoot) { return $false }
    }
    catch { }
    $generic = @(
        $env:SystemRoot,
        (Join-Path $env:SystemRoot 'System32'),
        $env:ProgramFiles,
        ${env:ProgramFiles(x86)},
        $env:LOCALAPPDATA,
        $env:APPDATA,
        $env:USERPROFILE
    ) | Where-Object { $_ }
    foreach ($g in $generic) {
        try { if ($full -ieq ([IO.Path]::GetFullPath($g).TrimEnd('\'))) { return $false } } catch { }
    }
    return $true
}

function Get-DescendantPids([int[]] $Roots, [object[]] $Processes) {
    $set = [Collections.Generic.HashSet[int]]::new()
    foreach ($id in $Roots) { [void]$set.Add([int]$id) }
    $changed = $true
    while ($changed) {
        $changed = $false
        foreach ($p in $Processes) {
            if ($set.Contains([int]$p.ParentPid) -and -not $set.Contains([int]$p.Pid)) {
                [void]$set.Add([int]$p.Pid)
                $changed = $true
            }
        }
    }
    return @($set)
}

function Add-RuntimeSignal {
    param([System.Collections.Generic.List[object]] $List, [string] $Family, [string] $Evidence, [string] $Strength = 'strong')
    if (-not $Evidence) { return }
    $key = "$Family|$Evidence"
    foreach ($old in $List) {
        if (("{0}|{1}" -f $old.Family, $old.Evidence) -eq $key) { return }
    }
    $List.Add([pscustomobject]@{ Family = $Family; Evidence = $Evidence; Strength = $Strength })
}

function Get-StaticRuntimeSignals([string] $ExePath, [string] $InstallRoot) {
    $signals = [System.Collections.Generic.List[object]]::new()
    if ($ExePath) {
        $ff = Get-FileFacts $ExePath
        $meta = @($ff.ProductName, $ff.Description, $ff.Company, $ff.OriginalFilename) -join ' | '
        if ($meta -match '(?i)electron') { Add-RuntimeSignal $signals 'Electron' ("EXE 版本资源：{0}" -f $meta) }
        if ($meta -match '(?i)chromium|google chrome') { Add-RuntimeSignal $signals 'Chromium' ("EXE 版本资源：{0}" -f $meta) }
        if ($meta -match '(?i)CEF|Chromium Embedded') { Add-RuntimeSignal $signals 'CEF' ("EXE 版本资源：{0}" -f $meta) }
        if ($meta -match '(?i)WebView2') { Add-RuntimeSignal $signals 'WebView2' ("EXE 版本资源：{0}" -f $meta) }
    }

    $root = if ($InstallRoot) { $InstallRoot } elseif ($ExePath) { Split-Path -Parent $ExePath } else { $null }
    if (-not $root -or -not (Test-Path -LiteralPath $root -PathType Container)) { return @($signals) }

    # Never recurse through broad system/vendor roots merely because the target
    # executable happens to live there (Explorer in C:\Windows is the canonical
    # example). Direct siblings are enough for those roots.
    $maxDepth = if (Test-SpecificInstallRoot $root) { 4 } else { 0 }
    $visitLimit = if ($maxDepth -gt 0) { 5000 } else { 1000 }
    $queue = [Collections.Generic.Queue[object]]::new()
    $queue.Enqueue([pscustomobject]@{ Path = $root; Depth = 0 })
    $visited = 0
    $skipDirs = '^(?i)(cache|caches|logs?|temp|tmp|node_modules|locales|swiftshader|dictionaries|user data)$'
    while ($queue.Count -gt 0 -and $visited -lt $visitLimit) {
        $item = $queue.Dequeue()
        $children = @()
        try { $children = @(Get-ChildItem -LiteralPath $item.Path -Force -ErrorAction Stop) } catch { continue }
        foreach ($child in $children) {
            $visited++
            if ($visited -ge $visitLimit) { break }
            $n = $child.Name.ToLowerInvariant()
            if ($child.PSIsContainer) {
                if ($n -eq 'app.asar.unpacked') { Add-RuntimeSignal $signals 'Electron' ("目录：{0}" -f $child.FullName.Substring($root.Length).TrimStart('\')) }
                if ($item.Depth -lt $maxDepth -and $n -notmatch $skipDirs) {
                    $queue.Enqueue([pscustomobject]@{ Path = $child.FullName; Depth = $item.Depth + 1 })
                }
                continue
            }
            $relative = $child.FullName.Substring($root.Length).TrimStart('\')
            switch -Regex ($n) {
                '^app\.asar$|^electron\.asar$|^electron\.exe$' { Add-RuntimeSignal $signals 'Electron' ("文件：{0}" -f $relative); continue }
                '^libcef\.dll$|^cefsharp.*\.dll$' { Add-RuntimeSignal $signals 'CEF' ("文件：{0}" -f $relative); continue }
                '^webview2loader\.dll$|^embeddedbrowserwebview\.dll$|^msedgewebview2\.exe$' { Add-RuntimeSignal $signals 'WebView2' ("文件：{0}" -f $relative); continue }
                '^chrome_elf\.dll$' { Add-RuntimeSignal $signals 'Chromium' ("文件：{0}" -f $relative); continue }
                '^icudtl\.dat$|^v8_context_snapshot\.bin$|^snapshot_blob\.bin$|^chrome_(100|200)_percent\.pak$' { Add-RuntimeSignal $signals 'Chromium' ("配套文件：{0}" -f $relative) 'supporting'; continue }
                '^flutter_windows\.dll$' { Add-RuntimeSignal $signals 'Flutter/自绘' ("文件：{0}" -f $relative); continue }
                '^qt[56]core\.dll$' { Add-RuntimeSignal $signals 'Qt/自绘' ("文件：{0}" -f $relative); continue }
                '^nw\.dll$' { Add-RuntimeSignal $signals 'NW.js/Chromium' ("文件：{0}" -f $relative); continue }
            }
        }
    }
    if ($visited -ge $visitLimit) { Add-Warning ("静态运行时文件扫描达到 {0} 项上限；较深的嵌入运行时可能未列出。" -f $visitLimit) }
    return @($signals)
}

function Get-DynamicRuntimeSignals([object[]] $Processes, [object[]] $Windows, [int[]] $RelevantPids) {
    $signals = [System.Collections.Generic.List[object]]::new()
    $pidSet = [Collections.Generic.HashSet[int]]::new()
    foreach ($id in $RelevantPids) { [void]$pidSet.Add([int]$id) }
    foreach ($p in $Processes) {
        if (-not $pidSet.Contains([int]$p.Pid)) { continue }
        $cmd = [string]$p.CommandLine
        if ($p.ProcessName -match '^(?i)electron$') { Add-RuntimeSignal $signals 'Electron' ("pid {0} 进程名 electron" -f $p.Pid) }
        if ($p.ProcessName -match '^(?i)msedgewebview2$') { Add-RuntimeSignal $signals 'WebView2' ("pid {0} 子进程 msedgewebview2" -f $p.Pid) }
        if ($cmd -match '(?i)--webview-exe-name|\\EBWebView\\|--embedded-browser-webview') { Add-RuntimeSignal $signals 'WebView2' ("pid {0} 命令行含 WebView2 标记" -f $p.Pid) }
        if ($cmd -match '(?i)(?:^|\s)--type=(renderer|gpu-process|utility|zygote|broker)') {
            Add-RuntimeSignal $signals 'Chromium' ("pid {0} 参数 --type={1}" -f $p.Pid, $Matches[1])
        }
        if ($cmd -match '(?i)--no-sandbox|--disable-features|--user-data-dir') {
            Add-RuntimeSignal $signals 'Chromium' ("pid {0} 含 Chromium 风格参数" -f $p.Pid) 'supporting'
        }
    }
    foreach ($w in $Windows) {
        if (-not $pidSet.Contains([int]$w.Pid)) { continue }
        if ($w.Cls -match '(?i)^Chrome_WidgetWin_|Chrome_RenderWidgetHostHWND') {
            Add-RuntimeSignal $signals 'Chromium/CEF/Electron' ("窗口类 {0} (pid {1})" -f $w.Cls, $w.Pid)
        }
        elseif ($w.Cls -match '(?i)WebView|CefBrowser') {
            Add-RuntimeSignal $signals 'WebView2/CEF' ("窗口类 {0} (pid {1})" -f $w.Cls, $w.Pid)
        }
    }

    # Loaded modules distinguish CEF/WebView2 when directory names are opaque.
    foreach ($id in @($RelevantPids | Select-Object -First 6)) {
        try {
            $gp = Get-Process -Id $id -ErrorAction Stop
            foreach ($m in @($gp.Modules)) {
                switch -Regex ($m.ModuleName) {
                    '^(?i)libcef\.dll$|^cefsharp.*\.dll$' { Add-RuntimeSignal $signals 'CEF' ("pid {0} 已加载 {1}" -f $id, $m.ModuleName); continue }
                    '^(?i)webview2loader\.dll$|^embeddedbrowserwebview\.dll$' { Add-RuntimeSignal $signals 'WebView2' ("pid {0} 已加载 {1}" -f $id, $m.ModuleName); continue }
                    '^(?i)chrome_elf\.dll$' { Add-RuntimeSignal $signals 'Chromium' ("pid {0} 已加载 {1}" -f $id, $m.ModuleName); continue }
                }
            }
        }
        catch { }
    }
    return @($signals)
}

function Get-ListeningPorts([int[]] $Pids) {
    $pidSet = [Collections.Generic.HashSet[int]]::new()
    foreach ($id in $Pids) { [void]$pidSet.Add([int]$id) }
    if ($pidSet.Count -eq 0) { return @() }
    $ports = [System.Collections.Generic.List[object]]::new()
    try {
        foreach ($c in @(Get-NetTCPConnection -State Listen -ErrorAction Stop)) {
            if ($pidSet.Contains([int]$c.OwningProcess)) {
                $ports.Add([pscustomobject]@{
                    Address = [string]$c.LocalAddress
                    Port = [int]$c.LocalPort
                    Pid = [int]$c.OwningProcess
                })
            }
        }
    }
    catch {
        try {
            foreach ($line in @(& "$env:SystemRoot\System32\netstat.exe" -ano -p tcp 2>$null)) {
                $parts = @($line.Trim() -split '\s+')
                if ($parts.Count -lt 5 -or $parts[0] -ne 'TCP') { continue }
                $owner = 0
                if (-not [int]::TryParse($parts[-1], [ref]$owner) -or -not $pidSet.Contains($owner)) { continue }
                # A listening row has an all-zero foreign endpoint regardless of
                # the localized spelling of LISTENING.
                if ($parts[2] -notmatch '(?:0\.0\.0\.0|\[?::\]?):0$') { continue }
                if ($parts[1] -notmatch '^(.*):(\d+)$') { continue }
                $ports.Add([pscustomobject]@{ Address = $Matches[1].Trim('[', ']'); Port = [int]$Matches[2]; Pid = $owner })
            }
        }
        catch { Add-Warning '无法读取本机 TCP 监听表。' }
    }
    return @($ports | Sort-Object Pid, Port, Address -Unique)
}

function Get-CdpVersion([string] $Address, [int] $Port) {
    $hosts = [System.Collections.Generic.List[string]]::new()
    if ($Address -in @('0.0.0.0', '*', '::', '[::]', '')) {
        $hosts.Add('127.0.0.1'); $hosts.Add('[::1]')
    }
    elseif ($Address -eq '::1') { $hosts.Add('[::1]') }
    elseif ($Address.Contains(':')) { $hosts.Add(('[' + $Address.Trim('[', ']') + ']')) }
    else { $hosts.Add($Address) }

    foreach ($hostName in $hosts) {
        $handler = $null; $client = $null; $response = $null
        try {
            Add-Type -AssemblyName System.Net.Http -ErrorAction SilentlyContinue
            $handler = [Net.Http.HttpClientHandler]::new()
            $handler.UseProxy = $false
            $handler.AllowAutoRedirect = $false
            $client = [Net.Http.HttpClient]::new($handler)
            $client.Timeout = [TimeSpan]::FromMilliseconds(900)
            $client.MaxResponseContentBufferSize = 65536
            $uri = "http://${hostName}:$Port/json/version"
            $response = $client.GetAsync($uri).GetAwaiter().GetResult()
            $body = $response.Content.ReadAsStringAsync().GetAwaiter().GetResult()
            $obj = $null
            try { $obj = $body | ConvertFrom-Json -ErrorAction Stop } catch { }
            $browser = if ($obj) { [string]$obj.Browser } else { $null }
            $ws = if ($obj) { [string]$obj.webSocketDebuggerUrl } else { $null }
            return [pscustomobject]@{
                IsCdp = [bool]($ws -or $browser)
                HttpStatus = [int]$response.StatusCode
                Browser = $browser
                WebSocket = $ws
                Uri = $uri
                Error = $null
            }
        }
        catch { $lastError = $_.Exception.Message }
        finally {
            if ($response) { $response.Dispose() }
            if ($client) { $client.Dispose() }
            elseif ($handler) { $handler.Dispose() }
        }
    }
    return [pscustomobject]@{ IsCdp = $false; HttpStatus = $null; Browser = $null; WebSocket = $null; Uri = $null; Error = $lastError }
}

function Get-RemoteDebugFacts([object[]] $Processes, [int[]] $RelevantPids) {
    $facts = [System.Collections.Generic.List[object]]::new()
    $pidSet = [Collections.Generic.HashSet[int]]::new()
    foreach ($id in $RelevantPids) { [void]$pidSet.Add([int]$id) }
    foreach ($p in $Processes) {
        if (-not $pidSet.Contains([int]$p.Pid) -or -not $p.CommandLine) { continue }
        $cmd = [string]$p.CommandLine
        $matches = [regex]::Matches($cmd, '(?i)(?:^|\s)--remote-debugging-port(?:=|\s+)(\d+)')
        foreach ($m in $matches) {
            $facts.Add([pscustomobject]@{ Pid = $p.Pid; Kind = 'remote-debugging-port'; Value = [int]$m.Groups[1].Value })
        }
        if ($cmd -match '(?i)(?:^|\s)--remote-debugging-pipe(?:\s|$)') {
            $facts.Add([pscustomobject]@{ Pid = $p.Pid; Kind = 'remote-debugging-pipe'; Value = 'present' })
        }
        if ($cmd -match '(?i)(?:^|\s)--inspect(?:-brk)?(?:=|\s+)([^\s"]+)') {
            $facts.Add([pscustomobject]@{ Pid = $p.Pid; Kind = 'Node inspect'; Value = $Matches[1] })
        }
    }
    return @($facts | Sort-Object Pid, Kind, Value -Unique)
}

function Test-TargetReference([string] $Command, [string] $ExePath, [string] $InstallRoot, [string] $ExeName) {
    if (-not $Command) { return $false }
    if ($ExePath -and $Command.IndexOf($ExePath, [StringComparison]::OrdinalIgnoreCase) -ge 0) { return $true }
    # Match the install root as a directory (trailing separator). A bare prefix
    # made D:\apps\qq claim D:\apps\qqmusic\...\QQMusicSvr.exe as its COM server.
    if (Test-SpecificInstallRoot $InstallRoot) {
        $rootPrefix = $InstallRoot.TrimEnd('\') + '\'
        if ($Command.IndexOf($rootPrefix, [StringComparison]::OrdinalIgnoreCase) -ge 0) { return $true }
    }
    if ($ExeName -and $ExeName -notmatch '^(?i)(update|launcher|applicationframehost|explorer)\.exe$') {
        if ($Command -match ('(?i)(?:^|[\\/"\s])' + [regex]::Escape($ExeName) + '(?:"|\s|$)')) { return $true }
    }
    return $false
}

function Get-UrlProtocols([string] $ExePath, [string] $InstallRoot, [string] $PackageRoot) {
    $items = [System.Collections.Generic.List[object]]::new()
    $exeName = if ($ExePath) { [IO.Path]::GetFileName($ExePath) } else { $null }
    $classes = $null
    try {
        $classes = [Microsoft.Win32.Registry]::ClassesRoot
        foreach ($name in $classes.GetSubKeyNames()) {
            $key = $null; $commandKey = $null
            try {
                $key = $classes.OpenSubKey($name)
                if (-not $key) { continue }
                $marker = $key.GetValue('URL Protocol', $null, [Microsoft.Win32.RegistryValueOptions]::DoNotExpandEnvironmentNames)
                if ($null -eq $marker) { continue }
                $commandKey = $key.OpenSubKey('shell\open\command')
                $command = if ($commandKey) { [string]$commandKey.GetValue('', '') } else { '' }
                if (Test-TargetReference $command $ExePath $InstallRoot $exeName) {
                    $items.Add([pscustomobject]@{ Scheme = $name; Source = '注册表 URL Protocol'; Detail = $command })
                }
            }
            catch { }
            finally {
                if ($commandKey) { $commandKey.Dispose() }
                if ($key) { $key.Dispose() }
            }
        }
    }
    catch { Add-Warning 'URL Protocol 注册表枚举失败。' }

    $manifest = if ($PackageRoot) { Join-Path $PackageRoot 'AppxManifest.xml' } else { $null }
    if ($manifest -and (Test-Path -LiteralPath $manifest -PathType Leaf)) {
        try {
            [xml]$xml = Get-Content -LiteralPath $manifest -Raw
            foreach ($node in @($xml.SelectNodes("//*[local-name()='Extension' and @Category='windows.protocol']/*[local-name()='Protocol']"))) {
                if ($node.Name) { $items.Add([pscustomobject]@{ Scheme = [string]$node.Name; Source = 'AppxManifest'; Detail = $manifest }) }
            }
            foreach ($node in @($xml.SelectNodes("//*[local-name()='Protocol']"))) {
                $scheme = [string]$node.GetAttribute('Name')
                if ($scheme -and -not ($items | Where-Object Scheme -EQ $scheme)) {
                    $items.Add([pscustomobject]@{ Scheme = $scheme; Source = 'AppxManifest'; Detail = $manifest })
                }
            }
        }
        catch { Add-Warning 'AppxManifest URL protocol 解析失败。' }
    }
    return @($items | Sort-Object Scheme -Unique)
}

function Get-RegistryDefault($Key, [string] $SubKey) {
    $sub = $null
    try {
        $sub = $Key.OpenSubKey($SubKey)
        if (-not $sub) { return '' }
        return [string]$sub.GetValue('', '')
    }
    catch { return '' }
    finally { if ($sub) { $sub.Dispose() } }
}

# COM automation is the Windows counterpart of an AppleScript dictionary: Office,
# WPS, Photoshop, AutoCAD, Visio and many line-of-business apps expose an object
# model through registered LocalServer32 classes and type libraries. This only
# reads the registry; instantiating a ProgID could launch a second instance.
function Get-ComAutomationFacts([string] $ExePath, [string] $InstallRoot) {
    $servers = [System.Collections.Generic.List[object]]::new()
    $typeLibs = [System.Collections.Generic.List[object]]::new()
    $exeName = if ($ExePath) { [IO.Path]::GetFileName($ExePath) } else { $null }
    $budget = [Diagnostics.Stopwatch]::StartNew()
    $visited = 0
    $truncated = $false
    if (-not $ExePath -and -not (Test-SpecificInstallRoot $InstallRoot)) {
        return [pscustomobject]@{ Servers = @(); TypeLibs = @(); Truncated = $false; Visited = 0 }
    }

    foreach ($view in @('CLSID', 'WOW6432Node\CLSID')) {
        $root = $null
        try { $root = [Microsoft.Win32.Registry]::ClassesRoot.OpenSubKey($view) } catch { $root = $null }
        if (-not $root) { continue }
        try {
            foreach ($clsid in $root.GetSubKeyNames()) {
                $visited++
                if ($budget.Elapsed.TotalSeconds -gt 8 -or $visited -gt 60000) { $truncated = $true; break }
                $key = $null
                try {
                    $key = $root.OpenSubKey($clsid)
                    if (-not $key) { continue }
                    $server = ''
                    $kind = $null
                    foreach ($serverKey in @('LocalServer32', 'LocalServer')) {
                        $sub = $key.OpenSubKey($serverKey)
                        if (-not $sub) { continue }
                        try { $server = [string]$sub.GetValue('', '', [Microsoft.Win32.RegistryValueOptions]::DoNotExpandEnvironmentNames) } finally { $sub.Dispose() }
                        if ($server) { $kind = $serverKey; break }
                    }
                    if (-not $server) { continue }
                    $expanded = [Environment]::ExpandEnvironmentVariables($server)
                    if (-not (Test-TargetReference $expanded $ExePath $InstallRoot $exeName)) { continue }
                    $servers.Add([pscustomobject]@{
                        Clsid = $clsid; Name = [string]$key.GetValue('', '')
                        ProgId = Get-RegistryDefault $key 'ProgID'
                        VersionIndependentProgId = Get-RegistryDefault $key 'VersionIndependentProgID'
                        TypeLib = Get-RegistryDefault $key 'TypeLib'
                        Server = $expanded; Kind = $kind; View = $view
                    })
                }
                catch { }
                finally { if ($key) { $key.Dispose() } }
            }
        }
        finally { $root.Dispose() }
        if ($truncated) { break }
    }

    $tlRoot = $null
    try { $tlRoot = [Microsoft.Win32.Registry]::ClassesRoot.OpenSubKey('TypeLib') } catch { $tlRoot = $null }
    if ($tlRoot -and -not $truncated) {
        try {
            foreach ($guid in $tlRoot.GetSubKeyNames()) {
                $visited++
                if ($budget.Elapsed.TotalSeconds -gt 10) { $truncated = $true; break }
                $guidKey = $null
                try {
                    $guidKey = $tlRoot.OpenSubKey($guid)
                    if (-not $guidKey) { continue }
                    foreach ($version in $guidKey.GetSubKeyNames()) {
                        $versionKey = $null
                        try {
                            $versionKey = $guidKey.OpenSubKey($version)
                            if (-not $versionKey) { continue }
                            $description = [string]$versionKey.GetValue('', '')
                            foreach ($lcid in $versionKey.GetSubKeyNames()) {
                                if ($lcid -notmatch '^\d+$') { continue }
                                $lcidKey = $null
                                try {
                                    $lcidKey = $versionKey.OpenSubKey($lcid)
                                    if (-not $lcidKey) { continue }
                                    foreach ($platform in @('win32', 'win64')) {
                                        $platformKey = $lcidKey.OpenSubKey($platform)
                                        if (-not $platformKey) { continue }
                                        try {
                                            $file = [Environment]::ExpandEnvironmentVariables([string]$platformKey.GetValue('', ''))
                                            # A trailing "\N" selects a resource id inside the file.
                                            $filePath = $file -replace '\\\d+$', ''
                                            if ($filePath -and (Test-TargetReference $filePath $ExePath $InstallRoot $exeName)) {
                                                $typeLibs.Add([pscustomobject]@{ Guid = $guid; Version = $version; Description = $description; Platform = $platform; File = $filePath })
                                            }
                                        }
                                        finally { $platformKey.Dispose() }
                                    }
                                }
                                catch { }
                                finally { if ($lcidKey) { $lcidKey.Dispose() } }
                            }
                        }
                        catch { }
                        finally { if ($versionKey) { $versionKey.Dispose() } }
                    }
                }
                catch { }
                finally { if ($guidKey) { $guidKey.Dispose() } }
            }
        }
        finally { $tlRoot.Dispose() }
    }
    elseif ($tlRoot) { $tlRoot.Dispose() }

    $uniqueServers = @($servers | Sort-Object @{ Expression = { [string]::IsNullOrEmpty($_.ProgId) } }, ProgId, Clsid -Unique)
    $uniqueTypeLibs = @($typeLibs | Sort-Object Guid, Version, Platform -Unique)
    return [pscustomobject]@{ Servers = $uniqueServers; TypeLibs = $uniqueTypeLibs; Truncated = $truncated; Visited = $visited }
}

function Get-IntegrityLabel([uint32] $Rid) {
    if ($Rid -eq 0) { return '未知/不可读' }
    if ($Rid -lt 0x1000) { return ("Untrusted (0x{0:X})" -f $Rid) }
    if ($Rid -lt 0x2000) { return ("Low (0x{0:X})" -f $Rid) }
    if ($Rid -lt 0x2100) { return ("Medium (0x{0:X})" -f $Rid) }
    if ($Rid -lt 0x3000) { return ("Medium+ (0x{0:X})" -f $Rid) }
    if ($Rid -lt 0x4000) { return ("High (0x{0:X})" -f $Rid) }
    if ($Rid -lt 0x5000) { return ("System (0x{0:X})" -f $Rid) }
    return ("Protected (0x{0:X})" -f $Rid)
}

function Get-UiaStats([long[]] $Handles, [int] $TimeoutSeconds = 12) {
    if (-not $Handles -or $Handles.Count -eq 0) {
        return [pscustomobject]@{ Available = $true; TimedOut = $false; Total = 0; Editable = 0; Actionable = 0; Focusable = 0; Offscreen = 0; Roles = ''; Windows = @(); Error = $null }
    }
    $handleText = ($Handles | Select-Object -Unique) -join ','
    $job = $null
    try {
        $job = Start-Job -ArgumentList $handleText -ScriptBlock {
            param([string] $HandleText)
            $ErrorActionPreference = 'Stop'
            try {
                Add-Type -AssemblyName UIAutomationClient -ErrorAction Stop
                Add-Type -AssemblyName UIAutomationTypes -ErrorAction SilentlyContinue
                $totals = [ordered]@{ Total = 0; Editable = 0; Actionable = 0; Focusable = 0; Offscreen = 0 }
                $roles = @{}
                $byWindow = [System.Collections.Generic.List[object]]::new()
                $invokeNames = @(
                    'InvokePatternIdentifiers.Pattern', 'TogglePatternIdentifiers.Pattern',
                    'SelectionItemPatternIdentifiers.Pattern', 'ExpandCollapsePatternIdentifiers.Pattern',
                    'RangeValuePatternIdentifiers.Pattern'
                )
                foreach ($raw in @($HandleText -split ',')) {
                    if (-not $raw) { continue }
                    $hwnd = [long]$raw
                    $w = [ordered]@{ Hwnd = $hwnd; Total = 0; Editable = 0; Actionable = 0; Focusable = 0; Offscreen = 0; Error = $null }
                    try {
                        $root = [System.Windows.Automation.AutomationElement]::FromHandle([IntPtr]$hwnd)
                        if (-not $root) { throw 'AutomationElement::FromHandle 返回 null' }
                        $elements = $root.FindAll(
                            [System.Windows.Automation.TreeScope]::Subtree,
                            [System.Windows.Automation.Condition]::TrueCondition
                        )
                        $limit = [Math]::Min($elements.Count, 25000)
                        for ($i = 0; $i -lt $limit; $i++) {
                            $el = $elements.Item($i)
                            try {
                                $current = $el.Current
                                $control = [string]$current.ControlType.ProgrammaticName
                                $control = $control -replace '^ControlType\.', ''
                                if (-not $roles.ContainsKey($control)) { $roles[$control] = 0 }
                                $roles[$control]++
                                $w.Total++; $totals.Total++
                                if ($current.IsKeyboardFocusable) { $w.Focusable++; $totals.Focusable++ }
                                if ($current.IsOffscreen) { $w.Offscreen++; $totals.Offscreen++ }

                                $patternNames = @()
                                try { $patternNames = @($el.GetSupportedPatterns() | ForEach-Object ProgrammaticName) } catch { }
                                $editable = $false
                                if ('ValuePatternIdentifiers.Pattern' -in $patternNames) {
                                    $vp = $null
                                    try {
                                        if ($el.TryGetCurrentPattern([System.Windows.Automation.ValuePattern]::Pattern, [ref]$vp)) {
                                            $editable = $current.IsEnabled -and -not $vp.Current.IsReadOnly
                                        }
                                    }
                                    catch { }
                                }
                                if (-not $editable -and $control -in @('Edit', 'Document')) {
                                    $editable = $current.IsEnabled -and $current.IsKeyboardFocusable
                                }
                                if ($editable) { $w.Editable++; $totals.Editable++ }

                                $actionable = $false
                                foreach ($pn in $patternNames) {
                                    if ($pn -in $invokeNames) { $actionable = $true; break }
                                }
                                # Chromium exposes LegacyIAccessible on many inert
                                # nodes. Count it only when MSAA publishes a real
                                # default action, not merely because the pattern
                                # exists.
                                if (-not $actionable -and 'LegacyIAccessiblePatternIdentifiers.Pattern' -in $patternNames) {
                                    $legacy = $null
                                    try {
                                        if ($el.TryGetCurrentPattern([System.Windows.Automation.LegacyIAccessiblePattern]::Pattern, [ref]$legacy)) {
                                            $actionable = -not [string]::IsNullOrWhiteSpace([string]$legacy.Current.DefaultAction)
                                        }
                                    }
                                    catch { }
                                }
                                if (-not $actionable -and $control -in @('Button', 'Hyperlink', 'MenuItem', 'CheckBox', 'RadioButton', 'ComboBox', 'TabItem', 'ListItem', 'TreeItem', 'Slider', 'Spinner')) {
                                    $actionable = $current.IsEnabled
                                }
                                if ($actionable) { $w.Actionable++; $totals.Actionable++ }
                            }
                            catch { }
                        }
                        if ($elements.Count -gt $limit) { $w.Error = "元素超过 $limit，统计已截断" }
                    }
                    catch { $w.Error = $_.Exception.Message }
                    $byWindow.Add([pscustomobject]$w)
                }
                $roleText = ($roles.GetEnumerator() | Sort-Object Value -Descending | Select-Object -First 8 | ForEach-Object { '{0}={1}' -f $_.Key, $_.Value }) -join ', '
                [pscustomobject]@{
                    Available = $true; TimedOut = $false
                    Total = $totals.Total; Editable = $totals.Editable; Actionable = $totals.Actionable
                    Focusable = $totals.Focusable; Offscreen = $totals.Offscreen
                    Roles = $roleText; Windows = @($byWindow); Error = $null
                }
            }
            catch {
                [pscustomobject]@{ Available = $false; TimedOut = $false; Total = 0; Editable = 0; Actionable = 0; Focusable = 0; Offscreen = 0; Roles = ''; Windows = @(); Error = $_.Exception.Message }
            }
        }
        $done = Wait-Job -Job $job -Timeout $TimeoutSeconds
        if (-not $done) {
            Stop-Job -Job $job -ErrorAction SilentlyContinue
            return [pscustomobject]@{ Available = $false; TimedOut = $true; Total = 0; Editable = 0; Actionable = 0; Focusable = 0; Offscreen = 0; Roles = ''; Windows = @(); Error = "UIA 读取超过 ${TimeoutSeconds}s，已中止辅助进程" }
        }
        $received = @(Receive-Job -Job $job -ErrorAction SilentlyContinue)
        $answer = $received | Where-Object { $_.PSObject.Properties.Name -contains 'Available' } | Select-Object -Last 1
        if ($answer) { return $answer }
        return [pscustomobject]@{ Available = $false; TimedOut = $false; Total = 0; Editable = 0; Actionable = 0; Focusable = 0; Offscreen = 0; Roles = ''; Windows = @(); Error = 'UIA 辅助进程没有返回统计' }
    }
    catch {
        return [pscustomobject]@{ Available = $false; TimedOut = $false; Total = 0; Editable = 0; Actionable = 0; Focusable = 0; Offscreen = 0; Roles = ''; Windows = @(); Error = $_.Exception.Message }
    }
    finally {
        if ($job) { Remove-Job -Job $job -Force -ErrorAction SilentlyContinue }
    }
}

# ---------- Resolve the supplied display name / process name / path ----------

if ([Environment]::OSVersion.Platform -ne [PlatformID]::Win32NT) {
    throw 'probe.ps1 只能在 Windows 上运行。'
}
if (-not $ProbeQuery) { throw '用法: probe.ps1 <app 显示名 | 进程名 | exe/lnk/目录路径>' }

$huWinLoaded = Import-HuWin
$allWindows = @()
if ($huWinLoaded) {
    try {
        [void][HuWin]::SetProcessDPIAware()
        $allWindows = @([HuWin]::AllWindows())
    }
    catch { Add-Warning ("窗口枚举失败：{0}" -f $_.Exception.Message) }
}
else { Add-Warning 'HuWin.dll/HuWin.cs 均不可用，窗口与完整性级别无法探测。' }

$processes = @(Get-ProcessSnapshot)

# 1. Exact path (exe, lnk, or directory).
$queryPath = [Environment]::ExpandEnvironmentVariables($ProbeQuery)
if (Test-Path -LiteralPath $queryPath -ErrorAction SilentlyContinue) {
    $item = Get-Item -LiteralPath $queryPath -Force
    if ($item.PSIsContainer) {
        $exe = Find-BestExecutable $item.FullName $item.Name $item.Name
        Add-Candidate -Path $exe -InstallLocation $item.FullName -DisplayName $item.Name -Source '直接目录路径' -Score 1000
    }
    elseif ($item.Extension -ieq '.lnk') {
        Add-ShortcutCandidate $item.FullName 1000
    }
    else {
        Add-Candidate -Path $item.FullName -DisplayName $item.BaseName -Source '直接文件路径' -Score 1100
    }
}

# 2. Running process name/path and existing window owner/title.
foreach ($p in $processes) {
    $score = Get-NameMatchScore $p.ProcessName $ProbeQuery
    if ($score -gt 0) {
        Add-Candidate -Path $p.Path -DisplayName $p.ProcessName -Source '运行中进程名' -Score (820 + $score) -ProcessId $p.Pid
    }
}
foreach ($w in $allWindows) {
    $ownerScore = Get-NameMatchScore $w.Owner $ProbeQuery
    $titleScore = Get-NameMatchScore $w.Title $ProbeQuery
    $score = [Math]::Max($ownerScore, $titleScore)
    if ($score -gt 0) {
        $p = $processes | Where-Object Pid -EQ ([int]$w.Pid) | Select-Object -First 1
        if ($p) {
            Add-Candidate -Path $p.Path -DisplayName $(if ($w.Title) { $w.Title } else { $w.Owner }) `
                -Source '运行中窗口' -Score (790 + $score) -ProcessId $p.Pid
        }
    }
}

# 3. Installed-program registry and App Paths.
foreach ($u in @(Get-UninstallEntries)) {
    Add-Candidate -Path $u.DisplayIcon -InstallLocation $u.InstallLocation -DisplayName $u.DisplayName `
        -DisplayVersion $u.DisplayVersion -Source $u.Source -Score (610 + [int]$u.Match)
}
foreach ($a in @(Get-AppPathMatches)) {
    Add-Candidate -Path $a.Path -DisplayName $a.DisplayName -Source $a.Source -Score (600 + [int]$a.Match)
}

# 4. Start-menu/Desktop shortcuts. Resolve only name matches, never execute them.
$shortcutRoots = @(
    [Environment]::GetFolderPath('StartMenu'),
    [Environment]::GetFolderPath('CommonStartMenu'),
    [Environment]::GetFolderPath('DesktopDirectory'),
    [Environment]::GetFolderPath('CommonDesktopDirectory')
) | Where-Object { $_ -and (Test-Path -LiteralPath $_ -PathType Container) } | Select-Object -Unique
foreach ($root in $shortcutRoots) {
    foreach ($link in @(Get-ChildItem -LiteralPath $root -Filter '*.lnk' -File -Recurse -ErrorAction SilentlyContinue)) {
        $score = Get-NameMatchScore $link.BaseName $ProbeQuery
        if ($score -gt 0) { Add-ShortcutCandidate $link.FullName (650 + $score) }
    }
}

# 5. Start Apps / AppX. This is the main path for localized Store-app names.
$matchedPackageRoot = $null
if (Get-Command Get-StartApps -ErrorAction SilentlyContinue) {
    try {
        $startMatches = @(Get-StartApps | Where-Object { (Get-NameMatchScore $_.Name $ProbeQuery) -gt 0 })
        $packages = $null
        foreach ($sa in $startMatches) {
            $score = Get-NameMatchScore $sa.Name $ProbeQuery
            $exe = $null; $pkgRoot = $null; $family = $null; $appId = [string]$sa.AppID
            if ($appId -match '^([^!]+)!(.+)$' -and (Get-Command Get-AppxPackage -ErrorAction SilentlyContinue)) {
                if ($null -eq $packages) { $packages = @(Get-AppxPackage -ErrorAction SilentlyContinue) }
                $family = $Matches[1]; $manifestAppId = $Matches[2]
                $pkg = $packages | Where-Object PackageFamilyName -EQ $family | Select-Object -First 1
                if ($pkg) {
                    $pkgRoot = [string]$pkg.InstallLocation
                    $manifestPath = Join-Path $pkgRoot 'AppxManifest.xml'
                    try {
                        [xml]$manifestXml = Get-Content -LiteralPath $manifestPath -Raw
                        $appNode = $manifestXml.SelectSingleNode("//*[local-name()='Application' and @Id='$manifestAppId']")
                        if ($appNode -and $appNode.Executable -and $appNode.Executable -notmatch '\$') {
                            $candidateExe = Join-Path $pkgRoot ([string]$appNode.Executable)
                            if (Test-Path -LiteralPath $candidateExe -PathType Leaf) { $exe = $candidateExe }
                        }
                    }
                    catch { }
                }
            }
            Add-Candidate -Path $exe -InstallLocation $pkgRoot -DisplayName $sa.Name -Source '开始菜单/Get-StartApps' `
                -Score (620 + $score) -PackageFamily $family -AppId $appId
        }
    }
    catch { Add-Warning ("Get-StartApps 探测失败：{0}" -f $_.Exception.Message) }
}

# 6. PATH command lookup is the final process-name fallback.
try {
    $commandName = if ($ProbeQuery -match '\.exe$') { $ProbeQuery } else { "$ProbeQuery.exe" }
    $cmd = Get-Command $commandName -CommandType Application -ErrorAction SilentlyContinue | Select-Object -First 1
    if ($cmd) { Add-Candidate -Path $cmd.Source -DisplayName $cmd.Name -Source 'PATH' -Score 640 }
}
catch { }

# Fill display-name matches from file version resources only if ordinary sources
# failed. This catches a localized product whose exe/process name is unrelated.
if ($script:Candidates.Count -eq 0) {
    foreach ($group in @($processes | Where-Object Path | Group-Object Path)) {
        $ff = Get-FileFacts $group.Name
        $score = [Math]::Max((Get-NameMatchScore $ff.ProductName $ProbeQuery), (Get-NameMatchScore $ff.Description $ProbeQuery))
        if ($score -gt 0) {
            foreach ($p in $group.Group) {
                Add-Candidate -Path $p.Path -DisplayName $(if ($ff.ProductName) { $ff.ProductName } else { $ff.Description }) `
                    -Source '运行中 EXE 版本资源' -Score (760 + $score) -ProcessId $p.Pid
            }
        }
    }
}

$dedup = foreach ($g in @($script:Candidates | Group-Object {
    if ($_.Path) { 'path:' + $_.Path.ToLowerInvariant() }
    elseif ($_.AppId) { 'app:' + $_.AppId.ToLowerInvariant() }
    else { 'name:' + ([string]$_.DisplayName).ToLowerInvariant() + '|' + $_.Source }
})) {
    $g.Group | Sort-Object Score -Descending | Select-Object -First 1
}
$rankedCandidates = @($dedup | Sort-Object @{ Expression = { [bool]$_.Path }; Descending = $true }, Score -Descending)
$selected = $rankedCandidates | Select-Object -First 1

# Classic UWP apps can expose their top-level window through
# ApplicationFrameHost.exe.  The window title is useful for correlation, but
# the host's System32 path/version is not the app's identity.  When Start Apps
# gives us a matching package, use that package for static facts and retain the
# host window later as a dynamic target.
if ($selected -and $selected.Pid -and $selected.Source -eq '运行中窗口') {
    $selectedProcess = $processes | Where-Object Pid -EQ ([int]$selected.Pid) | Select-Object -First 1
    if ($selectedProcess -and $selectedProcess.ProcessName -ieq 'ApplicationFrameHost') {
        $packagedMatch = $rankedCandidates |
            Where-Object { $_.PackageFamily -and $_.AppId -and (Get-NameMatchScore $_.DisplayName $ProbeQuery) -ge 72 } |
            Sort-Object Score -Descending |
            Select-Object -First 1
        if ($packagedMatch) {
            $packagedMatch.Source = '开始菜单/Get-StartApps（关联 ApplicationFrameHost 窗口）'
            $selected = $packagedMatch
        }
    }
}

Write-Output '花叔 Windows 应用能力探测器（只读）'
Write-Output ("查询: {0}" -f $ProbeQuery)
Write-Output '边界: 不启动/关闭/激活目标 app；不点击、不输入、不附加调试器。'

if (-not $selected) {
    Write-Section '结果'
    Write-Output '未找到匹配的安装记录、快捷方式、App Paths、AppX、运行进程或窗口。'
    Write-Output '可改用准确进程名（不带 .exe 也可）或 exe/lnk/安装目录的完整路径。'
    if ($script:Warnings.Count) {
        Write-Section '探测限制'
        $script:Warnings | ForEach-Object { Write-Output ("⚠️ {0}" -f $_) }
    }
    exit 1
}

$exePath = $selected.Path
$installRoot = if ($selected.InstallLocation) { $selected.InstallLocation } elseif ($exePath) { Split-Path -Parent $exePath } else { $null }
$matchedPackageRoot = if ($selected.PackageFamily) { $installRoot } else { $null }
$fileFacts = Get-FileFacts $exePath

# Identify primary and related processes after resolution.
$primarySet = [Collections.Generic.HashSet[int]]::new()
$uwpHostSet = [Collections.Generic.HashSet[int]]::new()
$selectedFromWindow = [bool]($selected.Pid -and $selected.Source -eq '运行中窗口')
if ($selected.Pid) { [void]$primarySet.Add([int]$selected.Pid) }
if (-not $selectedFromWindow) {
    foreach ($p in $processes) {
        if ($exePath -and $p.Path -and $p.Path -ieq $exePath) { [void]$primarySet.Add([int]$p.Pid) }
        elseif ((Get-NameMatchScore $p.ProcessName $ProbeQuery) -eq 100) { [void]$primarySet.Add([int]$p.Pid) }
    }
    foreach ($w in $allWindows) {
        if ((Get-NameMatchScore $w.Owner $ProbeQuery) -eq 100 -or (Get-NameMatchScore $w.Title $ProbeQuery) -ge 72) {
            [void]$primarySet.Add([int]$w.Pid)
            if ($selected.PackageFamily -and $w.Owner -ieq 'ApplicationFrameHost') {
                [void]$uwpHostSet.Add([int]$w.Pid)
            }
        }
    }
}

$relatedSet = [Collections.Generic.HashSet[int]]::new()
# Explorer, shells and service hosts are launch parents for unrelated apps. A
# blind descendant walk from them would classify most of the desktop as one app.
$launchParentNames = @('explorer', 'applicationframehost', 'svchost', 'services', 'wininit', 'winlogon', 'cmd', 'conhost', 'powershell', 'pwsh')
$descendantRoots = @()
foreach ($id in @($primarySet)) {
    $rootProcess = $processes | Where-Object Pid -EQ $id | Select-Object -First 1
    if ($rootProcess -and $rootProcess.ProcessName.ToLowerInvariant() -notin $launchParentNames) { $descendantRoots += [int]$id }
    else { [void]$relatedSet.Add([int]$id) }
}
foreach ($id in @(Get-DescendantPids $descendantRoots $processes)) { [void]$relatedSet.Add([int]$id) }
if (-not $selectedFromWindow -and (Test-SpecificInstallRoot $installRoot)) {
    $prefix = $installRoot.TrimEnd('\') + '\'
    foreach ($p in $processes) {
        if ($p.Path -and $p.Path.StartsWith($prefix, [StringComparison]::OrdinalIgnoreCase)) { [void]$relatedSet.Add([int]$p.Pid) }
    }
}
$primaryPids = @($primarySet | Sort-Object)
$relatedPids = @($relatedSet | Sort-Object)
$relatedProcesses = @($processes | Where-Object { $relatedSet.Contains([int]$_.Pid) } | Sort-Object Pid)
$targetWindows = @($allWindows | Where-Object {
    if (-not $relatedSet.Contains([int]$_.Pid)) { return $false }
    # One ApplicationFrameHost process can own unrelated Store-app windows.
    # Keep only the windows whose title still identifies the selected package.
    if ($uwpHostSet.Contains([int]$_.Pid)) {
        return (Get-NameMatchScore $_.Title $ProbeQuery) -ge 52
    }
    return $true
} | Sort-Object @{ Expression = 'Visible'; Descending = $true }, Pid, Hwnd)

Write-Section '目标'
Write-Output ("解析来源: {0}" -f $selected.Source)
Write-Output ("显示名: {0}" -f $(if ($selected.DisplayName) { $selected.DisplayName } else { '未知' }))
Write-Output ("安装路径: {0}" -f $(if ($installRoot) { $installRoot } else { '未知/无权限' }))
Write-Output ("可执行路径: {0}" -f $(if ($exePath) { $exePath } else { '未知/无权限' }))
$versions = @($selected.DisplayVersion, $fileFacts.ProductVersion, $fileFacts.FileVersion) | Where-Object { $_ } | Select-Object -Unique
Write-Output ("版本: {0}" -f $(if ($versions) { $versions -join ' | ' } else { '未知' }))
Write-Output ("PE 架构: {0}" -f $(Get-PEArchitecture $exePath))
if ($fileFacts.ProductName -or $fileFacts.Company) {
    Write-Output ("版本资源: Product={0}; Company={1}" -f $fileFacts.ProductName, $fileFacts.Company)
}
if ($rankedCandidates.Count -gt 1) {
    $alternates = @($rankedCandidates | Where-Object { $_.Path -and $_.Path -ine $exePath } | Select-Object -First 4)
    if ($alternates.Count) {
        Write-Output '其它匹配（用于排查多份安装/同名 app）:'
        foreach ($c in $alternates) { Write-Output ("  score={0} [{1}] {2}" -f $c.Score, $c.Source, $c.Path) }
    }
}

Write-Section '进程与完整性级别'
if ($relatedProcesses.Count -eq 0) {
    Write-Output '状态: 未运行（因此窗口、端口、动态运行时信号和 UIA 均不可探）。'
}
else {
    Write-Output ("主 PID: {0}" -f $(if ($primaryPids.Count) { $primaryPids -join ', ' } else { '未唯一识别' }))
    Write-Output ("相关 PID: {0}" -f ($relatedPids -join ', '))
    $selfIntegrity = if ($huWinLoaded) { [uint32][HuWin]::SelfIntegrity() } else { 0 }
    Write-Output ("probe 完整性: {0}" -f (Get-IntegrityLabel $selfIntegrity))
    foreach ($p in @($relatedProcesses | Select-Object -First 24)) {
        $rid = if ($huWinLoaded) { [uint32][HuWin]::IntegrityLevel([uint32]$p.Pid) } else { 0 }
        $uipi = if ($rid -gt 0 -and $selfIntegrity -gt 0 -and $rid -gt $selfIntegrity) { ' ⚠️ 高于 probe，SendInput/UIA 写操作可能被 UIPI 拦截' } else { '' }
        Write-Output ("  pid={0} ppid={1} name={2} integrity={3}{4}" -f $p.Pid, $p.ParentPid, $p.Name, (Get-IntegrityLabel $rid), $uipi)
        Write-Output ("      process-path={0}" -f $(if ($p.Path) { $p.Path } else { '未知/访问被拒' }))
    }
    if ($relatedProcesses.Count -gt 24) { Write-Output ("  ... 另有 {0} 个相关进程未展开" -f ($relatedProcesses.Count - 24)) }
}

$staticSignals = @(Get-StaticRuntimeSignals $exePath $installRoot)
$dynamicSignals = @(Get-DynamicRuntimeSignals $processes $allWindows $relatedPids)
$allSignals = @($staticSignals + $dynamicSignals)
Write-Section 'Chromium / Electron / CEF / WebView2 信号'
if ($allSignals.Count -eq 0) {
    Write-Output '未发现明确 Chromium 系信号；可能是原生 UI、其它自绘框架，或安装目录/进程信息不可读。'
}
else {
    $families = @($allSignals | Group-Object Family | Sort-Object Name)
    foreach ($family in $families) {
        $strong = @($family.Group | Where-Object Strength -EQ 'strong').Count
        $confidence = if ($strong -gt 0) { '明确' } else { '辅助' }
        Write-Output ("{0}: {1}（{2} 个信号）" -f $family.Name, $confidence, $family.Count)
        foreach ($s in @($family.Group | Select-Object -First 8)) { Write-Output ("  - {0}" -f $s.Evidence) }
        if ($family.Count -gt 8) { Write-Output ("  - ... 另有 {0} 条" -f ($family.Count - 8)) }
    }
}

$ports = @(Get-ListeningPorts $relatedPids)
$remoteFacts = @(Get-RemoteDebugFacts $processes $relatedPids)
$cdpResults = [System.Collections.Generic.List[object]]::new()
$requestedFirst = @($remoteFacts | Where-Object Kind -EQ 'remote-debugging-port' | ForEach-Object { [int]$_.Value })
$portsForProbe = @($ports | Sort-Object @{ Expression = { [int]$_.Port -in $requestedFirst }; Descending = $true }, Port)
$probeIndex = 0
foreach ($port in $portsForProbe) {
    $probeIndex++
    $cdp = if ($probeIndex -le 24) { Get-CdpVersion $port.Address $port.Port } else { $null }
    $cdpResults.Add([pscustomobject]@{ PortInfo = $port; Probe = $cdp })
}

Write-Section 'L0：端口 / CDP / URL Protocol'
if ($remoteFacts.Count) {
    Write-Output '已有 remote-debugging / inspect 参数:'
    foreach ($f in $remoteFacts) { Write-Output ("  pid={0} {1}={2}" -f $f.Pid, $f.Kind, $f.Value) }
}
else { Write-Output 'remote-debugging 参数: 未在可读命令行中发现' }

if ($ports.Count -eq 0) { Write-Output '本地 TCP 监听端口: 无（或目标未运行/端口表不可读）' }
else {
    Write-Output '本地 TCP 监听端口（仅相关 PID）:'
    foreach ($r in $cdpResults) {
        $p = $r.PortInfo; $c = $r.Probe
        if (-not $c) {
            Write-Output ("  {0}:{1} pid={2} → 已列出；CDP GET 未探（超过 24 个端口的时限）" -f $p.Address, $p.Port, $p.Pid)
        }
        elseif ($c.IsCdp) {
            Write-Output ("  {0}:{1} pid={2} → CDP ✅ HTTP {3}; Browser={4}" -f $p.Address, $p.Port, $p.Pid, $c.HttpStatus, $c.Browser)
            if ($c.WebSocket) { Write-Output ("      webSocketDebuggerUrl={0}" -f $c.WebSocket) }
        }
        elseif ($c.HttpStatus) {
            Write-Output ("  {0}:{1} pid={2} → 非 CDP（/json/version HTTP {3}）" -f $p.Address, $p.Port, $p.Pid, $c.HttpStatus)
        }
        else {
            Write-Output ("  {0}:{1} pid={2} → /json/version 无响应" -f $p.Address, $p.Port, $p.Pid)
        }
    }
}

$requestedPorts = @($remoteFacts | Where-Object Kind -EQ 'remote-debugging-port' | ForEach-Object { [int]$_.Value } | Select-Object -Unique)
foreach ($rp in $requestedPorts) {
    if (-not ($ports | Where-Object Port -EQ $rp)) { Write-Output ("  ⚠️ 参数请求 CDP 端口 {0}，但相关 PID 当前未监听该端口。" -f $rp) }
}
$protocols = @(Get-UrlProtocols $exePath $installRoot $matchedPackageRoot)
if ($protocols.Count -eq 0) { Write-Output 'URL protocol: 未发现指向该可执行文件/包的注册项' }
else {
    Write-Output 'URL protocol 线索（只枚举，未调用）:'
    foreach ($u in $protocols) { Write-Output ("  {0}://  [{1}] {2}" -f $u.Scheme, $u.Source, $u.Detail) }
}

$com = Get-ComAutomationFacts $exePath $installRoot
Write-Section 'L0：COM 自动化对象模型（只读注册表，未实例化）'
if ($com.Servers.Count -eq 0 -and $com.TypeLibs.Count -eq 0) {
    Write-Output '未发现指向该 exe/安装目录的 COM LocalServer32 或 TypeLib 注册项。'
}
else {
    if ($com.Servers.Count) {
        Write-Output ("COM 服务器 {0} 个（app 以 COM 对象模型对外暴露，等价于 Mac 的 AppleScript 字典）:" -f $com.Servers.Count)
        foreach ($s in @($com.Servers | Select-Object -First 12)) {
            $progText = if ($s.ProgId) { $s.ProgId } elseif ($s.VersionIndependentProgId) { $s.VersionIndependentProgId } else { '<无 ProgID>' }
            $vipText = if ($s.VersionIndependentProgId -and $s.VersionIndependentProgId -ne $s.ProgId) { " ({0})" -f $s.VersionIndependentProgId } else { '' }
            $tlText = if ($s.TypeLib) { ' typelib=yes' } else { '' }
            Write-Output ("  {0}{1}  clsid={2}  {3}{4}" -f $progText, $vipText, $s.Clsid, $s.Kind, $tlText)
            Write-Output ("      server={0}" -f $s.Server)
        }
        if ($com.Servers.Count -gt 12) { Write-Output ("  ... 另有 {0} 个 COM 类未展开" -f ($com.Servers.Count - 12)) }
    }
    if ($com.TypeLibs.Count) {
        Write-Output ("类型库 {0} 个:" -f $com.TypeLibs.Count)
        foreach ($t in @($com.TypeLibs | Select-Object -First 8)) {
            Write-Output ("  {0} v{1} [{2}] {3}" -f $(if ($t.Description) { $t.Description } else { $t.Guid }), $t.Version, $t.Platform, $t.File)
        }
        if ($com.TypeLibs.Count -gt 8) { Write-Output ("  ... 另有 {0} 个类型库未展开" -f ($com.TypeLibs.Count - 8)) }
    }
    Write-Output '判据提示: 注册了 ProgID 只说明对象模型存在。New-Object -ComObject 可能新起隐藏实例而非连接用户已开的窗口；先只读属性验证，写操作与保存/发送同样受停手线约束。'
}
if ($com.Truncated) { Add-Warning ("COM 注册表枚举在 {0} 项/时限内截断，结果可能不完整。" -f $com.Visited) }

Write-Section '窗口'
if ($targetWindows.Count -eq 0) { Write-Output '无目标顶层窗口（未运行、无窗口、路径关联失败或访问受限）。' }
else {
    foreach ($w in @($targetWindows | Select-Object -First 30)) {
        $title = ([string]$w.Title -replace '[\r\n\t]+', ' ').Trim()
        Write-Output ("  hwnd=0x{0:X} pid={1} owner={2} visible={3} minimized={4} cloaked={5} tool={6}" -f [long]$w.Hwnd, $w.Pid, $w.Owner, $w.Visible, $w.Iconic, $w.Cloaked, $w.Tool)
        Write-Output ("      rect=({0},{1}) {2}x{3} class={4} title={5}" -f $w.L, $w.T, $w.W, $w.H, $w.Cls, $(if ($title) { $title } else { '<空>' }))
    }
    if ($targetWindows.Count -gt 30) { Write-Output ("  ... 另有 {0} 个顶层窗口未展开" -f ($targetWindows.Count - 30)) }
}

$uiaHandles = @($targetWindows | Where-Object { $_.Visible -and -not $_.Cloaked -and -not $_.Tool } | Select-Object -ExpandProperty Hwnd -First 8)
$uia = Get-UiaStats ([long[]]$uiaHandles)
Write-Section 'L1：UI Automation（只读统计）'
if ($relatedProcesses.Count -eq 0) {
    Write-Output '未运行：UIA 动态树不可探。'
}
elseif (-not $uia.Available) {
    Write-Output ("UIA 不可用: {0}" -f $uia.Error)
}
else {
    Write-Output ("元素总数: {0}" -f $uia.Total)
    Write-Output ("可编辑控件: {0}" -f $uia.Editable)
    Write-Output ("可操作控件: {0}" -f $uia.Actionable)
    Write-Output ("可聚焦: {0}; 当前离屏: {1}" -f $uia.Focusable, $uia.Offscreen)
    Write-Output ("主要 ControlType: {0}" -f $(if ($uia.Roles) { $uia.Roles } else { '无' }))
    foreach ($uw in @($uia.Windows)) {
        $suffix = if ($uw.Error) { "; note=$($uw.Error)" } else { '' }
        Write-Output ("  hwnd=0x{0:X}: total={1}, editable={2}, actionable={3}{4}" -f [long]$uw.Hwnd, $uw.Total, $uw.Editable, $uw.Actionable, $suffix)
    }
    Write-Output '判据提示: “有控件”只是候选；真实写入仍须在后续操作中回读状态，不能把 API success 当生效。'
}

$hasCdp = @($cdpResults | Where-Object { $_.Probe.IsCdp }).Count -gt 0
$hasChromium = @($allSignals | Where-Object { $_.Family -match 'Chromium|Electron|CEF|WebView2|NW.js' }).Count -gt 0
$hasVisibleWindow = @($targetWindows | Where-Object { $_.Visible -and -not $_.Cloaked -and -not $_.Iconic }).Count -gt 0
$targetAboveSelf = $false
$integrityUnknown = [bool]($hasVisibleWindow -and (-not $huWinLoaded -or -not $primaryPids.Count))
if ($huWinLoaded -and $relatedPids.Count) {
    $selfRid = [uint32][HuWin]::SelfIntegrity()
    if ($selfRid -eq 0) { $integrityUnknown = $true }
    foreach ($id in $primaryPids) {
        $targetRid = [uint32][HuWin]::IntegrityLevel([uint32]$id)
        if ($targetRid -eq 0) { $integrityUnknown = $true }
        if ($targetRid -gt $selfRid -and $selfRid -gt 0) { $targetAboveSelf = $true }
    }
}

Write-Section 'L0 / L1 / L2 / L3 路径建议'
$hasCom = [bool]($com.Servers | Where-Object { $_.ProgId -or $_.VersionIndependentProgId } | Select-Object -First 1)
if ($hasCom) {
    $bestCom = $com.Servers | Where-Object { $_.ProgId -or $_.VersionIndependentProgId } | Select-Object -First 1
    $bestProg = if ($bestCom.VersionIndependentProgId) { $bestCom.VersionIndependentProgId } else { $bestCom.ProgId }
    Write-Output ('L0 ✅ 有 COM 对象模型：先查官方对象模型文档，只读试探 New-Object -ComObject {0}；它可能启动新实例，不要用它去改用户已打开的文档，除非用户同意。' -f $bestProg)
}
if ($hasCdp) {
    $bestCdp = $cdpResults | Where-Object { $_.Probe.IsCdp } | Select-Object -First 1
    Write-Output ('L0 ✅ 首选现有 CDP：node "{0}" {1} list' -f (Join-Path $ToolRoot 'cdp.js'), $bestCdp.PortInfo.Port)
}
elseif ($hasCom) {
    Write-Output 'L0 其它：无 CDP；COM 之外仍应核对 app 官方 CLI/SDK/文件接口。'
}
elseif ($protocols.Count -gt 0 -or $ports.Count -gt 0) {
    Write-Output 'L0 ⚠️ 有 URL scheme 或本地服务线索，但尚未证明具体路由/API；先做只读协议验证。'
}
elseif ($hasChromium) {
    Write-Output 'L0 候选：确认是 Chromium 系，但当前没有可用 CDP。若以后考虑注入 --remote-debugging-port，必须先征得重启许可；本探测器不会重启。'
}
else { Write-Output 'L0 暂无已证实结构接口。仍应优先查 app 官方 CLI/SDK/文件接口；probe 不会通过执行 --help 来试探。' }

if ($uia.Available -and $uia.Editable -gt 0 -and $uia.Actionable -gt 0) {
    Write-Output ("L1 ✅ UIA 有希望：可编辑 {0}、可操作 {1}；按 AutomationId/Name/ControlType 定位，并用状态回读验证。" -f $uia.Editable, $uia.Actionable)
}
elseif ($uia.Available -and ($uia.Editable -gt 0 -or $uia.Actionable -gt 0)) {
    Write-Output ("L1 ⚠️ UIA 部分可用：可编辑 {0}、可操作 {1}；缺失部分准备退 L2。" -f $uia.Editable, $uia.Actionable)
}
elseif ($relatedProcesses.Count -eq 0) { Write-Output 'L1 未知：app 未运行；由用户手动打开并显示窗口后重跑 probe。' }
else { Write-Output 'L1 ❌ 当前可见窗口没有可用 UIA 编辑/操作控件，别在空树上耗，准备 L2。' }

if ($hasVisibleWindow -and -not $targetAboveSelf -and -not $integrityUnknown) {
    Write-Output 'L2 ✅ 可走窗口相对坐标：每轮现场截图定位；SendInput 前必须显式借前台、检查遮挡/锁屏/用户在场，完成立即还回。'
}
elseif ($targetAboveSelf) {
    Write-Output 'L2 ⛔ 目标完整性高于 probe，UIPI 会静默吞输入；只在用户明确同意且同等完整性上下文中操作。'
}
elseif ($hasVisibleWindow -and $integrityUnknown) {
    Write-Output 'L2 ⛔ 无法确认自身或目标完整性级别；未知不等于可写。改走 CDP/UIA，或在可读取完整性级别的同一交互会话中重试。'
}
elseif ($targetWindows.Count -gt 0) { Write-Output 'L2 ⚠️ 窗口最小化/隐藏/被 cloaked；不改变 UI 状态就不能可靠走坐标。' }
else { Write-Output 'L2 未知/不可用：当前没有可见目标窗口。' }

if ($targetWindows.Count -gt 0) {
    Write-Output 'L3：像素截图是最后控制手段，也是每一步的验证手段；优先单窗口截图并做前后差分。'
}
else { Write-Output 'L3 暂不可探：没有目标窗口可截图。' }

if ($script:Warnings.Count) {
    Write-Section '探测限制 / 警告'
    $script:Warnings | ForEach-Object { Write-Output ("⚠️ {0}" -f $_) }
}

Write-Output ''
Write-Output '完成：全过程未启动、关闭或操控目标 app。'
$global:LASTEXITCODE = 0
