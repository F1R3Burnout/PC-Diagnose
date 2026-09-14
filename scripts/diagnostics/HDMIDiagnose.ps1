<#
.SYNOPSIS
    Read-only HDMI and display diagnostics for Windows 11.

.DESCRIPTION
    Collects Windows display paths, GPU and driver details, EDID, display audio,
    bandwidth estimates, and relevant event logs. It can also monitor display
    state changes and compare saved snapshots. It does not modify display,
    driver, registry, or device settings.

.EXAMPLE
    .\HDMIDiagnose.ps1 -Full

.EXAMPLE
    .\HDMIDiagnose.ps1 -Monitor -MonitorSeconds 300

.EXAMPLE
    .\HDMIDiagnose.ps1 -Snapshot BeforeTest

.EXAMPLE
    .\HDMIDiagnose.ps1 -Snapshot AfterTest

.EXAMPLE
    .\HDMIDiagnose.ps1 -Compare BeforeTest,AfterTest
#>

[CmdletBinding()]
param(
    [ValidateSet("Menu","Full","Monitor","EDID","Events","Snapshot","Compare","BandwidthTest","OpenReport")]
    [string]$Mode = "Menu",
    [switch]$Full,
    [switch]$Monitor,
    [switch]$EDID,
    [switch]$Events,
    [string]$Snapshot = "",
    [string[]]$Compare = @(),
    [switch]$BandwidthTest,
    [switch]$OpenReport,
    [Alias("?")][switch]$Help,
    [string]$OutputRoot = (Join-Path $env:SystemDrive "Temp\HDMIDiagnose"),
    [int]$MonitorSeconds = 0,
    [ValidateRange(500,10000)][int]$PollMilliseconds = 1000,
    [int]$EventDays = 7,
    [switch]$NoOpen,
    [string]$ModulePath = "",
    [string]$Branch = "main"
)

$ErrorActionPreference = "Stop"
$ProgressPreference = "SilentlyContinue"

function Resolve-HdmiModulePath {
    if ($ModulePath -and (Test-Path -LiteralPath $ModulePath)) { return (Resolve-Path -LiteralPath $ModulePath).Path }
    $candidates = @()
    if (-not [string]::IsNullOrWhiteSpace([string]$PSScriptRoot)) {
        $candidates += Join-Path $PSScriptRoot "HDMIDiagnostics.Core.psm1"
        $candidates += Join-Path $PSScriptRoot "..\..\lib\HDMIDiagnostics.Core.psm1"
    }
    foreach ($candidate in $candidates) {
        if (Test-Path -LiteralPath $candidate) { return (Resolve-Path -LiteralPath $candidate).Path }
    }

    $cacheRoot = Join-Path $env:TEMP "PC-Diagnose\displaydiag"
    New-Item -ItemType Directory -Force -Path $cacheRoot | Out-Null
    $escapedBranch = [Uri]::EscapeDataString($Branch)
    $rawBase = "https://raw.githubusercontent.com/F1R3Burnout/PC-Diagnose/$escapedBranch"
    foreach ($dependency in @("HDMIDiagnostics.Core.psm1","HDMIDiagnostics.Native.cs")) {
        $repositoryPath = if ($dependency -like "*.psm1") { "lib/HDMIDiagnostics.Core.psm1" } else { "lib/HDMIDiagnostics.Native.cs" }
        $destination = Join-Path $cacheRoot $dependency
        $content = (Invoke-WebRequest -UseBasicParsing -Uri "$rawBase/$repositoryPath").Content
        [IO.File]::WriteAllText($destination, ([string]$content).TrimStart([char]0xFEFF), [Text.UTF8Encoding]::new($true))
        try { Unblock-File -LiteralPath $destination -ErrorAction SilentlyContinue } catch {}
    }
    $downloadedModule = Join-Path $cacheRoot "HDMIDiagnostics.Core.psm1"
    if (Test-Path -LiteralPath $downloadedModule) { return $downloadedModule }
    throw "HDMIDiagnostics.Core.psm1 konnte weder lokal gefunden noch geladen werden."
}

function Show-HdmiHelp {
    @"
HDMI-/Display-Diagnose (read-only)

  -Full                         Vollständigen HTML/TXT/JSON-Bericht erzeugen
  -Monitor                      Display- und Audioänderungen live protokollieren
  -EDID                         EDID anzeigen und Rohdaten speichern
  -Events                       Relevante Ereignisprotokolle analysieren
  -Snapshot <Name>              Zustandsaufnahme speichern
  -Compare <Vorher>,<Nachher>   Zwei Zustandsaufnahmen vergleichen
  -BandwidthTest                Geführten Bandbreitentest starten
  -OpenReport                   Letzten HTML-Bericht öffnen

Optionen:
  -OutputRoot <Pfad>            Standard: %SystemDrive%\Temp\HDMIDiagnose
  -MonitorSeconds <Sekunden>    0 bedeutet bis Q gedrückt wird
  -PollMilliseconds <Millisek.> 500 bis 10000, Standard 1000
  -EventDays <Tage>             Standard 7
  -NoOpen                       HTML-Bericht nicht automatisch öffnen

Das Tool misst keine physikalische HDMI-Signalqualität, Bitfehlerrate,
Kabeldämpfung oder Augenmuster und behauptet keine HDMI-Version allein aus EDID.
"@
}

function Select-HdmiAction {
    Write-Host ""
    Write-Host "HDMI-/Display-Diagnose" -ForegroundColor Cyan
    Write-Host "========================" -ForegroundColor Cyan
    Write-Host "[1] Vollständige Diagnose erstellen"
    Write-Host "[2] Live-HDMI-/Display-Monitor starten"
    Write-Host "[3] EDID anzeigen"
    Write-Host "[4] Eventlogs analysieren"
    Write-Host "[5] Snapshot erstellen"
    Write-Host "[6] Snapshots vergleichen"
    Write-Host "[7] Bandbreiten-Testassistent"
    Write-Host "[8] Letzten Diagnosebericht öffnen"
    Write-Host "[9] Beenden"
    Write-Host ""
    $selection = Read-Host "Auswahl"
    switch ($selection) {
        "1" { return "Full" }
        "2" { return "Monitor" }
        "3" { return "EDID" }
        "4" { return "Events" }
        "5" { return "Snapshot" }
        "6" { return "Compare" }
        "7" { return "BandwidthTest" }
        "8" { return "OpenReport" }
        "9" { return "Exit" }
        default { throw "Ungültige Auswahl: $selection" }
    }
}

Import-Module (Resolve-HdmiModulePath) -Force
New-Item -ItemType Directory -Force -Path $OutputRoot | Out-Null

if ($Help) {
    Show-HdmiHelp
    return
}

if ($Full) { $Mode = "Full" }
elseif ($Monitor) { $Mode = "Monitor" }
elseif ($EDID) { $Mode = "EDID" }
elseif ($Events) { $Mode = "Events" }
elseif ($Snapshot) { $Mode = "Snapshot" }
elseif ($Compare.Count -gt 0) { $Mode = "Compare" }
elseif ($BandwidthTest) { $Mode = "BandwidthTest" }
elseif ($OpenReport) { $Mode = "OpenReport" }

if ($Mode -eq "Menu") { $Mode = Select-HdmiAction }
if ($Mode -eq "Exit") { return }

switch ($Mode) {
    "Full" {
        Invoke-HdmiFullDiagnostic -OutputRoot $OutputRoot -NoOpen:$NoOpen | Out-Null
    }
    "Monitor" {
        Start-HdmiLiveMonitor -OutputRoot $OutputRoot -MonitorSeconds $MonitorSeconds -PollMilliseconds $PollMilliseconds | Out-Null
    }
    "EDID" {
        Show-HdmiEdid -OutputRoot $OutputRoot | Out-Null
    }
    "Events" {
        Show-HdmiEvents -OutputRoot $OutputRoot -Days $EventDays | Out-Null
    }
    "Snapshot" {
        $name = $Snapshot
        if (-not $name) { $name = Read-Host "Name des Snapshots" }
        if (-not $name) { throw "Ein Snapshot-Name ist erforderlich." }
        Save-HdmiSnapshot -Name $name -OutputRoot $OutputRoot | Out-Null
    }
    "Compare" {
        $names = @($Compare)
        if ($names.Count -eq 1 -and $names[0] -match ',') { $names = @($names[0] -split ',') }
        if ($names.Count -lt 2) {
            $names = @((Read-Host "Name/Pfad des Vorher-Snapshots"),(Read-Host "Name/Pfad des Nachher-Snapshots"))
        }
        Compare-HdmiSnapshots -BeforeName $names[0] -AfterName $names[1] -OutputRoot $OutputRoot -NoOpen:$NoOpen | Out-Null
    }
    "BandwidthTest" {
        Start-HdmiBandwidthAssistant -OutputRoot $OutputRoot | Out-Null
    }
    "OpenReport" {
        $path = Open-HdmiLatestReport -OutputRoot $OutputRoot
        Write-Host "Geöffnet: $path" -ForegroundColor Green
    }
}
