Set-StrictMode -Version 2.0

function Test-HsThermalState {
    <#
    .SYNOPSIS
        Evaluates telemetry rows against the configured thermal thresholds
        (spec section 26) and returns "OK", "WARNING", or "ABORT" plus the
        sensor(s) responsible.
    #>
    param(
        [Parameter(Mandatory=$true)][object[]]$Rows,
        [Parameter(Mandatory=$true)]$Thresholds
    )

    $result = [pscustomobject]@{
        State  = "OK"
        Reason = ""
        Value  = $null
    }

    $checks = @(
        @{ Match = { param($r) $r.HardwareType -eq "Cpu" -and $r.SensorType -eq "Temperature" }; Warning = $Thresholds.CpuWarning; Abort = $Thresholds.CpuAbort; Label = "CPU" }
        @{ Match = { param($r) $r.HardwareType -like "Gpu*" -and $r.SensorType -eq "Temperature" -and $r.SensorName -notmatch "(?i)hotspot" }; Warning = $Thresholds.GpuCoreWarning; Abort = $Thresholds.GpuCoreAbort; Label = "GPU Core" }
        @{ Match = { param($r) $r.HardwareType -like "Gpu*" -and $r.SensorType -eq "Temperature" -and $r.SensorName -match "(?i)hotspot" }; Warning = $Thresholds.GpuHotspotWarning; Abort = $Thresholds.GpuHotspotAbort; Label = "GPU Hotspot" }
        @{ Match = { param($r) $r.HardwareType -eq "Storage" -and $r.SensorType -eq "Temperature" }; Warning = $Thresholds.NvmeWarning; Abort = $Thresholds.NvmeAbort; Label = "Storage" }
        @{ Match = { param($r) $r.HardwareType -eq "Motherboard" -and $r.SensorType -eq "Temperature" -and $r.SensorName -match "(?i)vrm" }; Warning = $Thresholds.VrmWarning; Abort = $Thresholds.VrmAbort; Label = "VRM" }
    )

    foreach ($check in $checks) {
        $matching = @($Rows | Where-Object { & $check.Match $_ })
        foreach ($row in $matching) {
            if ($row.Value -ge $check.Abort) {
                $result.State = "ABORT"
                $result.Reason = "$($check.Label) reached $($row.Value) C (abort threshold $($check.Abort) C)"
                $result.Value = $row.Value
                return $result
            }
            if ($row.Value -ge $check.Warning -and $result.State -ne "ABORT") {
                $result.State = "WARNING"
                $result.Reason = "$($check.Label) reached $($row.Value) C (warning threshold $($check.Warning) C)"
                $result.Value = $row.Value
            }
        }
    }

    return $result
}

Export-ModuleMember -Function * -Variable *
