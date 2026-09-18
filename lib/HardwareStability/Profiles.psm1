Set-StrictMode -Version 2.0

<#
    Central profile configuration (spec section 9). Every stage reads its
    pass counts / data volumes / durations from here instead of hardcoding
    numbers across many files.
#>

function Get-HsProfile {
    param([Parameter(Mandatory=$true)][ValidateSet("Quick","Standard","Extended")][string]$Name)

    $profiles = @{
        Quick = [pscustomobject]@{
            Name                       = "Quick"
            Description                = "Kurze sinnvolle Verifikation aller verfuegbaren Kernkomponenten."
            RamPasses                  = 4
            RamPercentOfPhysical       = 50
            CpuComputeMinutes          = 5
            CpuCacheImcMinutes         = 5
            CpuFftMode                 = "Smallest"
            GpuComputeIterations       = 50
            GpuComputeWorkgroups       = 256
            VramTestMinutes            = 6
            SurfaceScanEnabled         = $false
            SurfaceScanMaxBytes        = 2GB
            StorageWriteVerifyMB       = 256
            SmartSelfTest              = "Short"
            SystemStabilityMinutes     = 5
            IdleBaselineSeconds        = 20
            TelemetryIntervalSeconds   = 2
        }
        Standard = [pscustomobject]@{
            Name                       = "Standard"
            Description                = "Gruendlicher Stabilitaetstest inklusive Storage Surface Read."
            RamPasses                  = 8
            RamPercentOfPhysical       = 75
            CpuComputeMinutes          = 20
            CpuCacheImcMinutes         = 20
            CpuFftMode                 = "Small"
            GpuComputeIterations       = 500
            GpuComputeWorkgroups       = 1024
            VramTestMinutes            = 15
            SurfaceScanEnabled         = $true
            SurfaceScanMaxBytes        = 0 # 0 = full drive
            StorageWriteVerifyMB       = 1024
            SmartSelfTest              = "Short"
            SystemStabilityMinutes     = 15
            IdleBaselineSeconds        = 30
            TelemetryIntervalSeconds   = 2
        }
        Extended = [pscustomobject]@{
            Name                       = "Extended"
            Description                = "Mehr Passes, laengere Berechnungen, volle Coverage, Extended SMART Self-Test."
            RamPasses                  = 16
            RamPercentOfPhysical       = 85
            CpuComputeMinutes          = 60
            CpuCacheImcMinutes         = 60
            CpuFftMode                 = "Large"
            GpuComputeIterations       = 5000
            GpuComputeWorkgroups       = 2048
            VramTestMinutes            = 45
            SurfaceScanEnabled         = $true
            SurfaceScanMaxBytes        = 0
            StorageWriteVerifyMB       = 4096
            SmartSelfTest              = "Extended"
            SystemStabilityMinutes     = 30
            IdleBaselineSeconds        = 60
            TelemetryIntervalSeconds   = 1
        }
    }

    return $profiles[$Name]
}

function Get-HsThermalDefaults {
    <#
        Conservative safety defaults (spec section 26). These are safety
        limits, not diagnostic thresholds - if the platform documents lower
        limits, those should be respected instead.
    #>
    return [pscustomobject]@{
        CpuWarning       = 95
        CpuAbort         = 100
        GpuCoreWarning   = 90
        GpuCoreAbort     = 95
        GpuHotspotWarning = 105
        GpuHotspotAbort   = 110
        NvmeWarning      = 80
        NvmeAbort        = 85
        VrmWarning       = 105
        VrmAbort         = 115
    }
}

Export-ModuleMember -Function * -Variable *
