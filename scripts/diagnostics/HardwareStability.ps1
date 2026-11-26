<#
.SYNOPSIS
    Hardware-Stabilitaetstest: verification-first hardware stability testing
    for PC-Diagnose.

.DESCRIPTION
    Unlike a classic stress test, this tool checks hardware stability mainly
    through VERIFIABLE tests: known data / known computation -> hardware
    processes it -> result read back -> compared against the expected
    result -> mismatches recorded. High load/temperature are permitted
    side effects of individual tests, not the test result itself.

    See docs/HARDWARE_STABILITY_SPEC.md for the full specification and
    docs/HARDWARE_STABILITY_STATE.md / ACCEPTANCE.md for implementation
    status.

.PARAMETER Profile
    Quick (Kurz), Standard (Mittel), or Extended (Lang). Controls pass counts,
    data volume, and coverage - not just runtime (spec section 9). When it is
    not given and the console is interactive, the tool asks for it.

.PARAMETER Components
    Comma-separated subset to run: CPU,Cache,RAM,GPU,VRAM,Storage,PCIe,System

.PARAMETER DryRun
    Shows the planned inventory, stages, tools, and commands without
    starting any active hardware load or verification process.

.PARAMETER NoDownload
    Never downloads a third-party tool; missing tools degrade their stage
    to SKIPPED/UNSUPPORTED instead of aborting the whole run.

.PARAMETER SkipTelemetry
    Disables LibreHardwareMonitor-based telemetry sampling.

.PARAMETER SurfaceScanMaxBytes
    Bounds the Storage Surface Read scan (0 = full drive).

.PARAMETER NoPrompt
    Never ask anything (profile, retest). Without -Profile, Quick is used.

.PARAMETER RetestComponents
    Non-interactive targeted retest after the main run, e.g. "Cache,RAM".
    Keys: CPU, Cache, RAM, GPU, VRAM, GPULoad, Storage, System.

.PARAMETER RetestMinutes
    Duration per component for -RetestComponents (default 10).

.PARAMETER InstallPawnIO
    Installs the PawnIO driver (CPU temperature) without asking if it is
    missing. Without it, an interactive run asks once at start.

.PARAMETER NoDriverInstall
    Never installs or offers the PawnIO driver.

.PARAMETER MaxStageMinutes
    Caps every time-bound stage (and switches RAM to a time-bound run) for
    quick smoke checks. Results then only cover that shortened range.
#>

[CmdletBinding()]
param(
    # No [ValidateSet] with an empty default (it breaks when the param block
    # is run as code, e.g. via Invoke-Expression); validated below instead.
    [string]$Profile = "",

    [string]$Components = "CPU,Cache,RAM,GPU,VRAM,Storage,PCIe,System",

    [string]$OutputRoot = "C:\Temp",

    [switch]$NoDownload,
    [switch]$SkipTelemetry,
    [switch]$Resume,
    [switch]$DryRun,
    [long]$SurfaceScanMaxBytes = 0,
    [switch]$NoPrompt,
    [string]$RetestComponents = "",
    [double]$RetestMinutes = 0,
    [double]$MaxStageMinutes = 0,
    [switch]$InstallPawnIO,
    [switch]$NoDriverInstall,

    [string]$ModuleRootOverride = "",
    [string]$ConfigPathOverride = ""
)

$ErrorActionPreference = "Stop"
if ($Profile -and $Profile -notin @("Quick", "Standard", "Extended")) {
    throw "Unknown profile '$Profile'. Use Quick (Kurz), Standard (Mittel), Extended (Lang), or omit it to choose at start."
}
$ToolName = "Hardware-Stabilitaetstest"
$ToolVersion = "1.0"

# Fallback crash log: written to whenever an error happens before the run's
# own output folder (99_Runtime\runtime.log) exists yet - e.g. a module
# failing to load, or an error while collecting the hardware inventory -
# and appended to (not overwritten) by the trap below for any later
# unhandled error too, so it always has the full picture in one place.
$script:HsCrashLogPath = Join-Path $env:TEMP "PC-Diagnose\hardwarestability-crash.log"
New-Item -ItemType Directory -Force -Path (Split-Path $script:HsCrashLogPath -Parent) -ErrorAction SilentlyContinue | Out-Null

trap {
    $errorText = "[{0}] UNHANDLED ERROR: {1}: {2}`n{3}" -f (Get-Date -Format "yyyy-MM-dd HH:mm:ss"), $_.Exception.GetType().FullName, $_.Exception.Message, ($_.ScriptStackTrace -join " | ")
    Write-Host ""
    Write-Host $errorText -ForegroundColor Red
    try { $errorText | Out-File -FilePath $script:HsCrashLogPath -Encoding UTF8 -Append } catch {}
    try {
        if (Get-Variable -Name RuntimeLog -Scope Script -ErrorAction SilentlyContinue) {
            $errorText | Out-File -FilePath $script:RuntimeLog -Encoding UTF8 -Append -ErrorAction SilentlyContinue
        }
    } catch {}
    Write-Host "Crash log: $script:HsCrashLogPath" -ForegroundColor Yellow
    if (Get-Variable -Name Out -Scope Script -ErrorAction SilentlyContinue) {
        Write-Host "Run folder (if created): $script:Out" -ForegroundColor Yellow
    }
    break
}

# ---------------------------------------------------------------------------
# Module loading
# ---------------------------------------------------------------------------

$ModuleRoot = if ($ModuleRootOverride) { $ModuleRootOverride } else { Join-Path (Split-Path $PSScriptRoot -Parent | Split-Path -Parent) "lib\HardwareStability" }
$ConfigPath = if ($ConfigPathOverride) { $ConfigPathOverride } else { Join-Path (Split-Path $PSScriptRoot -Parent | Split-Path -Parent) "config\HardwareStabilityTools.json" }

foreach ($module in @(
    "Common.psm1","ProcessRunner.psm1","ToolManager.psm1","Profiles.psm1",
    "Inventory.psm1","Telemetry.psm1","ThermalGuard.psm1","EventCorrelation.psm1",
    "CrashRecovery.psm1","CpuTests.psm1","MemoryTests.psm1","GpuTests.psm1",
    "StorageTests.psm1","StorageSurface.psm1","StorageWriteVerify.psm1","StorageBackground.psm1","Reporting.psm1"
)) {
    Import-Module (Join-Path $ModuleRoot $module) -Force
}

function Test-HsAdminRequired {
    if (-not (Test-HsIsAdmin)) {
        Write-Host "ERROR: Hardware-Stabilitaetstest requires Administrator rights (SMART, raw disk read, elevated event logs)." -ForegroundColor Red
        exit 1
    }
}

if (-not $DryRun) {
    Test-HsAdminRequired
}

$ToolCacheRoot = Join-Path $env:TEMP "PC-Diagnose\HardwareStabilityTools"
New-Item -ItemType Directory -Force -Path $ToolCacheRoot | Out-Null

$selectedComponents = @($Components -split "," | ForEach-Object { $_.Trim() } | Where-Object { $_ })

function Select-HsProfileInteractive {
    Write-Host ""
    Write-Host "Hardware-Stabilitaetstest - Dauer und Intensitaet waehlen" -ForegroundColor Cyan
    Write-Host ""
    foreach ($choice in (Get-HsProfileChoice)) {
        $choiceProfile = Get-HsProfile -Name $choice.Name
        $minutes = Get-HsProfileEstimateMinutes -ProfileConfig $choiceProfile -Components $selectedComponents
        Write-Host ("  [{0}] {1,-7} ca. {2} Min. Lastphasen + RAM/Datentraeger" -f $choice.Key, $choice.Label, [math]::Round($minutes)) -ForegroundColor White
        Write-Host ("      {0}" -f $choice.Summary) -ForegroundColor Gray
    }
    Write-Host "  [0] Abbrechen" -ForegroundColor White
    Write-Host ""
    Write-Host "  RAM-Test, Surface-Scan und SMART-Selbsttest dauern je nach RAM-Groesse und Datentraeger zusaetzlich." -ForegroundColor DarkGray
    $answer = Read-HsChoice -Prompt "Auswahl [1-3, Enter = 1]" -Allowed @("0","1","2","3") -Default "1"
    if ($answer -eq "0") { return "" }
    return [string](@(Get-HsProfileChoice | Where-Object { $_.Key -eq $answer })[0].Name)
}

if (-not $Profile) {
    if ($DryRun -or -not (Test-HsInteractiveConsole -NoPrompt:$NoPrompt)) {
        $Profile = "Quick"
    } else {
        $chosenProfile = Select-HsProfileInteractive
        if (-not $chosenProfile) {
            Write-Host "Abgebrochen - es wurde kein Test gestartet." -ForegroundColor Yellow
            exit 0
        }
        $Profile = $chosenProfile
    }
}

function Set-HsProfileCap {
    <# Applies -MaxStageMinutes to a profile copy (smoke checks only). #>
    param([Parameter(Mandatory=$true)]$ProfileConfig, [Parameter(Mandatory=$true)][double]$Minutes)
    $capped = Get-HsRetestProfile -BaseProfile $ProfileConfig -Minutes $Minutes
    $capped.Name = $ProfileConfig.Name
    $capped.SurfaceScanEnabled = $ProfileConfig.SurfaceScanEnabled
    $capped.StorageWriteVerifyMB = [math]::Min([int]$ProfileConfig.StorageWriteVerifyMB, 64)
    $capped.GpuComputeIterations = [int]$ProfileConfig.GpuComputeIterations
    return $capped
}

$profileConfig = Get-HsProfile -Name $Profile
if ($MaxStageMinutes -gt 0) { $profileConfig = Set-HsProfileCap -ProfileConfig $profileConfig -Minutes $MaxStageMinutes }
$profileLabel = "$Profile ($((Get-HsProfile -Name $Profile).DisplayName))"
$thermalDefaults = Get-HsThermalDefaults

$Timestamp = Get-Date -Format "yyyyMMdd_HHmmss"
$ComputerSafe = ConvertTo-HsSafeFileName $env:COMPUTERNAME
$RunId = "PCStability_${ComputerSafe}_${Timestamp}"
$Out = Join-Path $OutputRoot $RunId

$script:HsRunStartTime = Get-Date
$Dirs = @{
    Root      = $Out
    System    = Join-Path $Out "01_System"
    Telemetry = Join-Path $Out "02_Telemetry"
    Cpu       = Join-Path $Out "03_CPU"
    Ram       = Join-Path $Out "04_RAM"
    Gpu       = Join-Path $Out "05_GPU"
    Storage   = Join-Path $Out "06_Storage"
    Events    = Join-Path $Out "07_Events"
    Dumps     = Join-Path $Out "08_Dumps"
    Runtime   = Join-Path $Out "99_Runtime"
}

# DryRun must not create the result folder tree - it only shows what WOULD
# happen (spec section 39). Everything below only runs for a real test.
if (-not $DryRun) {
    foreach ($dir in $Dirs.Values) { New-Item -ItemType Directory -Force -Path $dir | Out-Null }
}

$RuntimeLog = Join-Path $Dirs.Runtime "runtime.log"
$script:HsCancelRequested = $false
$script:HsStages = New-Object System.Collections.ArrayList
# Storage checks running in the background (StorageBackground.psm1) and the
# SMART self-test started at the beginning of a component run.
$script:HsStorageBackground = $null
$script:HsStorageBackgroundError = ""
$script:HsSelfTestRun = $null

function Write-Progress2 {
    param([string]$Text, [string]$Color = "Gray")
    if ($DryRun) { Write-Host $Text -ForegroundColor $Color; return }
    Write-HsLog -Path $RuntimeLog -Text $Text -Color $Color
}

function Get-HsCancelState { return $script:HsCancelRequested }

# Ctrl+C handling (spec section 33): a script-level try/finally around the
# whole run stops and cleans up every tracked child process. This is the
# supported PowerShell pattern for reacting to Ctrl+C in a running script -
# see docs/HARDWARE_STABILITY_STATE.md for how this was validated.
$engineExitAction = Register-EngineEvent -SourceIdentifier ([System.Management.Automation.PsEngineEvent]::Exiting) -Action {
    Stop-HsAllTrackedProcesses -Reason "PowerShell exiting"
}

function Get-HsTelemetrySampleForStage {
    param([string]$StageName)
    # Get-HsTelemetrySample already guarantees a clean array via its own
    # leading-comma return (see Telemetry.psm1); do NOT wrap this call in
    # @(...) at any call site - @() around a call that already returns via
    # a leading comma double-nests the result (confirmed empirically while
    # tracking this down: it silently produces a 1-element array whose one
    # element is itself the real array, breaking property access on every
    # row). Plain pass-through here, and plain "$x = Get-HsTelemetrySampleForStage"
    # at every caller, is the only combination that stays correct.
    if ($SkipTelemetry) { return ,@() }
    $rows = Get-HsTelemetrySample -Stage $StageName
    Save-HsStageTelemetry -Rows $rows
    return ,$rows
}

$script:HsStageTelemetryState = @{}
$script:HsThermalAbortReason = ""
$script:HsThermalWarningLast = @{ Reason = ""; At = [datetime]::MinValue }

function Save-HsStageTelemetry {
    <#
        Keeps temperatures, loads and power of every stage in
        02_Telemetry\StageTelemetry.csv (at most every 5 s). Without it a
        thermal abort could not be checked afterwards - only the idle
        baseline was written before.
    #>
    param([AllowNull()][object[]]$Rows)
    if ($DryRun) { return }
    Save-HsTelemetryRows -Rows $Rows -Path (Join-Path $Dirs.Telemetry "StageTelemetry.csv") -State $script:HsStageTelemetryState
}

function Test-HsThermalAbortOrCancel {
    param([string]$StageName)
    if ($script:HsCancelRequested) { return $true }
    if ($SkipTelemetry) { return $false }
    $rows = Get-HsTelemetrySample -Stage $StageName
    Save-HsStageTelemetry -Rows $rows
    $state = Invoke-HsThermalGuard -Rows $rows -Thresholds $thermalDefaults -State $script:HsThermalWarningLast -LogPath $RuntimeLog
    if ($state.State -eq "ABORT") {
        $script:HsThermalAbortReason = $state.Reason
        return $true
    }
    return $false
}

# ---------------------------------------------------------------------------
# Inventory
# ---------------------------------------------------------------------------

Write-Progress2 "$ToolName $ToolVersion - profile $profileLabel" "Cyan"
Write-Progress2 "Output folder: $Out" "Gray"
Write-Progress2 "Components: $($selectedComponents -join ', ')" "Gray"
if (-not $DryRun) {
    Write-Progress2 "Log file for this run: $RuntimeLog" "Gray"
    Write-Progress2 "Crash log (only written on an unhandled error): $script:HsCrashLogPath" "Gray"
}

$inventory = Get-HsHardwareInventory
if (-not $DryRun) {
    $inventory | ConvertTo-Json -Depth 6 | Out-File (Join-Path $Dirs.System "Inventory.json") -Encoding UTF8
}

if ($DryRun) {
    Write-Host ""
    Write-Host "=== DRY RUN - no active hardware load will be started ===" -ForegroundColor Yellow
    Write-Host ""
    Write-Host "Hardware inventory:" -ForegroundColor Cyan
    Write-Host "  Computer: $($inventory.ComputerName)"
    Write-Host "  CPU: $((@($inventory.Cpus) | ForEach-Object { $_.Name }) -join ', ')"
    Write-Host "  RAM: $([math]::Round($inventory.PhysicalRamBytes/1GB,1)) GB"
    Write-Host "  GPU: $((@($inventory.Gpus) | ForEach-Object { $_.Name }) -join ', ')"
    Write-Host "  Storage: $((@($inventory.PhysicalDisks) | ForEach-Object { "$($_.DeviceId) ($($_.Model))" }) -join ', ')"
    Write-Host ""
    Write-Host "Profile '$profileLabel':" -ForegroundColor Cyan
    $profileConfig | Format-List | Out-String | Write-Host
    Write-Host "Available durations (without -Profile the real run asks):" -ForegroundColor Cyan
    foreach ($choice in (Get-HsProfileChoice)) {
        $estimate = Get-HsProfileEstimateMinutes -ProfileConfig (Get-HsProfile -Name $choice.Name) -Components $selectedComponents
        Write-Host ("  {0,-7} ({1,-8}) ca. {2} min load stages + RAM/storage - {3}" -f $choice.Label, $choice.Name, [math]::Round($estimate), $choice.Summary)
    }
    Write-Host "Planned components: $($selectedComponents -join ', ')" -ForegroundColor Cyan
    Write-Host "Planned tools (resolved without downloading):" -ForegroundColor Cyan
    $cfg = Get-HsToolConfig -ConfigPath $ConfigPath
    foreach ($toolId in $cfg.tools.PSObject.Properties.Name) {
        $t = Resolve-HsTool -ToolId $toolId -ToolConfig $cfg -ToolCacheRoot $ToolCacheRoot -NoDownload
        Write-Host ("  {0,-20} available={1,-6} ({2})" -f $toolId, $t.Available, $t.Reason)
    }
    Write-Host ""
    Write-Host "Planned output root: $Out"
    Write-Host "Planned physical drives for Storage Surface Read: $((@($inventory.PhysicalDisks) | ForEach-Object { $_.DeviceId }) -join ', ')"
    Write-Host ""
    Write-Host "DryRun complete - no stage was executed." -ForegroundColor Green
    exit 0
}

# ---------------------------------------------------------------------------
# Crash recovery: check for a pending run from before a reboot (spec 28/29)
# ---------------------------------------------------------------------------

$pending = Get-HsPendingRun
if ($pending -and [string]$pending.Status -eq "Running") {
    Write-Host ""
    Write-Host "A previous Hardware-Stabilitaetstest run appears to have been interrupted:" -ForegroundColor Yellow
    Write-Host "  Stage: $($pending.Stage)  Started: $($pending.StageStarted)  Result dir: $($pending.ResultDirectory)"
    $check = Test-HsSystemResetSinceRun -PendingRun $pending
    Write-Host "  Classification: $($check.Classification) - $($check.Notes)"
    Write-Host ""
    Write-Host "[1] Analyze the previous incident and continue with a new run"
    Write-Host "[2] Continue with a new run without further analysis"
    Write-Host "[3] Exit"
    $choice = if (Test-HsInteractiveConsole -NoPrompt:$NoPrompt) { Read-Host "Select" } else { "1" }
    if ($choice -eq "3") { exit 0 }
    if ($choice -eq "1") {
        $incidentPath = Join-Path $pending.ResultDirectory "PreviousIncident.json"
        try {
            [pscustomobject]@{ Pending = $pending; Check = $check } | ConvertTo-Json -Depth 6 |
                Out-File -FilePath $incidentPath -Encoding UTF8
            Write-Host "Incident details written to $incidentPath" -ForegroundColor Green
        } catch {}
    }
    Clear-HsPendingRun
}

# ---------------------------------------------------------------------------
# Telemetry
# ---------------------------------------------------------------------------

# PawnIO: the driver LibreHardwareMonitor needs for CPU temperature. It is a
# kernel driver, so it is only installed after the user agrees (or with
# -InstallPawnIO) - and before telemetry starts, which reads it only once.
$pawnIoInstallNote = ""
if (-not $SkipTelemetry -and -not $NoDriverInstall) {
    $pawnIoInstallNote = Request-HsPawnIoInstall -ConfigPath $ConfigPath -ToolCacheRoot $ToolCacheRoot -NoDownload:$NoDownload `
        -Force:$InstallPawnIO -NoPrompt:$NoPrompt -LogPath $RuntimeLog
}

if (-not $SkipTelemetry) {
    Write-Progress2 "Initializing telemetry (LibreHardwareMonitor)..." "Cyan"
    $telemetryOk = Initialize-HsTelemetry -ConfigPath $ConfigPath -ToolCacheRoot $ToolCacheRoot -NoDownload:$NoDownload -PawnIoInstallNote $pawnIoInstallNote
    Write-Progress2 "Telemetry available: $telemetryOk" "Gray"
    $telemetryStatus = Get-HsTelemetryStatus
    if ($null -ne $telemetryStatus) {
        Write-Progress2 ("Telemetry host: {0}, library build: {1}, CPU temperature: {2}, GPU temperature: {3}, PawnIO: {4}" -f `
            $telemetryStatus.HostEdition, $telemetryStatus.LibraryBuild, $telemetryStatus.CpuTemperatureAvailable, `
            $telemetryStatus.GpuTemperatureAvailable, $(if ($telemetryStatus.PawnIoInstalled) { $telemetryStatus.PawnIoVersion } else { "not installed" })) "Gray"
        foreach ($note in @($telemetryStatus.Notes)) { Write-Progress2 "Telemetry: $note" "Yellow" }
        try {
            $telemetryStatus | ConvertTo-Json -Depth 4 | Out-File (Join-Path $Dirs.Telemetry "TelemetryStatus.json") -Encoding UTF8
        } catch {}
    }
} else {
    $telemetryStatus = $null
    Write-Progress2 "Telemetry sampling disabled (-SkipTelemetry)." "Gray"
}

# Idle baseline (spec section 25)
$idleRows = Get-HsTelemetrySampleForStage -StageName "IDLE_BASELINE"
$idleRows | Export-Csv -Path (Join-Path $Dirs.Telemetry "IdleBaseline.csv") -NoTypeInformation -Encoding UTF8 -ErrorAction SilentlyContinue
$idleState = if ($idleRows.Count -gt 0) { Test-HsThermalState -Rows $idleRows -Thresholds $thermalDefaults } else { [pscustomobject]@{ State = "OK" } }
if ($idleState.State -eq "ABORT") {
    Write-Progress2 "Idle baseline already at a critical temperature ($($idleState.Reason)) - skipping active load stages." "Red"
}

function Invoke-HsStageWrapper {
    param(
        [Parameter(Mandatory=$true)][string]$StageName,
        [Parameter(Mandatory=$true)][string]$Component,
        [Parameter(Mandatory=$true)][scriptblock]$Action,
        [string]$Tool = ""
    )

    $stage = New-HsStage -StageName $StageName -Component $Component -Tool $Tool
    [void]$script:HsStages.Add($stage)
    Start-HsStage $stage
    Write-Progress2 "START: $Component" "Cyan"
    Write-HsOverallProgress -Activity $script:HsOverallActivity -Status $script:HsOverallStatus -Stage $Component
    Step-HsRunPlan -StageName $StageName

    if ($idleState.State -eq "ABORT") {
        Complete-HsStage $stage -Status "THERMAL_ABORT" -Assessment "Configured safety threshold was already reached before this stage's load began."
        return $stage
    }

    # The pending-run marker names the background storage checks too: if the
    # PC resets during a GPU stage, they were running at the same time.
    $pendingStage = if ($script:HsStorageBackground -and -not $script:HsStorageBackground.Closed) { "$StageName + STORAGE (parallel)" } else { $StageName }
    Set-HsPendingRun -RunId $RunId -ResultDirectory $Out -Profile $Profile -Stage $pendingStage `
        -ExpectedEnd ([datetime]::Now.AddMinutes(60)) -Status "Running" | Out-Null

    $script:HsThermalAbortReason = ""
    try {
        & $Action $stage
        if ($script:HsThermalAbortReason -and $stage.Status -eq "INTERRUPTED") {
            Complete-HsStage $stage -Status "THERMAL_ABORT" -Assessment "Stopped by the thermal guard: $($script:HsThermalAbortReason). The stage did not run for its planned time; this is a safety stop, not a verified hardware error."
        }
    } catch {
        Add-HsNote -Stage $stage -Note "Unhandled error: $($_.Exception.Message)"
        Complete-HsStage $stage -Status "BLOCKED" -Assessment "Stage could not complete due to an unexpected error: $($_.Exception.Message)"
    } finally {
        if ($stage.Status -eq "SKIPPED" -and $stage.Ended -eq $null) {
            Complete-HsStage $stage -Status "SKIPPED"
        }
    }

    Clear-HsPendingRun
    Write-Progress2 ("{0}: {1}" -f $Component, $stage.Status) $(if ($stage.Status -eq "PASS") { "Green" } elseif ($stage.Status -eq "FAIL") { "Red" } else { "Yellow" })
    return $stage
}

function New-HsStageDirs {
    param([Parameter(Mandatory=$true)][string]$Root)
    $stageDirs = @{
        Cpu     = Join-Path $Root "03_CPU"
        Ram     = Join-Path $Root "04_RAM"
        Gpu     = Join-Path $Root "05_GPU"
        Storage = Join-Path $Root "06_Storage"
    }
    foreach ($dir in $stageDirs.Values) { New-Item -ItemType Directory -Force -Path $dir | Out-Null }
    return $stageDirs
}

function Get-HsStagePlan {
    <#
    .SYNOPSIS
        Planned stages of a component list in execution order, with their
        planned seconds - the basis of "Gesamt noch ..." in the progress bar.
        Seconds = -1 marks a stage whose length depends on the hardware and
        cannot be known up front (RAM passes, full surface scan, extended
        SMART self-test); the total is then shown as a minimum.
    #>
    param([Parameter(Mandatory=$true)][string[]]$Keys, [Parameter(Mandatory=$true)]$StageProfile)

    $plan = New-Object System.Collections.ArrayList
    $diskCount = [math]::Max(1, @($inventory.PhysicalDisks).Count)
    foreach ($key in $Keys) {
        switch ($key) {
            "CPU"   { [void]$plan.Add([pscustomobject]@{ Stage = "CPU_COMPUTE"; Seconds = [double]$StageProfile.CpuComputeMinutes * 60; Unknown = "" }) }
            "Cache" { [void]$plan.Add([pscustomobject]@{ Stage = "CPU_CACHE_IMC"; Seconds = [double]$StageProfile.CpuCacheImcMinutes * 60; Unknown = "" }) }
            "RAM" {
                if ([double]$StageProfile.RamDurationMinutes -gt 0) {
                    [void]$plan.Add([pscustomobject]@{ Stage = "RAM"; Seconds = [double]$StageProfile.RamDurationMinutes * 60; Unknown = "" })
                } else {
                    [void]$plan.Add([pscustomobject]@{ Stage = "RAM"; Seconds = -1; Unknown = "RAM" })
                }
            }
            "GPU"   { [void]$plan.Add([pscustomobject]@{ Stage = "GPU_COMPUTE"; Seconds = 15; Unknown = "" }) }
            { $_ -in @("VRAM","VRAMMemory") } { [void]$plan.Add([pscustomobject]@{ Stage = "VRAM"; Seconds = [double]$StageProfile.VramTestMinutes * 60; Unknown = "" }) }
        }
        if ($key -in @("VRAM","GPULoad")) {
            [void]$plan.Add([pscustomobject]@{ Stage = "GPU_LOAD_THERMAL"; Seconds = [double]$StageProfile.GpuLoadMinutes * 60; Unknown = "" })
        }
        if ($key -eq "Storage") {
            for ($d = 0; $d -lt $diskCount; $d++) { [void]$plan.Add([pscustomobject]@{ Stage = "STORAGE_SMART"; Seconds = 10; Unknown = "" }) }
            if ($StageProfile.SmartSelfTest -eq "Short") {
                [void]$plan.Add([pscustomobject]@{ Stage = "STORAGE_SMART_SELFTEST"; Seconds = 150; Unknown = "" })
            } else {
                [void]$plan.Add([pscustomobject]@{ Stage = "STORAGE_SMART_SELFTEST"; Seconds = -1; Unknown = "SMART-Test" })
            }
            if (-not $StageProfile.SurfaceScanEnabled) {
                [void]$plan.Add([pscustomobject]@{ Stage = "STORAGE_SURFACE"; Seconds = 1; Unknown = "" })
            } elseif ([double]$StageProfile.SurfaceScanMaxMinutes -gt 0) {
                [void]$plan.Add([pscustomobject]@{ Stage = "STORAGE_SURFACE"; Seconds = [double]$StageProfile.SurfaceScanMaxMinutes * 60; Unknown = "" })
            } else {
                [void]$plan.Add([pscustomobject]@{ Stage = "STORAGE_SURFACE"; Seconds = -1; Unknown = "Surface-Scan" })
            }
            [void]$plan.Add([pscustomobject]@{ Stage = "STORAGE_WRITE_VERIFY"; Seconds = 5 + [double]$StageProfile.StorageWriteVerifyMB * 2 / 250; Unknown = "" })
        }
        if ($key -eq "PCIe") { [void]$plan.Add([pscustomobject]@{ Stage = "PCIE_WHEA"; Seconds = 5; Unknown = "" }) }
        if ($key -eq "System") { [void]$plan.Add([pscustomobject]@{ Stage = "SYSTEM_STABILITY"; Seconds = [double]$StageProfile.SystemStabilityMinutes * 60; Unknown = "" }) }
    }

    # Storage parts that already ran in the background are mostly done when
    # the Storage stages are reached: the SMART self-test runs from the start
    # of the run, surface scan and write/verify during the GPU stages. Only
    # what is left after that time is still to wait for.
    $storageAt = -1
    for ($i = 0; $i -lt $plan.Count; $i++) { if ($plan[$i].Stage -eq "STORAGE_SMART") { $storageAt = $i; break } }
    if ($storageAt -ge 0) {
        $before = 0.0
        $gpuBudget = 0.0
        for ($i = 0; $i -lt $storageAt; $i++) {
            if ($plan[$i].Seconds -gt 0) {
                $before += $plan[$i].Seconds
                if ($plan[$i].Stage -in @("GPU_COMPUTE","VRAM","GPU_LOAD_THERMAL")) { $gpuBudget += $plan[$i].Seconds }
            }
        }
        $surfaceUnknown = $false
        foreach ($entry in $plan) {
            switch ($entry.Stage) {
                "STORAGE_SMART_SELFTEST" {
                    if ($entry.Seconds -ge 0) { $entry.Seconds = [math]::Max(5, $entry.Seconds - $before) }
                }
                "STORAGE_SURFACE" {
                    if ($entry.Seconds -lt 0) { $surfaceUnknown = $true }
                    else {
                        $left = [math]::Max(0, $entry.Seconds - $gpuBudget)
                        $gpuBudget -= ($entry.Seconds - $left)
                        $entry.Seconds = $left
                    }
                }
                "STORAGE_WRITE_VERIFY" {
                    if (-not $surfaceUnknown) {
                        $left = [math]::Max(1, $entry.Seconds - $gpuBudget)
                        $gpuBudget = [math]::Max(0, $gpuBudget - $entry.Seconds)
                        $entry.Seconds = $left
                    }
                }
            }
        }
    }
    return ,$plan
}

function Step-HsRunPlan {
    <# Moves the plan pointer to the stage that is starting and publishes what is left after it. #>
    param([Parameter(Mandatory=$true)][string]$StageName)
    if ($null -eq $script:HsStagePlan) { return }
    for ($i = $script:HsStagePlanIndex + 1; $i -lt $script:HsStagePlan.Count; $i++) {
        if ($script:HsStagePlan[$i].Stage -eq $StageName) { $script:HsStagePlanIndex = $i; break }
    }
    $later = @()
    for ($i = $script:HsStagePlanIndex + 1; $i -lt $script:HsStagePlan.Count; $i++) { $later += $script:HsStagePlan[$i] }
    $knownSeconds = 0.0
    foreach ($entry in $later) { if ($entry.Seconds -ge 0) { $knownSeconds += $entry.Seconds } }
    $unknown = @($later | Where-Object { $_.Unknown } | ForEach-Object { $_.Unknown } | Select-Object -Unique)
    $global:HsRunPlanState = @{
        LaterKnownSeconds = $knownSeconds
        LaterUnknownText  = ($unknown -join "/")
    }
}

$script:HsTemperatureCache = @{ At = [datetime]::MinValue; Line = ""; DiskAt = [datetime]::MinValue; DiskText = "" }
$script:HsSmartctlPath = ""

function Get-HsDiskTemperatureText {
    <#
        Windows disk temperature via smartctl (LibreHardwareMonitor's storage
        group is deliberately disabled, see Telemetry.psm1). Read-only and
        polled at most every 30 s.
    #>
    if (-not $script:HsSmartctlPath) { return "" }
    $now = Get-Date
    if (($now - $script:HsTemperatureCache.DiskAt).TotalSeconds -lt 30) { return $script:HsTemperatureCache.DiskText }
    $script:HsTemperatureCache.DiskAt = $now
    $text = ""
    try {
        $disk = @($inventory.PhysicalDisks) | Select-Object -First 1
        if ($disk) {
            $index = [int]($disk.DeviceId -replace '[^0-9]','')
            $run = Invoke-HsProcess -FilePath $script:HsSmartctlPath -ArgumentList @("-A", "/dev/pd$index") -TimeoutSeconds 15
            $out = [string]$run.StdOut
            $value = $null
            $nvme = [regex]::Match($out, '(?im)^Temperature:\s+(\d+)\s+Celsius')
            $ata = [regex]::Match($out, '(?im)^\s*(?:194|190)\s+\S*Temp\S*\s+(?:\S+\s+){7}(\d+)')
            if ($nvme.Success) { $value = [int]$nvme.Groups[1].Value } elseif ($ata.Success) { $value = [int]$ata.Groups[1].Value }
            if ($null -ne $value -and $value -gt 0) { $text = "Platte $value$([char]0x00B0)C" }
        }
    } catch {}
    $script:HsTemperatureCache.DiskText = $text
    return $text
}

function Get-HsTemperatureLine {
    <#
        One line with the current temperatures for the progress display,
        cached for 3 s. Only values a sensor actually reports are shown; a
        missing CPU temperature is named instead of being left out silently.
    #>
    $now = Get-Date
    if (($now - $script:HsTemperatureCache.At).TotalSeconds -lt 3) { return $script:HsTemperatureCache.Line }
    $script:HsTemperatureCache.At = $now
    $diskText = Get-HsDiskTemperatureText
    if ($SkipTelemetry) {
        $line = if ($diskText) { "Temperaturen: $diskText" } else { "" }
    } else {
        $rows = Get-HsTelemetrySample -Stage "DISPLAY"
        $pawnIoMissing = ($null -ne $telemetryStatus -and -not $telemetryStatus.PawnIoInstalled)
        $line = Format-HsTemperatureLine -Rows $rows -PawnIoMissing:$pawnIoMissing -Extra $diskText
    }
    $script:HsTemperatureCache.Line = $line
    return $line
}

function Start-HsEarlySmartSelfTest {
    <#
        Starts the SMART self-test on the Windows disk at the beginning of
        the run. It runs inside the drive (no CPU/RAM/GPU use), so it can run
        alongside every stage; the Storage stage only collects the result.
    #>
    param([Parameter(Mandatory=$true)]$StageProfile)
    $disk = @($inventory.PhysicalDisks) | Select-Object -First 1
    if (-not $disk) { return $null }
    $index = [int]($disk.DeviceId -replace '[^0-9]','')
    Write-Progress2 "SMART-Selbsttest ($($StageProfile.SmartSelfTest)) auf $($disk.DeviceId) wird gestartet - er laeuft im Laufwerk selbst, ohne CPU, RAM oder GPU zu belasten." "Gray"
    try {
        $run = Start-HsSmartSelfTestRun -ConfigPath $ConfigPath -ToolCacheRoot $ToolCacheRoot -DriveIndex $index `
            -TestType $StageProfile.SmartSelfTest -NoDownload:$NoDownload
    } catch {
        $run = [pscustomobject]@{ Started = $false; Status = "BLOCKED"; Reason = "Could not start the SMART self-test: $($_.Exception.Message)"; DriveIndex = $index; TestType = $StageProfile.SmartSelfTest; StartedAt = $null; ToolPath = "" }
    }
    if (-not $run.Started) { Write-Progress2 "SMART-Selbsttest nicht gestartet: $($run.Reason)" "Yellow" }
    return $run
}

function Start-HsParallelStorageChecks {
    <#
        Starts surface scan and write/read verification in the background
        (StorageBackground.psm1). Called before the first GPU stage, or at
        the Storage stage itself when no GPU stage is part of the run.
    #>
    param([Parameter(Mandatory=$true)]$StageProfile, [string]$StageSuffix = "", [switch]$DuringGpu)
    $disk = @($inventory.PhysicalDisks) | Select-Object -First 1
    $index = if ($disk) { [int]($disk.DeviceId -replace '[^0-9]','') } else { -1 }
    $diskName = if ($disk) { $disk.DeviceId } else { "-" }
    $maxBytes = if ($SurfaceScanMaxBytes -gt 0) { $SurfaceScanMaxBytes } else { [long]$StageProfile.SurfaceScanMaxBytes }
    $maxSeconds = [int][math]::Round([double]$StageProfile.SurfaceScanMaxMinutes * 60)
    $surfaceEnabled = [bool]($disk -and $StageProfile.SurfaceScanEnabled)
    try {
        $script:HsStorageBackground = Start-HsStorageBackgroundChecks -ModuleRoot $ModuleRoot -SurfaceEnabled $surfaceEnabled -DriveIndex $index `
            -SurfaceMaxBytes $maxBytes -SurfaceMaxSeconds $maxSeconds -SurfaceLabel "Surface-Scan $diskName$StageSuffix (nur lesen)" `
            -WriteVerifyDirectory (Join-Path $env:TEMP "PC-Diagnose_HS_WriteVerify") -WriteVerifySizeMB ([int]$StageProfile.StorageWriteVerifyMB) `
            -WriteVerifyLabel "Schreib-/Lesepruefung$StageSuffix" -DuringGpu:$DuringGpu
    } catch {
        # Never let the background start take the run down; the Storage
        # stages try again and report BLOCKED if it still fails.
        $script:HsStorageBackground = $null
        $script:HsStorageBackgroundError = $_.Exception.Message
        Write-Progress2 "Storage-Pruefung konnte nicht im Hintergrund gestartet werden: $($_.Exception.Message)" "Yellow"
        return
    }
    $script:HsStorageBackground | Add-Member -NotePropertyName DiskName -NotePropertyValue $diskName -Force
    $parts = @()
    if ($surfaceEnabled) { $parts += "Surface-Scan $diskName" }
    $parts += "Schreib-/Lesepruefung"
    if ($DuringGpu) {
        Write-Progress2 "Parallel gestartet: $($parts -join ' + ') laufen waehrend der GPU-Tests; das Ergebnis folgt bei den Storage-Stufen." "Cyan"
        $global:HsParallelStatusProvider = { Get-HsParallelStorageStatusText }
    }
}

function Get-HsParallelStorageStatusText {
    <# Short text for the progress line of the running stage; writes a log line every 10 %. #>
    $handle = $script:HsStorageBackground
    if (-not $handle -or $handle.Closed) { return "" }
    $status = Get-HsStorageBackgroundStatus -Handle $handle
    if ($status.Milestone) { Write-Progress2 "    Parallel: $($status.Milestone)" "DarkGray" }
    return $status.ShortText
}

function Set-HsStageTimes {
    <# Stage timing for parts that ran in the background: their real start and end, not the collection time. #>
    param([Parameter(Mandatory=$true)]$Stage, $Started, $Ended)
    if ($null -eq $Started) { return }
    $Stage.Started = [datetime]$Started
    if ($null -ne $Ended) { $Stage.Ended = [datetime]$Ended }
    if ($Stage.Ended) { $Stage.Duration = ($Stage.Ended - $Stage.Started).ToString() }
}

function Invoke-HsComponentStages {
    <#
    .SYNOPSIS
        Runs the stages for the given component keys with the given profile.
        Used for the main run and, with a retest profile and a label suffix,
        for targeted retests - so both always run the identical stage code.

    .DESCRIPTION
        Component keys: CPU, Cache, RAM, GPU, VRAM (VRAM + GPU load, as in
        -Components), Storage, PCIe, System, plus the retest-only keys
        VRAMMemory (memtest_vulkan only) and GPULoad (sustained load only).
        The stage actions below read $StageProfile / $StageDirs /
        $StageSuffix through PowerShell's dynamic scoping (they are invoked
        from Invoke-HsStageWrapper, which is called from here).
    #>
    param(
        [Parameter(Mandatory=$true)][string[]]$ComponentKeys,
        [Parameter(Mandatory=$true)]$StageProfile,
        [Parameter(Mandatory=$true)][hashtable]$StageDirs,
        [string]$StageSuffix = "",
        [string]$OverallActivity = "Hardware-Stabilitaetstest"
    )

    $order = @("CPU","Cache","RAM","GPU","VRAM","VRAMMemory","GPULoad","Storage","PCIe","System")
    $keys = @($order | Where-Object { $ComponentKeys -contains $_ })
    $script:HsStagePlan = Get-HsStagePlan -Keys $keys -StageProfile $StageProfile
    $script:HsStagePlanIndex = -1
    $cpuInfo = @($inventory.Cpus)[0]
    $script:HsOverallActivity = $OverallActivity
    $keyIndex = 0

    # Storage runs partly in parallel (see StorageBackground.psm1): the SMART
    # self-test from the start, surface scan + write/verify from the first GPU
    # stage on. CPU, Cache and RAM keep the machine to themselves.
    $storageSelected = $keys -contains "Storage"
    $parallelStartKey = @($keys | Where-Object { $_ -in @("GPU","VRAM","VRAMMemory","GPULoad") }) | Select-Object -First 1
    $script:HsSelfTestRun = $null
    $script:HsStorageBackground = $null
    if ($storageSelected) { $script:HsSelfTestRun = Start-HsEarlySmartSelfTest -StageProfile $StageProfile }

    try {
    foreach ($key in $keys) {
        $keyIndex++
        $script:HsOverallStatus = "Komponente $keyIndex von $($keys.Count)"

        if ($storageSelected -and $key -eq $parallelStartKey -and -not $script:HsStorageBackground) {
            Start-HsParallelStorageChecks -StageProfile $StageProfile -StageSuffix $StageSuffix -DuringGpu
        }

        switch ($key) {
            "CPU" {
                Invoke-HsStageWrapper -StageName "CPU_COMPUTE" -Component "CPU Compute$StageSuffix" -Tool "Prime95" -Action {
                    param($stage)
                    $r = Invoke-HsCpuTortureTest -StageName "CPU_COMPUTE" -ConfigPath $ConfigPath -ToolCacheRoot $ToolCacheRoot `
                        -OutputDirectory $StageDirs.Cpu -DurationMinutes $StageProfile.CpuComputeMinutes `
                        -LogicalProcessors ([int]$cpuInfo.LogicalProcessors) -PhysicalCores ([int]$cpuInfo.Cores) `
                        -NoDownload:$NoDownload -TelemetrySample { param($s) Get-HsTelemetrySampleForStage -StageName $s } `
                        -CancelCheck { Test-HsThermalAbortOrCancel -StageName "CPU_COMPUTE" } -ProgressLabel "CPU Compute$StageSuffix (Prime95)"
                    $stage.Tool = $r.Tool; $stage.ToolVersion = $r.ToolVersion; $stage.Command = $r.Command
                    $stage.Coverage = "$($r.Workers) worker(s), $([math]::Round($r.DurationSeconds/60,1)) minute(s)"
                    $stage.PeakTemperature = $r.PeakTemperature
                    $stage.ErrorCount = $r.FailurePatterns.Count
                    Complete-HsStage $stage -Status $r.Status -Assessment $r.Reason
                } | Out-Null
            }
            "Cache" {
                Invoke-HsStageWrapper -StageName "CPU_CACHE_IMC" -Component "CPU Cache / IMC$StageSuffix" -Tool "Prime95" -Action {
                    param($stage)
                    $r = Invoke-HsCpuTortureTest -StageName "CPU_CACHE_IMC" -ConfigPath $ConfigPath -ToolCacheRoot $ToolCacheRoot `
                        -OutputDirectory $StageDirs.Cpu -DurationMinutes $StageProfile.CpuCacheImcMinutes `
                        -LogicalProcessors ([int]$cpuInfo.LogicalProcessors) -PhysicalCores ([int]$cpuInfo.Cores) `
                        -NoDownload:$NoDownload -TelemetrySample { param($s) Get-HsTelemetrySampleForStage -StageName $s } `
                        -CancelCheck { Test-HsThermalAbortOrCancel -StageName "CPU_CACHE_IMC" } -ProgressLabel "CPU Cache / IMC$StageSuffix (Prime95)"
                    $stage.Tool = $r.Tool; $stage.ToolVersion = $r.ToolVersion; $stage.Command = $r.Command
                    $stage.Coverage = "$($r.Workers) worker(s) (all logical processors), $([math]::Round($r.DurationSeconds/60,1)) minute(s)"
                    $stage.PeakTemperature = $r.PeakTemperature
                    $stage.ErrorCount = $r.FailurePatterns.Count
                    Complete-HsStage $stage -Status $r.Status -Assessment $r.Reason
                } | Out-Null
            }
            "RAM" {
                Invoke-HsStageWrapper -StageName "RAM" -Component "RAM$StageSuffix" -Tool "MemoryChecker" -Action {
                    param($stage)
                    $ramSeconds = [int][math]::Round([double]$StageProfile.RamDurationMinutes * 60)
                    # As much RAM as is available right now; if MemoryChecker
                    # still cannot allocate it (memory taken meanwhile), retry
                    # with 10 points less instead of reporting nothing.
                    $ramTarget = Get-HsMaxRamPercent -MaxPercent ([int]$StageProfile.RamPercentOfPhysical)
                    $ramPercent = [int]$ramTarget.Percent
                    Write-Progress2 ("RAM: {0} MB available of {1} MB, testing {2}% (reserve {3} MB for Windows)" -f $ramTarget.FreeMB, $ramTarget.TotalMB, $ramPercent, $ramTarget.ReserveMB) "Gray"
                    for ($attempt = 1; $attempt -le 3; $attempt++) {
                        $r = Invoke-HsRamVerification -ConfigPath $ConfigPath -ToolCacheRoot $ToolCacheRoot -OutputDirectory $StageDirs.Ram `
                            -Passes $StageProfile.RamPasses -PercentOfPhysicalRam $ramPercent `
                            -DurationSeconds $ramSeconds -NoDownload:$NoDownload `
                            -CancelCheck { Test-HsThermalAbortOrCancel -StageName "RAM" } -ProgressLabel "RAM$StageSuffix (MemoryChecker, $ramPercent%)"
                        if ($r.Status -ne "BLOCKED" -or [string]$r.Reason -notmatch "(?i)allocat|not enough|exceeds" -or $ramPercent -le 20) { break }
                        Add-HsNote -Stage $stage -Note "Could not allocate $ramPercent% of RAM; retrying with $($ramPercent - 10)%."
                        Write-Progress2 "RAM: $ramPercent% could not be allocated - retrying with $($ramPercent - 10)%" "Yellow"
                        $ramPercent -= 10
                    }
                    $stage.Tool = $r.Tool; $stage.ToolVersion = $r.ToolVersion; $stage.Command = $r.Command
                    $stage.Coverage = if ($ramSeconds -gt 0) { "$($r.TargetPercent)% of physical RAM, continuous for $([math]::Round($r.DurationSeconds/60,1)) minute(s)" } else { "$($r.TargetPercent)% of physical RAM, $($r.Passes) pass(es)" }
                    $stage.ExitCode = $r.ExitCode
                    if ($r.VerificationErrors) { $stage.ErrorCount = $r.VerificationErrors }
                    Complete-HsStage $stage -Status $r.Status -Assessment $r.Reason
                } | Out-Null
            }
            "GPU" {
                Invoke-HsStageWrapper -StageName "GPU_COMPUTE" -Component "GPU Compute$StageSuffix" -Action {
                    param($stage)
                    $r = Invoke-HsGpuComputeVerification -ElementCount $StageProfile.GpuComputeWorkgroups `
                        -Iterations ([math]::Max(1,[int]($StageProfile.GpuComputeIterations/100))) -ProgressLabel "GPU Compute$StageSuffix (D3D11)"
                    $stage.Coverage = "$($r.ElementsVerified) integer operation(s), $($r.Iterations) iteration(s)"
                    $stage.ErrorCount = $r.Mismatches
                    Complete-HsStage $stage -Status $r.Status -Assessment $r.Reason
                } | Out-Null
            }
            { $_ -in @("VRAM","VRAMMemory") } {
                Invoke-HsStageWrapper -StageName "VRAM" -Component "VRAM$StageSuffix" -Tool "memtest_vulkan" -Action {
                    param($stage)
                    $r = Invoke-HsVramVerification -ConfigPath $ConfigPath -ToolCacheRoot $ToolCacheRoot -OutputDirectory $StageDirs.Gpu `
                        -DurationMinutes $StageProfile.VramTestMinutes -NoDownload:$NoDownload -ProgressLabel "VRAM$StageSuffix (memtest_vulkan)"
                    $stage.ToolVersion = $r.ToolVersion
                    $stage.Coverage = "$([math]::Round($r.DurationSeconds/60,1)) minute(s)"
                    Complete-HsStage $stage -Status $r.Status -Assessment $r.Reason
                } | Out-Null
            }
        }

        if ($key -in @("VRAM","GPULoad")) {
            Invoke-HsStageWrapper -StageName "GPU_LOAD_THERMAL" -Component "GPU Load / Thermal Validation$StageSuffix" -Action {
                param($stage)
                $r = Invoke-HsGpuLoadThermalValidation -DurationSeconds ([int][math]::Round([double]$StageProfile.GpuLoadMinutes * 60)) `
                    -TelemetrySample { param($s) Get-HsTelemetrySampleForStage -StageName $s } `
                    -CancelCheck { Test-HsThermalAbortOrCancel -StageName "GPU_LOAD_THERMAL" } -ProgressLabel "GPU Last / Temperatur$StageSuffix"
                $stage.Coverage = if ($r.HeavyKernel) { "$($r.Iterations) full-load dispatch(es), 1M threads x $($r.Rounds) rounds, $($r.VerifiedValues) value(s) verified" } else { "$($r.Iterations) sustained load iteration(s) (light mode)" }
                $stage.PeakTemperature = $r.PeakTemperature
                $loadStatus = $r.Status
                $loadReason = $r.Reason
                $driverResets = @(Get-HsGpuDriverResetEvents -Since $stage.Started)
                if ($driverResets.Count -gt 0 -and $loadStatus -eq "PASS") {
                    $loadStatus = "WARNING"
                    $loadReason = "Windows logged $($driverResets.Count) display driver reset(s) during the load (first: $($driverResets[0].TimeCreated.ToString('HH:mm:ss'))). $loadReason"
                }
                Complete-HsStage $stage -Status $loadStatus -Assessment $loadReason
            } | Out-Null
        }

        if ($key -eq "Storage") {
            # SMART is read-only and cheap, so every physical disk is queried (the
            # first disk alone could be a USB bridge that reports UNSUPPORTED while
            # the Windows disk stayed unchecked). The disk holding Windows is listed
            # first by the inventory; the SMART self-test runs only on that disk.
            $smartDisks = @($inventory.PhysicalDisks)
            if ($smartDisks.Count -eq 0) {
                Invoke-HsStageWrapper -StageName "STORAGE_SMART" -Component "Storage SMART$StageSuffix" -Tool "smartctl" -Action {
                    param($stage)
                    Complete-HsStage $stage -Status "SKIPPED" -Assessment "No physical disk found."
                } | Out-Null
            }
            $smartIsFirstDisk = $true
            foreach ($smartDisk in $smartDisks) {
                $smartIndex = [int]($smartDisk.DeviceId -replace '[^0-9]','')
                $smartRunSelfTest = $smartIsFirstDisk
                $smartIsFirstDisk = $false
                Invoke-HsStageWrapper -StageName "STORAGE_SMART" -Component "Storage SMART ($($smartDisk.DeviceId))$StageSuffix" -Tool "smartctl" -Action {
                    param($stage)
                    Write-HsStageProgress -Activity "SMART$StageSuffix" -Status "Lese SMART-Daten von $($smartDisk.DeviceId)" -Force
                    $r = Invoke-HsSmartQuery -ConfigPath $ConfigPath -ToolCacheRoot $ToolCacheRoot -DriveIndex $smartIndex -OutputDirectory $StageDirs.Storage -NoDownload:$NoDownload
                    Write-HsStageProgress -Activity "SMART$StageSuffix" -Completed
                    $stage.ToolVersion = $r.ToolVersion
                    $stage.Coverage = "$($smartDisk.DeviceId): $($smartDisk.Model)"
                    $stage.LogPaths = @($r.RawOutputPath)
                    Complete-HsStage $stage -Status $r.Status -Assessment $r.Reason
                } | Out-Null

                $smartStage = $script:HsStages[$script:HsStages.Count - 1]
                $selfTestRun = $script:HsSelfTestRun
                if ($smartRunSelfTest -and ($smartStage.Status -in @("PASS","WARNING") -or ($selfTestRun -and $selfTestRun.Started))) {
                    Invoke-HsStageWrapper -StageName "STORAGE_SMART_SELFTEST" -Component "Storage SMART Self-Test ($($smartDisk.DeviceId))$StageSuffix" -Tool "smartctl" -Action {
                        param($innerStage)
                        if (-not $selfTestRun) {
                            $selfTestRun = Start-HsSmartSelfTestRun -ConfigPath $ConfigPath -ToolCacheRoot $ToolCacheRoot -DriveIndex $smartIndex `
                                -TestType $StageProfile.SmartSelfTest -NoDownload:$NoDownload
                        }
                        if ($selfTestRun.Started) {
                            $innerStage.Started = [datetime]$selfTestRun.StartedAt
                            Add-HsNote -Stage $innerStage -Note "Started at $(([datetime]$selfTestRun.StartedAt).ToString('HH:mm:ss')) at the beginning of the run; it runs inside the drive while the other stages load CPU, RAM and GPU."
                        }
                        $selfTest = Wait-HsSmartSelfTestResult -Run $selfTestRun -ProgressLabel "SMART-Selbsttest $($smartDisk.DeviceId)$StageSuffix"
                        Complete-HsStage $innerStage -Status $selfTest.Status -Assessment $selfTest.Reason
                    } | Out-Null
                }
            }
            $script:HsSelfTestRun = $null

            # Surface scan and write/read verification ran in the background
            # during the GPU stages (or start now if there were none); here
            # their results are collected, waiting for what is still running.
            if (-not $script:HsStorageBackground) {
                Start-HsParallelStorageChecks -StageProfile $StageProfile -StageSuffix $StageSuffix
            }
            $global:HsParallelStatusProvider = $null
            $storageRun = $script:HsStorageBackground
            if (-not $storageRun) {
                foreach ($blocked in @(@("STORAGE_SURFACE","Storage Surface Read"), @("STORAGE_WRITE_VERIFY","Storage Write/Read Verification"))) {
                    Invoke-HsStageWrapper -StageName $blocked[0] -Component "$($blocked[1])$StageSuffix" -Action {
                        param($stage)
                        Complete-HsStage $stage -Status "BLOCKED" -Assessment "The storage check could not be started: $script:HsStorageBackgroundError"
                    } | Out-Null
                }
                continue
            }
            $parallelNote = if ($storageRun.DuringGpu) { "Ran in the background during the GPU stages (started $(([datetime]$storageRun.StartedAt).ToString('HH:mm:ss')))." } else { "" }

            Invoke-HsStageWrapper -StageName "STORAGE_SURFACE" -Component "Storage Surface Read$StageSuffix" -Action {
                param($stage)
                if (-not $storageRun.Settings.SurfaceEnabled) {
                    Complete-HsStage $stage -Status "SKIPPED" -Assessment "Surface scan disabled for this profile or no disk found."
                    return
                }
                Wait-HsStorageBackgroundChecks -Handle $storageRun -Until Surface -ProgressLabel "$($storageRun.Settings.SurfaceLabel)" `
                    -CancelCheck { Test-HsThermalAbortOrCancel -StageName "STORAGE_SURFACE" }
                $r = $storageRun.Sync.Surface
                if ($null -eq $r) {
                    $why = if ($storageRun.Sync.SurfaceError) { $storageRun.Sync.SurfaceError } elseif ($storageRun.Sync.Error) { $storageRun.Sync.Error } else { "no result was returned" }
                    $noResultStatus = if ($script:HsThermalAbortReason -or $storageRun.Sync.Cancel) { "INTERRUPTED" } else { "BLOCKED" }
                    Complete-HsStage $stage -Status $noResultStatus -Assessment "Surface scan did not complete: $why"
                    return
                }
                $stage.Coverage = "$($storageRun.DiskName) (Windows disk first): $([math]::Round($r.BytesRead/1GB,2)) / $([math]::Round($r.TotalBytes/1GB,2)) GB read"
                $stage.ErrorCount = $r.Errors.Count
                if ($parallelNote) { Add-HsNote -Stage $stage -Note $parallelNote }
                Complete-HsStage $stage -Status $r.Status -Assessment $r.Reason
                Set-HsStageTimes -Stage $stage -Started $storageRun.Sync.SurfaceStarted -Ended $storageRun.Sync.SurfaceEnded
            } | Out-Null

            Invoke-HsStageWrapper -StageName "STORAGE_WRITE_VERIFY" -Component "Storage Write/Read Verification$StageSuffix" -Action {
                param($stage)
                Wait-HsStorageBackgroundChecks -Handle $storageRun -Until All -ProgressLabel "$($storageRun.Settings.WriteVerifyLabel)" `
                    -CancelCheck { Test-HsThermalAbortOrCancel -StageName "STORAGE_WRITE_VERIFY" }
                $final = Complete-HsStorageBackgroundChecks -Handle $storageRun
                $r = $final.WriteVerify
                if ($null -eq $r) {
                    if ($storageRun.Sync.Cancel) {
                        Complete-HsStage $stage -Status "SKIPPED" -Assessment "Not run: the storage checks were stopped before the write/read verification began (thermal guard or cancel)."
                    } else {
                        $why = if ($final.WriteError) { $final.WriteError } else { "no result was returned" }
                        Complete-HsStage $stage -Status "BLOCKED" -Assessment "Write/read verification did not complete: $why"
                    }
                    return
                }
                $stage.Coverage = "$([math]::Round($r.BytesVerified/1MB,1)) MB written/read/verified"
                $stage.ErrorCount = $r.Mismatches
                if ($parallelNote) { Add-HsNote -Stage $stage -Note $parallelNote }
                Complete-HsStage $stage -Status $r.Status -Assessment $r.Reason
                Set-HsStageTimes -Stage $stage -Started $final.WriteStarted -Ended $final.WriteEnded
            } | Out-Null
            Complete-HsStorageBackgroundChecks -Handle $storageRun -TimeoutSeconds 10 | Out-Null
            $script:HsStorageBackground = $null
        }

        if ($key -eq "PCIe") {
            Invoke-HsStageWrapper -StageName "PCIE_WHEA" -Component "PCIe / WHEA$StageSuffix" -Action {
                param($stage)
                $wheaEvents = @()
                try {
                    $raw = Get-HsEventsSafe -Filter @{ LogName = "System"; ProviderName = "Microsoft-Windows-WHEA-Logger" } -Maximum 100
                    $wheaEvents = @($raw | ForEach-Object { ConvertTo-HsEventRow -Event $_ })
                } catch {}
                $stage.EventsFound = $wheaEvents
                if ($wheaEvents.Count -eq 0) {
                    Complete-HsStage $stage -Status "PASS" -Assessment "No WHEA hardware error events found."
                } else {
                    $categories = @($wheaEvents | ForEach-Object { Get-HsWheaCategory -Event $_ } | Select-Object -Unique)
                    $assessment = ($categories | ForEach-Object { Get-HsWheaAssessment -Category $_ }) -join " "
                    # Separate errors logged DURING this test from older ones:
                    # only the former were triggered by this load.
                    $duringRun = @($wheaEvents | Where-Object { $_.TimeCreated -and $_.TimeCreated -ge $script:HsRunStartTime })
                    $newest = @($wheaEvents | Where-Object { $_.TimeCreated } | Sort-Object TimeCreated -Descending | Select-Object -First 1)
                    $newestText = if ($newest.Count -gt 0) { ", newest $($newest[0].TimeCreated.ToString('yyyy-MM-dd HH:mm'))" } else { "" }
                    $stage.Coverage = "$($wheaEvents.Count) WHEA event(s), $($duringRun.Count) during this run$newestText`: $($categories -join ', ')"
                    $timing = if ($duringRun.Count -gt 0) { "$($duringRun.Count) of them were logged DURING this test run, i.e. under this load." } else { "None of them was logged during this test run; they come from earlier use of the PC." }
                    Complete-HsStage $stage -Status "WARNING" -Assessment "$timing $assessment"
                }
            } | Out-Null
        }

        if ($key -eq "System") {
            Invoke-HsStageWrapper -StageName "SYSTEM_STABILITY" -Component "System Stability (CPU+GPU+RAM)$StageSuffix" -Action {
                param($stage)
                $durationSeconds = [int][math]::Round([double]$StageProfile.SystemStabilityMinutes * 60)

                # RAM is verified WHILE CPU and GPU are loaded: a weak PSU, VRM
                # or memory controller often only shows up with all three busy.
                # MemoryChecker runs in this process (registered for Ctrl+C
                # cleanup), the GPU load in a background job, Prime95 blocks.
                # Available RAM minus an extra 1.5 GB for Prime95 and the GPU job.
                $systemRamTarget = Get-HsMaxRamPercent -ExtraReserveMB 1536 -MaxPercent ([int]$StageProfile.SystemStabilityRamPercent)
                $systemRamPercent = [int]$systemRamTarget.Percent
                $ramLoad = Start-HsRamBackgroundLoad -ConfigPath $ConfigPath -ToolCacheRoot $ToolCacheRoot -OutputDirectory $StageDirs.Ram `
                    -PercentOfPhysicalRam $systemRamPercent -NoDownload:$NoDownload
                $gpuJob = $null
                $ramResult = $null
                try {
                    $gpuJob = Start-Job -ScriptBlock {
                        param($moduleRoot, $seconds)
                        Import-Module (Join-Path $moduleRoot "GpuTests.psm1") -Force
                        Invoke-HsGpuLoadThermalValidation -DurationSeconds $seconds -Quiet
                    } -ArgumentList $ModuleRoot, $durationSeconds

                    # Own output folder: the combined run reuses the CPU_COMPUTE workload
                    # and would otherwise overwrite the CPU Compute stage's log.
                    $cpuResult = Invoke-HsCpuTortureTest -StageName "CPU_COMPUTE" -ConfigPath $ConfigPath -ToolCacheRoot $ToolCacheRoot `
                        -OutputDirectory (Join-Path $StageDirs.Cpu "SystemStability") -DurationMinutes $StageProfile.SystemStabilityMinutes `
                        -LogicalProcessors ([int]$cpuInfo.LogicalProcessors) -PhysicalCores ([int]$cpuInfo.Cores) `
                        -NoDownload:$NoDownload -CancelCheck { Test-HsThermalAbortOrCancel -StageName "SYSTEM_STABILITY" } `
                        -ProgressLabel "Systemtest CPU + GPU + RAM$StageSuffix"
                } finally {
                    $ramResult = Complete-HsRamBackgroundLoad -Load $ramLoad
                    # A thermal abort or Ctrl+C ends the CPU part early: the GPU
                    # load must stop then too, not keep running unguarded.
                    if ($gpuJob -and ($null -eq $cpuResult -or $cpuResult.Status -eq "INTERRUPTED") -and $gpuJob.State -eq "Running") {
                        Stop-Job -Job $gpuJob -ErrorAction SilentlyContinue
                    }
                }
                $gpuResult = $null
                $gpuJobError = ""
                try {
                    $gpuResult = Receive-Job -Job $gpuJob -Wait -ErrorAction Stop | Select-Object -Last 1
                } catch {
                    $gpuJobError = $_.Exception.Message
                } finally {
                    Remove-Job -Job $gpuJob -Force -ErrorAction SilentlyContinue
                }
                $driverResets = @(Get-HsGpuDriverResetEvents -Since $stage.Started)
                if ($null -eq $gpuResult) {
                    $gpuStatus = if ($cpuResult.Status -eq "INTERRUPTED") { "INTERRUPTED" } else { "BLOCKED" }
                    $resetText = if ($driverResets.Count -gt 0) { " Windows logged $($driverResets.Count) display driver reset(s) during this stage (first: $($driverResets[0].TimeCreated.ToString('HH:mm:ss')))." } else { "" }
                    $gpuResult = [pscustomobject]@{
                        Status     = $gpuStatus
                        Reason     = "The GPU load process ended without a result$(if ($gpuJobError) { " ($gpuJobError)" })$resetText"
                        Iterations = 0
                        DeviceLost = $false
                    }
                } elseif ($driverResets.Count -gt 0 -and $gpuResult.Status -eq "PASS") {
                    $gpuResult.Status = "WARNING"
                    $gpuResult.Reason = "Windows logged $($driverResets.Count) display driver reset(s) during the combined load. $($gpuResult.Reason)"
                }

                $stage.Coverage = "CPU: $($cpuResult.Workers) worker(s); GPU: $($gpuResult.Iterations) iteration(s); RAM: $systemRamPercent% continuous, $($ramResult.Passes) complete pass(es)"
                $partsText = "CPU: $($cpuResult.Status), GPU: $($gpuResult.Status), RAM: $($ramResult.Status)"
                if ($cpuResult.Status -eq "FAIL" -or $gpuResult.Status -eq "FAIL" -or $ramResult.Status -eq "FAIL") {
                    $ramDetail = if ($ramResult.Status -eq "FAIL") { " RAM: $($ramResult.Reason)" } else { "" }
                    Complete-HsStage $stage -Status "FAIL" -Assessment "Combined CPU+GPU+RAM activity produced a verified error ($partsText). Individual components may still pass in isolation; under combined load the power supply, VRM, memory controller and mainboard become more suspect.$ramDetail"
                } elseif ($gpuResult.DeviceLost) {
                    Complete-HsStage $stage -Status "FAIL" -Assessment "GPU device was lost during combined system activity ($partsText)."
                } elseif ($cpuResult.Status -eq "PASS" -and $gpuResult.Status -eq "WARNING" -and $ramResult.Status -eq "PASS") {
                    Complete-HsStage $stage -Status "WARNING" -Assessment "CPU, GPU and RAM workloads ran concurrently without a verified calculation error, but: $($gpuResult.Reason)"
                } elseif ($cpuResult.Status -eq "PASS" -and $gpuResult.Status -eq "PASS" -and $ramResult.Status -eq "PASS") {
                    Complete-HsStage $stage -Status "PASS" -Assessment "CPU, GPU and RAM workloads ran concurrently for $($StageProfile.SystemStabilityMinutes) minute(s) with no verified errors."
                } else {
                    # A combined PASS is only meaningful if ALL workloads really ran.
                    $allNotRun = (@($cpuResult.Status, $gpuResult.Status, $ramResult.Status) | Where-Object { $_ -notin @("SKIPPED","UNSUPPORTED") }).Count -eq 0
                    $partStatus = if ($cpuResult.Status -eq "INTERRUPTED") { "INTERRUPTED" } elseif ($allNotRun) { "SKIPPED" } else { "BLOCKED" }
                    Complete-HsStage $stage -Status $partStatus -Assessment "Combined stability could not be verified because not all workloads completed ($partsText). CPU: $($cpuResult.Reason) GPU: $($gpuResult.Reason) RAM: $($ramResult.Reason)"
                }
            } | Out-Null
        }
    }

    } finally {
        # Ctrl+C or an unexpected error: background storage checks must not
        # keep reading the disk after the run ended.
        $global:HsParallelStatusProvider = $null
        if ($script:HsStorageBackground) {
            Complete-HsStorageBackgroundChecks -Handle $script:HsStorageBackground -TimeoutSeconds 10 | Out-Null
            $script:HsStorageBackground = $null
        }
        $script:HsSelfTestRun = $null
    }

    Write-HsOverallProgress -Activity $OverallActivity -Completed
    $global:HsRunPlanState = $null
}

function Get-HsRetestKeysForStage {
    <# Component keys that re-run the given stage; empty = not retestable. #>
    param([Parameter(Mandatory=$true)][string]$StageName)
    switch ($StageName) {
        "CPU_COMPUTE"            { return @("CPU") }
        "CPU_CACHE_IMC"          { return @("Cache") }
        "RAM"                    { return @("RAM") }
        "GPU_COMPUTE"            { return @("GPU","GPULoad") }
        "VRAM"                   { return @("VRAMMemory") }
        "GPU_LOAD_THERMAL"       { return @("GPULoad") }
        "STORAGE_SMART"          { return @("Storage") }
        "STORAGE_SMART_SELFTEST" { return @("Storage") }
        "STORAGE_SURFACE"        { return @("Storage") }
        "STORAGE_WRITE_VERIFY"   { return @("Storage") }
        "SYSTEM_STABILITY"       { return @("System") }
        # PCIE_WHEA reads past event log entries; running it again tests nothing new.
        default                  { return @() }
    }
}

function Get-HsNoticeableStages {
    <# Stages worth a targeted retest: verified errors, warnings, or runs that did not complete. #>
    param([object[]]$Stages)
    return @($Stages | Where-Object {
        $_.Status -in @("FAIL","WARNING","BLOCKED","INTERRUPTED","THERMAL_ABORT","SYSTEM_RESET") -and
        @(Get-HsRetestKeysForStage -StageName $_.StageName).Count -gt 0
    })
}

function Show-HsStageSummary {
    param([object[]]$Stages, [string]$Title)
    Write-Host ""
    Write-Host $Title -ForegroundColor Cyan
    foreach ($s in $Stages) {
        $color = switch ($s.Status) { "PASS" { "Green" } "FAIL" { "Red" } { $_ -in @("SKIPPED","UNSUPPORTED") } { "DarkGray" } default { "Yellow" } }
        Write-Host ("  {0,-14} {1}" -f $s.Status, $s.Component) -ForegroundColor $color
    }
}

function Read-HsRetestRequest {
    <#
        Asks which noticeable component(s) to test again and for how long.
        Returns $null for "no retest".
    #>
    param([Parameter(Mandatory=$true)][object[]]$Noticeable)

    Write-Host ""
    Write-Host "Auffaellige Ergebnisse:" -ForegroundColor Yellow
    $options = @()
    $number = 0
    foreach ($s in $Noticeable) {
        $number++
        $reason = ([string]$s.Assessment -replace '\s+', ' ')
        if ($reason.Length -gt 110) { $reason = $reason.Substring(0, 110) + "..." }
        Write-Host ("  [{0}] {1} - {2}" -f $number, $s.Component, $s.Status) -ForegroundColor White
        if ($reason) { Write-Host "      $reason" -ForegroundColor Gray }
        $options += [pscustomobject]@{ Number = [string]$number; Keys = @(Get-HsRetestKeysForStage -StageName $s.StageName) }
    }
    Write-Host ""
    Write-Host "Soll eine Komponente gezielt erneut getestet werden?" -ForegroundColor Cyan
    while ($true) {
        $answer = ([string](Read-Host "Nummer(n) eingeben, z. B. 1 oder 1,3 - Enter = nein")).Trim()
        if (-not $answer) { return $null }
        $picked = @($answer -split '[,; ]+' | Where-Object { $_ })
        $invalid = @($picked | Where-Object { $_ -notin @($options | ForEach-Object { $_.Number }) })
        if ($invalid.Count -eq 0) { break }
        Write-Host "  Unbekannte Nummer(n): $($invalid -join ', ')" -ForegroundColor Yellow
    }
    $keys = @($options | Where-Object { $picked -contains $_.Number } | ForEach-Object { $_.Keys } | Select-Object -Unique)

    $minutes = Read-HsDurationMinutes -Title "Wie lange soll jede gewaehlte Komponente getestet werden?" -Choices @(10, 30, 60) `
        -Labels @("Kurz", "Mittel", "Lang") -DefaultIndex 1 -MaxMinutes 600 `
        -Hint "Datentraeger: Surface-Scan der Windows-Platte fuer diese Dauer plus Schreib-/Lesepruefung."
    return [pscustomobject]@{ Keys = $keys; Minutes = [double]$minutes }
}

function Save-HsRunReport {
    $html = New-HsHtmlReport -Stages @($script:HsStages) -Inventory $inventory -Profile $profileLabel -RunId $RunId -SystemResetInfo $systemResetInfo `
        -TelemetryStatus $telemetryStatus -TelemetrySkipped:$SkipTelemetry
    [IO.File]::WriteAllText((Join-Path $Out "00_Result.html"), $html, [Text.UTF8Encoding]::new($false))
    (New-HsSummaryText -Stages @($script:HsStages)) | Out-File (Join-Path $Out "00_Summary.txt") -Encoding UTF8
    Export-HsStagesCsv -Stages @($script:HsStages) -Path (Join-Path $Out "00_TestStages.csv")
}

# ---------------------------------------------------------------------------
# Main run
# ---------------------------------------------------------------------------

# Live temperatures in the progress display. smartctl is resolved up front
# (downloaded only if the Storage stages will need it anyway) so the Windows
# disk temperature is shown from the first stage on.
try {
    $smartTool = Resolve-HsTool -ToolId "smartmontools" -ToolConfig (Get-HsToolConfig -ConfigPath $ConfigPath) -ToolCacheRoot $ToolCacheRoot `
        -NoDownload:($NoDownload -or -not ($selectedComponents -contains "Storage"))
    if ($smartTool.Available) { $script:HsSmartctlPath = $smartTool.ExecutablePath }
} catch {}
$global:HsTemperatureProvider = { Get-HsTemperatureLine }

$mainDirs = @{ Cpu = $Dirs.Cpu; Ram = $Dirs.Ram; Gpu = $Dirs.Gpu; Storage = $Dirs.Storage }
Invoke-HsComponentStages -ComponentKeys $selectedComponents -StageProfile $profileConfig -StageDirs $mainDirs `
    -OverallActivity "Hardware-Stabilitaetstest ($profileLabel)"

# ---------------------------------------------------------------------------
# System-Reset check for THIS run and reporting
# ---------------------------------------------------------------------------

$systemResetInfo = [pscustomobject]@{ Classification = "NONE"; Notes = "" }

# Written right away so the results are safe even if the console is closed
# at the retest question below.
Save-HsRunReport
Show-HsStageSummary -Stages @($script:HsStages) -Title "Ergebnis ($profileLabel): $(Get-HsOverallStatus -Stages @($script:HsStages))"

# ---------------------------------------------------------------------------
# Targeted retest of noticeable components
# ---------------------------------------------------------------------------

$retestRound = 0
$lastRoundStages = @($script:HsStages)
while ($true) {
    $noticeable = Get-HsNoticeableStages -Stages $lastRoundStages
    $request = $null
    if ($RetestComponents) {
        if ($retestRound -gt 0) { break }
        $request = [pscustomobject]@{
            Keys    = @($RetestComponents -split "," | ForEach-Object { $_.Trim() } | Where-Object { $_ })
            Minutes = $(if ($RetestMinutes -gt 0) { $RetestMinutes } else { 10.0 })
        }
    } elseif ($noticeable.Count -gt 0 -and (Test-HsInteractiveConsole -NoPrompt:$NoPrompt)) {
        $request = Read-HsRetestRequest -Noticeable $noticeable
    }
    if ($null -eq $request -or @($request.Keys).Count -eq 0) { break }

    $retestRound++
    $minutes = [double]$request.Minutes
    if ($MaxStageMinutes -gt 0) { $minutes = [math]::Min($minutes, $MaxStageMinutes) }
    $retestProfile = Get-HsRetestProfile -BaseProfile $profileConfig -Minutes $minutes
    if ($MaxStageMinutes -gt 0) { $retestProfile.StorageWriteVerifyMB = [math]::Min([int]$retestProfile.StorageWriteVerifyMB, 64) }
    $retestDirs = New-HsStageDirs -Root (Join-Path $Out ("Retest_{0}" -f $retestRound))
    $suffix = " (Retest $retestRound, $minutes min)"
    Write-Progress2 "Gezielter Wiederholungstest $retestRound - $(@($request.Keys) -join ', ') - $minutes Minute(n) je Komponente" "Cyan"

    $before = $script:HsStages.Count
    Invoke-HsComponentStages -ComponentKeys @($request.Keys) -StageProfile $retestProfile -StageDirs $retestDirs -StageSuffix $suffix `
        -OverallActivity "Wiederholungstest $retestRound"
    $lastRoundStages = @($script:HsStages | Select-Object -Skip $before)
    Save-HsRunReport
    Show-HsStageSummary -Stages $lastRoundStages -Title "Ergebnis Wiederholungstest $retestRound"
}

Unregister-Event -SourceIdentifier $engineExitAction.Name -ErrorAction SilentlyContinue

@"
Hardware-Stabilitaetstest result package for $($inventory.ComputerName)

This is a verification-first hardware stability test, not only a stress
test: known data/computation is processed by the hardware, read back, and
compared against the expected result.

PASS means: within the range actually tested, no errors were detected.
It does not guarantee the hardware is completely free of defects.
Stages marked "(Retest ...)" are targeted repeats chosen after the main run;
they add evidence but do not replace the original result.
"@ | Out-File (Join-Path $Out "README.txt") -Encoding UTF8

if (Get-Variable -Name HsTemperatureProviderError -Scope Global -ValueOnly -ErrorAction SilentlyContinue) {
    Write-Progress2 "Temperature display failed during the run: $global:HsTemperatureProviderError" "Yellow"
}
$global:HsTemperatureProvider = $null
$global:HsTemperatureProviderError = $null
$global:HsRunPlanState = $null
Close-HsTelemetry
New-HsResultZip -SourceDirectory $Out -ZipPath "$Out.zip"

Write-Host ""
Write-Host "Overall: $(Get-HsOverallStatus -Stages @($script:HsStages))" -ForegroundColor Cyan
Write-Host "Result folder: $Out"
Write-Host "Result package: $Out.zip"

if ([Environment]::UserInteractive) {
    try {
        Start-Process (Join-Path $Out "00_Result.html")
    } catch {}
}
