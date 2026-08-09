<#
.SYNOPSIS
    Compares an NTLite verification ZIP with the current Windows installation.

.DESCRIPTION
    Read-only checker for NTLite presets and Windows unattended XML files. The checker
    reports only what can be demonstrated from the supplied source files and the current
    machine. Settings that cannot be proven after deployment are marked Not verifiable.
#>

[CmdletBinding()]
param(
    [string]$InputZip = "",
    [string]$OutputRoot = "C:\Temp\NTLiteChecker",
    [switch]$OpenReport = $true
)

$ErrorActionPreference = "Stop"
$ToolName = "NTLiteChecker"
$ToolVersion = "1.2"

function Test-IsAdmin {
    $identity = [Security.Principal.WindowsIdentity]::GetCurrent()
    $principal = New-Object Security.Principal.WindowsPrincipal($identity)
    return $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

function ConvertTo-HtmlText {
    param([AllowNull()][object]$Value)
    if ($null -eq $Value) { return "" }
    return [System.Net.WebUtility]::HtmlEncode([string]$Value)
}

function Protect-SensitiveText {
    param([AllowNull()][object]$Value)
    if ($null -eq $Value) { return "" }
    $text = [string]$Value
    $text = [regex]::Replace($text, '(?i)\b(ProductKey|Password|Passphrase|Token|Secret|ApiKey)\b\s*[:=]\s*("[^"]*"|''[^'']*''|\S+)', '$1=<redacted>')
    $text = [regex]::Replace($text, '(?i)\b([A-Z0-9]{5}-){4}[A-Z0-9]{5}\b', '<redacted-product-key>')
    return $text
}

function ConvertTo-RegistryProviderPath {
    param([AllowNull()][string]$Path)
    if ([string]::IsNullOrWhiteSpace($Path)) { return $null }
    $normalized = $Path.Trim().Trim('"').Trim("'") -replace '/', '\'
    $prefixes = @{
        'HKEY_LOCAL_MACHINE' = 'HKLM:'
        'HKLM' = 'HKLM:'
        'HKEY_CURRENT_USER' = 'HKCU:'
        'HKCU' = 'HKCU:'
        'HKEY_CLASSES_ROOT' = 'HKCR:'
        'HKCR' = 'HKCR:'
        'HKEY_USERS' = 'HKU:'
        'HKU' = 'HKU:'
    }
    foreach ($prefix in $prefixes.Keys) {
        if ($normalized -ieq $prefix) { return $prefixes[$prefix] + '\' }
        if ($normalized.StartsWith($prefix + '\', [StringComparison]::OrdinalIgnoreCase)) {
            return $prefixes[$prefix] + $normalized.Substring($prefix.Length)
        }
    }
    if ($normalized -match '^(HKLM|HKCU|HKCR|HKU):\\') { return $normalized }
    return $null
}

function Select-InputZip {
    Add-Type -AssemblyName System.Windows.Forms
    $dialog = New-Object System.Windows.Forms.OpenFileDialog
    $dialog.Title = "Select the NTLite verification ZIP"
    $dialog.Filter = "ZIP archives (*.zip)|*.zip"
    $dialog.Multiselect = $false
    if ($dialog.ShowDialog() -ne [System.Windows.Forms.DialogResult]::OK) {
        throw "No ZIP archive was selected."
    }
    return $dialog.FileName
}

function Expand-SafeZip {
    param(
        [Parameter(Mandatory=$true)][string]$Path,
        [Parameter(Mandatory=$true)][string]$Destination
    )

    Add-Type -AssemblyName System.IO.Compression.FileSystem
    $root = [IO.Path]::GetFullPath($Destination).TrimEnd('\') + '\'
    $archive = [IO.Compression.ZipFile]::OpenRead($Path)
    try {
        foreach ($entry in $archive.Entries) {
            if ([string]::IsNullOrWhiteSpace($entry.FullName)) { continue }
            $target = [IO.Path]::GetFullPath((Join-Path $Destination $entry.FullName))
            if (-not $target.StartsWith($root, [StringComparison]::OrdinalIgnoreCase)) {
                throw "Unsafe ZIP entry rejected: $($entry.FullName)"
            }
            if ([string]::IsNullOrWhiteSpace($entry.Name)) {
                New-Item -ItemType Directory -Force -Path $target | Out-Null
                continue
            }
            $parent = Split-Path -Parent $target
            New-Item -ItemType Directory -Force -Path $parent | Out-Null
            [IO.Compression.ZipFileExtensions]::ExtractToFile($entry, $target, $true)
        }
    } finally {
        $archive.Dispose()
    }
}

function Get-RegistryValueSafe {
    param([string]$Path, [string]$Name)
    try {
        $item = Get-ItemProperty -LiteralPath $Path -ErrorAction Stop
        $property = $item.PSObject.Properties[$Name]
        if ($null -eq $property) { return $null }
        return $property.Value
    } catch {
        return $null
    }
}

function Test-ExpectedValue {
    param([AllowNull()][object]$Actual, [AllowNull()][string]$Expected)
    if ($null -eq $Actual) { return $false }
    return ([string]$Actual).Trim() -ieq ([string]$Expected).Trim()
}

$isAdmin = Test-IsAdmin
if (-not $isAdmin) {
    Write-Warning "$ToolName is running without Administrator rights. Some machine-wide checks may be unavailable."
}

if ([string]::IsNullOrWhiteSpace($InputZip)) {
    $InputZip = Select-InputZip
}
$InputZip = [IO.Path]::GetFullPath($InputZip)
if (-not (Test-Path -LiteralPath $InputZip -PathType Leaf)) {
    throw "ZIP archive not found: $InputZip"
}
if ([IO.Path]::GetExtension($InputZip) -ine ".zip") {
    throw "The selected input must be a ZIP archive."
}

$timestamp = Get-Date -Format "yyyyMMdd_HHmmss"
$computerSafe = $env:COMPUTERNAME -replace '[\\/:*?"<>| ]', '_'
$outputFolder = Join-Path $OutputRoot "NTLiteChecker_${computerSafe}_${timestamp}"
$extractFolder = Join-Path $env:TEMP "NTLiteChecker_$([guid]::NewGuid().ToString('N'))"
New-Item -ItemType Directory -Force -Path $outputFolder, $extractFolder | Out-Null

Write-Host ""
Write-Host "$ToolName $ToolVersion" -ForegroundColor Cyan
Write-Host "Input:  $InputZip" -ForegroundColor Gray
Write-Host "Output: $outputFolder" -ForegroundColor Gray
Write-Host ""

$results = New-Object System.Collections.Generic.List[object]
$sources = New-Object System.Collections.Generic.List[object]
$localSetupEvidence = New-Object System.Collections.Generic.List[object]

function Add-Result {
    param(
        [ValidateSet("Matched", "Mismatch", "Conflict", "Not verifiable", "Info")][string]$Status,
        [string]$Area,
        [string]$Item,
        [string]$Expected,
        [string]$Actual,
        [string]$Explanation,
        [string]$Source
    )
    $results.Add([pscustomobject]@{
        Status = $Status
        Area = $Area
        Item = $Item
        Expected = $Expected
        Actual = $Actual
        Explanation = $Explanation
        Source = $Source
    })
}

function Add-RegistryAssertionResult {
    param(
        [Parameter(Mandatory=$true)][string]$RegistryPath,
        [Parameter(Mandatory=$true)][string]$ValueName,
        [AllowNull()][string]$Expected,
        [bool]$ExpectAbsent = $false,
        [Parameter(Mandatory=$true)][string]$Source
    )
    $providerPath = ConvertTo-RegistryProviderPath $RegistryPath
    if (-not $providerPath) {
        Add-Result "Not verifiable" "Script assertions" "$RegistryPath\$ValueName" $Expected "Unsupported registry hive" `
            "The source contains a registry instruction, but its hive cannot be inspected safely by this checker." $Source
        return
    }
    $actual = Get-RegistryValueSafe -Path $providerPath -Name $ValueName
    if ($ExpectAbsent) {
        $status = if ($null -eq $actual) { "Matched" } else { "Mismatch" }
        $actualText = if ($null -eq $actual) { "Value is absent" } else { [string]$actual }
        Add-Result $status "Script assertions" "$providerPath\$ValueName" "Value is absent" $actualText `
            "Compared with a literal registry deletion instruction found in the supplied source file. The source file was not executed." $Source
        return
    }
    if ($null -eq $actual) {
        Add-Result "Mismatch" "Script assertions" "$providerPath\$ValueName" $Expected "Value is missing" `
            "Compared with a literal registry instruction found in the supplied source file. The source file was not executed." $Source
    } elseif (Test-ExpectedValue -Actual $actual -Expected $Expected) {
        Add-Result "Matched" "Script assertions" "$providerPath\$ValueName" $Expected ([string]$actual) `
            "The current registry value matches the literal instruction found in the supplied source file. This verifies the resulting state, not the historical execution." $Source
    } else {
        Add-Result "Mismatch" "Script assertions" "$providerPath\$ValueName" $Expected ([string]$actual) `
            "The current registry value differs from the literal instruction found in the supplied source file." $Source
    }
}

function Get-LiteralRegistryAssertions {
    param(
        [Parameter(Mandatory=$true)][IO.FileInfo]$File,
        [Parameter(Mandatory=$true)][string]$RelativePath
    )
    $assertions = New-Object System.Collections.Generic.List[object]
    $lines = @(Get-Content -LiteralPath $File.FullName -ErrorAction Stop)
    if ($File.Extension -ieq ".reg") {
        $currentKey = $null
        for ($index = 0; $index -lt $lines.Count; $index++) {
            $line = $lines[$index].Trim()
            if ($line -match '^\[(?<key>HKEY_[^\]]+)\]$') {
                $currentKey = $matches.key
                continue
            }
            if (-not $currentKey) { continue }
            if ($line -match '^(?<name>@|"(?:[^"\\]|\\.)*")=(?<data>.*)$') {
                $name = if ($matches.name -eq '@') { '(Default)' } else { $matches.name.Trim('"') }
                $raw = $matches.data.Trim()
                $expectAbsent = ($raw -eq '-')
                $value = $raw
                if ($raw -match '(?i)^dword:(?<hex>[0-9a-f]{8})$') { $value = [convert]::ToInt64($matches.hex, 16).ToString() }
                elseif ($raw -match '^"(?<text>.*)"$') { $value = $matches.text -replace '\\"', '"' -replace '\\\\', '\' }
                elseif ($raw -match '(?i)^hex(?:\([0-9a-f]+\))?:') { continue }
                $assertions.Add([pscustomobject]@{ Path=$currentKey; Name=$name; Expected=$value; Absent=$expectAbsent; Source="$RelativePath | line $($index + 1)" })
            }
        }
        return $assertions
    }

    for ($index = 0; $index -lt $lines.Count; $index++) {
        $line = [string]$lines[$index]
        if ($line -match '(?i)\breg(?:\.exe)?\s+add\s+["'']?(?<path>(?:HKLM|HKCU|HKCR|HKU|HKEY_[A-Z_]+)\\[^"'']+?)["'']?\s+/v\s+["'']?(?<name>[^\s"'']+)["'']?.*?\s/d\s+["'']?(?<value>[^\s"'']+)["'']?') {
            $assertions.Add([pscustomobject]@{ Path=$matches.path.Trim(); Name=$matches.name; Expected=$matches.value; Absent=$false; Source="$RelativePath | line $($index + 1)" })
            continue
        }
        if ($line -match '(?i)\b(?:Set|New)-ItemProperty\b.*?-Path\s+["''](?<path>[^"'']+)["''].*?-Name\s+["''](?<name>[^"'']+)["''].*?-Value\s+(?:["''](?<quoted>[^"'']*)["'']|(?<plain>[^\s;]+))') {
            $value = if ($matches.quoted -ne $null -and $matches.quoted -ne '') { $matches.quoted } else { $matches.plain }
            $assertions.Add([pscustomobject]@{ Path=$matches.path; Name=$matches.name; Expected=$value; Absent=$false; Source="$RelativePath | line $($index + 1)" })
        }
    }
    return $assertions
}

try {
    Expand-SafeZip -Path $InputZip -Destination $extractFolder
    $files = @(Get-ChildItem -LiteralPath $extractFolder -Recurse -File)
    if ($files.Count -eq 0) { throw "The ZIP archive is empty." }

    $presetDocs = New-Object System.Collections.Generic.List[object]
    $unattendDocs = New-Object System.Collections.Generic.List[object]

    foreach ($file in $files) {
        $relative = $file.FullName.Substring($extractFolder.Length).TrimStart('\')
        $kind = "Supporting file"
        $parseState = "Not parsed"
        if ($file.Name -match '(?i)^NTLite(?:_dism)?\.log$') {
            $kind = if ($file.Name -match '(?i)_dism') { "NTLite DISM log" } else { "NTLite processing log" }
            $parseState = "Queued for error and warning scan"
        } elseif ($file.Extension -in @(".ps1", ".cmd", ".bat")) {
            $kind = "Post-setup script"
            $parseState = "Queued for safe static inspection; never executed"
        } elseif ($file.Extension -ieq ".reg") {
            $kind = "Registry file"
            $parseState = "Queued for safe state comparison; never imported"
        } elseif ($file.Extension -ieq ".xml") {
            try {
                $xml = New-Object System.Xml.XmlDocument
                $xml.PreserveWhitespace = $false
                $xml.Load($file.FullName)
                $rootName = $xml.DocumentElement.LocalName
                if ($rootName -eq "Preset") {
                    $kind = "NTLite preset"
                    $parseState = "Parsed"
                    $presetDocs.Add([pscustomobject]@{ File = $file; Relative = $relative; Xml = $xml })
                } elseif ($rootName -eq "unattend") {
                    $kind = "Windows unattended setup"
                    $parseState = "Parsed"
                    $unattendDocs.Add([pscustomobject]@{ File = $file; Relative = $relative; Xml = $xml })
                } else {
                    $kind = "Other XML"
                    $parseState = "Parsed, unsupported root '$rootName'"
                }
            } catch {
                $kind = "Invalid XML"
                $parseState = $_.Exception.Message
            }
        }
        $sources.Add([pscustomobject]@{
            File = $relative
            Type = $kind
            SizeKB = [math]::Round($file.Length / 1KB, 2)
            SHA256 = (Get-FileHash -LiteralPath $file.FullName -Algorithm SHA256).Hash
            State = $parseState
        })
    }

    if ($presetDocs.Count -eq 0 -and $unattendDocs.Count -eq 0) {
        throw "No NTLite preset XML or Windows unattended XML was found in the ZIP."
    }

    Add-Result -Status "Info" -Area "Input" -Item "Verification package" `
        -Expected "NTLite preset and/or Windows unattended XML" `
        -Actual "$($presetDocs.Count) preset(s), $($unattendDocs.Count) unattended file(s), $($files.Count) total file(s)" `
        -Explanation "Every result below identifies the XML file from which the expectation was read." `
        -Source ([IO.Path]::GetFileName($InputZip))

    if (-not $isAdmin) {
        Add-Result "Info" "Input" "Execution context" "Administrator" "Standard user" `
            "The parser completed, but protected package or machine-wide state may be unavailable. The menu starts this checker with UAC by default." `
            "Current PowerShell process"
    }

    # Different image versions or GUIDs are useful warnings when presets are collected from separate sessions.
    $imageRows = foreach ($doc in $presetDocs) {
        $node = $doc.Xml.SelectSingleNode("//*[local-name()='ImageInfo']/*[local-name()='Version']")
        $guid = $doc.Xml.SelectSingleNode("//*[local-name()='ImageInfo']/*[local-name()='GUID']")
        [pscustomobject]@{
            Source = $doc.Relative
            Version = if ($node) { [string]$node.InnerText } else { "Unknown" }
            Guid = if ($guid) { [string]$guid.InnerText } else { "Unknown" }
        }
    }
    $imageVersions = @($imageRows.Version | Sort-Object -Unique)
    $imageSessions = @($imageRows.Guid | Sort-Object -Unique)
    if ($imageVersions.Count -gt 1) {
        Add-Result "Not verifiable" "Input" "Presets were created against different Windows image versions" `
            "One final image version and session" (($imageRows | ForEach-Object { "$($_.Source): $($_.Version), $($_.Guid)" }) -join " | ") `
            "This can be valid in a staged image workflow, but the separate files do not prove the final state. Include the final auto-saved preset and application order." `
            (($imageRows.Source) -join "; ")
    } elseif ($imageRows.Count -gt 0) {
        Add-Result "Info" "Input" "NTLite image reference" $imageRows[0].Version $imageRows[0].Guid `
            "This identifies the image session recorded in the preset; it is not proof that the preset was applied." $imageRows[0].Source
        if ($imageSessions.Count -gt 1) {
            Add-Result "Info" "Input" "Multiple NTLite image session IDs" "One final auto-saved session" ($imageSessions -join "; ") `
                "The presets reference the same Windows version but were saved from different NTLite image sessions. The final auto-saved preset determines the effective combined configuration." `
                (($imageRows.Source) -join "; ")
        }
    }

    $autoSavedPresets = @($presetDocs | Where-Object { $_.Xml.DocumentElement.GetAttribute("isAutoSaved") -ieq "true" })
    if ($autoSavedPresets.Count -eq 0) {
        Add-Result "Not verifiable" "Input" "Final NTLite session preset" "Auto-saved final preset" "Missing from ZIP" `
            "Separate presets do not record the final append/overwrite order. Include the auto-saved session created after the final Apply operation." `
            ([IO.Path]::GetFileName($InputZip))
    } else {
        Add-Result "Matched" "Input" "Final NTLite session preset" "Auto-saved final preset" (($autoSavedPresets.Relative) -join "; ") `
            "The package contains at least one preset marked as an auto-saved NTLite session." (($autoSavedPresets.Relative) -join "; ")
    }

    $tweakMap = @{
        "Dsh\AllowNewsAndInterests" = @{ Path="HKLM:\SOFTWARE\Policies\Microsoft\Dsh"; Value="AllowNewsAndInterests"; Scope="Machine policy" }
        "WindowsUpdate\TargetReleaseVersionInfo" = @{ Path="HKLM:\SOFTWARE\Policies\Microsoft\Windows\WindowsUpdate"; Value="TargetReleaseVersionInfo"; Scope="Machine policy" }
        "AU\NoAutoUpdate" = @{ Path="HKLM:\SOFTWARE\Policies\Microsoft\Windows\WindowsUpdate\AU"; Value="NoAutoUpdate"; Scope="Machine policy" }
        "WindowsStore\AutoDownload" = @{ Path="HKLM:\SOFTWARE\Policies\Microsoft\WindowsStore"; Value="AutoDownload"; Scope="Machine policy" }
        "OneDrive\DisableFileSyncNGSC" = @{ Path="HKLM:\SOFTWARE\Policies\Microsoft\Windows\OneDrive"; Value="DisableFileSyncNGSC"; Scope="Machine policy" }
        "BitLocker\PreventDeviceEncryption" = @{ Path="HKLM:\SYSTEM\CurrentControlSet\Control\BitLocker"; Value="PreventDeviceEncryption"; Scope="Machine" }
        "GraphicsDrivers\HwSchMode" = @{ Path="HKLM:\SYSTEM\CurrentControlSet\Control\GraphicsDrivers"; Value="HwSchMode"; Scope="Machine" }
        "WindowsAI\DisableAIDataAnalysis" = @{ Path="HKLM:\SOFTWARE\Policies\Microsoft\Windows\WindowsAI"; Value="DisableAIDataAnalysis"; Scope="Machine policy" }
        "WindowsCopilot\TurnOffWindowsCopilot" = @{ Path="HKLM:\SOFTWARE\Policies\Microsoft\Windows\WindowsCopilot"; Value="TurnOffWindowsCopilot"; Scope="Machine policy" }
        "PushNotifications\ToastEnabled" = @{ Path="HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\PushNotifications"; Value="ToastEnabled"; Scope="Current user" }
        "Mouse\MouseSpeed" = @{ Path="HKCU:\Control Panel\Mouse"; Value="MouseSpeed"; Scope="Current user" }
        "Advanced\LaunchTo" = @{ Path="HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\Explorer\Advanced"; Value="LaunchTo"; Scope="Current user" }
        "Advanced\ShowTaskViewButton" = @{ Path="HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\Explorer\Advanced"; Value="ShowTaskViewButton"; Scope="Current user" }
        "Advanced\TaskbarAl" = @{ Path="HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\Explorer\Advanced"; Value="TaskbarAl"; Scope="Current user" }
        "Advanced\TaskbarMn" = @{ Path="HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\Explorer\Advanced"; Value="TaskbarMn"; Scope="Current user" }
        "Search\SearchboxTaskbarMode" = @{ Path="HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\Search"; Value="SearchboxTaskbarMode"; Scope="Current user" }
        "ContentDeliveryManager\SubscribedContent-338393Enabled" = @{ Path="HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\ContentDeliveryManager"; Value="SubscribedContent-338393Enabled"; Scope="Current user" }
        "ContentDeliveryManager\SubscribedContent-310093Enabled" = @{ Path="HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\ContentDeliveryManager"; Value="SubscribedContent-310093Enabled"; Scope="Current user" }
        "Privacy\TailoredExperiencesWithDiagnosticDataEnabled" = @{ Path="HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\Privacy"; Value="TailoredExperiencesWithDiagnosticDataEnabled"; Scope="Current user" }
        "System\EnableActivityFeed" = @{ Path="HKLM:\SOFTWARE\Policies\Microsoft\Windows\System"; Value="EnableActivityFeed"; Scope="Machine policy" }
        "System\EnableCdp" = @{ Path="HKLM:\SOFTWARE\Policies\Microsoft\Windows\System"; Value="EnableCdp"; Scope="Machine policy" }
        "System\DisableAutomaticRestartSignOn" = @{ Path="HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Policies\System"; Value="DisableAutomaticRestartSignOn"; Scope="Machine" }
        "Explorer\DisableSearchBoxSuggestions" = @{ Path="HKCU:\SOFTWARE\Policies\Microsoft\Windows\Explorer"; Value="DisableSearchBoxSuggestions"; Scope="Current user" }
        "Explorer\HideRecentlyAddedApps" = @{ Path="HKCU:\SOFTWARE\Policies\Microsoft\Windows\Explorer"; Value="HideRecentlyAddedApps"; Scope="Current user policy" }
        "Explorer\NoPinningStoreToTaskbar" = @{ Path="HKCU:\SOFTWARE\Policies\Microsoft\Windows\Explorer"; Value="NoPinningStoreToTaskbar"; Scope="Current user policy" }
        "Explorer\NoReadingPane" = @{ Path="HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\Policies\Explorer"; Value="NoReadingPane"; Scope="Current user policy" }
        "Explorer\NoRecentDocsHistory" = @{ Path="HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\Policies\Explorer"; Value="NoRecentDocsHistory"; Scope="Current user policy" }
        "Explorer\ShowOrHideMostUsedApps" = @{ Path="HKLM:\SOFTWARE\Policies\Microsoft\Windows\Explorer"; Value="ShowOrHideMostUsedApps"; Scope="Machine policy" }
        "Explorer\ShowFrequent" = @{ Path="HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\Explorer"; Value="ShowFrequent"; Scope="Current user" }
        "Explorer\ShowRecent" = @{ Path="HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\Explorer"; Value="ShowRecent"; Scope="Current user" }
        "DeliveryOptimization\DODownloadMode" = @{ Path="HKLM:\SOFTWARE\Policies\Microsoft\Windows\DeliveryOptimization"; Value="DODownloadMode"; Scope="Machine policy" }
        "Windows Search\AllowCloudSearch" = @{ Path="HKLM:\SOFTWARE\Policies\Microsoft\Windows\Windows Search"; Value="AllowCloudSearch"; Scope="Machine policy" }
    }

    $tweakRows = New-Object System.Collections.Generic.List[object]
    foreach ($doc in $presetDocs) {
        foreach ($node in @($doc.Xml.SelectNodes("//*[local-name()='Tweaks']/*[local-name()='Settings']/*[local-name()='TweakGroup']/*[local-name()='Tweak']"))) {
            $tweakRows.Add([pscustomobject]@{
                Name = [string]$node.GetAttribute("name")
                Group = [string]$node.ParentNode.GetAttribute("name")
                Expected = [string]$node.InnerText
                Source = $doc.Relative
            })
        }
    }

    foreach ($group in @($tweakRows | Group-Object Name)) {
        $expectedValues = @($group.Group.Expected | Sort-Object -Unique)
        $sourceList = ($group.Group.Source | Sort-Object -Unique) -join "; "
        if ($expectedValues.Count -gt 1) {
            Add-Result "Conflict" "Settings" $group.Name ($expectedValues -join " or ") "Conflicting presets" `
                "The ZIP contains more than one desired value. The checker cannot determine the NTLite load/append order from the XML files alone." $sourceList
            continue
        }
        $expected = [string]$expectedValues[0]
        if ($tweakMap.ContainsKey($group.Name)) {
            $map = $tweakMap[$group.Name]
            $actual = Get-RegistryValueSafe -Path $map.Path -Name $map.Value
            if ($null -eq $actual) {
                Add-Result "Mismatch" "Settings" $group.Name $expected "Value is missing" `
                    "The mapped $($map.Scope.ToLower()) registry value is not present on the current system." `
                    "$sourceList | Registry: $($map.Path)\$($map.Value)"
            } elseif (Test-ExpectedValue -Actual $actual -Expected $expected) {
                Add-Result "Matched" "Settings" $group.Name $expected ([string]$actual) `
                    "The current $($map.Scope.ToLower()) value matches the preset." `
                    "$sourceList | Registry: $($map.Path)\$($map.Value)"
            } else {
                Add-Result "Mismatch" "Settings" $group.Name $expected ([string]$actual) `
                    "The current $($map.Scope.ToLower()) value differs from the preset." `
                    "$sourceList | Registry: $($map.Path)\$($map.Value)"
            }
        } else {
            Add-Result "Not verifiable" "Settings" $group.Name $expected "No reliable registry mapping available" `
                "NTLite stores a logical setting name, not necessarily the complete Windows registry path. A verified mapping or an explicit assertion file is required." $sourceList
        }
    }

    $installedPackagesText = ""
    try {
        $installedPackagesText = (@(Get-WindowsPackage -Online -ErrorAction Stop | Select-Object -ExpandProperty PackageName) -join "`n")
    } catch {}
    $appxNames = @()
    $appxInventoryAvailable = $false
    try {
        $appxNames += @(Get-AppxPackage -AllUsers -ErrorAction Stop | Select-Object -ExpandProperty Name)
        $appxInventoryAvailable = $true
    } catch {}
    try {
        $appxNames += @(Get-AppxProvisionedPackage -Online -ErrorAction Stop | Select-Object -ExpandProperty DisplayName)
        $appxInventoryAvailable = $true
    } catch {}
    $appxNames = @($appxNames | Where-Object { $_ } | Sort-Object -Unique)

    foreach ($doc in $presetDocs) {
        foreach ($node in @($doc.Xml.SelectNodes("//*[local-name()='Packages']/*[local-name()='File']"))) {
            $packagePath = [string]$node.InnerText
            $leaf = [IO.Path]::GetFileName($packagePath)
            $kb = [regex]::Match($leaf, '(?i)kb\d+')
            if ($kb.Success) {
                if ($installedPackagesText -match [regex]::Escape($kb.Value)) {
                    Add-Result "Matched" "Updates and apps" $kb.Value "Installed or retained" "Installed package found" `
                        "The current Windows package inventory contains this KB identifier." $doc.Relative
                } else {
                    Add-Result "Not verifiable" "Updates and apps" $kb.Value "Integrated into the image" "No retained package name found" `
                        "A superseded update may be removed during component cleanup. Absence from the current package inventory is not sufficient proof of failure." $doc.Relative
                }
                continue
            }
            if ($leaf -match '(?i)\.(appx|msix|appxbundle|msixbundle)$') {
                $baseName = $leaf -replace '(?i)\.(appx|msix|appxbundle|msixbundle)$', ''
                $candidate = ($baseName -split '_')[0]
                if ($baseName -match '(?i)^PowerShell-') { $candidate = "Microsoft.PowerShell" }
                $candidateAliases = @($candidate)
                if ($candidate -ieq "Microsoft.WSL") {
                    $candidateAliases += "MicrosoftCorporationII.WindowsSubsystemForLinux"
                }
                $match = @($appxNames | Where-Object {
                    $installedName = $_
                    @($candidateAliases | Where-Object { $installedName -like "$_*" }).Count -gt 0
                }) | Select-Object -First 1
                if ($match) {
                    Add-Result "Matched" "Updates and apps" $candidate "Installed or provisioned" $match `
                        "A matching AppX/MSIX package is installed or provisioned." $doc.Relative
                } elseif ($appxInventoryAvailable) {
                    Add-Result "Mismatch" "Updates and apps" $candidate "Installed or provisioned" "Not found" `
                        "No matching installed or provisioned AppX/MSIX package was found for this preset entry." $doc.Relative
                } else {
                    Add-Result "Not verifiable" "Updates and apps" $candidate "Installed or provisioned" "AppX inventory unavailable" `
                        "The current PowerShell context could not read installed or provisioned AppX/MSIX packages." $doc.Relative
                }
                continue
            }
            Add-Result "Not verifiable" "Updates and apps" $leaf "Integrated or executed by NTLite" "No durable package identity" `
                "Executable update payloads cannot be proven from their source filename alone. NTLite.log or a product-specific state assertion is required." $doc.Relative
        }
    }

    foreach ($doc in $presetDocs) {
        foreach ($node in @($doc.Xml.SelectNodes("//*[local-name()='Execution']/*[local-name()='Add']/*[local-name()='Item']"))) {
            $pathNode = $node.SelectSingleNode("./*[local-name()='Path']")
            $paramsNode = $node.SelectSingleNode("./*[local-name()='Params']")
            $indexNode = $node.SelectSingleNode("./*[local-name()='Index']")
            $commandPath = if ($pathNode) { [string]$pathNode.InnerText } else { "Unknown command" }
            $expectedCommand = $commandPath
            if ($paramsNode -and -not [string]::IsNullOrWhiteSpace($paramsNode.InnerText)) { $expectedCommand += " " + $paramsNode.InnerText }
            Add-Result "Not verifiable" "Post-setup" ([IO.Path]::GetFileName($commandPath)) `
                "Run successfully at order $($indexNode.InnerText)" "Referenced by preset; exit code unavailable" `
                "A preset proves intent, not execution. The checker verifies durable effects when a safe current-state assertion is available and searches local Panther logs for invocation evidence." `
                (Protect-SensitiveText "$($doc.Relative) | $expectedCommand")
        }
    }

    foreach ($doc in $unattendDocs) {
        $xml = $doc.Xml
        $source = $doc.Relative
        $timeZoneNode = $xml.SelectSingleNode("//*[local-name()='TimeZone']")
        if ($timeZoneNode) {
            $expected = [string]$timeZoneNode.InnerText
            $actual = try { (Get-TimeZone).Id } catch { "Unavailable" }
            Add-Result $(if ($actual -eq $expected) { "Matched" } else { "Mismatch" }) "Windows setup" "Time zone" $expected $actual `
                "Compared with the active Windows time zone." $source
        }
        $systemLocaleNode = $xml.SelectSingleNode("//*[local-name()='settings' and @pass='oobeSystem']//*[local-name()='SystemLocale']")
        if ($systemLocaleNode) {
            $expected = [string]$systemLocaleNode.InnerText
            $actual = try { (Get-WinSystemLocale).Name } catch { "Unavailable" }
            Add-Result $(if ($actual -ieq $expected) { "Matched" } else { "Mismatch" }) "Windows setup" "System locale" $expected $actual `
                "Compared with the active Windows system locale." $source
        }
        foreach ($accountNode in @($xml.SelectNodes("//*[local-name()='LocalAccount']"))) {
            $nameNode = $accountNode.SelectSingleNode("./*[local-name()='Name']")
            $groupNode = $accountNode.SelectSingleNode("./*[local-name()='Group']")
            if (-not $nameNode) { continue }
            $name = [string]$nameNode.InnerText
            $groupName = if ($groupNode) { [string]$groupNode.InnerText } else { "" }
            $user = try { Get-LocalUser -Name $name -ErrorAction Stop } catch { $null }
            if (-not $user) {
                Add-Result "Mismatch" "Windows setup" "Local account: $name" "Account exists; group $groupName" "Account not found" `
                    "The local account requested by the unattended setup file is missing." $source
            } else {
                $inGroup = $false
                if ($groupName) {
                    try { $inGroup = [bool](@(Get-LocalGroupMember -Group $groupName -ErrorAction Stop | Where-Object { $_.Name -like "*\$name" }).Count) } catch {}
                }
                $status = if (-not $groupName -or $inGroup) { "Matched" } else { "Mismatch" }
                $actual = if (-not $groupName) { "Account exists" } elseif ($inGroup) { "Account exists in $groupName" } else { "Account exists but is not in $groupName" }
                Add-Result $status "Windows setup" "Local account: $name" "Account exists; group $groupName" $actual `
                    "Passwords are deliberately never read or displayed." $source
            }
        }
        $autoLogonNode = $xml.SelectSingleNode("//*[local-name()='AutoLogon']/*[local-name()='Enabled']")
        if ($autoLogonNode) {
            $expectedEnabled = ([string]$autoLogonNode.InnerText -ieq "true")
            $actualValue = Get-RegistryValueSafe "HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Winlogon" "AutoAdminLogon"
            $actualEnabled = ([string]$actualValue -eq "1")
            Add-Result $(if ($actualEnabled -eq $expectedEnabled) { "Matched" } else { "Mismatch" }) "Windows setup" "Automatic logon" `
                ([string]$expectedEnabled) ([string]$actualEnabled) `
                "Compared with the effective Winlogon state. Credentials are not collected." $source
        }
        foreach ($nodeName in @("SkipMachineOOBE", "SkipUserOOBE", "ProtectYourPC", "DynamicUpdate", "SkipAutoActivation")) {
            $nodes = @($xml.SelectNodes("//*[local-name()='$nodeName']"))
            foreach ($node in $nodes) {
                $value = if ($nodeName -eq "DynamicUpdate") { [string]$node.InnerXml } else { [string]$node.InnerText }
                Add-Result "Not verifiable" "Windows setup" $nodeName $value "No durable final-state assertion" `
                    "This setup-time instruction cannot be proven from the current state alone. Panther logs are required for execution evidence." $source
            }
        }
    }

    if ($unattendDocs.Count -eq 0) {
        Add-Result "Not verifiable" "Input" "Windows unattended setup" "Complete autounattend.xml or unattend.xml" "Missing from ZIP" `
            "Account, locale, OOBE, image selection, and other Windows Setup expectations cannot be compared without the generated unattended file." `
            ([IO.Path]::GetFileName($InputZip))
    }

    $hasNtliteLog = @($files | Where-Object { $_.Name -match '(?i)^NTLite.*\.log$' }).Count -gt 0
    if (-not $hasNtliteLog) {
        Add-Result "Not verifiable" "Input" "NTLite processing log" "Matching NTLite.log" "Missing from ZIP" `
            "Preset XML files describe intent. NTLite.log is needed to identify image-processing warnings and failures." `
            ([IO.Path]::GetFileName($InputZip))
    }

    # NTLite build logs prove image-processing activity, but not the effective state after Windows Setup.
    foreach ($logFile in @($files | Where-Object { $_.Name -match '(?i)^NTLite(?:_dism)?\.log$' })) {
        $relative = $logFile.FullName.Substring($extractFolder.Length).TrimStart('\')
        $lines = @(Get-Content -LiteralPath $logFile.FullName -ErrorAction SilentlyContinue)
        $failures = New-Object System.Collections.Generic.List[object]
        $warnings = New-Object System.Collections.Generic.List[object]
        for ($index = 0; $index -lt $lines.Count; $index++) {
            $line = [string]$lines[$index]
            if ([string]::IsNullOrWhiteSpace($line)) { continue }
            if ($line -match '(?i)(?:\b(?:failed|failure|aborted|exception)\b|(?:^|\s)error(?:\s+\d+)?\s*:)' -and $line -notmatch '(?i)\berrors?\s*[:=]\s*0\b') {
                $failures.Add([pscustomobject]@{ Line=$index + 1; Text=(Protect-SensitiveText $line.Trim()) })
            } elseif ($line -match '(?i)(?:^|\s)warn(?:ing)?\s*:') {
                $warnings.Add([pscustomobject]@{ Line=$index + 1; Text=(Protect-SensitiveText $line.Trim()) })
            }
        }
        if ($failures.Count -eq 0) {
            Add-Result "Matched" "Image processing" $logFile.Name "No failure markers" "No failure markers found in $($lines.Count) line(s)" `
                "The supplied NTLite build log contains no obvious Error, Failed, Aborted, or Exception marker. This does not replace final-state checks." $relative
        } else {
            $examples = @($failures | Select-Object -First 8 | ForEach-Object { "line $($_.Line): $($_.Text)" }) -join " | "
            $sourceLines = @($failures | Select-Object -First 25 | ForEach-Object { "$relative line $($_.Line)" }) -join "; "
            Add-Result "Mismatch" "Image processing" $logFile.Name "No NTLite processing failures" "$($failures.Count) failure marker(s)" `
                "Review the build operation before trusting the image. First entries: $examples" $sourceLines
        }
        if ($warnings.Count -gt 0) {
            $warningExamples = @($warnings | Select-Object -First 5 | ForEach-Object { "line $($_.Line): $($_.Text)" }) -join " | "
            Add-Result "Info" "Image processing" "$($logFile.Name) warnings" "Review warnings" "$($warnings.Count) warning marker(s)" `
                "Warnings do not always indicate a failed build. First entries: $warningExamples" $relative
        }
    }

    # Parse only literal registry instructions. Supplied files are never executed or imported.
    $scriptFiles = @($files | Where-Object { $_.Extension -in @('.reg', '.ps1', '.cmd', '.bat') })
    $scriptAssertions = New-Object System.Collections.Generic.List[object]
    foreach ($scriptFile in $scriptFiles) {
        $relative = $scriptFile.FullName.Substring($extractFolder.Length).TrimStart('\')
        try {
            $assertions = @(Get-LiteralRegistryAssertions -File $scriptFile -RelativePath $relative)
            if ($assertions.Count -eq 0) {
                Add-Result "Not verifiable" "Post-setup source" $relative "Script effect is present on this PC" "No safe literal registry assertion found" `
                    "The file is inventoried and hashed, but the checker will not execute it or guess the effects of variables, functions, installers, or external programs." $relative
                continue
            }
            Add-Result "Info" "Post-setup source" $relative "$($assertions.Count) literal registry instruction(s)" "Compared with current registry" `
                "Only directly readable REG entries and literal reg.exe/Set-ItemProperty/New-ItemProperty commands are evaluated." $relative
            foreach ($assertion in $assertions) {
                $scriptAssertions.Add($assertion)
            }
        } catch {
            Add-Result "Not verifiable" "Post-setup source" $relative "Static source inspection" "Parser could not inspect this file" `
                (Protect-SensitiveText $_.Exception.Message) $relative
        }
    }
    foreach ($assertionGroup in @($scriptAssertions | Group-Object { "$(ConvertTo-RegistryProviderPath $_.Path)|$($_.Name)|$($_.Expected)|$($_.Absent)" })) {
        $assertion = $assertionGroup.Group[0]
        $assertionSources = @($assertionGroup.Group.Source | Sort-Object -Unique) -join "; "
        Add-RegistryAssertionResult -RegistryPath $assertion.Path -ValueName $assertion.Name `
            -Expected ([string]$assertion.Expected) -ExpectAbsent ([bool]$assertion.Absent) -Source $assertionSources
    }

    # Inspect durable Windows Setup evidence already present on the installed PC.
    $setupLogPaths = @(
        "$env:WINDIR\Panther\setuperr.log",
        "$env:WINDIR\Panther\setupact.log",
        "$env:WINDIR\Panther\UnattendGC\setuperr.log",
        "$env:WINDIR\Panther\UnattendGC\setupact.log"
    )
    foreach ($setupPath in $setupLogPaths) {
        if (-not (Test-Path -LiteralPath $setupPath -PathType Leaf)) { continue }
        $item = Get-Item -LiteralPath $setupPath
        $readable = $true
        $readError = ""
        try {
            $lines = @(Get-Content -LiteralPath $setupPath -ErrorAction Stop)
        } catch {
            $lines = @()
            $readable = $false
            $readError = Protect-SensitiveText $_.Exception.Message
        }
        $nonEmpty = @($lines | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })
        $hash = try { (Get-FileHash -LiteralPath $setupPath -Algorithm SHA256 -ErrorAction Stop).Hash } catch { "Unavailable" }
        $localSetupEvidence.Add([pscustomobject]@{
            File = $setupPath
            SizeKB = [math]::Round($item.Length / 1KB, 2)
            LastWriteTime = $item.LastWriteTime.ToString('yyyy-MM-dd HH:mm:ss')
            NonEmptyLines = $nonEmpty.Count
            Readable = $readable
            SHA256 = $hash
        })
        if (-not $readable) {
            Add-Result "Not verifiable" "Windows Setup evidence" $setupPath "Readable local setup log" "Access unavailable" `
                "The checker could not inspect this protected log in the current execution context: $readError" $setupPath
            continue
        }
        if ($item.Name -ieq 'setuperr.log') {
            if ($nonEmpty.Count -eq 0) {
                Add-Result "Matched" "Windows Setup evidence" $setupPath "No recorded setup errors" "Log is empty" `
                    "Windows retained this setup error log and it contains no non-empty records." $setupPath
            } else {
                $sample = @($nonEmpty | Select-Object -First 6 | ForEach-Object { Protect-SensitiveText ([string]$_).Trim() }) -join " | "
                Add-Result "Mismatch" "Windows Setup evidence" $setupPath "No recorded setup errors" "$($nonEmpty.Count) non-empty line(s)" `
                    "Windows Setup recorded messages in setuperr.log. They require review because not every retained message is fatal. First entries: $sample" $setupPath
            }
        } else {
            $executionLines = New-Object System.Collections.Generic.List[object]
            for ($index = 0; $index -lt $lines.Count; $index++) {
                if ([string]$lines[$index] -match '(?i)SetupComplete|RunSynchronous|FirstLogonCommands') {
                    $executionLines.Add([pscustomobject]@{ Line=$index + 1; Text=(Protect-SensitiveText ([string]$lines[$index]).Trim()) })
                }
            }
            if ($executionLines.Count -gt 0) {
                $sample = @($executionLines | Select-Object -First 6 | ForEach-Object { "line $($_.Line): $($_.Text)" }) -join " | "
                Add-Result "Info" "Windows Setup evidence" "$($item.Directory.Name)\$($item.Name)" "Setup command invocation evidence" "$($executionLines.Count) related line(s)" `
                    "Windows recorded setup command activity. This can prove invocation, but not the inner exit codes of every script. First entries: $sample" $setupPath
            }
        }
    }
    if ($localSetupEvidence.Count -eq 0) {
        Add-Result "Not verifiable" "Windows Setup evidence" "Panther logs" "Local Windows Setup logs" "No standard Panther logs found" `
            "The current Windows installation no longer exposes the standard setupact.log or setuperr.log files at the checked locations." "$env:WINDIR\Panther"
    }

    $resultCsv = Join-Path $outputFolder "VerificationResults.csv"
    $sourceCsv = Join-Path $outputFolder "SourceInventory.csv"
    $setupEvidenceCsv = Join-Path $outputFolder "LocalSetupEvidence.csv"
    $results | Export-Csv -LiteralPath $resultCsv -NoTypeInformation -Encoding UTF8
    $sources | Export-Csv -LiteralPath $sourceCsv -NoTypeInformation -Encoding UTF8
    $localSetupEvidence | Export-Csv -LiteralPath $setupEvidenceCsv -NoTypeInformation -Encoding UTF8

    $statusOrder = @{ "Conflict"=0; "Mismatch"=1; "Not verifiable"=2; "Matched"=3; "Info"=4 }
    $ordered = @($results | Sort-Object @{Expression={ $statusOrder[$_.Status] }}, Area, Item)
    $counts = @{}
    foreach ($status in @("Matched", "Mismatch", "Conflict", "Not verifiable", "Info")) {
        $counts[$status] = @($results | Where-Object Status -eq $status).Count
    }

    $sectionsHtml = ""
    foreach ($status in @("Conflict", "Mismatch", "Not verifiable", "Matched", "Info")) {
        $rows = @($ordered | Where-Object Status -eq $status)
        if ($rows.Count -eq 0) { continue }
        $open = if ($status -in @("Conflict", "Mismatch")) { " open" } else { "" }
        $rowHtml = foreach ($row in $rows) {
            "<tr><td>$(ConvertTo-HtmlText $row.Area)</td><td><strong>$(ConvertTo-HtmlText $row.Item)</strong></td><td>$(ConvertTo-HtmlText $row.Expected)</td><td>$(ConvertTo-HtmlText $row.Actual)</td><td>$(ConvertTo-HtmlText $row.Explanation)</td><td><code>$(ConvertTo-HtmlText $row.Source)</code></td></tr>"
        }
        $sectionsHtml += "<details class='section status-$($status -replace ' ','-')'$open><summary><span>$status</span><b>$($rows.Count)</b></summary><div class='table-wrap'><table><thead><tr><th>Area</th><th>Check</th><th>Expected</th><th>Current result</th><th>Meaning</th><th>Source</th></tr></thead><tbody>$($rowHtml -join '')</tbody></table></div></details>"
    }

    $sourceRowsHtml = foreach ($source in $sources | Sort-Object Type, File) {
        "<tr><td>$(ConvertTo-HtmlText $source.File)</td><td>$(ConvertTo-HtmlText $source.Type)</td><td>$(ConvertTo-HtmlText $source.State)</td><td>$(ConvertTo-HtmlText $source.SizeKB)</td><td><code>$(ConvertTo-HtmlText $source.SHA256)</code></td></tr>"
    }
    $created = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
    $html = @"
<!doctype html>
<html lang="en"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1">
<title>NTLiteChecker Result</title>
<style>
:root{--text:#102033;--muted:#5d7188;--line:#cfd9e6;--bg:#f5f8fc;--panel:#fff;--bad:#fff0ea;--bad-line:#b63b16;--warn:#fff8d6;--warn-line:#a96b00;--unknown:#eef3ff;--unknown-line:#2851a3;--good:#e9f9ef;--good-line:#18753c;--info:#edf7fb;--info-line:#126986}*{box-sizing:border-box}body{margin:0;background:var(--bg);color:var(--text);font:15px/1.45 Segoe UI,Arial,sans-serif}main{max-width:1800px;margin:auto;padding:24px}h1{margin:0 0 4px;font-size:30px;letter-spacing:0}.meta{color:var(--muted);margin-bottom:20px}.summary{display:grid;grid-template-columns:repeat(5,minmax(135px,1fr));gap:10px;margin:0 0 22px}.metric{background:var(--panel);border:1px solid var(--line);border-left:6px solid var(--info-line);padding:14px}.metric b{display:block;font-size:24px}.metric span{color:var(--muted)}.metric.bad{border-left-color:var(--bad-line)}.metric.warn{border-left-color:var(--warn-line)}.metric.good{border-left-color:var(--good-line)}details.section{background:var(--panel);border:1px solid var(--line);border-left:6px solid var(--info-line);margin:12px 0}details.status-Conflict,details.status-Mismatch{background:var(--bad);border-left-color:var(--bad-line)}details.status-Not-verifiable{background:var(--warn);border-left-color:var(--warn-line)}details.status-Matched{background:var(--good);border-left-color:var(--good-line)}details.status-Info{background:var(--info);border-left-color:var(--info-line)}summary{cursor:pointer;padding:16px 18px;font-size:18px;font-weight:700;display:flex;justify-content:space-between}summary b{background:#fff;border:1px solid var(--line);min-width:34px;text-align:center;padding:3px 9px;border-radius:17px}.table-wrap{overflow-x:auto;border-top:1px solid var(--line)}table{width:100%;min-width:1100px;border-collapse:collapse;background:rgba(255,255,255,.7)}th,td{text-align:left;vertical-align:top;border-bottom:1px solid var(--line);padding:10px 12px}th{background:#edf2f8;font-size:13px}code{font:12px/1.4 Consolas,monospace;word-break:break-word}.note{background:#fff;border:1px solid var(--line);padding:14px 16px;margin:16px 0}.source{margin-top:28px}@media(max-width:900px){main{padding:12px}.summary{grid-template-columns:repeat(2,1fr)}h1{font-size:25px}}
</style></head><body><main>
<h1>NTLiteChecker Result</h1>
<div class="meta">Version $ToolVersion | Created: $created | Computer: $(ConvertTo-HtmlText $env:COMPUTERNAME) | Input: $(ConvertTo-HtmlText ([IO.Path]::GetFileName($InputZip)))</div>
<div class="summary">
<div class="metric good"><b>$($counts['Matched'])</b><span>Matched</span></div>
<div class="metric bad"><b>$($counts['Mismatch'])</b><span>Mismatch</span></div>
<div class="metric bad"><b>$($counts['Conflict'])</b><span>Conflicts</span></div>
<div class="metric warn"><b>$($counts['Not verifiable'])</b><span>Not verifiable</span></div>
<div class="metric"><b>$($counts['Info'])</b><span>Information</span></div>
</div>
<div class="note"><strong>How to read this report:</strong> Matched means the current state can be demonstrated or a supplied processing log contains no obvious failure marker. Mismatch means a directly comparable state differs, is missing, or a build/setup log contains failure evidence. Not verifiable means the supplied source does not leave enough durable evidence. This checker is read-only: supplied scripts and REG files are inspected but never executed or imported.</div>
$sectionsHtml
<details class="section source"><summary><span>Source package inventory</span><b>$($sources.Count)</b></summary><div class="table-wrap"><table><thead><tr><th>File</th><th>Type</th><th>Parser state</th><th>KB</th><th>SHA-256</th></tr></thead><tbody>$($sourceRowsHtml -join '')</tbody></table></div></details>
</main></body></html>
"@
    $reportPath = Join-Path $outputFolder "NTLiteChecker_Result.html"
    [IO.File]::WriteAllText($reportPath, $html, [Text.UTF8Encoding]::new($true))

    $resultZipPath = "${outputFolder}_Result.zip"
    Compress-Archive -Path (Join-Path $outputFolder '*') -DestinationPath $resultZipPath -CompressionLevel Optimal -Force

    Write-Host "Verification complete." -ForegroundColor Green
    Write-Host "Matched: $($counts['Matched']) | Mismatch: $($counts['Mismatch']) | Conflict: $($counts['Conflict']) | Not verifiable: $($counts['Not verifiable'])" -ForegroundColor Gray
    Write-Host "Report: $reportPath" -ForegroundColor Cyan
    Write-Host "Result ZIP: $resultZipPath" -ForegroundColor Cyan
    if ($OpenReport) { Start-Process -FilePath $reportPath | Out-Null }
} finally {
    if (Test-Path -LiteralPath $extractFolder) {
        Remove-Item -LiteralPath $extractFolder -Recurse -Force -ErrorAction SilentlyContinue
    }
}
