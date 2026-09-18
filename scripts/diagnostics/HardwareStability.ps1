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
    Quick, Standard, or Extended. Controls pass counts, data volume, and
    coverage - not just runtime (spec section 9).

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
#>

[CmdletBinding()]
param(
    [ValidateSet("Quick","Standard","Extended")]
    [string]$Profile = "Quick",

    [string]$Components = "CPU,Cache,RAM,GPU,VRAM,Storage,PCIe,System",

    [string]$OutputRoot = "C:\Temp",

    [switch]$NoDownload,
    [switch]$SkipTelemetry,
    [switch]$Resume,
    [switch]$DryRun,
    [long]$SurfaceScanMaxBytes = 0,

    [string]$ModuleRootOverride = "",
    [string]$ConfigPathOverride = ""
)

$ErrorActionPreference = "Stop"
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

$profileConfig = Get-HsProfile -Name $Profile
$thermalDefaults = Get-HsThermalDefaults
$selectedComponents = @($Components -split "," | ForEach-Object { $_.Trim() } | Where-Object { $_ })

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
    if ($SkipTelemetry) { return @() }
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

Write-Progress2 "$ToolName $ToolVersion - profile $Profile" "Cyan"
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
    Write-Host "Profile '$Profile':" -ForegroundColor Cyan
    $profileConfig | Format-List | Out-String | Write-Host
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
    $choice = Read-Host "Select"
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
} else {
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

# ---------------------------------------------------------------------------
# CPU
# ---------------------------------------------------------------------------

if ($selectedComponents -contains "CPU") {
    Invoke-HsStageWrapper -StageName "CPU_COMPUTE" -Component "CPU Compute" -Tool "Prime95" -Action {
        param($stage)
        $cpuCount = (@($inventory.Cpus)[0])
        $r = Invoke-HsCpuTortureTest -StageName "CPU_COMPUTE" -ConfigPath $ConfigPath -ToolCacheRoot $ToolCacheRoot `
            -OutputDirectory $Dirs.Cpu -DurationMinutes $profileConfig.CpuComputeMinutes `
            -LogicalProcessors ([int]$cpuCount.LogicalProcessors) -PhysicalCores ([int]$cpuCount.Cores) `
            -NoDownload:$NoDownload -TelemetrySample { param($s) Get-HsTelemetrySampleForStage -StageName $s } `
            -CancelCheck { Test-HsThermalAbortOrCancel -StageName "CPU_COMPUTE" }
        $stage.Tool = $r.Tool; $stage.ToolVersion = $r.ToolVersion; $stage.Command = $r.Command
        $stage.Coverage = "$($r.Workers) worker(s), $([math]::Round($r.DurationSeconds/60,1)) minute(s)"
        $stage.PeakTemperature = $r.PeakTemperature
        $stage.ErrorCount = $r.FailurePatterns.Count
        Complete-HsStage $stage -Status $r.Status -Assessment $r.Reason
    }
}

if ($selectedComponents -contains "Cache") {
    Invoke-HsStageWrapper -StageName "CPU_CACHE_IMC" -Component "CPU Cache / IMC" -Tool "Prime95" -Action {
        param($stage)
        $cpuCount = (@($inventory.Cpus)[0])
        $r = Invoke-HsCpuTortureTest -StageName "CPU_CACHE_IMC" -ConfigPath $ConfigPath -ToolCacheRoot $ToolCacheRoot `
            -OutputDirectory $Dirs.Cpu -DurationMinutes $profileConfig.CpuCacheImcMinutes `
            -LogicalProcessors ([int]$cpuCount.LogicalProcessors) -PhysicalCores ([int]$cpuCount.Cores) `
            -NoDownload:$NoDownload -TelemetrySample { param($s) Get-HsTelemetrySampleForStage -StageName $s } `
            -CancelCheck { Test-HsThermalAbortOrCancel -StageName "CPU_CACHE_IMC" }
        $stage.Tool = $r.Tool; $stage.ToolVersion = $r.ToolVersion; $stage.Command = $r.Command
        $stage.Coverage = "$($r.Workers) worker(s) (all logical processors), $([math]::Round($r.DurationSeconds/60,1)) minute(s)"
        $stage.PeakTemperature = $r.PeakTemperature
        $stage.ErrorCount = $r.FailurePatterns.Count
        Complete-HsStage $stage -Status $r.Status -Assessment $r.Reason
    }
}

# ---------------------------------------------------------------------------
# RAM
# ---------------------------------------------------------------------------

if ($selectedComponents -contains "RAM") {
    Invoke-HsStageWrapper -StageName "RAM" -Component "RAM" -Tool "MemoryChecker" -Action {
        param($stage)
        $r = Invoke-HsRamVerification -ConfigPath $ConfigPath -ToolCacheRoot $ToolCacheRoot -OutputDirectory $Dirs.Ram `
            -Passes $profileConfig.RamPasses -PercentOfPhysicalRam $profileConfig.RamPercentOfPhysical `
            -CancelCheck { Test-HsThermalAbortOrCancel -StageName "RAM" }
        $stage.Tool = $r.Tool; $stage.ToolVersion = $r.ToolVersion; $stage.Command = $r.Command
        $stage.Coverage = "$($r.TargetPercent)% of physical RAM, $($r.Passes) pass(es)"
        $stage.ExitCode = $r.ExitCode
        Complete-HsStage $stage -Status $r.Status -Assessment $r.Reason
    }
}

# ---------------------------------------------------------------------------
# GPU / VRAM
# ---------------------------------------------------------------------------

if ($selectedComponents -contains "GPU") {
    Invoke-HsStageWrapper -StageName "GPU_COMPUTE" -Component "GPU Compute" -Action {
        param($stage)
        $r = Invoke-HsGpuComputeVerification -ElementCount $profileConfig.GpuComputeWorkgroups -Iterations ([math]::Max(1,[int]($profileConfig.GpuComputeIterations/100)))
        $stage.Coverage = "$($r.ElementsVerified) integer operation(s), $($r.Iterations) iteration(s)"
        $stage.ErrorCount = $r.Mismatches
        Complete-HsStage $stage -Status $r.Status -Assessment $r.Reason
    }
}

if ($selectedComponents -contains "VRAM") {
    Invoke-HsStageWrapper -StageName "VRAM" -Component "VRAM" -Tool "memtest_vulkan" -Action {
        param($stage)
        $r = Invoke-HsVramVerification -ConfigPath $ConfigPath -ToolCacheRoot $ToolCacheRoot -OutputDirectory $Dirs.Gpu `
            -DurationMinutes $profileConfig.VramTestMinutes -NoDownload:$NoDownload
        $stage.ToolVersion = $r.ToolVersion
        $stage.Coverage = "$([math]::Round($r.DurationSeconds/60,1)) minute(s)"
        Complete-HsStage $stage -Status $r.Status -Assessment $r.Reason
    }

    Invoke-HsStageWrapper -StageName "GPU_LOAD_THERMAL" -Component "GPU Load / Thermal Validation" -Action {
        param($stage)
        $r = Invoke-HsGpuLoadThermalValidation -DurationSeconds ($profileConfig.VramTestMinutes * 60 / 3) `
            -TelemetrySample { param($s) Get-HsTelemetrySampleForStage -StageName $s } `
            -CancelCheck { Test-HsThermalAbortOrCancel -StageName "GPU_LOAD_THERMAL" }
        $stage.Coverage = "$($r.Iterations) sustained load iteration(s)"
        $stage.PeakTemperature = $r.PeakTemperature
        Complete-HsStage $stage -Status $r.Status -Assessment $r.Reason
    }
}

# ---------------------------------------------------------------------------
# Storage
# ---------------------------------------------------------------------------

if ($selectedComponents -contains "Storage") {
    Invoke-HsStageWrapper -StageName "STORAGE_SMART" -Component "Storage SMART" -Tool "smartctl" -Action {
        param($stage)
        $disk = @($inventory.PhysicalDisks) | Select-Object -First 1
        if (-not $disk) { Complete-HsStage $stage -Status "SKIPPED" -Assessment "No physical disk found."; return }
        $index = [int]($disk.DeviceId -replace '[^0-9]','')
        $r = Invoke-HsSmartQuery -ConfigPath $ConfigPath -ToolCacheRoot $ToolCacheRoot -DriveIndex $index -OutputDirectory $Dirs.Storage -NoDownload:$NoDownload
        $stage.ToolVersion = $r.ToolVersion
        $stage.LogPaths = @($r.RawOutputPath)
        Complete-HsStage $stage -Status $r.Status -Assessment $r.Reason

        if ($r.Status -in @("PASS","WARNING")) {
            $selfTest = Start-HsSmartSelfTest -ConfigPath $ConfigPath -ToolCacheRoot $ToolCacheRoot -DriveIndex $index `
                -TestType $profileConfig.SmartSelfTest -NoDownload:$NoDownload
            Invoke-HsStageWrapper -StageName "STORAGE_SMART_SELFTEST" -Component "Storage SMART Self-Test" -Tool "smartctl" -Action {
                param($innerStage)
                Complete-HsStage $innerStage -Status $selfTest.Status -Assessment $selfTest.Reason
            } | Out-Null
        }
    }

    Invoke-HsStageWrapper -StageName "STORAGE_SURFACE" -Component "Storage Surface Read" -Action {
        param($stage)
        $disk = @($inventory.PhysicalDisks) | Select-Object -First 1
        if (-not $disk -or -not $profileConfig.SurfaceScanEnabled) {
            Complete-HsStage $stage -Status "SKIPPED" -Assessment "Surface scan disabled for this profile or no disk found."
            return
        }
        $index = [int]($disk.DeviceId -replace '[^0-9]','')
        $maxBytes = if ($SurfaceScanMaxBytes -gt 0) { $SurfaceScanMaxBytes } else { $profileConfig.SurfaceScanMaxBytes }
        $r = Invoke-HsStorageSurfaceScan -DriveIndex $index -MaxBytes $maxBytes -CancelCheck { Test-HsThermalAbortOrCancel -StageName "STORAGE_SURFACE" }
        $stage.Coverage = "$([math]::Round($r.BytesRead/1GB,2)) / $([math]::Round($r.TotalBytes/1GB,2)) GB read"
        $stage.ErrorCount = $r.Errors.Count
        Complete-HsStage $stage -Status $r.Status -Assessment $r.Reason
    }

    Invoke-HsStageWrapper -StageName "STORAGE_WRITE_VERIFY" -Component "Storage Write/Read Verification" -Action {
        param($stage)
        $r = Invoke-HsStorageWriteReadVerify -Directory (Join-Path $env:TEMP "PC-Diagnose_HS_WriteVerify") -SizeMB $profileConfig.StorageWriteVerifyMB
        $stage.Coverage = "$([math]::Round($r.BytesVerified/1MB,1)) MB written/read/verified"
        $stage.ErrorCount = $r.Mismatches
        Complete-HsStage $stage -Status $r.Status -Assessment $r.Reason
    }
}

# ---------------------------------------------------------------------------
# PCIe / WHEA
# ---------------------------------------------------------------------------

if ($selectedComponents -contains "PCIe") {
    Invoke-HsStageWrapper -StageName "PCIE_WHEA" -Component "PCIe / WHEA" -Action {
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
    }
}

# ---------------------------------------------------------------------------
# System stability (combined)
# ---------------------------------------------------------------------------

if ($selectedComponents -contains "System") {
    Invoke-HsStageWrapper -StageName "SYSTEM_STABILITY" -Component "System Stability" -Action {
        param($stage)
        $cpuCount = (@($inventory.Cpus)[0])
        $durationSeconds = $profileConfig.SystemStabilityMinutes * 60
        $deadline = [datetime]::Now.AddSeconds($durationSeconds)
        $gpuJob = Start-Job -ScriptBlock {
            param($moduleRoot, $seconds)
            Import-Module (Join-Path $moduleRoot "GpuTests.psm1") -Force
            Invoke-HsGpuLoadThermalValidation -DurationSeconds $seconds
        } -ArgumentList $ModuleRoot, $durationSeconds

        $cpuResult = Invoke-HsCpuTortureTest -StageName "CPU_COMPUTE" -ConfigPath $ConfigPath -ToolCacheRoot $ToolCacheRoot `
            -OutputDirectory $Dirs.Cpu -DurationMinutes $profileConfig.SystemStabilityMinutes `
            -LogicalProcessors ([int]$cpuCount.LogicalProcessors) -PhysicalCores ([int]$cpuCount.Cores) `
            -NoDownload:$NoDownload -CancelCheck { Test-HsThermalAbortOrCancel -StageName "SYSTEM_STABILITY" }

        $gpuResult = Receive-Job -Job $gpuJob -Wait -AutoRemoveJob

        $stage.Coverage = "CPU: $($cpuResult.Workers) worker(s); GPU: $($gpuResult.Iterations) iteration(s)"
        if ($cpuResult.Status -eq "FAIL" -or $gpuResult.Status -eq "FAIL") {
            Complete-HsStage $stage -Status "FAIL" -Assessment "Combined CPU+GPU activity produced a verified error (CPU: $($cpuResult.Status), GPU: $($gpuResult.Status)). Individual components may still pass in isolation."
        } elseif ($gpuResult.DeviceLost) {
            Complete-HsStage $stage -Status "FAIL" -Assessment "GPU device was lost during combined system activity."
        } else {
            Complete-HsStage $stage -Status "PASS" -Assessment "CPU and GPU workloads ran concurrently for $($profileConfig.SystemStabilityMinutes) minute(s) with no verified errors."
        }
    }
}

# ---------------------------------------------------------------------------
# System-Reset check for THIS run and reporting
# ---------------------------------------------------------------------------

$systemResetInfo = [pscustomobject]@{ Classification = "NONE"; Notes = "" }

Unregister-Event -SourceIdentifier $engineExitAction.Name -ErrorAction SilentlyContinue

$html = New-HsHtmlReport -Stages @($script:HsStages) -Inventory $inventory -Profile $Profile -RunId $RunId -SystemResetInfo $systemResetInfo
[IO.File]::WriteAllText((Join-Path $Out "00_Result.html"), $html, [Text.UTF8Encoding]::new($false))
(New-HsSummaryText -Stages @($script:HsStages)) | Out-File (Join-Path $Out "00_Summary.txt") -Encoding UTF8
Export-HsStagesCsv -Stages @($script:HsStages) -Path (Join-Path $Out "00_TestStages.csv")

@"
Hardware-Stabilitaetstest result package for $($inventory.ComputerName)

This is a verification-first hardware stability test, not only a stress
test: known data/computation is processed by the hardware, read back, and
compared against the expected result.

PASS means: within the range actually tested, no errors were detected.
It does not guarantee the hardware is completely free of defects.
"@ | Out-File (Join-Path $Out "README.txt") -Encoding UTF8

Close-HsTelemetry
New-HsResultZip -SourceDirectory $Out -ZipPath "$Out.zip"

Write-Host ""
Write-Host "Overall: $(Get-HsOverallStatus -Stages @($script:HsStages))" -ForegroundColor Cyan
Write-Host "Result folder: $Out"
Write-Host "Result package: $Out.zip"

try {
    Start-Process (Join-Path $Out "00_Result.html")
} catch {}
