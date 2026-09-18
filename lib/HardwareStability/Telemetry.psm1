Set-StrictMode -Version 2.0

$moduleDir = $PSScriptRoot
Import-Module (Join-Path $moduleDir "ToolManager.psm1") -Force

$script:HsComputer = $null
$script:HsTelemetryAvailable = $false

function Initialize-HsTelemetry {
    <#
    .SYNOPSIS
        Loads LibreHardwareMonitorLib and opens CPU/GPU/Motherboard sensors.

    .DESCRIPTION
        Storage and RAM-SPD hardware groups are intentionally left disabled:
        LibreHardwareMonitor's optional NuGet dependencies for those groups
        (DiskInfoToolkit, RAMSPDToolkit-NDD) are not vendored by this project,
        and calling Computer.Open() with those groups enabled throws before
        any hardware is enumerated at all (verified during implementation -
        see docs/HARDWARE_STABILITY_STATE.md). Storage temperature is instead
        read directly from smartctl in StorageTests.psm1, which is the more
        authoritative source for drive temperature anyway. Returns $false
        (not a terminating error) if the library cannot be loaded so callers
        degrade to "no telemetry available" rather than aborting the run.
    #>
    param(
        [Parameter(Mandatory=$true)][string]$ConfigPath,
        [Parameter(Mandatory=$true)][string]$ToolCacheRoot,
        [switch]$NoDownload
    )

    if ($script:HsTelemetryAvailable) { return $true }

    try {
        $cfg = Get-HsToolConfig -ConfigPath $ConfigPath
        $resolved = Resolve-HsTool -ToolId "librehardwaremonitor" -ToolConfig $cfg -ToolCacheRoot $ToolCacheRoot -NoDownload:$NoDownload
        if (-not $resolved.Available) {
            Write-Warning "Telemetry unavailable: $($resolved.Reason)"
            return $false
        }

        if (-not ("LibreHardwareMonitor.Hardware.Computer" -as [type])) {
            Add-Type -Path $resolved.ExecutablePath -ErrorAction Stop
        }

        $computer = New-Object LibreHardwareMonitor.Hardware.Computer
        $computer.IsCpuEnabled = $true
        $computer.IsGpuEnabled = $true
        $computer.IsMotherboardEnabled = $true
        $computer.IsMemoryEnabled = $false
        $computer.IsStorageEnabled = $false
        $computer.IsNetworkEnabled = $false
        $computer.IsControllerEnabled = $false

        try {
            $computer.Open()
        } catch {
            # Best-effort: some hardware groups may already be populated even
            # if Open() threw for an unrelated optional dependency.
            Write-Warning "LibreHardwareMonitor Open() reported an error (continuing with whatever hardware was already detected): $($_.Exception.Message)"
        }

        if ($computer.Hardware.Count -eq 0) {
            return $false
        }

        $script:HsComputer = $computer
        $script:HsTelemetryAvailable = $true
        return $true
    } catch {
        Write-Warning "Telemetry initialization failed: $($_.Exception.Message)"
        return $false
    }
}

function Get-HsTelemetrySample {
    <#
    .SYNOPSIS
        Returns one telemetry row per currently available sensor value.
        Only sensors that actually report a value are included - nothing is
        synthesized (spec section 24/25).
    #>
    param([Parameter(Mandatory=$true)][string]$Stage)

    $rows = @()
    # The leading comma forces PowerShell to return this AS an array, even
    # when it is empty: "return $rows" on an empty array is otherwise
    # unwrapped to $null by the pipeline, which then fails to bind to a
    # downstream [object[]] Mandatory parameter (observed for real: this
    # collapsed to $null whenever telemetry was unavailable, breaking every
    # stage that checked the thermal guard - see
    # docs/HARDWARE_STABILITY_STATE.md).
    if (-not $script:HsTelemetryAvailable -or $null -eq $script:HsComputer) { return ,$rows }

    $timestamp = Get-Date
    foreach ($hw in $script:HsComputer.Hardware) {
        try { $hw.Update() } catch { continue }
        $rows += Get-HsHardwareSensorRows -Hardware $hw -Stage $Stage -Timestamp $timestamp
        foreach ($sub in $hw.SubHardware) {
            try { $sub.Update() } catch { continue }
            $rows += Get-HsHardwareSensorRows -Hardware $sub -Stage $Stage -Timestamp $timestamp
        }
    }
    return ,$rows
}

function Get-HsHardwareSensorRows {
    param($Hardware, [string]$Stage, [datetime]$Timestamp)
    $rows = @()
    foreach ($sensor in $Hardware.Sensors) {
        if ($null -eq $sensor.Value) { continue }
        $rows += [pscustomobject]@{
            Timestamp    = $Timestamp.ToString("yyyy-MM-dd HH:mm:ss.fff")
            Stage        = $Stage
            HardwareType = [string]$Hardware.HardwareType
            HardwareName = [string]$Hardware.Name
            SensorType   = [string]$sensor.SensorType
            SensorName   = [string]$sensor.Name
            Value        = [math]::Round([double]$sensor.Value, 2)
        }
    }
    return $rows
}

function Get-HsPeakTemperature {
    <#
        Returns the highest Temperature-type sensor value seen across the
        given telemetry rows, or $null if none were captured.
    #>
    param([object[]]$Rows)
    $temps = @($Rows | Where-Object { $_.SensorType -eq "Temperature" } | Select-Object -ExpandProperty Value)
    if ($temps.Count -eq 0) { return $null }
    return ($temps | Measure-Object -Maximum).Maximum
}

function Close-HsTelemetry {
    if ($script:HsComputer) {
        try { $script:HsComputer.Close() } catch {}
    }
    $script:HsComputer = $null
    $script:HsTelemetryAvailable = $false
}

Export-ModuleMember -Function * -Variable *
