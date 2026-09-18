<#
.SYNOPSIS
    Remote starter for PC-Diagnose tools.

.DESCRIPTION
    Intended entry point:
        irm https://raw.githubusercontent.com/F1R3Burnout/PC-Diagnose/main/r | iex
#>

[CmdletBinding()]
param(
    [string]$Tool = "menu",
    [string]$Branch = "main",
    [string]$OutputRoot = "C:\Temp",
    [int]$DaysBack = 0,
    [int]$MaxEvents = 2000,
    [int]$EventTimeoutSeconds = 180,
    [int]$StepTimeoutSeconds = 90,
    [switch]$PrivacyMode,
    [switch]$AutoInstallDebugTools,
    [switch]$DaysBackProvided,
    [switch]$NoElevate,
    [string]$OutputPath = "C:\Temp\NetzwerkDiagnose",
    [string[]]$LocalTargets = @(),
    [string[]]$TcpTargets = @(),
    [string[]]$DnsTestNames = @("google.de", "microsoft.com", "dns.msftncsi.com"),
    [string]$LanSpeedTarget = "",
    [string]$SmbTestPath = "",
    [int]$SmbTestSizeMB = 256,
    [int]$PingCount = 10,
    [int]$EventHours = 168,
    [switch]$IncludeEventLogs,
    [switch]$IncludeRawData,
    [switch]$IncludeTraceroute,
    [switch]$IncludeMtuTest,
    [switch]$IncludeSpeedtest,
    [switch]$IncludeSubnetDiscovery,
    [switch]$NoInternetTest,
    [switch]$NoWriteTests,
    [ValidateSet("Quick","Standard","Extended")]
    [string]$Profile = "Quick",
    [string]$Components = "CPU,Cache,RAM,GPU,VRAM,Storage,PCIe,System",
    [switch]$NoDownload,
    [switch]$SkipTelemetry,
    [switch]$HsDryRun,
    [long]$SurfaceScanMaxBytes = 0
)

$ErrorActionPreference = "Stop"
$ProgressPreference = "SilentlyContinue"
$DaysBackWasProvided = $PSBoundParameters.ContainsKey("DaysBack") -or [bool]$DaysBackProvided

$RepoOwner = "F1R3Burnout"
$RepoName = "PC-Diagnose"
$RawBase = "https://raw.githubusercontent.com/$RepoOwner/$RepoName/$Branch"
$ApiBase = "https://api.github.com/repos/$RepoOwner/$RepoName/contents"
$BootstrapUrl = "$RawBase/r"
$ManifestUrl = "$RawBase/manifest.json"

try {
    [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
} catch {}

# Persistent, append-only log for this launcher stage (menu, manifest fetch,
# elevation, tool download). Console output alone is lost as soon as the
# window closes, which made a real failure here (a false-positive antivirus
# block of the elevation relaunch) hard to diagnose from a screenshot alone.
# HardwareStability.ps1 and the other tools have their own, more detailed
# per-run logs once they actually start (see their own output folders); this
# file specifically covers everything before that point.
$BootstrapLogDir = Join-Path $env:TEMP "PC-Diagnose"
New-Item -ItemType Directory -Force -Path $BootstrapLogDir -ErrorAction SilentlyContinue | Out-Null
$BootstrapLogPath = Join-Path $BootstrapLogDir "bootstrap.log"

function Write-BootstrapLog {
    param([string]$Text)
    $line = "[{0}] {1}" -f (Get-Date -Format "yyyy-MM-dd HH:mm:ss"), $Text
    try { $line | Out-File -FilePath $BootstrapLogPath -Encoding UTF8 -Append } catch {}
}

Write-BootstrapLog "=== bootstrap.ps1 started (Tool=$Tool, Branch=$Branch, PID=$PID) ==="

function Test-IsAdmin {
    $currentIdentity = [Security.Principal.WindowsIdentity]::GetCurrent()
    $principal = New-Object Security.Principal.WindowsPrincipal($currentIdentity)
    return $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

function Get-RemoteText {
    param([Parameter(Mandatory=$true)][string]$Uri)

    $text = (Invoke-WebRequest -UseBasicParsing -Uri $Uri).Content
    return ([string]$text).TrimStart([char]0xFEFF)
}

function Get-RepositoryFileText {
    param([Parameter(Mandatory=$true)][string]$Path)

    $escapedPath = ([string]$Path).TrimStart("/") -replace " ", "%20"
    $escapedRef = [Uri]::EscapeDataString($Branch)
    $response = Invoke-WebRequest -UseBasicParsing -Uri "$ApiBase/$escapedPath`?ref=$escapedRef"
    $fileInfo = $response.Content | ConvertFrom-Json
    $base64 = ([string]$fileInfo.content) -replace '\s', ''
    return ([Text.Encoding]::UTF8.GetString([Convert]::FromBase64String($base64))).TrimStart([char]0xFEFF)
}

function Get-Manifest {
    $json = Get-RepositoryFileText -Path "manifest.json"
    return $json | ConvertFrom-Json
}

function Quote-ForSingleQuotedPowerShell {
    param([AllowNull()][string]$Value)

    if ($null -eq $Value) { return "''" }
    return "'" + ([string]$Value -replace "'", "''") + "'"
}

function Start-ElevatedBootstrap {
    param([Parameter(Mandatory=$true)][string]$SelectedTool)

    $command = @(
        "[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12"
        "& ([scriptblock]::Create((Invoke-WebRequest -UseBasicParsing -Uri $(Quote-ForSingleQuotedPowerShell $BootstrapUrl)).Content.TrimStart([char]0xFEFF))) " +
            "-Tool $(Quote-ForSingleQuotedPowerShell $SelectedTool) " +
            "-Branch $(Quote-ForSingleQuotedPowerShell $Branch) " +
            "-OutputRoot $(Quote-ForSingleQuotedPowerShell $OutputRoot) " +
            "-DaysBack $DaysBack " +
            "-MaxEvents $MaxEvents " +
            "-EventTimeoutSeconds $EventTimeoutSeconds " +
            "-StepTimeoutSeconds $StepTimeoutSeconds " +
            "$(if ($PrivacyMode) { '-PrivacyMode ' } else { '' })" +
            "$(if ($AutoInstallDebugTools) { '-AutoInstallDebugTools ' } else { '' })" +
            "$(if ($DaysBackWasProvided) { '-DaysBackProvided ' } else { '' })" +
            "-NoElevate"
    ) -join "; "

    # A relaunch built from -EncodedCommand (base64 of "download + scriptblock.Create +
    # invoke") matches the generic pattern several antivirus ML classifiers flag as a
    # dropper/stager (observed in practice as a false-positive "Trojan:Win32/Commando.A!ml"
    # detection on a legitimate run of this exact code). Writing the same command to a
    # plain, readable temporary .ps1 file and launching it with -File instead removes that
    # signature without changing what actually runs.
    $elevatedScriptPath = Join-Path ([IO.Path]::GetTempPath()) ("PC-Diagnose-elevate-{0}.ps1" -f ([guid]::NewGuid().ToString("N")))
    [IO.File]::WriteAllText($elevatedScriptPath, $command, [Text.UTF8Encoding]::new($true))
    Write-BootstrapLog "Elevation: writing relaunch script to $elevatedScriptPath for tool '$SelectedTool'"
    try {
        Start-Process -FilePath "powershell.exe" -ArgumentList @("-NoExit", "-NoProfile", "-ExecutionPolicy", "Bypass", "-File", $elevatedScriptPath) -Verb RunAs | Out-Null
        Write-BootstrapLog "Elevation: Start-Process -Verb RunAs returned without throwing (a UAC prompt may still be pending, or the elevated window may already be open)."
    } catch {
        Write-BootstrapLog "Elevation FAILED: $($_.Exception.GetType().FullName): $($_.Exception.Message)"
        Write-Host ""
        Write-Host "Could not open an elevated PowerShell window automatically: $($_.Exception.Message)" -ForegroundColor Red
        Write-Host "Open PowerShell as Administrator yourself (right-click Start -> 'Windows PowerShell (Admin)') and run:" -ForegroundColor Yellow
        Write-Host "  irm $BootstrapUrl | iex" -ForegroundColor Yellow
        Write-Host "Log file for this attempt: $BootstrapLogPath" -ForegroundColor DarkGray
    }
}

function Show-ToolList {
    param([Parameter(Mandatory=$true)]$Manifest)

    Write-Host ""
    Write-Host "PC-Diagnose Tools" -ForegroundColor Cyan
    Write-Host "=================" -ForegroundColor Cyan
    Write-Host ""

    $i = 1
    foreach ($item in $Manifest.tools) {
        $adminText = if ($item.requiresAdmin) { "Admin" } else { "User" }
        Write-Host ("[{0}] {1} ({2})" -f $i, $item.name, $adminText) -ForegroundColor Yellow
        Write-Host ("    {0}" -f $item.description) -ForegroundColor Gray
        Write-Host ("    Tool-ID: {0}" -f $item.id) -ForegroundColor DarkGray
        $i++
    }

    Write-Host ""
}

function Select-ToolFromMenu {
    param([Parameter(Mandatory=$true)]$Manifest)

    Show-ToolList -Manifest $Manifest
    $selection = Read-Host "Enter number or tool ID"

    if ([string]::IsNullOrWhiteSpace($selection)) {
        throw "No selection entered."
    }

    $number = 0
    if ([int]::TryParse($selection, [ref]$number)) {
        if ($number -lt 1 -or $number -gt $Manifest.tools.Count) {
            throw "Invalid selection: $selection"
        }

        return [string]$Manifest.tools[$number - 1].id
    }

    return [string]$selection
}

function Read-DaysBackForTool {
    param(
        [Parameter(Mandatory=$true)][string]$ToolId,
        [int]$DefaultDays = 0
    )

    if ($ToolId -ne "pcdiag" -or $DaysBackWasProvided) {
        return $DaysBack
    }

    Write-Host ""
    $inputValue = Read-Host "How many days back should be analyzed? [all]"
    if ([string]::IsNullOrWhiteSpace($inputValue)) {
        return 0
    }

    $parsed = 0
    if (-not [int]::TryParse($inputValue, [ref]$parsed) -or $parsed -lt 0 -or $parsed -gt 3650) {
        throw "Invalid DaysBack value: $inputValue. Press Enter or enter 0 for all entries, or enter a number between 1 and 3650."
    }

    return $parsed
}

function Invoke-RemoteTool {
    param(
        [Parameter(Mandatory=$true)]$Manifest,
        [Parameter(Mandatory=$true)][string]$SelectedTool
    )

    $toolInfo = @($Manifest.tools | Where-Object { $_.id -eq $SelectedTool -or $_.name -eq $SelectedTool }) | Select-Object -First 1
    if (-not $toolInfo) {
        Write-BootstrapLog "Tool not found: $SelectedTool"
        throw "Tool not found: $SelectedTool"
    }
    Write-BootstrapLog "Resolved tool: id=$($toolInfo.id) name=$($toolInfo.name) requiresAdmin=$($toolInfo.requiresAdmin)"

    if ($toolInfo.id -eq "pcdiag") {
        $script:DaysBack = Read-DaysBackForTool -ToolId ([string]$toolInfo.id) -DefaultDays 0
    }

    if ($toolInfo.requiresAdmin -and -not (Test-IsAdmin)) {
        if ($NoElevate) {
            throw "This tool requires Administrator rights: $($toolInfo.name)"
        }

        Write-Host ""
        Write-Host "$($toolInfo.name) requires Administrator rights. Opening UAC..." -ForegroundColor Yellow
        Start-ElevatedBootstrap -SelectedTool ([string]$toolInfo.id)
        return
    }

    $toolUri = "$RawBase/$($toolInfo.path)"
    $cacheRoot = Join-Path $env:TEMP "PC-Diagnose"
    $toolCacheDir = Join-Path $cacheRoot ([string]$toolInfo.id)
    New-Item -ItemType Directory -Force -Path $toolCacheDir | Out-Null

    $scriptPath = Join-Path $toolCacheDir (Split-Path -Path ([string]$toolInfo.path) -Leaf)
    $scriptText = Get-RepositoryFileText -Path ([string]$toolInfo.path)
    [IO.File]::WriteAllText($scriptPath, [string]$scriptText, [Text.UTF8Encoding]::new($true))
    Write-BootstrapLog "Fetched tool script $($toolInfo.path) -> $scriptPath ($($scriptText.Length) chars)"
    try {
        Unblock-File -LiteralPath $scriptPath -ErrorAction SilentlyContinue
    } catch {}

    $dependencyPaths = @{}
    foreach ($dependency in @($toolInfo.dependencies)) {
        if ([string]::IsNullOrWhiteSpace([string]$dependency)) { continue }
        # Preserve the dependency's relative subfolder structure (e.g.
        # "lib/HardwareStability/Native/RawDiskReader.cs") under the cache
        # dir instead of flattening to just the leaf file name, so modules
        # that Import-Module their siblings or load a "Native\*.cs" file
        # relative to their own folder keep working when fetched standalone.
        $relativePath = ([string]$dependency).Replace("/", "\")
        $dependencyPath = Join-Path $toolCacheDir $relativePath
        New-Item -ItemType Directory -Force -Path (Split-Path -Path $dependencyPath -Parent) | Out-Null
        $dependencyText = Get-RepositoryFileText -Path ([string]$dependency)
        [IO.File]::WriteAllText($dependencyPath, [string]$dependencyText, [Text.UTF8Encoding]::new($true))
        try { Unblock-File -LiteralPath $dependencyPath -ErrorAction SilentlyContinue } catch {}
        $dependencyPaths[(Split-Path -Path ([string]$dependency) -Leaf)] = $dependencyPath
        $dependencyPaths[[string]$dependency] = $dependencyPath
    }
    if (@($toolInfo.dependencies).Count -gt 0) {
        Write-BootstrapLog "Fetched $(@($toolInfo.dependencies).Count) dependency file(s) into $toolCacheDir"
    }

    Write-Host ""
    Write-Host ("Starting {0}..." -f $toolInfo.name) -ForegroundColor Cyan
    Write-Host ("Source: {0}" -f $toolUri) -ForegroundColor DarkGray
    Write-Host ""

    $toolArgs = @{}
    if ($toolInfo.id -eq "pcdiag") {
        $toolArgs.OutputRoot = $OutputRoot
        $toolArgs.DaysBack = $DaysBack
        $toolArgs.MaxEvents = $MaxEvents
        $toolArgs.EventTimeoutSeconds = $EventTimeoutSeconds
        $toolArgs.StepTimeoutSeconds = $StepTimeoutSeconds
        if ($PrivacyMode) {
            $toolArgs.PrivacyMode = $true
        }
        if ($AutoInstallDebugTools) {
            $toolArgs.AutoInstallDebugTools = $true
        }
    } elseif ($toolInfo.id -eq "netdiag") {
        $toolArgs.OutputPath = $OutputPath
        $toolArgs.LocalTargets = $LocalTargets
        $toolArgs.TcpTargets = $TcpTargets
        $toolArgs.DnsTestNames = $DnsTestNames
        $toolArgs.LanSpeedTarget = $LanSpeedTarget
        $toolArgs.SmbTestPath = $SmbTestPath
        $toolArgs.SmbTestSizeMB = $SmbTestSizeMB
        $toolArgs.PingCount = $PingCount
        $toolArgs.EventHours = $EventHours
        if ($IncludeEventLogs) {
            $toolArgs.IncludeEventLogs = $true
        }
        if ($IncludeRawData) {
            $toolArgs.IncludeRawData = $true
        }
        if ($IncludeTraceroute) {
            $toolArgs.IncludeTraceroute = $true
        }
        if ($IncludeMtuTest) {
            $toolArgs.IncludeMtuTest = $true
        }
        if ($IncludeSpeedtest) {
            $toolArgs.IncludeSpeedtest = $true
        }
        if ($IncludeSubnetDiscovery) {
            $toolArgs.IncludeSubnetDiscovery = $true
        }
        if ($NoInternetTest) {
            $toolArgs.NoInternetTest = $true
        }
        if ($NoWriteTests) {
            $toolArgs.NoWriteTests = $true
        }
        $toolArgs.OpenReport = $true
    } elseif ($toolInfo.id -eq "displaydiag") {
        $toolArgs.OutputRoot = Join-Path $OutputRoot "HDMIDiagnose"
        $toolArgs.Branch = $Branch
        if ($dependencyPaths.ContainsKey("HDMIDiagnostics.Core.psm1")) {
            $toolArgs.ModulePath = $dependencyPaths["HDMIDiagnostics.Core.psm1"]
        }
    } elseif ($toolInfo.id -eq "hardwarestability") {
        $toolArgs.OutputRoot = $OutputRoot
        $toolArgs.Profile = $Profile
        $toolArgs.Components = $Components
        $toolArgs.SurfaceScanMaxBytes = $SurfaceScanMaxBytes
        if ($NoDownload) { $toolArgs.NoDownload = $true }
        if ($SkipTelemetry) { $toolArgs.SkipTelemetry = $true }
        if ($HsDryRun) { $toolArgs.DryRun = $true }
        $toolArgs.ModuleRootOverride = Join-Path $toolCacheDir "lib\HardwareStability"
        $toolArgs.ConfigPathOverride = Join-Path $toolCacheDir "config\HardwareStabilityTools.json"
    }

    Write-BootstrapLog "Launching $($toolInfo.id) with args: $((@($toolArgs.Keys) | ForEach-Object { "$_=$($toolArgs[$_])" }) -join ', ')"
    $toolScriptBlock = [scriptblock]::Create([string]$scriptText)
    & $toolScriptBlock @toolArgs
}

try {
    $manifest = Get-Manifest
    Write-BootstrapLog "Fetched manifest.json: $(@($manifest.tools).Count) tool(s)"

    if ($Tool -eq "list") {
        Show-ToolList -Manifest $manifest
        return
    }

    if ($Tool -eq "menu") {
        $Tool = Select-ToolFromMenu -Manifest $manifest
        Write-BootstrapLog "Menu selection: $Tool"
    }

    Invoke-RemoteTool -Manifest $manifest -SelectedTool $Tool
    Write-BootstrapLog "=== bootstrap.ps1 finished normally ==="
} catch {
    Write-BootstrapLog "UNHANDLED ERROR: $($_.Exception.GetType().FullName): $($_.Exception.Message)"
    Write-BootstrapLog ($_.ScriptStackTrace -join " | ")
    Write-Host ""
    Write-Host "PC-Diagnose failed to start: $($_.Exception.Message)" -ForegroundColor Red
    Write-Host "Details were written to: $BootstrapLogPath" -ForegroundColor Yellow
    throw
}
