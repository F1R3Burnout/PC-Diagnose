Set-StrictMode -Version 2.0

function Test-HsThermalState {
    <#
    .SYNOPSIS
        Evaluates telemetry rows against the configured thermal thresholds
        (spec section 26) and returns "OK", "WARNING", or "ABORT" plus the
        sensor(s) responsible.
    #>
    param(
        [AllowNull()][object[]]$Rows,
        [Parameter(Mandatory=$true)]$Thresholds
    )
    # Defense in depth: a $null here (e.g. telemetry unavailable) must be
    # treated as "no data", not a caller error - an empty array returned
    # from a function collapses to $null at the call site under PowerShell's
    # pipeline unwrapping, which broke every stage checking the thermal
    # guard until this was caught (see docs/HARDWARE_STABILITY_STATE.md).
    if ($null -eq $Rows) { $Rows = @() }

    $result = [pscustomobject]@{
        State  = "OK"
        Reason = ""
        Value  = $null
    }

    # Sensor classes. GPU names differ by vendor and LibreHardwareMonitor
    # version: AMD reports "GPU Hot Spot" (with a space) and "GPU Memory",
    # NVIDIA "GPU Hot Spot"/"GPU Memory Junction". The hotspot used to be
    # matched as "hotspot" only, so an AMD hotspot of 99 C (normal under
    # full load, limit 110 C) was judged as GPU CORE against 95 C and aborted
    # the GPU stage after 4 s on a real RX 6700. Motherboard sensors come
    # from the Super I/O chip (HardwareType "SuperIO"), so VRM limits were
    # never applied before either.
    $gpuHotspotPattern = '(?i)hot\s*spot|junction'
    $gpuMemoryPattern = '(?i)memory|vram|mem\b'
    $checks = @(
        @{ Match = { param($r) $r.HardwareType -eq "Cpu" -and $r.SensorType -eq "Temperature" }; Warning = $Thresholds.CpuWarning; Abort = $Thresholds.CpuAbort; Label = "CPU" }
        @{ Match = { param($r) $r.HardwareType -like "Gpu*" -and $r.SensorType -eq "Temperature" -and $r.SensorName -notmatch $gpuHotspotPattern -and $r.SensorName -notmatch $gpuMemoryPattern }; Warning = $Thresholds.GpuCoreWarning; Abort = $Thresholds.GpuCoreAbort; Label = "GPU Core" }
        @{ Match = { param($r) $r.HardwareType -like "Gpu*" -and $r.SensorType -eq "Temperature" -and $r.SensorName -match $gpuMemoryPattern }; Warning = $Thresholds.GpuMemoryWarning; Abort = $Thresholds.GpuMemoryAbort; Label = "GPU Memory" }
        @{ Match = { param($r) $r.HardwareType -like "Gpu*" -and $r.SensorType -eq "Temperature" -and $r.SensorName -match $gpuHotspotPattern -and $r.SensorName -notmatch $gpuMemoryPattern }; Warning = $Thresholds.GpuHotspotWarning; Abort = $Thresholds.GpuHotspotAbort; Label = "GPU Hotspot" }
        @{ Match = { param($r) $r.HardwareType -eq "Storage" -and $r.SensorType -eq "Temperature" }; Warning = $Thresholds.NvmeWarning; Abort = $Thresholds.NvmeAbort; Label = "Storage" }
        @{ Match = { param($r) $r.HardwareType -in @("Motherboard","SuperIO") -and $r.SensorType -eq "Temperature" -and $r.SensorName -match "(?i)vrm|mos" }; Warning = $Thresholds.VrmWarning; Abort = $Thresholds.VrmAbort; Label = "VRM" }
    )

    foreach ($check in $checks) {
        # The explicit $null -ne $_ guard is a deliberate final safety net:
        # this exact class of bug (a $null element ending up inside what
        # should be a clean array, from "$array += <function call that
        # returned nothing>" elsewhere) has bitten this project more than
        # once - see the Get-HsHardwareSensorRows fix in Telemetry.psm1.
        $matching = @($Rows | Where-Object { $null -ne $_ -and (& $check.Match $_) })
        foreach ($row in $matching) {
            if ($row.Value -ge $check.Abort) {
                $result.State = "ABORT"
                $result.Reason = "$($check.Label) ($($row.SensorName)) reached $($row.Value) C (abort threshold $($check.Abort) C)"
                $result.Value = $row.Value
                return $result
            }
            if ($row.Value -ge $check.Warning -and $result.State -ne "ABORT") {
                $result.State = "WARNING"
                $result.Reason = "$($check.Label) ($($row.SensorName)) reached $($row.Value) C (warning threshold $($check.Warning) C)"
                $result.Value = $row.Value
            }
        }
    }

    return $result
}

Export-ModuleMember -Function * -Variable *
