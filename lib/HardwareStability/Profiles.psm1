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
            DisplayName                = "Kurz"
            Description                = "Kurze sinnvolle Verifikation aller verfuegbaren Kernkomponenten."
            RamPasses                  = 4
            RamPercentOfPhysical       = 50
            CpuComputeMinutes          = 5
            CpuCacheImcMinutes         = 5
            CpuFftMode                 = "Smallest"
            GpuComputeIterations       = 50
            GpuComputeWorkgroups       = 256
            VramTestMinutes            = 6
            GpuLoadMinutes             = 2
            RamDurationMinutes         = 0 # 0 = run RamPasses; >0 = continuous for this long (retests)
            SystemStabilityRamPercent  = 40
            SurfaceScanEnabled         = $false
            SurfaceScanMaxBytes        = 2GB
            SurfaceScanMaxMinutes      = 0 # >0 = time-limited scan (retests)
            StorageWriteVerifyMB       = 256
            SmartSelfTest              = "Short"
            SystemStabilityMinutes     = 5
            IdleBaselineSeconds        = 20
            TelemetryIntervalSeconds   = 2
        }
        Standard = [pscustomobject]@{
            Name                       = "Standard"
            DisplayName                = "Mittel"
            Description                = "Gruendlicher Stabilitaetstest inklusive Storage Surface Read."
            RamPasses                  = 8
            RamPercentOfPhysical       = 75
            CpuComputeMinutes          = 20
            CpuCacheImcMinutes         = 20
            CpuFftMode                 = "Small"
            GpuComputeIterations       = 500
            GpuComputeWorkgroups       = 1024
            VramTestMinutes            = 15
            GpuLoadMinutes             = 5
            RamDurationMinutes         = 0 # 0 = run RamPasses; >0 = continuous for this long (retests)
            SystemStabilityRamPercent  = 50
            SurfaceScanEnabled         = $true
            SurfaceScanMaxBytes        = 0 # 0 = full drive
            SurfaceScanMaxMinutes      = 0 # >0 = time-limited scan (retests)
            StorageWriteVerifyMB       = 1024
            SmartSelfTest              = "Short"
            SystemStabilityMinutes     = 15
            IdleBaselineSeconds        = 30
            TelemetryIntervalSeconds   = 2
        }
        Extended = [pscustomobject]@{
            Name                       = "Extended"
            DisplayName                = "Lang"
            Description                = "Mehr Passes, laengere Berechnungen, volle Coverage, Extended SMART Self-Test."
            RamPasses                  = 16
            RamPercentOfPhysical       = 85
            CpuComputeMinutes          = 60
            CpuCacheImcMinutes         = 60
            CpuFftMode                 = "Large"
            GpuComputeIterations       = 5000
            GpuComputeWorkgroups       = 2048
            VramTestMinutes            = 45
            GpuLoadMinutes             = 15
            RamDurationMinutes         = 0 # 0 = run RamPasses; >0 = continuous for this long (retests)
            SystemStabilityRamPercent  = 60
            SurfaceScanEnabled         = $true
            SurfaceScanMaxBytes        = 0
            SurfaceScanMaxMinutes      = 0 # >0 = time-limited scan (retests)
            StorageWriteVerifyMB       = 4096
            SmartSelfTest              = "Extended"
            SystemStabilityMinutes     = 30
            IdleBaselineSeconds        = 60
            TelemetryIntervalSeconds   = 1
        }
    }

    return $profiles[$Name]
}

function Get-HsProfileChoice {
    <#
        The three choices offered when the hardware test starts without an
        explicit -Profile. "Kurz/Mittel/Lang" differ in duration AND
        intensity (RAM share and passes, GPU workload size, data volume,
        surface scan, SMART self-test type) - see the profile table above.
    #>
    return @(
        [pscustomobject]@{ Key = "1"; Name = "Quick";    Label = "Kurz";   Summary = "je 5 Min. CPU/Cache, RAM 50% x4, Datei 256 MB, kein Surface-Scan" }
        [pscustomobject]@{ Key = "2"; Name = "Standard"; Label = "Mittel"; Summary = "je 20 Min. CPU/Cache, RAM 75% x8, Datei 1 GB, Surface-Scan der Windows-Platte" }
        [pscustomobject]@{ Key = "3"; Name = "Extended"; Label = "Lang";   Summary = "je 60 Min. CPU/Cache, RAM 85% x16, Datei 4 GB, voller Surface-Scan, erweiterter SMART-Test" }
    )
}

function Get-HsProfileEstimateMinutes {
    <#
        Planned minutes of the time-bound stages for the selected components.
        RAM passes, the surface scan and the SMART self-test depend on the
        hardware (RAM size, disk size/speed) and come on top.
    #>
    param([Parameter(Mandatory=$true)]$ProfileConfig, [string[]]$Components = @("CPU","Cache","RAM","GPU","VRAM","Storage","PCIe","System"))
    $minutes = 0.0
    if ($Components -contains "CPU") { $minutes += $ProfileConfig.CpuComputeMinutes }
    if ($Components -contains "Cache") { $minutes += $ProfileConfig.CpuCacheImcMinutes }
    if ($Components -contains "VRAM") { $minutes += $ProfileConfig.VramTestMinutes + $ProfileConfig.GpuLoadMinutes }
    if ($Components -contains "System") { $minutes += $ProfileConfig.SystemStabilityMinutes }
    if ($Components -contains "RAM" -and $ProfileConfig.RamDurationMinutes -gt 0) { $minutes += $ProfileConfig.RamDurationMinutes }
    return $minutes
}

function Get-HsRetestProfile {
    <#
    .SYNOPSIS
        Profile copy for a targeted retest of one or more components with a
        user-chosen duration. Every time-bound stage runs for that duration;
        RAM switches to continuous mode for the same time; storage gets a
        time-limited surface scan of the same length and a larger
        write/verify file. Data-volume settings of the base profile are kept.
    #>
    param([Parameter(Mandatory=$true)]$BaseProfile, [Parameter(Mandatory=$true)][double]$Minutes)
    $copy = [pscustomobject]@{}
    foreach ($property in $BaseProfile.PSObject.Properties) {
        $copy | Add-Member -NotePropertyName $property.Name -NotePropertyValue $property.Value
    }
    $copy.Name = "$($BaseProfile.Name)-Retest"
    $copy.CpuComputeMinutes = $Minutes
    $copy.CpuCacheImcMinutes = $Minutes
    $copy.VramTestMinutes = $Minutes
    $copy.GpuLoadMinutes = $Minutes
    $copy.SystemStabilityMinutes = $Minutes
    $copy.RamDurationMinutes = $Minutes
    $copy.SurfaceScanEnabled = $true
    $copy.SurfaceScanMaxBytes = 0
    $copy | Add-Member -NotePropertyName SurfaceScanMaxMinutes -NotePropertyValue $Minutes -Force
    $copy.StorageWriteVerifyMB = [math]::Max([int]$BaseProfile.StorageWriteVerifyMB, 1024)
    $copy.GpuComputeIterations = [math]::Max([int]$BaseProfile.GpuComputeIterations, 500)
    return $copy
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
