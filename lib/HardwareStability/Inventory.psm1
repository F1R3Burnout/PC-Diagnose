Set-StrictMode -Version 2.0

function Get-HsUnknownOrValue {
    param([AllowNull()]$Value)
    if ($null -eq $Value -or ([string]$Value).Trim().Length -eq 0) { return "Unsupported" }
    return $Value
}

function Get-HsHardwareInventory {
    <#
    .SYNOPSIS
        Collects the hardware inventory required before running any stage
        (spec section 8). Every field is read from actual Windows/CIM data;
        nothing is invented, and unavailable values are reported as
        "Unsupported" rather than omitted silently.
    #>

    $os = $null
    $computerSystem = $null
    $bios = $null
    try { $os = Get-CimInstance Win32_OperatingSystem -ErrorAction Stop } catch {}
    try { $computerSystem = Get-CimInstance Win32_ComputerSystem -ErrorAction Stop } catch {}
    try { $bios = Get-CimInstance Win32_BIOS -ErrorAction Stop } catch {}
    $baseboard = $null
    try { $baseboard = Get-CimInstance Win32_BaseBoard -ErrorAction Stop } catch {}

    $cpus = @()
    try { $cpus = @(Get-CimInstance Win32_Processor -ErrorAction Stop) } catch {}

    $gpus = @()
    try { $gpus = @(Get-CimInstance Win32_VideoController -ErrorAction Stop) } catch {}

    $physicalMemoryModules = @()
    try { $physicalMemoryModules = @(Get-CimInstance Win32_PhysicalMemory -ErrorAction Stop) } catch {}

    $disks = @()
    try { $disks = @(Get-CimInstance Win32_DiskDrive -ErrorAction Stop) } catch {}

    $volumes = @()
    try { $volumes = @(Get-CimInstance Win32_Volume -ErrorAction Stop | Where-Object { $_.DriveLetter }) } catch {}

    $physicalDisksMsft = @()
    try { $physicalDisksMsft = @(Get-PhysicalDisk -ErrorAction Stop) } catch {}

    $powerScheme = ""
    try {
        $activeSchemeLine = (powercfg /getactivescheme) 2>$null
        if ($activeSchemeLine -match '\(([^)]+)\)\s*$') { $powerScheme = $matches[1] }
    } catch {}

    $wheaHistoryCount = 0
    try {
        $wheaHistoryCount = @(Get-WinEvent -FilterHashtable @{ LogName = "System"; ProviderName = "Microsoft-Windows-WHEA-Logger" } -MaxEvents 50 -ErrorAction Stop).Count
    } catch {}

    return [pscustomobject]@{
        ComputerName      = $env:COMPUTERNAME
        WindowsVersion    = Get-HsUnknownOrValue ($os.Caption)
        WindowsBuild      = Get-HsUnknownOrValue ($os.BuildNumber)
        BootTime          = if ($os) { $os.LastBootUpTime } else { $null }
        Bios              = Get-HsUnknownOrValue ("$($bios.Manufacturer) $($bios.SMBIOSBIOSVersion)".Trim())
        Mainboard         = Get-HsUnknownOrValue ("$($baseboard.Manufacturer) $($baseboard.Product)".Trim())
        Cpus              = @($cpus | ForEach-Object {
            [pscustomobject]@{
                Name              = Get-HsUnknownOrValue $_.Name
                LogicalProcessors = Get-HsUnknownOrValue $_.NumberOfLogicalProcessors
                Cores             = Get-HsUnknownOrValue $_.NumberOfCores
                MaxClockMHz       = Get-HsUnknownOrValue $_.MaxClockSpeed
            }
        })
        PhysicalRamBytes  = if ($computerSystem) { [int64]$computerSystem.TotalPhysicalMemory } else { $null }
        AvailableRamMB    = if ($os) { [int64]$os.FreePhysicalMemory / 1024 } else { $null }
        RamModules        = @($physicalMemoryModules | ForEach-Object {
            [pscustomobject]@{
                Capacity   = Get-HsUnknownOrValue $_.Capacity
                SpeedMHz   = Get-HsUnknownOrValue $_.Speed
                Manufacturer = Get-HsUnknownOrValue $_.Manufacturer
                PartNumber = Get-HsUnknownOrValue (([string]$_.PartNumber).Trim())
            }
        })
        Gpus              = @($gpus | ForEach-Object {
            [pscustomobject]@{
                Name         = Get-HsUnknownOrValue $_.Name
                DriverVersion = Get-HsUnknownOrValue $_.DriverVersion
                VramBytes    = if ($_.AdapterRAM -gt 0) { [int64]$_.AdapterRAM } else { $null }
            }
        })
        PhysicalDisks     = @($disks | ForEach-Object {
            $index = $_.Index
            $health = @($physicalDisksMsft | Where-Object { $_.DeviceId -eq [string]$index }) | Select-Object -First 1
            [pscustomobject]@{
                DeviceId      = "PhysicalDrive$index"
                Model         = Get-HsUnknownOrValue $_.Model
                SerialNumber  = Get-HsUnknownOrValue (([string]$_.SerialNumber).Trim())
                FirmwareRevision = Get-HsUnknownOrValue $_.FirmwareRevision
                CapacityBytes = [int64]$_.Size
                InterfaceType = Get-HsUnknownOrValue $_.InterfaceType
                BusType       = if ($health) { Get-HsUnknownOrValue $health.BusType } else { "Unsupported" }
                HealthStatus  = if ($health) { Get-HsUnknownOrValue $health.HealthStatus } else { "Unsupported" }
                OperationalStatus = if ($health) { Get-HsUnknownOrValue ($health.OperationalStatus -join ",") } else { "Unsupported" }
            }
        })
        Volumes           = @($volumes | ForEach-Object {
            [pscustomobject]@{
                DriveLetter = $_.DriveLetter
                Label       = Get-HsUnknownOrValue $_.Label
                FileSystem  = Get-HsUnknownOrValue $_.FileSystem
                CapacityBytes = [int64]$_.Capacity
                FreeSpaceBytes = [int64]$_.FreeSpace
            }
        })
        PowerScheme       = Get-HsUnknownOrValue $powerScheme
        RecentWheaEventCount = $wheaHistoryCount
    }
}

Export-ModuleMember -Function * -Variable *
