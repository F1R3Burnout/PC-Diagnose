<#
.SYNOPSIS
    Remote starter for PC-Diagnose tools.

.DESCRIPTION
    Intended entry point:
        irm https://raw.githubusercontent.com/F1R3Burnout/PC-Diagnose/main/bootstrap.ps1 | iex

    Direct tool call:
        & ([scriptblock]::Create((irm https://raw.githubusercontent.com/F1R3Burnout/PC-Diagnose/main/bootstrap.ps1))) -Tool serverdiag
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
    [switch]$NoElevate
)

$ErrorActionPreference = "Stop"
$ProgressPreference = "SilentlyContinue"

$RepoOwner = "F1R3Burnout"
$RepoName = "PC-Diagnose"
$RawBase = "https://raw.githubusercontent.com/$RepoOwner/$RepoName/$Branch"
$BootstrapUrl = "$RawBase/b"
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

    return (Invoke-WebRequest -UseBasicParsing -Uri $Uri).Content
}

function Get-Manifest {
    $json = Get-RemoteText -Uri $ManifestUrl
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
        "& ([scriptblock]::Create((Invoke-RestMethod -UseBasicParsing -Uri $(Quote-ForSingleQuotedPowerShell $BootstrapUrl)))) " +
            "-Tool $(Quote-ForSingleQuotedPowerShell $SelectedTool) " +
            "-Branch $(Quote-ForSingleQuotedPowerShell $Branch) " +
            "-OutputRoot $(Quote-ForSingleQuotedPowerShell $OutputRoot) " +
            "-DaysBack $DaysBack " +
            "-MaxEvents $MaxEvents " +
            "-EventTimeoutSeconds $EventTimeoutSeconds " +
            "-StepTimeoutSeconds $StepTimeoutSeconds " +
            "$(if ($PrivacyMode) { '-PrivacyMode ' } else { '' })" +
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
    $selection = Read-Host "Nummer oder Tool-ID eingeben"

    if ([string]::IsNullOrWhiteSpace($selection)) {
        throw "Keine Auswahl getroffen."
    }

    $number = 0
    if ([int]::TryParse($selection, [ref]$number)) {
        if ($number -lt 1 -or $number -gt $Manifest.tools.Count) {
            throw "Ungueltige Auswahl: $selection"
        }

        return [string]$Manifest.tools[$number - 1].id
    }

    return [string]$selection
}

function Invoke-RemoteTool {
    param(
        [Parameter(Mandatory=$true)]$Manifest,
        [Parameter(Mandatory=$true)][string]$SelectedTool
    )

    $toolInfo = @($Manifest.tools | Where-Object { $_.id -eq $SelectedTool -or $_.name -eq $SelectedTool }) | Select-Object -First 1
    if (-not $toolInfo) {
        throw "Tool nicht gefunden: $SelectedTool"
    }

    if ($toolInfo.requiresAdmin -and -not (Test-IsAdmin)) {
        if ($NoElevate) {
            throw "Dieses Tool benoetigt Administratorrechte: $($toolInfo.name)"
        }

        Write-Host ""
        Write-Host "$($toolInfo.name) benoetigt Administratorrechte. UAC wird geoeffnet..." -ForegroundColor Yellow
        Start-ElevatedBootstrap -SelectedTool ([string]$toolInfo.id)
        return
    }

    $toolUri = "$RawBase/$($toolInfo.path)"
    $cacheRoot = Join-Path $env:TEMP "PC-Diagnose"
    $toolCacheDir = Join-Path $cacheRoot ([string]$toolInfo.id)
    New-Item -ItemType Directory -Force -Path $toolCacheDir | Out-Null

    $scriptPath = Join-Path $toolCacheDir (Split-Path -Path ([string]$toolInfo.path) -Leaf)
    $scriptText = Get-RemoteText -Uri $toolUri
    [IO.File]::WriteAllText($scriptPath, [string]$scriptText, [Text.UTF8Encoding]::new($true))

    Write-Host ""
    Write-Host ("Starte {0}..." -f $toolInfo.name) -ForegroundColor Cyan
    Write-Host ("Quelle: {0}" -f $toolUri) -ForegroundColor DarkGray
    Write-Host ""

    $toolArgs = @{}
    if ($toolInfo.id -eq "serverdiag") {
        $toolArgs.OutputRoot = $OutputRoot
        $toolArgs.DaysBack = $DaysBack
        $toolArgs.MaxEvents = $MaxEvents
        $toolArgs.EventTimeoutSeconds = $EventTimeoutSeconds
        $toolArgs.StepTimeoutSeconds = $StepTimeoutSeconds
        if ($PrivacyMode) {
            $toolArgs.PrivacyMode = $true
        }
    }

    & $scriptPath @toolArgs
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
