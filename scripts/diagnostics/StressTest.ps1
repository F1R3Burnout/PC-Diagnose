<#
.SYNOPSIS
    Klassischer Stresstest: Prime95 + FurMark unter Volllast - wie
    "A Stresstest.bat", aber mit automatischem Download, Temperaturanzeige
    in der Konsole (statt HWMonitor), Temperaturschutz und Ergebnisdatei.

.DESCRIPTION
    Varianten: CPU + GPU gleichzeitig (Prime95 + FurMark), nur CPU
    (Prime95, alle Threads) oder nur GPU (FurMark). Dauer waehlbar.

    Prime95 prueft seine Rechenergebnisse selbst (Rundungs-/Summenfehler =
    FAIL). FurMark erzeugt nur Last und Waerme und prueft nichts nach: ein
    GPU-"PASS" heisst hier "lief die volle Zeit ohne Absturz, Treiber-Reset
    oder Ueberhitzung". Fuer eine verifizierende GPU-/VRAM-Pruefung gibt es
    den Hardware-Stabilitaetstest.

    Alle Werkzeuge kommen von der offiziellen Quelle und werden vor dem
    Start geprueft (SHA256 aus dem winget-Manifest,
    config/HardwareStabilityTools.json). Es wird nichts installiert ausser,
    falls noetig, der Microsoft Visual C++ Laufzeit (fuer FurMark) und - nach
    Rueckfrage - dem PawnIO-Treiber (fuer die CPU-Temperatur).

.PARAMETER Mode
    Both (CPU + GPU), CPU oder GPU. Leer = Auswahl beim Start.

.PARAMETER Minutes
    Dauer in Minuten. 0 = Auswahl beim Start (ohne Rueckfrage: 30).

.PARAMETER NoPrompt
    Nichts fragen: ohne -Mode CPU + GPU, ohne -Minutes 30 Minuten.
#>

[CmdletBinding()]
param(
    # No [ValidateSet] with an empty default (breaks when the param block is
    # run as code); validated below instead.
    [string]$Mode = "",
    [double]$Minutes = 0,
    [string]$OutputRoot = "C:\Temp",
    [switch]$NoPrompt,
    [switch]$NoDownload,
    [switch]$SkipTelemetry,
    [switch]$InstallPawnIO,
    [switch]$NoDriverInstall,
    [int]$FurMarkWidth = 1280,
    [int]$FurMarkHeight = 720,
    [string]$ToolCacheRoot = "",
    [string]$ModuleRootOverride = "",
    [string]$ConfigPathOverride = ""
)

$ErrorActionPreference = "Stop"
if ($Mode -and $Mode -notin @("Both", "CPU", "GPU")) {
    throw "Unbekannter Modus '$Mode'. Erlaubt: Both (CPU + GPU), CPU, GPU - oder leer lassen fuer die Auswahl beim Start."
}

$script:StressCrashLogPath = Join-Path $env:TEMP "PC-Diagnose\stresstest-crash.log"
New-Item -ItemType Directory -Force -Path (Split-Path $script:StressCrashLogPath -Parent) -ErrorAction SilentlyContinue | Out-Null

trap {
    $errorText = "[{0}] UNHANDLED ERROR: {1}: {2}`n{3}" -f (Get-Date -Format "yyyy-MM-dd HH:mm:ss"), $_.Exception.GetType().FullName, $_.Exception.Message, ($_.ScriptStackTrace -join " | ")
    Write-Host ""
    Write-Host $errorText -ForegroundColor Red
    try { $errorText | Out-File -FilePath $script:StressCrashLogPath -Encoding UTF8 -Append } catch {}
    try { Stop-HsAllTrackedProcesses -Reason "Stresstest error" } catch {}
    Write-Host "Crash log: $script:StressCrashLogPath" -ForegroundColor Yellow
    break
}

# ---------------------------------------------------------------------------
# Modules and basic setup
# ---------------------------------------------------------------------------

$ModuleRoot = if ($ModuleRootOverride) { $ModuleRootOverride } else { Join-Path (Split-Path $PSScriptRoot -Parent | Split-Path -Parent) "lib\HardwareStability" }
$ConfigPath = if ($ConfigPathOverride) { $ConfigPathOverride } else { Join-Path (Split-Path $PSScriptRoot -Parent | Split-Path -Parent) "config\HardwareStabilityTools.json" }

foreach ($module in @(
    "Common.psm1","ProcessRunner.psm1","ToolManager.psm1","Profiles.psm1","Inventory.psm1","Telemetry.psm1",
    "ThermalGuard.psm1","EventCorrelation.psm1","CpuTests.psm1","GpuTests.psm1","StressTest.psm1"
)) {
    Import-Module (Join-Path $ModuleRoot $module) -Force
}

if (-not (Test-HsIsAdmin)) {
    Write-Host "FEHLER: Der Stresstest braucht Administratorrechte (Temperatursensoren, Treiber)." -ForegroundColor Red
    exit 1
}

# Shared with the Hardware-Stabilitaetstest: Prime95, LibreHardwareMonitor
# and PawnIO are downloaded only once.
if (-not $ToolCacheRoot) { $ToolCacheRoot = Join-Path $env:TEMP "PC-Diagnose\HardwareStabilityTools" }
New-Item -ItemType Directory -Force -Path $ToolCacheRoot | Out-Null

# ---------------------------------------------------------------------------
# Choice: what and how long
# ---------------------------------------------------------------------------

if (-not $Mode) {
    if (-not (Test-HsInteractiveConsole -NoPrompt:$NoPrompt)) {
        $Mode = "Both"
    } else {
        Write-Host ""
        Write-Host "Stresstest (Prime95 + FurMark) - was soll belastet werden?" -ForegroundColor Cyan
        Write-Host ""
        foreach ($choice in (Get-HsStressModeChoice)) {
            Write-Host ("  [{0}] {1}" -f $choice.Key, $choice.Label) -ForegroundColor White
        }
        Write-Host "  [0] Abbrechen" -ForegroundColor White
        Write-Host ""
        $answer = Read-HsChoice -Prompt "Auswahl [1-3, Enter = 1]" -Allowed @("0","1","2","3") -Default "1"
        if ($answer -eq "0") { Write-Host "Abgebrochen - es wurde kein Test gestartet." -ForegroundColor Yellow; exit 0 }
        $Mode = [string](@(Get-HsStressModeChoice | Where-Object { $_.Key -eq $answer })[0].Mode)
    }
}

if ($Minutes -le 0) {
    if (-not (Test-HsInteractiveConsole -NoPrompt:$NoPrompt)) {
        $Minutes = 30
    } else {
        $Minutes = Read-HsDurationMinutes -Title "Wie lange?" -Choices @(15, 30, 60) -DefaultIndex 2 -MaxMinutes 1440
    }
}

$modeLabel = switch ($Mode) { "Both" { "CPU + GPU" } "CPU" { "nur CPU" } "GPU" { "nur GPU" } }
$runCpu = $Mode -in @("Both","CPU")
$runGpu = $Mode -in @("Both","GPU")
$plannedSeconds = [double]$Minutes * 60

$Timestamp = Get-Date -Format "yyyyMMdd_HHmmss"
$Out = Join-Path $OutputRoot ("PCStress_{0}_{1}" -f (ConvertTo-HsSafeFileName $env:COMPUTERNAME), $Timestamp)
New-Item -ItemType Directory -Force -Path $Out | Out-Null
$RuntimeLog = Join-Path $Out "runtime.log"

function Write-Progress2 {
    param([string]$Text, [string]$Color = "Gray")
    Write-HsLog -Path $RuntimeLog -Text $Text -Color $Color
}

Write-Progress2 "Stresstest ($modeLabel, $Minutes Min.) - Ergebnisordner: $Out" "Cyan"

# Same inventory as the Hardware-Stabilitaetstest.
$inventory = Get-HsHardwareInventory
try { $inventory | ConvertTo-Json -Depth 6 | Out-File (Join-Path $Out "Inventory.json") -Encoding UTF8 } catch {}
$cpus = @($inventory.Cpus)
$cpuInfo = [pscustomobject]@{
    Name              = (@($cpus | ForEach-Object { ([string]$_.Name).Trim() }) | Select-Object -Unique) -join ", "
    Cores             = [math]::Max(1, [int](@($cpus | ForEach-Object { [int]($_.Cores -as [int]) }) | Measure-Object -Sum).Sum)
    LogicalProcessors = [math]::Max(1, [int](@($cpus | ForEach-Object { [int]($_.LogicalProcessors -as [int]) }) | Measure-Object -Sum).Sum)
}
$gpuNames = (@($inventory.Gpus | ForEach-Object { ([string]$_.Name).Trim() }) | Select-Object -Unique) -join ", "
Write-Progress2 "CPU: $($cpuInfo.Name) ($($cpuInfo.Cores) Kerne / $($cpuInfo.LogicalProcessors) Threads); GPU: $gpuNames" "Gray"

# ---------------------------------------------------------------------------
# Temperatures (LibreHardwareMonitor) and the thermal guard
# ---------------------------------------------------------------------------

$telemetryStatus = $null
if (-not $SkipTelemetry -and -not $NoDriverInstall) {
    Request-HsPawnIoInstall -ConfigPath $ConfigPath -ToolCacheRoot $ToolCacheRoot -NoDownload:$NoDownload `
        -Force:$InstallPawnIO -NoPrompt:$NoPrompt -LogPath $RuntimeLog | Out-Null
}
if (-not $SkipTelemetry) {
    Write-Progress2 "Temperatursensoren werden vorbereitet (LibreHardwareMonitor) ..." "Cyan"
    $telemetryOk = Initialize-HsTelemetry -ConfigPath $ConfigPath -ToolCacheRoot $ToolCacheRoot -NoDownload:$NoDownload
    $telemetryStatus = Get-HsTelemetryStatus
    if (-not $telemetryOk) { Write-Progress2 "Keine Temperatursensoren verfuegbar - der Temperaturschutz ist in diesem Lauf aus." "Yellow" }
    elseif ($null -ne $telemetryStatus -and -not $telemetryStatus.CpuTemperatureAvailable) { Write-Progress2 "CPU-Temperatur nicht verfuegbar (PawnIO fehlt?) - der Temperaturschutz sieht nur die GPU." "Yellow" }
}

$thermalDefaults = Get-HsThermalDefaults
$script:StressPeaks = @{}
$script:StressThermalAbort = ""
$script:StressWarningLast = @{ Reason = ""; At = [datetime]::MinValue }
$script:StressTelemetryState = @{}
$script:StressDisplay = @{ At = [datetime]::MinValue; Line = "" }
$telemetryCsv = Join-Path $Out "Telemetry.csv"

function Get-StressSample {
    if ($SkipTelemetry) { return ,@() }
    $rows = Get-HsTelemetrySample -Stage "STRESS"
    Update-HsTemperaturePeaks -Peaks $script:StressPeaks -Rows $rows
    Save-HsTelemetryRows -Rows $rows -Path $telemetryCsv -State $script:StressTelemetryState
    return ,$rows
}

function Test-StressAbort {
    <# Thermal guard: true stops the whole test. #>
    if ($SkipTelemetry) { return $false }
    $rows = Get-StressSample
    $state = Invoke-HsThermalGuard -Rows $rows -Thresholds $thermalDefaults -State $script:StressWarningLast -LogPath $RuntimeLog
    if ($state.State -eq "ABORT") {
        $script:StressThermalAbort = $state.Reason
        return $true
    }
    return $false
}

function Get-StressTemperatureLine {
    $now = Get-Date
    if (($now - $script:StressDisplay.At).TotalSeconds -lt 3) { return $script:StressDisplay.Line }
    $script:StressDisplay.At = $now
    $rows = Get-HsTelemetrySample -Stage "DISPLAY"
    Update-HsTemperaturePeaks -Peaks $script:StressPeaks -Rows $rows
    $pawnIoMissing = ($null -ne $telemetryStatus -and -not $telemetryStatus.PawnIoInstalled)
    # The maxima so far, as HWMonitor's "Max" column used to show them.
    $maxParts = @()
    foreach ($pair in @(@("Cpu","CPU"), @("Gpu","GPU"), @("GpuHotspot","Hotspot"))) {
        if ($script:StressPeaks.ContainsKey($pair[0]) -and $null -ne $script:StressPeaks[$pair[0]]) { $maxParts += "$($pair[1]) $([math]::Round([double]$script:StressPeaks[$pair[0]]))" }
    }
    $maxText = if ($maxParts.Count -gt 0) { "Max $($maxParts -join ', ')$([char]0x00B0)C" } else { "" }
    $script:StressDisplay.Line = Format-HsTemperatureLine -Rows $rows -PawnIoMissing:$pawnIoMissing -Extra $maxText
    return $script:StressDisplay.Line
}

# ---------------------------------------------------------------------------
# Tools
# ---------------------------------------------------------------------------

$toolConfig = Get-HsToolConfig -ConfigPath $ConfigPath
$furMark = $null
$gpuResult = $null
if ($runGpu) {
    if (-not (Test-HsVcRuntimeInstalled)) {
        Write-Progress2 "FurMark braucht die Microsoft Visual C++ Laufzeit (x64) - sie fehlt und wird installiert ..." "Cyan"
        $vcInstall = Install-HsVcRedist -ConfigPath $ConfigPath -ToolCacheRoot $ToolCacheRoot -NoDownload:$NoDownload
        Write-Progress2 "Visual C++ Laufzeit: $($vcInstall.Message)" $(if ($vcInstall.Installed) { "Green" } else { "Yellow" })
    }
    Write-Progress2 "FurMark wird bereitgestellt ..." "Gray"
    $furMark = Resolve-HsTool -ToolId "furmark2" -ToolConfig $toolConfig -ToolCacheRoot $ToolCacheRoot -NoDownload:$NoDownload
    if (-not $furMark.Available) {
        Write-Progress2 "FurMark nicht verfuegbar: $($furMark.Reason)" "Yellow"
        $gpuResult = [pscustomobject]@{ Status = "BLOCKED"; Reason = "FurMark nicht verfuegbar: $($furMark.Reason)"; Seconds = 0; ExitCode = $null }
    }
}

# ---------------------------------------------------------------------------
# The run
# ---------------------------------------------------------------------------

$activity = "Stresstest ($modeLabel, $Minutes Min.)"
$global:HsRunPlanState = $null
$global:HsTemperatureProvider = if ($SkipTelemetry) { $null } else { { Get-StressTemperatureLine } }
$furMarkHandle = $null
$furMarkExitedAt = $null
$cpuResult = $null
$cancelled = $true
$runStart = Get-Date
$plannedEnd = $runStart.AddSeconds($plannedSeconds)

function Get-StressFurMarkStatusText {
    if (-not $furMarkHandle) { return "" }
    if ($furMarkHandle.Process.HasExited) {
        if (-not $script:FurMarkExitNoted) {
            $script:FurMarkExitNoted = $true
            Write-Progress2 "FurMark wurde vorzeitig beendet (Exit-Code $(try { $furMarkHandle.Process.ExitCode } catch { '?' }))." "Yellow"
        }
        return "FurMark BEENDET"
    }
    return "FurMark laeuft"
}
$script:FurMarkExitNoted = $false

try {
    Write-HsOverallProgress -Activity $activity -Stage "Start"

    if ($runGpu -and $furMark -and $furMark.Available) {
        # FurMark gets one extra minute: it must not stop before Prime95; the
        # script stops it at the end, and if the script dies FurMark still
        # ends by itself shortly after.
        $furMarkArgs = Get-HsFurMarkArguments -Seconds ([int][math]::Round($plannedSeconds) + 60) -Width $FurMarkWidth -Height $FurMarkHeight
        Write-Progress2 "FurMark startet: furmark.exe $($furMarkArgs -join ' ')" "Cyan"
        $furMarkHandle = Start-HsBackgroundProcess -FilePath $furMark.ExecutablePath -ArgumentList $furMarkArgs `
            -StdOutPath (Join-Path $Out "FurMark_output.txt") -Stage "STRESS_GPU" -WorkingDirectory (Split-Path $furMark.ExecutablePath -Parent)
        Start-Sleep -Seconds 3
    }

    if ($runCpu) {
        if ($furMarkHandle) { $global:HsParallelStatusProvider = { Get-StressFurMarkStatusText } }
        Write-Progress2 "Prime95 startet (Torture-Test, $($cpuInfo.LogicalProcessors) Worker)." "Cyan"
        $cpuResult = Invoke-HsCpuTortureTest -StageName "CPU_CACHE_IMC" -ConfigPath $ConfigPath -ToolCacheRoot $ToolCacheRoot `
            -OutputDirectory $Out -DurationMinutes $Minutes -LogicalProcessors $cpuInfo.LogicalProcessors -PhysicalCores $cpuInfo.Cores `
            -NoDownload:$NoDownload -TelemetrySample { param($s) Get-StressSample } -CancelCheck { Test-StressAbort } `
            -ProgressLabel "Prime95 (alle Threads)"
        Write-Progress2 "Prime95: $($cpuResult.Status) - $($cpuResult.Reason)" $(if ($cpuResult.Status -eq "PASS") { "Green" } elseif ($cpuResult.Status -eq "FAIL") { "Red" } else { "Yellow" })
    } elseif ($furMarkHandle) {
        $watch = [Diagnostics.Stopwatch]::StartNew()
        $lastCheck = -10.0
        while ($watch.Elapsed.TotalSeconds -lt $plannedSeconds) {
            Start-Sleep -Seconds 1
            $progress = Get-HsTimeProgress -ElapsedSeconds $watch.Elapsed.TotalSeconds -TotalSeconds $plannedSeconds
            Write-HsStageProgress -Activity "FurMark (GPU)" -Status $progress.Text -Percent $progress.Percent -SecondsRemaining $progress.Remaining
            if ($furMarkHandle.Process.HasExited) { break }
            if (($watch.Elapsed.TotalSeconds - $lastCheck) -ge 5) {
                $lastCheck = $watch.Elapsed.TotalSeconds
                if (Test-StressAbort) { break }
            }
        }
        Write-HsStageProgress -Activity "FurMark (GPU)" -Completed
    }
    $cancelled = $false
} finally {
    $global:HsParallelStatusProvider = $null
    if ($furMarkHandle) {
        if ($furMarkHandle.Process.HasExited) { try { $furMarkExitedAt = $furMarkHandle.Process.ExitTime } catch { $furMarkExitedAt = Get-Date } }
        $furMarkStop = Stop-HsBackgroundProcess -Handle $furMarkHandle -Reason "Stresstest end"
    }
    Stop-HsAllTrackedProcesses -Reason "Stresstest end"
    Write-HsOverallProgress -Activity $activity -Completed
    $global:HsTemperatureProvider = $null
}
$runEnd = Get-Date

# ---------------------------------------------------------------------------
# Result
# ---------------------------------------------------------------------------

if ($runGpu -and $furMarkHandle) {
    $ranSeconds = if ($furMarkExitedAt) { ([datetime]$furMarkExitedAt - $runStart).TotalSeconds } else { ($runEnd - $runStart).TotalSeconds }
    if ($furMarkExitedAt -and [datetime]$furMarkExitedAt -lt $plannedEnd.AddSeconds(-5) -and -not $script:StressThermalAbort) {
        $exitText = if ($null -ne $furMarkStop.ExitCode) { "Exit-Code $($furMarkStop.ExitCode)" } else { "ohne Exit-Code" }
        $gpuResult = [pscustomobject]@{ Status = "WARNING"; Seconds = $ranSeconds; ExitCode = $furMarkStop.ExitCode
            Reason = "FurMark hat sich nach $(Format-HsDuration $ranSeconds) von geplanten $(Format-HsDuration $plannedSeconds) selbst beendet ($exitText). Moegliche Ursachen: Absturz unter Last, Grafiktreiber, fehlendes OpenGL. Siehe FurMark_output.txt." }
    } elseif ($script:StressThermalAbort -or $cancelled) {
        $gpuResult = [pscustomobject]@{ Status = "INTERRUPTED"; Seconds = $ranSeconds; ExitCode = $null; Reason = "FurMark wurde nach $(Format-HsDuration $ranSeconds) gestoppt (Temperaturschutz oder Abbruch)." }
    } else {
        $gpuResult = [pscustomobject]@{ Status = "PASS"; Seconds = $ranSeconds; ExitCode = $null; Reason = "FurMark lief die vollen $(Format-HsDuration $plannedSeconds) ohne Absturz." }
    }
}

$driverResets = if ($runGpu) { @(Get-HsGpuDriverResetEvents -Since $runStart).Count } else { 0 }
$wheaEvents = 0
try { $wheaEvents = @(Get-HsEventsSafe -Filter @{ LogName = "System"; ProviderName = "Microsoft-Windows-WHEA-Logger"; StartTime = $runStart }).Count } catch {}

$verdict = Get-HsStressVerdict -Mode $Mode -CpuResult $cpuResult -GpuResult $gpuResult -DriverResets $driverResets -WheaEvents $wheaEvents `
    -ThermalAbortReason $script:StressThermalAbort -Cancelled $cancelled

$deg = "$([char]0x00B0)C"
function Format-StressPeak {
    param([string]$Key)
    if ($script:StressPeaks.ContainsKey($Key) -and $null -ne $script:StressPeaks[$Key]) { return "$([math]::Round([double]$script:StressPeaks[$Key]))$deg" }
    return "nicht gemessen"
}

$lines = New-Object System.Collections.ArrayList
[void]$lines.Add("Stresstest - $env:COMPUTERNAME")
[void]$lines.Add("==========================================")
[void]$lines.Add("Ergebnis:        $($verdict.Status)")
[void]$lines.Add("Variante:        $modeLabel")
[void]$lines.Add("Dauer:           geplant $(Format-HsDuration $plannedSeconds), gelaufen $(Format-HsDuration ($runEnd - $runStart).TotalSeconds)")
[void]$lines.Add("Zeitraum:        $($runStart.ToString('yyyy-MM-dd HH:mm:ss')) - $($runEnd.ToString('HH:mm:ss'))")
[void]$lines.Add("CPU:             $($cpuInfo.Name)")
[void]$lines.Add("GPU:             $gpuNames")
[void]$lines.Add("")
if ($runCpu) {
    $cpuLine = if ($cpuResult) { "$($cpuResult.Status) - $($cpuResult.Workers) Worker - $($cpuResult.Reason)" } else { "lief nicht" }
    [void]$lines.Add("Prime95:         $cpuLine")
}
if ($runGpu) {
    $gpuLine = if ($gpuResult) { "$($gpuResult.Status) - $($gpuResult.Reason)" } else { "lief nicht" }
    [void]$lines.Add("FurMark:         $gpuLine")
}
[void]$lines.Add("")
[void]$lines.Add("Hoechste Temperaturen (LibreHardwareMonitor):")
[void]$lines.Add("  CPU:           $(Format-StressPeak 'Cpu')")
[void]$lines.Add("  GPU:           $(Format-StressPeak 'Gpu')")
[void]$lines.Add("  GPU Hotspot:   $(Format-StressPeak 'GpuHotspot')")
[void]$lines.Add("  VRM:           $(Format-StressPeak 'Vrm')")
[void]$lines.Add("Grafiktreiber-Resets waehrend des Tests: $driverResets")
[void]$lines.Add("WHEA-Hardwarefehler waehrend des Tests:  $wheaEvents")
if ($verdict.Findings.Count -gt 0) {
    [void]$lines.Add("")
    [void]$lines.Add("Auffaellig:")
    foreach ($finding in $verdict.Findings) { [void]$lines.Add("  - $finding") }
}
[void]$lines.Add("")
[void]$lines.Add("Hinweis: FurMark erzeugt Last und Waerme, prueft aber keine Rechenergebnisse.")
[void]$lines.Add("Fuer eine verifizierende Pruefung von GPU, VRAM und RAM den Hardware-Stabilitaetstest verwenden.")
$summaryText = $lines -join [Environment]::NewLine
$summaryText | Out-File -FilePath (Join-Path $Out "00_Summary.txt") -Encoding UTF8
[pscustomobject]@{
    Status = $verdict.Status; Mode = $Mode; PlannedMinutes = $Minutes; Started = $runStart; Ended = $runEnd
    Cpu = $cpuResult; Gpu = $gpuResult; Peaks = $script:StressPeaks; DriverResets = $driverResets; WheaEvents = $wheaEvents
    ThermalAbort = $script:StressThermalAbort; Findings = $verdict.Findings
} | ConvertTo-Json -Depth 5 | Out-File -FilePath (Join-Path $Out "00_Result.json") -Encoding UTF8

if (-not $SkipTelemetry) { try { Close-HsTelemetry } catch {} }

Write-Host ""
$color = switch ($verdict.Status) { "PASS" { "Green" } "FAIL" { "Red" } default { "Yellow" } }
foreach ($line in $lines) { Write-Host $line -ForegroundColor $(if ($line -like "Ergebnis:*") { $color } else { "Gray" }) }
Write-Host ""
Write-Host "Ergebnisordner: $Out" -ForegroundColor Cyan
