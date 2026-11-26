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
    "StorageTests.psm1","StorageSurface.psm1","StorageWriteVerify.psm1","Reporting.psm1"
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

function Test-HsInteractiveConsole {
    # Prompts only make sense with a real console user: not in CI, not with
    # redirected input, not in a non-interactive remote session.
    if ($NoPrompt) { return $false }
    try {
        if (-not [Environment]::UserInteractive) { return $false }
        if ([Console]::IsInputRedirected) { return $false }
    } catch { return $false }
    return $true
}

function Read-HsChoice {
    <# Reads one of the allowed answers; repeats on anything else. #>
    param([Parameter(Mandatory=$true)][string]$Prompt, [Parameter(Mandatory=$true)][string[]]$Allowed, [string]$Default = "")
    while ($true) {
        $answer = ([string](Read-Host $Prompt)).Trim()
        if ([string]::IsNullOrEmpty($answer) -and $Default) { return $Default }
        if ($Allowed -contains $answer) { return $answer }
        Write-Host "  Bitte eine der Optionen eingeben: $($Allowed -join ', ')" -ForegroundColor Yellow
    }
}

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
    if ($DryRun -or -not (Test-HsInteractiveConsole)) {
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
    return Get-HsTelemetrySample -Stage $StageName
}

function Test-HsThermalAbortOrCancel {
    param([string]$StageName)
    if ($script:HsCancelRequested) { return $true }
    if ($SkipTelemetry) { return $false }
    $rows = Get-HsTelemetrySample -Stage $StageName
    $state = Test-HsThermalState -Rows $rows -Thresholds $thermalDefaults
    if ($state.State -eq "ABORT") {
        Write-Progress2 "THERMAL ABORT: $($state.Reason)" "Red"
        return $true
    }
    if ($state.State -eq "WARNING") {
        Write-Progress2 "Thermal warning: $($state.Reason)" "Yellow"
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
    $choice = if (Test-HsInteractiveConsole) { Read-Host "Select" } else { "1" }
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

if (-not $SkipTelemetry) {
    Write-Progress2 "Initializing telemetry (LibreHardwareMonitor)..." "Cyan"
    $telemetryOk = Initialize-HsTelemetry -ConfigPath $ConfigPath -ToolCacheRoot $ToolCacheRoot -NoDownload:$NoDownload
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

    Set-HsPendingRun -RunId $RunId -ResultDirectory $Out -Profile $Profile -Stage $StageName `
        -ExpectedEnd ([datetime]::Now.AddMinutes(60)) -Status "Running" | Out-Null

    try {
        & $Action $stage
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
    $deg = "$([char]0x00B0)C"
    $parts = @()
    if (-not $SkipTelemetry) {
        $rows = Get-HsTelemetrySample -Stage "DISPLAY"
        $temps = @($rows | Where-Object { $null -ne $_ -and $_.SensorType -eq "Temperature" })
        $cpu = @($temps | Where-Object { $_.HardwareType -eq "Cpu" } | ForEach-Object { $_.Value } | Measure-Object -Maximum)
        if ($cpu.Count -gt 0 -and $cpu[0].Count -gt 0) {
            $parts += "CPU $([math]::Round($cpu[0].Maximum))$deg"
        } elseif ($null -ne $telemetryStatus -and -not $telemetryStatus.PawnIoInstalled) {
            $parts += "CPU - (PawnIO fehlt)"
        } else {
            $parts += "CPU -"
        }
        $gpuCore = @($temps | Where-Object { $_.HardwareType -like "Gpu*" -and $_.SensorName -notmatch "(?i)hot\s*spot|memory|junction" } | ForEach-Object { $_.Value } | Measure-Object -Maximum)
        $gpuHot = @($temps | Where-Object { $_.HardwareType -like "Gpu*" -and $_.SensorName -match "(?i)hot\s*spot|junction" } | ForEach-Object { $_.Value } | Measure-Object -Maximum)
        if ($gpuCore.Count -gt 0 -and $gpuCore[0].Count -gt 0) {
            $gpuText = "GPU $([math]::Round($gpuCore[0].Maximum))$deg"
            if ($gpuHot.Count -gt 0 -and $gpuHot[0].Count -gt 0) { $gpuText = "$gpuText (Hotspot $([math]::Round($gpuHot[0].Maximum))$deg)" }
            $parts += $gpuText
        }
        $vrm = @($temps | Where-Object { $_.HardwareType -eq "Motherboard" -or $_.HardwareType -eq "SuperIO" } | Where-Object { $_.SensorName -match "(?i)vrm|mos" } | ForEach-Object { $_.Value } | Measure-Object -Maximum)
        if ($vrm.Count -gt 0 -and $vrm[0].Count -gt 0) { $parts += "VRM $([math]::Round($vrm[0].Maximum))$deg" }
    }
    $diskText = Get-HsDiskTemperatureText
    if ($diskText) { $parts += $diskText }
    $line = if ($parts.Count -gt 0) { "Temperaturen: " + ($parts -join " | ") } else { "" }
    $script:HsTemperatureCache.Line = $line
    return $line
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

    foreach ($key in $keys) {
        $keyIndex++
        $script:HsOverallStatus = "Komponente $keyIndex von $($keys.Count)"

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
                    $r = Invoke-HsRamVerification -ConfigPath $ConfigPath -ToolCacheRoot $ToolCacheRoot -OutputDirectory $StageDirs.Ram `
                        -Passes $StageProfile.RamPasses -PercentOfPhysicalRam $StageProfile.RamPercentOfPhysical `
                        -DurationSeconds $ramSeconds -NoDownload:$NoDownload `
                        -CancelCheck { Test-HsThermalAbortOrCancel -StageName "RAM" } -ProgressLabel "RAM$StageSuffix (MemoryChecker)"
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
                $stage.Coverage = "$($r.Iterations) sustained load iteration(s)"
                $stage.PeakTemperature = $r.PeakTemperature
                Complete-HsStage $stage -Status $r.Status -Assessment $r.Reason
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
                if ($smartRunSelfTest -and $smartStage.Status -in @("PASS","WARNING")) {
                    Invoke-HsStageWrapper -StageName "STORAGE_SMART_SELFTEST" -Component "Storage SMART Self-Test ($($smartDisk.DeviceId))$StageSuffix" -Tool "smartctl" -Action {
                        param($innerStage)
                        $selfTest = Start-HsSmartSelfTest -ConfigPath $ConfigPath -ToolCacheRoot $ToolCacheRoot -DriveIndex $smartIndex `
                            -TestType $StageProfile.SmartSelfTest -NoDownload:$NoDownload -ProgressLabel "SMART-Selbsttest $($smartDisk.DeviceId)$StageSuffix"
                        Complete-HsStage $innerStage -Status $selfTest.Status -Assessment $selfTest.Reason
                    } | Out-Null
                }
            }

            Invoke-HsStageWrapper -StageName "STORAGE_SURFACE" -Component "Storage Surface Read$StageSuffix" -Action {
                param($stage)
                $disk = @($inventory.PhysicalDisks) | Select-Object -First 1
                if (-not $disk -or -not $StageProfile.SurfaceScanEnabled) {
                    Complete-HsStage $stage -Status "SKIPPED" -Assessment "Surface scan disabled for this profile or no disk found."
                    return
                }
                $index = [int]($disk.DeviceId -replace '[^0-9]','')
                $maxBytes = if ($SurfaceScanMaxBytes -gt 0) { $SurfaceScanMaxBytes } else { $StageProfile.SurfaceScanMaxBytes }
                $maxSeconds = [int][math]::Round([double]$StageProfile.SurfaceScanMaxMinutes * 60)
                $r = Invoke-HsStorageSurfaceScan -DriveIndex $index -MaxBytes $maxBytes -MaxSeconds $maxSeconds `
                    -CancelCheck { Test-HsThermalAbortOrCancel -StageName "STORAGE_SURFACE" } -ProgressLabel "Surface-Scan $($disk.DeviceId)$StageSuffix (nur lesen)"
                $stage.Coverage = "$($disk.DeviceId) (Windows disk first): $([math]::Round($r.BytesRead/1GB,2)) / $([math]::Round($r.TotalBytes/1GB,2)) GB read"
                $stage.ErrorCount = $r.Errors.Count
                Complete-HsStage $stage -Status $r.Status -Assessment $r.Reason
            } | Out-Null

            Invoke-HsStageWrapper -StageName "STORAGE_WRITE_VERIFY" -Component "Storage Write/Read Verification$StageSuffix" -Action {
                param($stage)
                $r = Invoke-HsStorageWriteReadVerify -Directory (Join-Path $env:TEMP "PC-Diagnose_HS_WriteVerify") -SizeMB $StageProfile.StorageWriteVerifyMB `
                    -ProgressLabel "Schreib-/Lesepruefung$StageSuffix"
                $stage.Coverage = "$([math]::Round($r.BytesVerified/1MB,1)) MB written/read/verified"
                $stage.ErrorCount = $r.Mismatches
                Complete-HsStage $stage -Status $r.Status -Assessment $r.Reason
            } | Out-Null
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
                    $stage.Coverage = "$($wheaEvents.Count) WHEA event(s): $($categories -join ', ')"
                    Complete-HsStage $stage -Status "WARNING" -Assessment $assessment
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
                $ramLoad = Start-HsRamBackgroundLoad -ConfigPath $ConfigPath -ToolCacheRoot $ToolCacheRoot -OutputDirectory $StageDirs.Ram `
                    -PercentOfPhysicalRam $StageProfile.SystemStabilityRamPercent -NoDownload:$NoDownload
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
                }
                $gpuResult = Receive-Job -Job $gpuJob -Wait -AutoRemoveJob | Select-Object -Last 1

                $stage.Coverage = "CPU: $($cpuResult.Workers) worker(s); GPU: $($gpuResult.Iterations) iteration(s); RAM: $($StageProfile.SystemStabilityRamPercent)% continuous, $($ramResult.Passes) complete pass(es)"
                $partsText = "CPU: $($cpuResult.Status), GPU: $($gpuResult.Status), RAM: $($ramResult.Status)"
                if ($cpuResult.Status -eq "FAIL" -or $gpuResult.Status -eq "FAIL" -or $ramResult.Status -eq "FAIL") {
                    $ramDetail = if ($ramResult.Status -eq "FAIL") { " RAM: $($ramResult.Reason)" } else { "" }
                    Complete-HsStage $stage -Status "FAIL" -Assessment "Combined CPU+GPU+RAM activity produced a verified error ($partsText). Individual components may still pass in isolation; under combined load the power supply, VRM, memory controller and mainboard become more suspect.$ramDetail"
                } elseif ($gpuResult.DeviceLost) {
                    Complete-HsStage $stage -Status "FAIL" -Assessment "GPU device was lost during combined system activity ($partsText)."
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

    Write-Host ""
    Write-Host "Wie lange soll jede gewaehlte Komponente getestet werden?" -ForegroundColor Cyan
    Write-Host "  [1] Kurz   - 10 Minuten"
    Write-Host "  [2] Mittel - 30 Minuten"
    Write-Host "  [3] Lang   - 60 Minuten"
    Write-Host "  [4] Eigene Dauer in Minuten"
    Write-Host "  Datentraeger: Surface-Scan der Windows-Platte fuer diese Dauer plus Schreib-/Lesepruefung." -ForegroundColor DarkGray
    $durationChoice = Read-HsChoice -Prompt "Auswahl [1-4, Enter = 1]" -Allowed @("1","2","3","4") -Default "1"
    $minutes = switch ($durationChoice) { "1" { 10 } "2" { 30 } "3" { 60 } default { 0 } }
    while ($minutes -le 0) {
        $custom = ([string](Read-Host "Minuten (1-600)")).Trim()
        $parsed = 0
        if ([int]::TryParse($custom, [ref]$parsed) -and $parsed -ge 1 -and $parsed -le 600) { $minutes = $parsed }
        else { Write-Host "  Bitte eine ganze Zahl von 1 bis 600 eingeben." -ForegroundColor Yellow }
    }
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
    } elseif ($noticeable.Count -gt 0 -and (Test-HsInteractiveConsole)) {
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
