<#
.SYNOPSIS
    Interactive cleanup assistant for stale hardware traces.

.DESCRIPTION
    Finds non-present devices, driver services with missing files, and old third-party driver packages.
    Nothing is removed automatically. Destructive actions require explicit item selection and confirmation.
#>

[CmdletBinding()]
param(
    [string]$OutputRoot = "C:\Temp",
    [switch]$IncludeAdvanced
)

$ErrorActionPreference = "Continue"
$ToolName = "HardwareCleanupAssist"
$ToolVersion = "Lite v1 Review First"
$RunStarted = Get-Date

function Test-IsAdmin {
    $currentIdentity = [Security.Principal.WindowsIdentity]::GetCurrent()
    $principal = New-Object Security.Principal.WindowsPrincipal($currentIdentity)
    return $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

if (-not (Test-IsAdmin)) {
    Write-Host "ERROR: Please run this tool as Administrator." -ForegroundColor Red
    exit 1
}

$Timestamp = Get-Date -Format "yyyyMMdd_HHmmss"
$ComputerSafe = ($env:COMPUTERNAME -replace '[\\/:*?"<>| ]', '_')
$Out = Join-Path $OutputRoot "HardwareCleanupAssist_${ComputerSafe}_${Timestamp}"
New-Item -ItemType Directory -Force -Path $Out | Out-Null
$LogPath = Join-Path $Out "cleanup.log"
Start-Transcript -Path (Join-Path $Out "transcript.txt") -Force | Out-Null

function Write-Log {
    param(
        [string]$Text,
        [string]$Color = "Gray"
    )

    $line = "[{0}] {1}" -f (Get-Date -Format "HH:mm:ss"), $Text
    Write-Host $line -ForegroundColor $Color
    $line | Out-File $LogPath -Encoding UTF8 -Append
}

function Normalize-DriverPath {
    param([AllowNull()][string]$PathName)

    if ([string]::IsNullOrWhiteSpace($PathName)) { return "" }
    $candidate = ([string]$PathName).Trim()
    if ($candidate.StartsWith('"')) {
        $candidate = ($candidate -split '"')[1]
    } else {
        $candidate = ($candidate -split '\s+')[0]
    }
    if ($candidate -match '^\\\?\?\\') {
        $candidate = $candidate -replace '^\\\?\?\\', ''
    }
    if ($candidate -match '^\\SystemRoot\\') {
        $candidate = Join-Path $env:WINDIR ($candidate.Substring(12))
    } elseif ($candidate -match '^System32\\') {
        $candidate = Join-Path $env:WINDIR $candidate
    }
    return $candidate
}

function Invoke-LoggedCommand {
    param(
        [Parameter(Mandatory=$true)][string]$FilePath,
        [Parameter(Mandatory=$true)][string[]]$Arguments
    )

    $display = "$FilePath " + ($Arguments -join " ")
    Write-Log "RUN: $display" "Yellow"
    $output = & $FilePath @Arguments 2>&1
    $exit = $LASTEXITCODE
    $output | ForEach-Object {
        $text = [string]$_
        Write-Host $text
        $text | Out-File $LogPath -Encoding UTF8 -Append
    }
    Write-Log "ExitCode: $exit" $(if ($exit -eq 0) { "Green" } else { "DarkYellow" })
    return $exit
}

function Read-SelectionNumbers {
    param(
        [int]$Max,
        [string]$Prompt = "Enter numbers separated by comma, or leave empty to cancel"
    )

    $inputValue = Read-Host $Prompt
    if ([string]::IsNullOrWhiteSpace($inputValue)) { return @() }
    if ($inputValue.Trim().ToUpperInvariant() -eq "ALL") {
        return 1..$Max
    }

    $selected = New-Object System.Collections.Generic.List[int]
    foreach ($part in ($inputValue -split ',')) {
        $value = 0
        if ([int]::TryParse($part.Trim(), [ref]$value) -and $value -ge 1 -and $value -le $Max) {
            if (-not $selected.Contains($value)) { $selected.Add($value) }
        }
    }
    return @($selected)
}

function Confirm-Action {
    param([Parameter(Mandatory=$true)][string]$Phrase)

    $answer = Read-Host "Type $Phrase to continue"
    return $answer -eq $Phrase
}

function Get-PhantomDevices {
    if (-not (Get-Command Get-PnpDevice -ErrorAction SilentlyContinue)) { return @() }

    $advancedClasses = 'System|Processor|Volume|VolumeSnapshot|DiskDrive|SCSIAdapter|SoftwareComponent|SoftwareDevice|LegacyDriver'
    $devices = @(Get-PnpDevice -ErrorAction SilentlyContinue | Where-Object {
        [string]$_.Problem -match 'CM_PROB_PHANTOM'
    } | ForEach-Object {
        $isAdvanced = [string]$_.Class -match $advancedClasses
        [PSCustomObject]@{
            Status = [string]$_.Status
            Class = [string]$_.Class
            FriendlyName = [string]$_.FriendlyName
            InstanceId = [string]$_.InstanceId
            Problem = [string]$_.Problem
            Risk = if ($isAdvanced) { "Advanced" } else { "Normal" }
        }
    })

    if ($IncludeAdvanced) { return $devices }
    return @($devices | Where-Object { $_.Risk -ne "Advanced" })
}

function Get-MissingDriverServices {
    @(Get-CimInstance Win32_SystemDriver -ErrorAction SilentlyContinue | ForEach-Object {
        $path = Normalize-DriverPath $_.PathName
        if ($path -match '\.sys$' -and -not (Test-Path -LiteralPath $path -ErrorAction SilentlyContinue)) {
            [PSCustomObject]@{
                Name = [string]$_.Name
                DisplayName = [string]$_.DisplayName
                State = [string]$_.State
                Status = [string]$_.Status
                StartMode = [string]$_.StartMode
                MissingPath = $path
                OriginalPathName = [string]$_.PathName
            }
        }
    })
}

function Get-OldThirdPartyDrivers {
    $classes = @("Net", "SCSIAdapter", "HDC", "DiskDrive", "Storage", "System", "Display", "MEDIA", "USB", "HIDClass", "SoftwareComponent", "Extension")
    $cutoff = (Get-Date).AddYears(-4)
    @(Get-CimInstance Win32_PnPSignedDriver -ErrorAction SilentlyContinue | Where-Object {
        $classes -contains $_.DeviceClass -and
        "$($_.Manufacturer)" -notmatch 'Microsoft|Windows|Standard|Standardsystem|WireGuard|Tailscale' -and
        $_.DriverDate -and
        ([datetime]$_.DriverDate) -lt $cutoff
    } | Sort-Object Manufacturer, DeviceClass, DeviceName | Select-Object DeviceName, DeviceClass, Manufacturer, DriverVersion, DriverDate, InfName, DeviceID)
}

function Export-Inventory {
    param(
        [object[]]$PhantomDevices,
        [object[]]$MissingServices,
        [object[]]$OldDrivers
    )

    $PhantomDevices | Export-Csv (Join-Path $Out "PhantomDevices.csv") -NoTypeInformation -Encoding UTF8
    $MissingServices | Export-Csv (Join-Path $Out "MissingDriverServices.csv") -NoTypeInformation -Encoding UTF8
    $OldDrivers | Export-Csv (Join-Path $Out "OldThirdPartyDrivers_ReviewOnly.csv") -NoTypeInformation -Encoding UTF8
}

function Show-IndexedTable {
    param(
        [object[]]$Rows,
        [string[]]$Columns,
        [int]$MaxRows = 60
    )

    $indexed = @()
    $i = 1
    foreach ($row in @($Rows | Select-Object -First $MaxRows)) {
        $obj = [ordered]@{ No = $i }
        foreach ($column in $Columns) {
            $obj[$column] = $row.$column
        }
        $indexed += [PSCustomObject]$obj
        $i++
    }
    $indexed | Format-Table -AutoSize
}

Write-Host ""
Write-Host "$ToolName $ToolVersion" -ForegroundColor Cyan
Write-Host "===============================" -ForegroundColor Cyan
Write-Host ""
Write-Host "This tool can remove stale hardware traces, but only after explicit selection." -ForegroundColor Yellow
Write-Host "It is safest to remove one group at a time, reboot, and rerun PCDiagLite." -ForegroundColor Yellow
Write-Host ""

$phantomDevices = @(Get-PhantomDevices)
$missingServices = @(Get-MissingDriverServices)
$oldDrivers = @(Get-OldThirdPartyDrivers)
Export-Inventory -PhantomDevices $phantomDevices -MissingServices $missingServices -OldDrivers $oldDrivers

Write-Log "Output folder: $Out" "Gray"
Write-Log "Phantom devices shown: $($phantomDevices.Count)" "Gray"
Write-Log "Missing driver services: $($missingServices.Count)" "Gray"
Write-Log "Old third-party drivers for review: $($oldDrivers.Count)" "Gray"

do {
    Write-Host ""
    Write-Host "Hardware Cleanup Menu" -ForegroundColor Cyan
    Write-Host "=====================" -ForegroundColor Cyan
    Write-Host "[1] Remove selected non-present phantom devices ($($phantomDevices.Count))"
    Write-Host "[2] Delete selected driver services with missing .sys files ($($missingServices.Count))"
    Write-Host "[3] Review old third-party driver packages ($($oldDrivers.Count))"
    Write-Host "[4] Refresh scan"
    Write-Host "[0] Exit"
    Write-Host ""
    $choice = Read-Host "Enter selection"

    switch ($choice) {
        "1" {
            if ($phantomDevices.Count -eq 0) {
                Write-Host "No phantom devices available for this mode." -ForegroundColor Green
                continue
            }
            Show-IndexedTable -Rows $phantomDevices -Columns @("Risk","Class","FriendlyName","InstanceId") -MaxRows 80
            Write-Host ""
            Write-Host "Tip: default view excludes advanced classes like System, Processor, Volume, DiskDrive." -ForegroundColor DarkGray
            Write-Host "Run with -IncludeAdvanced only when you deliberately want those shown." -ForegroundColor DarkGray
            $numbers = @(Read-SelectionNumbers -Max $phantomDevices.Count)
            if ($numbers.Count -eq 0) { continue }
            Write-Host "Selected $($numbers.Count) device(s)." -ForegroundColor Yellow
            if (-not (Confirm-Action -Phrase "REMOVE")) { Write-Host "Cancelled." -ForegroundColor Gray; continue }
            foreach ($number in $numbers) {
                $device = $phantomDevices[$number - 1]
                Invoke-LoggedCommand -FilePath "pnputil.exe" -Arguments @("/remove-device", [string]$device.InstanceId) | Out-Null
            }
        }
        "2" {
            if ($missingServices.Count -eq 0) {
                Write-Host "No driver services with missing .sys files found." -ForegroundColor Green
                continue
            }
            Show-IndexedTable -Rows $missingServices -Columns @("Name","DisplayName","State","StartMode","MissingPath") -MaxRows 80
            Write-Host ""
            Write-Host "Deleting services is destructive. Confirm the service is stale first." -ForegroundColor Red
            $numbers = @(Read-SelectionNumbers -Max $missingServices.Count)
            if ($numbers.Count -eq 0) { continue }
            Write-Host "Selected $($numbers.Count) service(s)." -ForegroundColor Yellow
            if (-not (Confirm-Action -Phrase "DELETE")) { Write-Host "Cancelled." -ForegroundColor Gray; continue }
            foreach ($number in $numbers) {
                $service = $missingServices[$number - 1]
                Invoke-LoggedCommand -FilePath "sc.exe" -Arguments @("query", [string]$service.Name) | Out-Null
                Invoke-LoggedCommand -FilePath "sc.exe" -Arguments @("delete", [string]$service.Name) | Out-Null
            }
        }
        "3" {
            if ($oldDrivers.Count -eq 0) {
                Write-Host "No old third-party driver packages found." -ForegroundColor Green
                continue
            }
            Show-IndexedTable -Rows $oldDrivers -Columns @("DeviceClass","DeviceName","Manufacturer","DriverVersion","DriverDate","InfName") -MaxRows 100
            Write-Host ""
            Write-Host "This page is review-only. Old chipset/network/storage drivers may still belong to current hardware." -ForegroundColor Yellow
            Write-Host "Inspect a package manually, for example:" -ForegroundColor Gray
            Write-Host "pnputil.exe /enum-drivers | findstr.exe /i oem123.inf" -ForegroundColor DarkGray
            Write-Host "Prefer vendor uninstallers for GPU, chipset, audio, RGB, and security software." -ForegroundColor Gray
        }
        "4" {
            $phantomDevices = @(Get-PhantomDevices)
            $missingServices = @(Get-MissingDriverServices)
            $oldDrivers = @(Get-OldThirdPartyDrivers)
            Export-Inventory -PhantomDevices $phantomDevices -MissingServices $missingServices -OldDrivers $oldDrivers
            Write-Log "Scan refreshed." "Green"
        }
        "0" {}
        default { Write-Host "Unknown selection." -ForegroundColor DarkYellow }
    }
} while ($choice -ne "0")

Write-Host ""
Write-Log "Finished. Review logs and CSV files in: $Out" "Green"
try { Stop-Transcript | Out-Null } catch {}
