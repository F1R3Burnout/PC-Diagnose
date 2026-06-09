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
    [int]$DaysBack = 30,
    [int]$MaxEvents = 2000,
    [int]$EventTimeoutSeconds = 180,
    [int]$StepTimeoutSeconds = 90,
    [switch]$PrivacyMode,
    [switch]$AutoInstallDebugTools,
    [switch]$DaysBackProvided,
    [switch]$NoElevate
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

    $encoded = [Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes($command))
    Start-Process -FilePath "powershell.exe" -ArgumentList "-NoExit -NoProfile -ExecutionPolicy Bypass -EncodedCommand $encoded" -Verb RunAs | Out-Null
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
        [int]$DefaultDays = 30
    )

    if ($ToolId -ne "pcdiag" -or $DaysBackWasProvided) {
        return $DaysBack
    }

    Write-Host ""
    $inputValue = Read-Host "How many days back should be analyzed? [$DefaultDays]"
    if ([string]::IsNullOrWhiteSpace($inputValue)) {
        return $DefaultDays
    }

    $parsed = 0
    if (-not [int]::TryParse($inputValue, [ref]$parsed) -or $parsed -lt 1 -or $parsed -gt 3650) {
        throw "Invalid DaysBack value: $inputValue. Enter a number between 1 and 3650."
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
        throw "Tool not found: $SelectedTool"
    }

    if ($toolInfo.id -eq "pcdiag") {
        $script:DaysBack = Read-DaysBackForTool -ToolId ([string]$toolInfo.id) -DefaultDays 30
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
    try {
        Unblock-File -LiteralPath $scriptPath -ErrorAction SilentlyContinue
    } catch {}

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
    } elseif ($toolInfo.id -eq "hwcleanup") {
        $toolArgs.OutputRoot = $OutputRoot
    }

    $toolScriptBlock = [scriptblock]::Create([string]$scriptText)
    & $toolScriptBlock @toolArgs
}

$manifest = Get-Manifest

if ($Tool -eq "list") {
    Show-ToolList -Manifest $manifest
    return
}

if ($Tool -eq "menu") {
    $Tool = Select-ToolFromMenu -Manifest $manifest
}

Invoke-RemoteTool -Manifest $manifest -SelectedTool $Tool
