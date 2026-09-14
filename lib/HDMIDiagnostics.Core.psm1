Set-StrictMode -Version 2.0
$script:ModuleRoot = $PSScriptRoot
$script:NativeLoaded = $false
$script:UnknownValue = "Nicht zuverlässig über Windows API ermittelbar"

function ConvertTo-HdmiSafeFileName {
    param([AllowNull()][string]$Value)
    if ([string]::IsNullOrWhiteSpace($Value)) { return "Unknown" }
    $safe = $Value
    foreach ($character in [IO.Path]::GetInvalidFileNameChars()) {
        $safe = $safe.Replace([string]$character, "_")
    }
    return ($safe -replace '\s+', '_').Trim('_')
}

function ConvertTo-HdmiHtml {
    param([AllowNull()]$Value)
    if ($null -eq $Value) { return "" }
    return [Net.WebUtility]::HtmlEncode([string]$Value)
}

function Write-HdmiJson {
    param(
        [Parameter(Mandatory=$true)][string]$Path,
        [AllowNull()]$InputObject,
        [int]$Depth = 10
    )
    $json = ConvertTo-Json -InputObject $InputObject -Depth $Depth
    [IO.File]::WriteAllText($Path, [string]$json, [Text.UTF8Encoding]::new($false))
}

function Initialize-HdmiNativeApi {
    if ($script:NativeLoaded -and ("PCDiagnose.Display.DisplayConfigReader" -as [type])) { return }
    if ("PCDiagnose.Display.DisplayConfigReader" -as [type]) {
        $script:NativeLoaded = $true
        return
    }

    $sourcePath = Join-Path $script:ModuleRoot "HDMIDiagnostics.Native.cs"
    if (-not (Test-Path -LiteralPath $sourcePath)) {
        throw "Windows display API source is missing: $sourcePath"
    }

    Add-Type -TypeDefinition ([IO.File]::ReadAllText($sourcePath)) -Language CSharp -ErrorAction Stop
    $script:NativeLoaded = $true
}

function Get-HdmiSystemInfo {
    $os = $null
    $computer = $null
    $board = $null
    $bios = $null
    $processors = @()
    try { $os = Get-CimInstance Win32_OperatingSystem -ErrorAction Stop } catch {}
    try { $computer = Get-CimInstance Win32_ComputerSystem -ErrorAction Stop } catch {}
    try { $board = Get-CimInstance Win32_BaseBoard -ErrorAction Stop | Select-Object -First 1 } catch {}
    try { $bios = Get-CimInstance Win32_BIOS -ErrorAction Stop | Select-Object -First 1 } catch {}
    try { $processors = @(Get-CimInstance Win32_Processor -ErrorAction Stop) } catch {}

    $ramBytes = 0
    try {
        $ramBytes = [double](Get-CimInstance Win32_PhysicalMemory -ErrorAction Stop | Measure-Object Capacity -Sum).Sum
    } catch {
        if ($computer) { $ramBytes = [double]$computer.TotalPhysicalMemory }
    }

    $cpuNames = @($processors | ForEach-Object { [string]$_.Name.Trim() }) -join "; "
    [pscustomobject]@{
        CapturedAt = (Get-Date).ToString("yyyy-MM-dd HH:mm:ss.fff zzz")
        ComputerName = $env:COMPUTERNAME
        Windows = if ($os) { [string]$os.Caption } else { $script:UnknownValue }
        Version = if ($os) { [string]$os.Version } else { $script:UnknownValue }
        Build = if ($os) { [string]$os.BuildNumber } else { $script:UnknownValue }
        Mainboard = if ($board) { (([string]$board.Manufacturer).Trim() + " " + ([string]$board.Product).Trim()).Trim() } else { $script:UnknownValue }
        BiosVersion = if ($bios) { [string]$bios.SMBIOSBIOSVersion } else { $script:UnknownValue }
        BiosDate = if ($bios -and $bios.ReleaseDate) { ([datetime]$bios.ReleaseDate).ToString("yyyy-MM-dd") } else { $script:UnknownValue }
        Cpu = if ($cpuNames) { $cpuNames } else { $script:UnknownValue }
        RamGB = if ($ramBytes -gt 0) { [math]::Round($ramBytes / 1GB, 1) } else { $null }
        IsAdministrator = (New-Object Security.Principal.WindowsPrincipal([Security.Principal.WindowsIdentity]::GetCurrent())).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
        PowerShell = $PSVersionTable.PSVersion.ToString()
        Source = "CIM: Win32_OperatingSystem, Win32_ComputerSystem, Win32_BaseBoard, Win32_BIOS, Win32_Processor, Win32_PhysicalMemory"
    }
}

function Get-HdmiGpuInfo {
    $signedDrivers = @()
    try {
        $signedDrivers = @(Get-CimInstance Win32_PnPSignedDriver -ErrorAction Stop | Where-Object { $_.DeviceClass -eq "DISPLAY" })
    } catch {}

    $wddmByName = @{}
    $dxdiagPath = Join-Path $env:TEMP ("HDMIDiagnostics_dxdiag_{0}.xml" -f [guid]::NewGuid().ToString("N"))
    try {
        $process = Start-Process -FilePath (Join-Path $env:SystemRoot "System32\dxdiag.exe") -ArgumentList "/whql:off /x `"$dxdiagPath`"" -PassThru -WindowStyle Hidden
        if ($process.WaitForExit(30000) -and (Test-Path -LiteralPath $dxdiagPath)) {
            [xml]$dx = Get-Content -LiteralPath $dxdiagPath -Raw
            foreach ($device in @($dx.DxDiag.DisplayDevices.DisplayDevice)) {
                if ($device.CardName) { $wddmByName[[string]$device.CardName] = [string]$device.DriverModel }
            }
        }
    } catch {} finally {
        Remove-Item -LiteralPath $dxdiagPath -Force -ErrorAction SilentlyContinue
    }

    $controllers = @()
    try { $controllers = @(Get-CimInstance Win32_VideoController -ErrorAction Stop) } catch {}
    foreach ($controller in $controllers) {
        $pnpId = [string]$controller.PNPDeviceID
        $driver = @($signedDrivers | Where-Object { [string]$_.DeviceID -eq $pnpId }) | Select-Object -First 1
        $name = [string]$controller.Name
        [pscustomobject]@{
            Name = $name
            Manufacturer = [string]$controller.AdapterCompatibility
            PnpDeviceId = $pnpId
            Status = [string]$controller.Status
            DriverVersion = if ($driver -and $driver.DriverVersion) { [string]$driver.DriverVersion } else { [string]$controller.DriverVersion }
            DriverDate = if ($driver -and $driver.DriverDate) { ([datetime]$driver.DriverDate).ToString("yyyy-MM-dd") } elseif ($controller.DriverDate) { ([datetime]$controller.DriverDate).ToString("yyyy-MM-dd") } else { $script:UnknownValue }
            InfName = if ($driver) { [string]$driver.InfName } else { "" }
            WddmVersion = if ($wddmByName.ContainsKey($name) -and $wddmByName[$name]) { $wddmByName[$name] } else { $script:UnknownValue }
            CurrentHorizontalResolution = $controller.CurrentHorizontalResolution
            CurrentVerticalResolution = $controller.CurrentVerticalResolution
            CurrentRefreshRate = $controller.CurrentRefreshRate
            Source = "CIM: Win32_VideoController and Win32_PnPSignedDriver; WDDM: dxdiag XML when available"
        }
    }
}

function Get-HdmiMonitorKey {
    param([AllowNull()][string]$Value)
    if ([string]::IsNullOrWhiteSpace($Value)) { return "" }
    $normalized = $Value.ToUpperInvariant()
    if ($normalized -match 'DISPLAY[\\#]+([^\\#]+)[\\#]+([^\\#\{]+)') {
        $instance = $matches[2] -replace '_\d+$', ''
        return "DISPLAY\$($matches[1])\$instance"
    }
    if ($normalized -match 'DISPLAY\\([^\\]+)') { return "DISPLAY\$($matches[1])" }
    return $normalized
}

function Get-HdmiDisplayState {
    Initialize-HdmiNativeApi
    $primaryByDevice = @{}
    try {
        Add-Type -AssemblyName System.Windows.Forms -ErrorAction Stop
        foreach ($screen in [Windows.Forms.Screen]::AllScreens) {
            $primaryByDevice[[string]$screen.DeviceName] = [bool]$screen.Primary
        }
    } catch {}

    $records = @([PCDiagnose.Display.DisplayConfigReader]::GetActivePaths())
    foreach ($record in $records) {
        $refresh = if ($record.RefreshRateHz -gt 0) { $record.RefreshRateHz } else { $record.PhysicalRefreshRateHz }
        $friendly = [string]$record.MonitorFriendlyName
        if ([string]::IsNullOrWhiteSpace($friendly)) { $friendly = "Unbenanntes Display" }
        [pscustomobject]@{
            Key = Get-HdmiMonitorKey -Value ([string]$record.MonitorDevicePath)
            FriendlyName = $friendly
            MonitorDevicePath = [string]$record.MonitorDevicePath
            SourceName = [string]$record.SourceName
            AdapterDevicePath = [string]$record.AdapterDevicePath
            AdapterLuid = $record.AdapterLuid
            SourceId = $record.SourceId
            TargetId = $record.TargetId
            ConnectorType = ([string]$record.OutputTechnology -replace 'DISPLAYPORT_EXTERNAL', 'DisplayPort' -replace 'DISPLAYPORT_EMBEDDED', 'Embedded DisplayPort')
            ConnectorInstance = $record.ConnectorInstance
            Width = $record.Width
            Height = $record.Height
            RefreshRateHz = [math]::Round($refresh, 3)
            PhysicalRefreshRateHz = if ($record.PhysicalRefreshRateHz -gt 0) { [math]::Round($record.PhysicalRefreshRateHz, 3) } else { $null }
            PixelRateHz = $record.PixelRateHz
            ScanLineOrdering = [string]$record.ScanLineOrdering
            Rotation = [string]$record.Rotation
            ScalingMode = [string]$record.Scaling
            Position = "{0},{1}" -f $record.PositionX, $record.PositionY
            Primary = if ($primaryByDevice.ContainsKey([string]$record.SourceName)) { $primaryByDevice[[string]$record.SourceName] } else { $false }
            PreferredWidth = $record.PreferredWidth
            PreferredHeight = $record.PreferredHeight
            HdrSupported = if ($record.AdvancedColorInfoAvailable) { $record.AdvancedColorSupported } else { $null }
            HdrEnabled = if ($record.AdvancedColorInfoAvailable) { $record.AdvancedColorEnabled } else { $null }
            ColorEncoding = if ($record.AdvancedColorInfoAvailable) { [string]$record.ColorEncoding } else { $script:UnknownValue }
            BitsPerColorChannel = if ($record.AdvancedColorInfoAvailable -and $record.BitsPerColorChannel -gt 0) { $record.BitsPerColorChannel } else { $null }
            SdrWhiteLevelNits = if ($record.SdrWhiteLevelAvailable) { [math]::Round($record.SdrWhiteLevelNits, 1) } else { $null }
            TargetAvailable = $record.TargetAvailable
            EdidIdsValid = $record.EdidIdsValid
            Source = "Windows CCD API: QueryDisplayConfig and DisplayConfigGetDeviceInfo"
        }
    }
}

function Get-HdmiDetailedTiming {
    param([byte[]]$Bytes, [int]$Offset)
    if ($Offset -lt 0 -or ($Offset + 17) -ge $Bytes.Length) { return $null }
    $pixelClock = ([int]$Bytes[$Offset] + ([int]$Bytes[$Offset + 1] -shl 8)) * 10000
    if ($pixelClock -le 0) { return $null }
    $hActive = [int]$Bytes[$Offset + 2] + (([int]$Bytes[$Offset + 4] -band 0xF0) -shl 4)
    $hBlank = [int]$Bytes[$Offset + 3] + (([int]$Bytes[$Offset + 4] -band 0x0F) -shl 8)
    $vActive = [int]$Bytes[$Offset + 5] + (([int]$Bytes[$Offset + 7] -band 0xF0) -shl 4)
    $vBlank = [int]$Bytes[$Offset + 6] + (([int]$Bytes[$Offset + 7] -band 0x0F) -shl 8)
    $refresh = 0
    if (($hActive + $hBlank) -gt 0 -and ($vActive + $vBlank) -gt 0) {
        $refresh = $pixelClock / (($hActive + $hBlank) * ($vActive + $vBlank))
    }
    return [pscustomobject]@{
        Width = $hActive
        Height = $vActive
        RefreshRateHz = [math]::Round($refresh, 2)
        PixelClockMHz = [math]::Round($pixelClock / 1MB, 3)
    }
}

function ConvertFrom-HdmiEdid {
    [CmdletBinding()]
    param([Parameter(Mandatory=$true)][byte[]]$Bytes)

    $validHeader = $Bytes.Length -ge 128 -and (($Bytes[0..7] -join ',') -eq '0,255,255,255,255,255,255,0')
    $baseChecksumValid = $false
    if ($Bytes.Length -ge 128) {
        $sum = 0
        foreach ($value in $Bytes[0..127]) { $sum = ($sum + $value) -band 0xFF }
        $baseChecksumValid = ($sum -eq 0)
    }

    $manufacturer = ""
    $productId = $null
    $serialNumber = $null
    if ($Bytes.Length -ge 16) {
        $manufacturerWord = ([int]$Bytes[8] -shl 8) -bor [int]$Bytes[9]
        $manufacturer = [string]([char](64 + (($manufacturerWord -shr 10) -band 31))) + [char](64 + (($manufacturerWord -shr 5) -band 31)) + [char](64 + ($manufacturerWord -band 31))
        $productId = [int]$Bytes[10] + ([int]$Bytes[11] -shl 8)
        $serialNumber = [uint32]([int64]$Bytes[12] + ([int64]$Bytes[13] -shl 8) + ([int64]$Bytes[14] -shl 16) + ([int64]$Bytes[15] -shl 24))
    }

    $displayName = ""
    $serialText = ""
    $preferredTiming = $null
    if ($Bytes.Length -ge 126) {
        foreach ($offset in @(54, 72, 90, 108)) {
            if ($Bytes[$offset] -eq 0 -and $Bytes[$offset + 1] -eq 0 -and $Bytes[$offset + 2] -eq 0) {
                $tag = $Bytes[$offset + 3]
                if ($tag -eq 0xFC -or $tag -eq 0xFF) {
                    $textBytes = [byte[]]$Bytes[($offset + 5)..($offset + 17)]
                    $text = ([Text.Encoding]::ASCII.GetString($textBytes) -replace '[\x00\r\n]', '').Trim()
                    if ($tag -eq 0xFC) { $displayName = $text }
                    if ($tag -eq 0xFF) { $serialText = $text }
                }
            } elseif (-not $preferredTiming) {
                $preferredTiming = Get-HdmiDetailedTiming -Bytes $Bytes -Offset $offset
            }
        }
    }

    $standardTimings = New-Object Collections.Generic.List[string]
    if ($Bytes.Length -ge 54) {
        for ($offset = 38; $offset -le 52; $offset += 2) {
            if ($Bytes[$offset] -eq 0x01 -and $Bytes[$offset + 1] -eq 0x01) { continue }
            $width = ([int]$Bytes[$offset] + 31) * 8
            $aspectCode = ([int]$Bytes[$offset + 1] -shr 6) -band 3
            $height = switch ($aspectCode) {
                0 { [math]::Round($width * 10 / 16) }
                1 { [math]::Round($width * 3 / 4) }
                2 { [math]::Round($width * 4 / 5) }
                default { [math]::Round($width * 9 / 16) }
            }
            $refresh = ([int]$Bytes[$offset + 1] -band 0x3F) + 60
            $standardTimings.Add(("{0}x{1} @ {2} Hz" -f $width, $height, $refresh))
        }
    }

    $ctaPresent = $false
    $audioSupported = $false
    $hdrStaticMetadata = $false
    $hdmiVsdb = $false
    $hdmiForumVsdb = $false
    $maxTmdsMHz = $null
    $ycbcr444 = $false
    $ycbcr422 = $false
    $ycbcr420 = $false
    $deepColor30 = $false
    $deepColor36 = $false
    $deepColor48 = $false
    $extensionChecksumsValid = $true
    $ctaRevision = $null
    $extensionCount = if ($Bytes.Length -ge 127) { [int]$Bytes[126] } else { 0 }

    for ($block = 1; $block -le $extensionCount; $block++) {
        $base = $block * 128
        if (($base + 127) -ge $Bytes.Length) {
            $extensionChecksumsValid = $false
            continue
        }
        $checksum = 0
        foreach ($value in $Bytes[$base..($base + 127)]) { $checksum = ($checksum + $value) -band 0xFF }
        if ($checksum -ne 0) { $extensionChecksumsValid = $false }
        if ($Bytes[$base] -ne 0x02) { continue }

        $ctaPresent = $true
        $ctaRevision = [int]$Bytes[$base + 1]
        $flags = [int]$Bytes[$base + 3]
        $audioSupported = $audioSupported -or (($flags -band 0x40) -ne 0)
        $ycbcr444 = $ycbcr444 -or (($flags -band 0x20) -ne 0)
        $ycbcr422 = $ycbcr422 -or (($flags -band 0x10) -ne 0)
        $end = [int]$Bytes[$base + 2]
        if ($end -eq 0 -or $end -gt 127) { $end = 127 }
        $cursor = 4
        while ($cursor -lt $end) {
            $header = [int]$Bytes[$base + $cursor]
            $tag = ($header -shr 5) -band 7
            $length = $header -band 31
            if ($length -eq 0) { $cursor++; continue }
            if (($cursor + $length) -ge 128) { break }
            $payloadStart = $base + $cursor + 1
            if ($tag -eq 1) { $audioSupported = $true }
            if ($tag -eq 3 -and $length -ge 3) {
                $oui = [int]$Bytes[$payloadStart] -bor ([int]$Bytes[$payloadStart + 1] -shl 8) -bor ([int]$Bytes[$payloadStart + 2] -shl 16)
                if ($oui -eq 0x000C03) {
                    $hdmiVsdb = $true
                    if ($length -ge 6) {
                        $feature = [int]$Bytes[$payloadStart + 5]
                        $deepColor30 = $deepColor30 -or (($feature -band 0x10) -ne 0)
                        $deepColor36 = $deepColor36 -or (($feature -band 0x20) -ne 0)
                        $deepColor48 = $deepColor48 -or (($feature -band 0x40) -ne 0)
                    }
                    if ($length -ge 7 -and $Bytes[$payloadStart + 6] -gt 0) {
                        $maxTmdsMHz = [int]$Bytes[$payloadStart + 6] * 5
                    }
                }
                if ($oui -eq 0xC45DD8) {
                    $hdmiForumVsdb = $true
                    if ($length -ge 5 -and $Bytes[$payloadStart + 4] -gt 0) {
                        $forumRate = [int]$Bytes[$payloadStart + 4] * 5
                        if ($null -eq $maxTmdsMHz -or $forumRate -gt $maxTmdsMHz) { $maxTmdsMHz = $forumRate }
                    }
                }
            }
            if ($tag -eq 7 -and $length -ge 1) {
                $extendedTag = [int]$Bytes[$payloadStart]
                if ($extendedTag -eq 0x06) { $hdrStaticMetadata = $true }
                if ($extendedTag -eq 0x0E -or $extendedTag -eq 0x0F) { $ycbcr420 = $true }
            }
            $cursor += 1 + $length
        }
    }

    [pscustomobject]@{
        ValidHeader = $validHeader
        BaseChecksumValid = $baseChecksumValid
        ExtensionChecksumsValid = $extensionChecksumsValid
        ManufacturerId = $manufacturer
        ProductId = $productId
        NumericSerialNumber = $serialNumber
        SerialText = $serialText
        DisplayName = $displayName
        EdidVersion = if ($Bytes.Length -ge 20) { "{0}.{1}" -f $Bytes[18], $Bytes[19] } else { "" }
        ManufactureWeek = if ($Bytes.Length -ge 17) { [int]$Bytes[16] } else { $null }
        ManufactureYear = if ($Bytes.Length -ge 18) { 1990 + [int]$Bytes[17] } else { $null }
        WidthCm = if ($Bytes.Length -ge 22) { [int]$Bytes[21] } else { $null }
        HeightCm = if ($Bytes.Length -ge 23) { [int]$Bytes[22] } else { $null }
        PreferredTiming = $preferredTiming
        StandardTimings = [string[]]$standardTimings.ToArray()
        ExtensionCount = $extensionCount
        Cta861Present = $ctaPresent
        CtaRevision = $ctaRevision
        AudioSupported = $audioSupported
        HdrStaticMetadata = $hdrStaticMetadata
        HdmiVsdb = $hdmiVsdb
        HdmiForumVsdb = $hdmiForumVsdb
        MaxTmdsClockMHz = $maxTmdsMHz
        YCbCr444 = $ycbcr444
        YCbCr422 = $ycbcr422
        YCbCr420 = $ycbcr420
        DeepColor30Bit = $deepColor30
        DeepColor36Bit = $deepColor36
        DeepColor48Bit = $deepColor48
        HdmiCapabilityStatement = if ($hdmiForumVsdb) { "EDID enthält HDMI-Forum-Merkmale, die auf neuere HDMI-/FRL-Funktionen hindeuten; keine definitive HDMI-Versionsbestimmung." } elseif ($hdmiVsdb) { "EDID enthält einen HDMI Vendor Specific Data Block; keine definitive HDMI-Versionsbestimmung." } else { "Keine belastbare HDMI-Versionsaussage aus den dekodierten EDID-Blöcken möglich." }
        Vrr = $script:UnknownValue
        Allm = $script:UnknownValue
        RawLength = $Bytes.Length
    }
}

function Get-HdmiEdidData {
    [CmdletBinding()]
    param([string]$OutputDirectory = "")

    if ($OutputDirectory) { New-Item -ItemType Directory -Force -Path $OutputDirectory | Out-Null }
    $rawRecords = New-Object Collections.Generic.List[object]
    $seen = @{}

    try {
        $instances = @(Get-CimInstance -Namespace root\wmi -ClassName WmiMonitorDescriptorMethods -ErrorAction Stop)
        foreach ($instance in $instances) {
            try {
                $first = Invoke-CimMethod -InputObject $instance -MethodName WmiGetMonitorRawEEdidV1Block -Arguments @{ BlockId = [uint32]0 } -ErrorAction Stop
                $bytes = New-Object Collections.Generic.List[byte]
                $bytes.AddRange([byte[]]$first.BlockContent)
                $extensionCount = if ($first.BlockContent.Count -ge 127) { [int]$first.BlockContent[126] } else { 0 }
                for ($block = 1; $block -le $extensionCount; $block++) {
                    try {
                        $next = Invoke-CimMethod -InputObject $instance -MethodName WmiGetMonitorRawEEdidV1Block -Arguments @{ BlockId = [uint32]$block } -ErrorAction Stop
                        $bytes.AddRange([byte[]]$next.BlockContent)
                    } catch { break }
                }
                $key = Get-HdmiMonitorKey -Value ([string]$instance.InstanceName)
                $seen[$key] = $true
                $rawRecords.Add([pscustomobject]@{
                    InstanceName = [string]$instance.InstanceName
                    Key = $key
                    Active = [bool]$instance.Active
                    Bytes = [byte[]]$bytes.ToArray()
                    Source = "WMI root\wmi: WmiMonitorDescriptorMethods.WmiGetMonitorRawEEdidV1Block"
                })
            } catch {}
        }
    } catch {}

    try {
        $displayRoot = "Registry::HKEY_LOCAL_MACHINE\SYSTEM\CurrentControlSet\Enum\DISPLAY"
        foreach ($vendorKey in @(Get-ChildItem -LiteralPath $displayRoot -ErrorAction Stop)) {
            foreach ($instanceKey in @(Get-ChildItem -LiteralPath $vendorKey.PSPath -ErrorAction SilentlyContinue)) {
                $deviceParameters = Join-Path $instanceKey.PSPath "Device Parameters"
                $edid = (Get-ItemProperty -LiteralPath $deviceParameters -Name EDID -ErrorAction SilentlyContinue).EDID
                if (-not $edid) { continue }
                $instanceName = "DISPLAY\{0}\{1}" -f $vendorKey.PSChildName, $instanceKey.PSChildName
                $key = Get-HdmiMonitorKey -Value $instanceName
                if ($seen.ContainsKey($key)) { continue }
                $rawRecords.Add([pscustomobject]@{
                    InstanceName = $instanceName
                    Key = $key
                    Active = $false
                    Bytes = [byte[]]$edid
                    Source = "Registry: HKLM\SYSTEM\CurrentControlSet\Enum\DISPLAY\$($vendorKey.PSChildName)\$($instanceKey.PSChildName)\Device Parameters\EDID"
                })
            }
        }
    } catch {}

    $index = 0
    foreach ($raw in $rawRecords) {
        $index++
        $parsed = ConvertFrom-HdmiEdid -Bytes $raw.Bytes
        $fileName = "EDID_{0:D2}_{1}.bin" -f $index, (ConvertTo-HdmiSafeFileName -Value ($parsed.DisplayName + "_" + $parsed.ManufacturerId + $parsed.ProductId))
        $rawPath = if ($OutputDirectory) { Join-Path $OutputDirectory $fileName } else { "" }
        if ($rawPath) { [IO.File]::WriteAllBytes($rawPath, [byte[]]$raw.Bytes) }
        $sha = [Security.Cryptography.SHA256]::Create()
        try { $hash = ([BitConverter]::ToString($sha.ComputeHash([byte[]]$raw.Bytes))).Replace("-", "") } finally { $sha.Dispose() }
        [pscustomobject]@{
            Key = $raw.Key
            InstanceName = $raw.InstanceName
            Active = $raw.Active
            DisplayName = $parsed.DisplayName
            ManufacturerId = $parsed.ManufacturerId
            ProductId = $parsed.ProductId
            SerialNumber = if ($parsed.SerialText) { $parsed.SerialText } else { $parsed.NumericSerialNumber }
            EdidVersion = $parsed.EdidVersion
            ValidHeader = $parsed.ValidHeader
            BaseChecksumValid = $parsed.BaseChecksumValid
            ExtensionChecksumsValid = $parsed.ExtensionChecksumsValid
            PhysicalSize = if ($parsed.WidthCm -or $parsed.HeightCm) { "{0} x {1} cm" -f $parsed.WidthCm, $parsed.HeightCm } else { "" }
            PreferredTiming = $parsed.PreferredTiming
            StandardTimings = $parsed.StandardTimings
            Cta861Present = $parsed.Cta861Present
            CtaRevision = $parsed.CtaRevision
            AudioSupported = $parsed.AudioSupported
            HdrStaticMetadata = $parsed.HdrStaticMetadata
            HdmiVsdb = $parsed.HdmiVsdb
            HdmiForumVsdb = $parsed.HdmiForumVsdb
            MaxTmdsClockMHz = $parsed.MaxTmdsClockMHz
            YCbCr444 = $parsed.YCbCr444
            YCbCr422 = $parsed.YCbCr422
            YCbCr420 = $parsed.YCbCr420
            DeepColor30Bit = $parsed.DeepColor30Bit
            DeepColor36Bit = $parsed.DeepColor36Bit
            DeepColor48Bit = $parsed.DeepColor48Bit
            Vrr = $parsed.Vrr
            Allm = $parsed.Allm
            HdmiCapabilityStatement = $parsed.HdmiCapabilityStatement
            RawFile = $rawPath
            RawLength = $parsed.RawLength
            Sha256 = $hash
            Source = $raw.Source
        }
    }
}

function Get-HdmiAudioInfo {
    $devices = New-Object Collections.Generic.List[object]
    try {
        foreach ($device in @(Get-CimInstance Win32_SoundDevice -ErrorAction Stop)) {
            $name = [string]$device.Name
            $manufacturer = [string]$device.Manufacturer
            if ($name -notmatch '(?i)display audio|hdmi|high definition audio|nvidia|amd|intel' -and $manufacturer -notmatch '(?i)nvidia|amd|intel') { continue }
            $devices.Add([pscustomobject]@{
                Type = "SoundDevice"
                Name = $name
                Status = [string]$device.Status
                Manufacturer = $manufacturer
                PnpDeviceId = [string]$device.PNPDeviceID
                Present = $true
                Source = "CIM: Win32_SoundDevice"
            })
        }
    } catch {}

    if (Get-Command Get-PnpDevice -ErrorAction SilentlyContinue) {
        try {
            foreach ($endpoint in @(Get-PnpDevice -Class AudioEndpoint -ErrorAction Stop)) {
                $devices.Add([pscustomobject]@{
                    Type = "AudioEndpoint"
                    Name = [string]$endpoint.FriendlyName
                    Status = [string]$endpoint.Status
                    Manufacturer = ""
                    PnpDeviceId = [string]$endpoint.InstanceId
                    Present = [bool]$endpoint.Present
                    Source = "PnP: Get-PnpDevice -Class AudioEndpoint"
                })
            }
        } catch {}
    }
    return @($devices | Sort-Object Type,Name,PnpDeviceId -Unique)
}

function ConvertTo-HdmiEventCategory {
    param($Event)
    $provider = [string]$Event.ProviderName
    $message = [string]$Event.Message
    $id = [int]$Event.Id
    if ($provider -eq 'Display' -and $id -eq 4101) { return "GPU_DRIVER_RESET" }
    if ($provider -match 'Windows Error Reporting' -and $message -match '(?i)LiveKernelEvent|141|117|193') { return "LIVE_KERNEL_EVENT" }
    if ($provider -match 'WHEA') { return "HARDWARE_ERROR" }
    if ($provider -match 'Kernel-Power|Power-Troubleshooter') { return "POWER_STATE" }
    if ($provider -match 'Kernel-PnP|DeviceSetupManager|DriverFrameworks' -and $message -match '(?i)display|monitor|audio|hdmi|hdaudio|VEN_1002|VEN_10DE|VEN_8086') { return "DISPLAY_DEVICE_CHANGE" }
    if ($message -match '(?i)display driver.*stopped responding|anzeigetreiber.*reagiert|TDR|amdkmdag|nvlddmkm|igdkmd') { return "GPU_DRIVER_EVENT" }
    if ($message -match '(?i)monitor|display|hdmi|hdaudio') { return "DISPLAY_RELATED_EVENT" }
    return "OTHER_RELEVANT_EVENT"
}

function Get-HdmiRelevantEvents {
    [CmdletBinding()]
    param(
        [datetime]$Since = (Get-Date).AddDays(-7),
        [int]$MaxEventsPerLog = 3000
    )

    $candidates = New-Object Collections.Generic.List[object]
    $queries = @(
        @{ LogName = "System"; Level = @(1,2,3) },
        @{ LogName = "Application"; Level = @(1,2,3) }
    )
    foreach ($query in $queries) {
        try {
            $events = @(Get-WinEvent -FilterHashtable @{ LogName=$query.LogName; StartTime=$Since; Level=$query.Level } -MaxEvents $MaxEventsPerLog -ErrorAction Stop)
            foreach ($event in $events) {
                $provider = [string]$event.ProviderName
                $message = [string]$event.Message
                $id = [int]$event.Id
                $relevant = $provider -match '(?i)Display|Graphics|DxgKrnl|Kernel-PnP|DeviceSetupManager|DriverFrameworks|WHEA|Kernel-Power|Power-Troubleshooter|Windows Error Reporting|amdkmdag|nvlddmkm|igfx|igdkmd|Audio' -or
                    $message -match '(?i)display|monitor|hdmi|hdaudio|graphics|gpu|LiveKernelEvent|TDR|amdkmdag|nvlddmkm|igdkmd'
                if (-not $relevant) { continue }
                $candidates.Add([pscustomobject]@{
                    TimeCreated = ([datetime]$event.TimeCreated).ToString("yyyy-MM-dd HH:mm:ss.fff")
                    Window = if ($event.TimeCreated -ge (Get-Date).AddHours(-1)) { "Letzte Stunde" } elseif ($event.TimeCreated -ge (Get-Date).AddHours(-24)) { "Letzte 24 Stunden" } else { "Letzte 7 Tage" }
                    Category = ConvertTo-HdmiEventCategory -Event $event
                    LogName = [string]$event.LogName
                    ProviderName = $provider
                    Id = $id
                    RecordId = $event.RecordId
                    Level = [string]$event.LevelDisplayName
                    Message = $message
                    Source = "Event Viewer: $($event.LogName), $provider, Event $id, Record $($event.RecordId)"
                })
            }
        } catch {}
    }

    $optionalLogs = @(
        "Microsoft-Windows-Kernel-PnP/Configuration",
        "Microsoft-Windows-DriverFrameworks-UserMode/Operational",
        "Microsoft-Windows-DeviceSetupManager/Admin"
    )
    foreach ($logName in $optionalLogs) {
        try {
            $log = Get-WinEvent -ListLog $logName -ErrorAction Stop
            if (-not $log.IsEnabled) { continue }
            foreach ($event in @(Get-WinEvent -FilterHashtable @{ LogName=$logName; StartTime=$Since } -MaxEvents 1000 -ErrorAction Stop)) {
                $message = [string]$event.Message
                if ($message -notmatch '(?i)display|monitor|hdmi|hdaudio|graphics|VEN_1002|VEN_10DE|VEN_8086') { continue }
                $candidates.Add([pscustomobject]@{
                    TimeCreated = ([datetime]$event.TimeCreated).ToString("yyyy-MM-dd HH:mm:ss.fff")
                    Window = if ($event.TimeCreated -ge (Get-Date).AddHours(-1)) { "Letzte Stunde" } elseif ($event.TimeCreated -ge (Get-Date).AddHours(-24)) { "Letzte 24 Stunden" } else { "Letzte 7 Tage" }
                    Category = ConvertTo-HdmiEventCategory -Event $event
                    LogName = [string]$event.LogName
                    ProviderName = [string]$event.ProviderName
                    Id = [int]$event.Id
                    RecordId = $event.RecordId
                    Level = [string]$event.LevelDisplayName
                    Message = $message
                    Source = "Event Viewer: $($event.LogName), $($event.ProviderName), Event $($event.Id), Record $($event.RecordId)"
                })
            }
        } catch {}
    }
    return @($candidates | Sort-Object TimeCreated -Descending -Unique)
}

function Get-HdmiBandwidthEstimate {
    param([Parameter(Mandatory=$true)]$Display)
    $bits = if ($Display.BitsPerColorChannel) { [double]$Display.BitsPerColorChannel } else { 8.0 }
    $encoding = [string]$Display.ColorEncoding
    $components = switch -Regex ($encoding) {
        '422' { 2.0; break }
        '420' { 1.5; break }
        default { 3.0 }
    }
    $bitsPerPixel = $bits * $components
    $pixelRate = [double]$Display.PixelRateHz
    $pixelRateSource = "Windows display signal timing"
    if ($pixelRate -le 0) {
        $pixelRate = [double]$Display.Width * [double]$Display.Height * [double]$Display.RefreshRateHz * 1.15
        $pixelRateSource = "active pixels plus assumed 15 percent timing overhead"
    }
    $payloadGbps = $pixelRate * $bitsPerPixel / 1e9
    $transportGbps = $payloadGbps * 1.25
    $classification = if ($transportGbps -lt 4) {
        "Niedrige Display-Bandbreite"
    } elseif ($transportGbps -lt 10) {
        "Mittlere Display-Bandbreite"
    } elseif ($transportGbps -le 18.2) {
        "Hohe HDMI-2.0-/TMDS-Bandbreite"
    } else {
        "HDMI-2.1-/FRL- oder DSC-Bereich"
    }
    [pscustomobject]@{
        Display = $Display.FriendlyName
        Mode = "{0}x{1} @ {2} Hz" -f $Display.Width, $Display.Height, $Display.RefreshRateHz
        ColorEncoding = $encoding
        BitsPerColorChannel = if ($Display.BitsPerColorChannel) { $Display.BitsPerColorChannel } else { "8 (angenommen)" }
        BitsPerPixel = $bitsPerPixel
        ActivePayloadGbps = [math]::Round($payloadGbps, 2)
        EstimatedTmdsTransportGbps = [math]::Round($transportGbps, 2)
        Classification = $classification
        Method = "Näherung aus Pixeltakt, Farbtiefe und Farbformat mit 8b/10b-Overhead; Blankings, DSC und tatsächlich ausgehandelter FRL-Modus können abweichen. Pixeltaktquelle: $pixelRateSource."
        Source = "Calculated from Windows CCD display state; not a physical HDMI measurement"
    }
}

function Get-HdmiSnapshotState {
    [CmdletBinding()]
    param(
        [string]$EdidOutputDirectory = "",
        [switch]$SkipSystem
    )
    $displays = @(Get-HdmiDisplayState)
    $gpus = if ($SkipSystem) { @() } else { @(Get-HdmiGpuInfo) }
    $edids = @(Get-HdmiEdidData -OutputDirectory $EdidOutputDirectory)
    $mappedDisplays = foreach ($display in $displays) {
        $edid = @($edids | Where-Object { $_.Key -and ($_.Key -eq $display.Key -or $display.Key -like ($_.Key + '*') -or $_.Key -like ($display.Key + '*')) }) | Select-Object -First 1
        $adapterPathNormalized = ([string]$display.AdapterDevicePath).ToUpperInvariant() -replace '#','\'
        $gpu = @($gpus | Where-Object {
            $pnp = ([string]$_.PnpDeviceId).ToUpperInvariant()
            if (-not $pnp) { return $false }
            $parts = @($pnp -split '\\')
            $matchKey = if ($parts.Count -ge 2) { "$($parts[0])\$($parts[1])" } else { $pnp }
            return $adapterPathNormalized.Contains($matchKey)
        }) | Select-Object -First 1
        $copy = [ordered]@{}
        foreach ($property in $display.PSObject.Properties) { $copy[$property.Name] = $property.Value }
        $copy["GpuName"] = if ($gpu) { $gpu.Name } else { $script:UnknownValue }
        $copy["GpuDriverVersion"] = if ($gpu) { $gpu.DriverVersion } else { "" }
        $copy["DesktopScalingPercent"] = $script:UnknownValue
        $copy["EdidDisplayName"] = if ($edid) { $edid.DisplayName } else { "" }
        $copy["EdidSha256"] = if ($edid) { $edid.Sha256 } else { "" }
        $copy["EdidSource"] = if ($edid) { $edid.Source } else { "" }
        [pscustomobject]$copy
    }
    [pscustomobject]@{
        CapturedAt = (Get-Date).ToString("yyyy-MM-dd HH:mm:ss.fff zzz")
        System = if ($SkipSystem) { $null } else { Get-HdmiSystemInfo }
        Gpus = @($gpus)
        Displays = @($mappedDisplays)
        Edid = @($edids)
        Audio = @(Get-HdmiAudioInfo)
        Source = "Combined read-only snapshot from Windows CCD API, CIM/WMI, PnP, and registry EDID fallback"
    }
}

function Get-HdmiComparableMap {
    param([Parameter(Mandatory=$true)]$State)
    $map = @{}
    foreach ($display in @($State.Displays)) {
        $key = if ($display.Key) { [string]$display.Key } elseif ($display.MonitorDevicePath) { [string]$display.MonitorDevicePath } else { [string]$display.SourceName }
        $map["DISPLAY|$key"] = [ordered]@{
            Kind = "Display"
            Name = $display.FriendlyName
            Width = $display.Width
            Height = $display.Height
            RefreshRateHz = $display.RefreshRateHz
            ConnectorType = $display.ConnectorType
            HdrEnabled = $display.HdrEnabled
            HdrSupported = $display.HdrSupported
            ColorEncoding = $display.ColorEncoding
            BitsPerColorChannel = $display.BitsPerColorChannel
            EdidSha256 = $display.EdidSha256
            AdapterDevicePath = $display.AdapterDevicePath
        }
    }
    foreach ($audio in @($State.Audio)) {
        $key = if ($audio.PnpDeviceId) { [string]$audio.PnpDeviceId } else { [string]$audio.Name }
        $map["AUDIO|$key"] = [ordered]@{
            Kind = "Audio"
            Name = $audio.Name
            Status = $audio.Status
            Present = $audio.Present
        }
    }
    foreach ($gpu in @($State.Gpus)) {
        $key = if ($gpu.PnpDeviceId) { [string]$gpu.PnpDeviceId } else { [string]$gpu.Name }
        $map["GPU|$key"] = [ordered]@{
            Kind = "GPU"
            Name = $gpu.Name
            Status = $gpu.Status
            DriverVersion = $gpu.DriverVersion
            DriverDate = $gpu.DriverDate
        }
    }
    return $map
}

function Compare-HdmiSnapshotState {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory=$true)]$Before,
        [Parameter(Mandatory=$true)]$After
    )
    $beforeMap = Get-HdmiComparableMap -State $Before
    $afterMap = Get-HdmiComparableMap -State $After
    $keys = @($beforeMap.Keys + $afterMap.Keys | Sort-Object -Unique)
    $changes = New-Object Collections.Generic.List[object]
    foreach ($key in $keys) {
        if (-not $beforeMap.ContainsKey($key)) {
            $changes.Add([pscustomobject]@{ Timestamp=$After.CapturedAt; EventType=($afterMap[$key].Kind.ToUpperInvariant() + "_CONNECTED"); Device=$afterMap[$key].Name; Property="Presence"; Before="Missing"; After="Present"; Key=$key })
            continue
        }
        if (-not $afterMap.ContainsKey($key)) {
            $changes.Add([pscustomobject]@{ Timestamp=$After.CapturedAt; EventType=($beforeMap[$key].Kind.ToUpperInvariant() + "_DISCONNECTED"); Device=$beforeMap[$key].Name; Property="Presence"; Before="Present"; After="Missing"; Key=$key })
            continue
        }
        foreach ($property in $beforeMap[$key].Keys) {
            if ($property -eq "Kind" -or $property -eq "Name") { continue }
            $beforeValue = [string]$beforeMap[$key][$property]
            $afterValue = [string]$afterMap[$key][$property]
            if ($beforeValue -ne $afterValue) {
                $eventType = switch -Regex ($property) {
                    'Width|Height' { "RESOLUTION_CHANGED"; break }
                    'RefreshRate' { "REFRESH_RATE_CHANGED"; break }
                    'Hdr' { "HDR_STATE_CHANGED"; break }
                    'Edid' { "EDID_CHANGED"; break }
                    'Driver' { "GPU_DRIVER_CHANGED"; break }
                    default { ($beforeMap[$key].Kind.ToUpperInvariant() + "_STATE_CHANGED") }
                }
                $changes.Add([pscustomobject]@{ Timestamp=$After.CapturedAt; EventType=$eventType; Device=$afterMap[$key].Name; Property=$property; Before=$beforeValue; After=$afterValue; Key=$key })
            }
        }
    }
    return [object[]]$changes.ToArray()
}

function Get-HdmiDiagnostics {
    param(
        [Parameter(Mandatory=$true)]$State,
        [object[]]$Events = @(),
        [object[]]$ObservedChanges = @()
    )
    $findings = New-Object Collections.Generic.List[object]
    $gpuEvents = @($Events | Where-Object { $_.Category -match 'GPU_DRIVER_RESET|LIVE_KERNEL_EVENT|GPU_DRIVER_EVENT' })
    $deviceEvents = @($Events | Where-Object { $_.Category -eq 'DISPLAY_DEVICE_CHANGE' })
    $displayChanges = @($ObservedChanges | Where-Object { $_.EventType -match 'DISPLAY_(CONNECTED|DISCONNECTED)|EDID_CHANGED' })
    $audioChanges = @($ObservedChanges | Where-Object { $_.EventType -match 'AUDIO_(CONNECTED|DISCONNECTED)' })
    $badEdid = @($State.Edid | Where-Object { -not $_.ValidHeader -or -not $_.BaseChecksumValid -or -not $_.ExtensionChecksumsValid })
    $bandwidth = @($State.Displays | ForEach-Object { Get-HdmiBandwidthEstimate -Display $_ })

    if (@($State.Displays).Count -eq 0) {
        $findings.Add([pscustomobject]@{ Severity="High"; Category="Display"; Title="Kein aktiver Displaypfad erkannt"; Confidence="Starker Verdacht"; Explanation="Windows meldet aktuell keinen aktiven Desktop-Displaypfad."; Evidence="QueryDisplayConfig lieferte keine aktiven Ziele."; Source="Windows CCD API" })
    }
    if ($gpuEvents.Count -gt 0) {
        $latest = $gpuEvents | Select-Object -First 1
        $findings.Add([pscustomobject]@{ Severity="High"; Category="GPU-Treiber"; Title="Grafiktreiber- oder GPU-Ereignisse gefunden"; Confidence="Starker Verdacht"; Explanation="Ein zeitnaher Grafiktreiber-Reset oder LiveKernelEvent macht GPU, Treiber oder Systemstabilität wahrscheinlicher als ein reines Kabelproblem."; Evidence=("{0} relevante Ereignisse; zuletzt {1}, {2} Event {3}." -f $gpuEvents.Count,$latest.TimeCreated,$latest.ProviderName,$latest.Id); Source=$latest.Source })
    }
    if ($displayChanges.Count -gt 0) {
        $findings.Add([pscustomobject]@{ Severity="Warning"; Category="Signalpfad"; Title="Windows erkennt Änderungen am Displaypfad"; Confidence="Mittlerer Verdacht"; Explanation="Ein echter Disconnect/Reconnect erhöht den Verdacht auf Kabel, Stecker, Port, AVR/Switch, Hot-Plug-Detect oder Stromversorgung des Displays."; Evidence="$($displayChanges.Count) im Live-/Snapshot-Vergleich erkannte Displayänderungen"; Source="Live monitor or snapshot comparison" })
    } elseif ($deviceEvents.Count -gt 0) {
        $latestDeviceEvent = $deviceEvents | Select-Object -First 1
        $findings.Add([pscustomobject]@{ Severity="Info"; Category="Geräteverlauf"; Title="Displaybezogene PnP-/Installationsereignisse vorhanden"; Confidence="Schwacher Verdacht"; Explanation="Diese Einträge liefern Kontext zu Treiber- und Geräteänderungen, beweisen allein aber keinen HDMI-Reconnect und kein Kabelproblem."; Evidence=("{0} passende Ereignisse in bis zu sieben Tagen; zuletzt {1}." -f $deviceEvents.Count,$latestDeviceEvent.TimeCreated); Source=$latestDeviceEvent.Source })
    }
    if ($audioChanges.Count -gt 0) {
        $findings.Add([pscustomobject]@{ Severity="Warning"; Category="HDMI-Audio"; Title="Display-Audio änderte sich während der Beobachtung"; Confidence="Mittlerer Verdacht"; Explanation="Der gleichzeitige Verlust des Audioendpunkts spricht für eine Änderung des gesamten Display-/Handshake-Pfads und nicht nur für einen Bildfehler in einer Anwendung."; Evidence="$($audioChanges.Count) Audioänderungen"; Source="Live monitor or snapshot comparison" })
    }
    foreach ($edid in $badEdid) {
        $findings.Add([pscustomobject]@{ Severity="Warning"; Category="EDID"; Title="EDID ist unvollständig oder besitzt eine ungültige Prüfsumme"; Confidence="Mittlerer Verdacht"; Explanation="Das kann auf einen unvollständigen Registry-Eintrag, einen fehlerhaften Handshake oder nicht sauber gelesene Erweiterungsblöcke hindeuten. Es beweist keinen Kabeldefekt."; Evidence=("{0}: Header={1}, Basis-Prüfsumme={2}, Erweiterungen={3}" -f $edid.DisplayName,$edid.ValidHeader,$edid.BaseChecksumValid,$edid.ExtensionChecksumsValid); Source=$edid.Source })
    }
    foreach ($estimate in @($bandwidth | Where-Object { $_.Classification -match 'Hohe|HDMI-2.1' })) {
        $findings.Add([pscustomobject]@{ Severity="Info"; Category="Bandbreite"; Title="Aktiver Modus benötigt eine hohe geschätzte Übertragungsrate"; Confidence="Hinweis"; Explanation="Fehler, die nur bei diesem Modus auftreten, erhöhen den Verdacht auf Bandbreitenreserve, Kabel, Port oder Zwischenhardware. Die Berechnung ist keine Signalqualitätsmessung."; Evidence=("{0}: {1}, geschätzt {2} Gbit/s" -f $estimate.Display,$estimate.Mode,$estimate.EstimatedTmdsTransportGbps); Source=$estimate.Source })
    }
    if ($findings.Count -eq 0) {
        $findings.Add([pscustomobject]@{ Severity="OK"; Category="Übersicht"; Title="Keine eindeutige Displaystörung in den erfassten Daten"; Confidence="Hinweis"; Explanation="Der aktuelle Zustand ist unauffällig. Sporadische Schwarzbilder benötigen für eine zeitliche Zuordnung den Live-Monitor."; Evidence="Keine passenden GPU-Reset-, Reconnect- oder EDID-Prüfsummenbefunde."; Source="Combined diagnostic rules" })
    }

    $scores = [ordered]@{
        "Kabel/Signalpfad" = 0
        "GPU/Treiber" = 0
        "EDID/Handshake" = 0
        "HDMI-Audio" = 0
    }
    if ($displayChanges.Count -gt 0) { $scores["Kabel/Signalpfad"] += 2; $scores["EDID/Handshake"] += 2 }
    if ($deviceEvents.Count -gt 0) { $scores["Kabel/Signalpfad"] += 1; $scores["EDID/Handshake"] += 1 }
    if ($gpuEvents.Count -gt 0) { $scores["GPU/Treiber"] += 3 }
    if ($badEdid.Count -gt 0) { $scores["EDID/Handshake"] += 2 }
    if ($audioChanges.Count -gt 0) { $scores["HDMI-Audio"] += 2; $scores["Kabel/Signalpfad"] += 1 }
    $confidence = foreach ($name in $scores.Keys) {
        $score = $scores[$name]
        [pscustomobject]@{
            Category = $name
            Confidence = if ($score -ge 3) { "Starker Verdacht" } elseif ($score -eq 2) { "Mittlerer Verdacht" } elseif ($score -eq 1) { "Schwacher Verdacht" } else { "Hinweis" }
            Score = $score
            Basis = switch ($name) {
                "Kabel/Signalpfad" { "Windows-seitig erkannte Display-/Audio-Pfadänderungen" }
                "GPU/Treiber" { "TDR-, Display-, WER- und LiveKernel-Ereignisse" }
                "EDID/Handshake" { "EDID-Prüfsummen und Änderungen des Displaypfads" }
                "HDMI-Audio" { "Auftauchen oder Verschwinden von Audioendpunkten" }
            }
        }
    }
    $recommendations = New-Object Collections.Generic.List[object]
    if ($gpuEvents.Count -gt 0) {
        $recommendations.Add([pscustomobject]@{Priority=1;Test="GPU-Treiberzustand und Systemstabilität prüfen";Reason="Zeitgleiche TDR-/LiveKernel-Ereignisse sprechen stärker für GPU oder Treiber als für ein reines Kabelproblem."})
    }
    if ($displayChanges.Count -gt 0) {
        $recommendations.Add([pscustomobject]@{Priority=1;Test="Anderes zertifiziertes Kabel und anderen Port testen; AVR, Switch oder Splitter umgehen";Reason="Windows hat echte Änderungen des Displaypfads erkannt."})
    }
    if (@($bandwidth | Where-Object { $_.Classification -match 'Hohe|HDMI-2.1' }).Count -gt 0) {
        $recommendations.Add([pscustomobject]@{Priority=2;Test="Gleiche Auflösung zuerst mit 60 Hz und danach mit deaktiviertem HDR vergleichen";Reason="Damit wird geprüft, ob die Störung mit steigender Übertragungsrate korreliert."})
    }
    if ($badEdid.Count -gt 0) {
        $recommendations.Add([pscustomobject]@{Priority=2;Test="EDID nach erneutem Verbinden sowie direkt ohne Zwischenhardware vergleichen";Reason="Ungültige oder wechselnde EDID-Daten können auf Handshake- oder Pfadprobleme hindeuten."})
    }
    $recommendations.Add([pscustomobject]@{Priority=3;Test="Live-Monitor während des nächsten Schwarzbilds laufen lassen";Reason="Nur so lässt sich ein kurzer Bildausfall zeitlich einem Reconnect, Audioverlust oder GPU-Reset zuordnen."})
    [pscustomobject]@{ Findings=[object[]]$findings.ToArray(); Confidence=@($confidence); Bandwidth=@($bandwidth); Recommendations=[object[]]$recommendations.ToArray() }
}

function ConvertTo-HdmiTableHtml {
    param([object[]]$Rows, [hashtable[]]$Columns)
    if (@($Rows).Count -eq 0) { return '<div class="empty">Keine Daten erfasst.</div>' }
    $visible = New-Object Collections.Generic.List[hashtable]
    foreach ($column in $Columns) {
        $hasValue = $false
        foreach ($row in $Rows) {
            $value = $row.($column.Name)
            if ($null -ne $value -and [string]$value -ne "") { $hasValue = $true; break }
        }
        if ($hasValue) { $visible.Add($column) }
    }
    $builder = New-Object Text.StringBuilder
    [void]$builder.Append('<div class="table-wrap"><table><thead><tr>')
    foreach ($column in $visible) { [void]$builder.Append('<th>' + (ConvertTo-HdmiHtml $column.Label) + '</th>') }
    [void]$builder.Append('</tr></thead><tbody>')
    foreach ($row in $Rows) {
        [void]$builder.Append('<tr>')
        foreach ($column in $visible) {
            $value = $row.($column.Name)
            if ($value -is [array]) { $value = $value -join '; ' }
            $class = ""
            if ($column.Name -match 'Severity|Confidence|Status|HdrEnabled') {
                $text = [string]$value
                if ($text -match 'High|Error|Stark|False|Fehler') { $class = ' class="bad"' }
                elseif ($text -match 'Warning|Mittel') { $class = ' class="warn"' }
                elseif ($text -match 'OK|True|Aktiv') { $class = ' class="good"' }
                else { $class = ' class="info"' }
            }
            [void]$builder.Append('<td' + $class + '>' + (ConvertTo-HdmiHtml $value) + '</td>')
        }
        [void]$builder.Append('</tr>')
    }
    [void]$builder.Append('</tbody></table></div>')
    return $builder.ToString()
}

function New-HdmiHtmlReport {
    param(
        [Parameter(Mandatory=$true)]$State,
        [Parameter(Mandatory=$true)]$Diagnostics,
        [object[]]$Events,
        [Parameter(Mandatory=$true)][string]$Path
    )
    $system = $State.System
    $gpuSummary = @($State.Gpus | ForEach-Object { "$($_.Name) ($($_.DriverVersion))" }) -join "; "
    $displaySummary = @($State.Displays | ForEach-Object { "$($_.FriendlyName): $($_.Width)x$($_.Height) @ $($_.RefreshRateHz) Hz" }) -join "; "
    $problemCount = @($Diagnostics.Findings | Where-Object { $_.Severity -match 'High|Warning|Error' }).Count
    $statusClass = if ($problemCount -gt 0) { "warn" } else { "good" }

    $systemRows = @([pscustomobject]@{Computer=$system.ComputerName;Windows=("{0} {1} (Build {2})" -f $system.Windows,$system.Version,$system.Build);Mainboard=$system.Mainboard;BIOS=("{0} / {1}" -f $system.BiosVersion,$system.BiosDate);CPU=$system.Cpu;RAM=if($system.RamGB){"$($system.RamGB) GB"}else{""};Source=$system.Source})
    $html = @"
<!doctype html><html lang="de"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1">
<title>HDMI-/Display-Diagnose</title><style>
:root{--ink:#172033;--muted:#5c677d;--line:#cfd9e8;--panel:#f7f9fc;--blue:#2563eb;--blue-bg:#eff6ff;--green:#08783e;--green-bg:#e8fff1;--amber:#985800;--amber-bg:#fff7df;--red:#b42318;--red-bg:#fff0ee}*{box-sizing:border-box}body{margin:0;font:14px/1.42 Segoe UI,Arial,sans-serif;color:var(--ink);background:#fff}main{max-width:1680px;margin:auto;padding:22px 28px 48px}h1{font-size:25px;margin:0 0 4px}h2{font-size:17px;margin:0}.sub{color:var(--muted);margin-bottom:14px}.summary{display:grid;grid-template-columns:repeat(4,minmax(150px,1fr));border:1px solid var(--line);border-left:5px solid var(--blue);background:var(--blue-bg);margin:14px 0 18px}.metric{padding:10px 12px;border-right:1px solid var(--line)}.metric:last-child{border:0}.metric b{display:block;font-size:12px;color:var(--muted);font-weight:600}.metric span{font-weight:650}details{border:1px solid var(--line);border-left:5px solid var(--blue);margin:10px 0;background:var(--panel)}summary{cursor:pointer;padding:11px 14px;font-size:16px;font-weight:700;list-style:none}summary::-webkit-details-marker{display:none}summary:before{content:'›';display:inline-block;margin-right:8px;transform:rotate(0);transition:.15s}details[open] summary:before{transform:rotate(90deg)}.body{padding:0 14px 14px}.table-wrap{overflow:auto;border:1px solid var(--line);background:white}table{border-collapse:collapse;width:max-content;min-width:100%;font-size:12.5px}th,td{text-align:left;vertical-align:top;padding:7px 8px;border-right:1px solid var(--line);border-bottom:1px solid var(--line);min-width:82px;max-width:620px;overflow-wrap:anywhere}th{background:#edf2f8;position:sticky;top:0;white-space:nowrap}.empty{padding:13px;border:1px dashed var(--line);background:white;color:var(--muted)}.good,.warn,.bad,.info{font-weight:700}.good{color:var(--green);background:var(--green-bg)}.warn{color:var(--amber);background:var(--amber-bg)}.bad{color:var(--red);background:var(--red-bg)}.info{color:#174ea6;background:#eaf2ff}.notice{padding:10px 12px;background:#fff;border:1px solid var(--line);color:var(--muted)}code{font-family:Consolas,monospace}@media(max-width:850px){main{padding:14px}.summary{grid-template-columns:1fr 1fr}.metric:nth-child(2){border-right:0}}
</style></head><body><main><h1>HDMI-/Display-Diagnose</h1><div class="sub">Read-only Diagnose vom $(ConvertTo-HdmiHtml $State.CapturedAt). Keine Signalqualitätsmessung.</div>
<div class="summary"><div class="metric"><b>Status</b><span class="$statusClass">$problemCount Problemhinweis(e)</span></div><div class="metric"><b>GPU</b><span>$(ConvertTo-HdmiHtml $gpuSummary)</span></div><div class="metric"><b>Aktive Displays</b><span>$(@($State.Displays).Count)</span></div><div class="metric"><b>Modus</b><span>$(ConvertTo-HdmiHtml $displaySummary)</span></div></div>
<details open><summary>Auffälligkeiten und Diagnose</summary><div class="body">$(ConvertTo-HdmiTableHtml -Rows $Diagnostics.Findings -Columns @(@{Name='Severity';Label='Stufe'},@{Name='Category';Label='Kategorie'},@{Name='Title';Label='Befund'},@{Name='Confidence';Label='Sicherheit'},@{Name='Explanation';Label='Einordnung'},@{Name='Evidence';Label='Beleg'},@{Name='Source';Label='Quelle'}))</div></details>
<details open><summary>Wahrscheinliche Fehlerkategorien</summary><div class="body">$(ConvertTo-HdmiTableHtml -Rows $Diagnostics.Confidence -Columns @(@{Name='Category';Label='Kategorie'},@{Name='Confidence';Label='Bewertung'},@{Name='Basis';Label='Grundlage'}))</div></details>
<details open><summary>Empfohlene nächste Tests</summary><div class="body">$(ConvertTo-HdmiTableHtml -Rows $Diagnostics.Recommendations -Columns @(@{Name='Priority';Label='Reihenfolge'},@{Name='Test';Label='Test'},@{Name='Reason';Label='Warum'}))</div></details>
<details open><summary>System und wichtigste Hardware</summary><div class="body">$(ConvertTo-HdmiTableHtml -Rows $systemRows -Columns @(@{Name='Computer';Label='Computer'},@{Name='Windows';Label='Windows'},@{Name='Mainboard';Label='Mainboard'},@{Name='BIOS';Label='BIOS'},@{Name='CPU';Label='CPU'},@{Name='RAM';Label='RAM'},@{Name='Source';Label='Quelle'}))</div></details>
<details open><summary>Aktive Displays: $(@($State.Displays).Count)</summary><div class="body">$(ConvertTo-HdmiTableHtml -Rows $State.Displays -Columns @(@{Name='FriendlyName';Label='Display'},@{Name='GpuName';Label='Grafikadapter'},@{Name='GpuDriverVersion';Label='GPU-Treiber'},@{Name='ConnectorType';Label='Anschluss'},@{Name='Width';Label='Breite'},@{Name='Height';Label='Höhe'},@{Name='RefreshRateHz';Label='Hz'},@{Name='PhysicalRefreshRateHz';Label='physische Hz'},@{Name='Primary';Label='Primär'},@{Name='HdrSupported';Label='HDR unterstützt'},@{Name='HdrEnabled';Label='HDR aktiv'},@{Name='ColorEncoding';Label='Farbformat'},@{Name='BitsPerColorChannel';Label='Bit/Kanal'},@{Name='ScalingMode';Label='Pfadskalierung'},@{Name='DesktopScalingPercent';Label='Desktop-Skalierung'},@{Name='MonitorDevicePath';Label='Gerätepfad'},@{Name='Source';Label='Quelle'}))</div></details>
<details><summary>GPU und Treiber: $(@($State.Gpus).Count)</summary><div class="body">$(ConvertTo-HdmiTableHtml -Rows $State.Gpus -Columns @(@{Name='Name';Label='GPU'},@{Name='Manufacturer';Label='Hersteller'},@{Name='Status';Label='Status'},@{Name='DriverVersion';Label='Treiberversion'},@{Name='DriverDate';Label='Treiberdatum'},@{Name='WddmVersion';Label='WDDM'},@{Name='PnpDeviceId';Label='PNP-ID'},@{Name='Source';Label='Quelle'}))</div></details>
<details><summary>EDID: $(@($State.Edid).Count) Einträge</summary><div class="body"><div class="notice">EDID beschreibt gemeldete Fähigkeiten. Daraus wird keine definitive HDMI-Version und keine Kabelqualität abgeleitet.</div>$(ConvertTo-HdmiTableHtml -Rows $State.Edid -Columns @(@{Name='DisplayName';Label='Display'},@{Name='ManufacturerId';Label='Hersteller-ID'},@{Name='ProductId';Label='Produkt-ID'},@{Name='SerialNumber';Label='Seriennummer'},@{Name='EdidVersion';Label='EDID'},@{Name='PreferredTiming';Label='Preferred Timing'},@{Name='Cta861Present';Label='CTA-861'},@{Name='HdrStaticMetadata';Label='HDR-Metadaten'},@{Name='AudioSupported';Label='Audio'},@{Name='HdmiVsdb';Label='HDMI VSDB'},@{Name='HdmiForumVsdb';Label='HDMI Forum VSDB'},@{Name='MaxTmdsClockMHz';Label='Max. TMDS MHz'},@{Name='HdmiCapabilityStatement';Label='Einordnung'},@{Name='BaseChecksumValid';Label='Prüfsumme'},@{Name='RawFile';Label='Rohdatei'},@{Name='Source';Label='Quelle'}))</div></details>
<details><summary>Geschätzte Bandbreite</summary><div class="body"><div class="notice">Näherung, keine Messung. Blankings, DSC, Link-Training und tatsächlich ausgehandelter FRL-Modus können abweichen.</div>$(ConvertTo-HdmiTableHtml -Rows $Diagnostics.Bandwidth -Columns @(@{Name='Display';Label='Display'},@{Name='Mode';Label='Modus'},@{Name='ColorEncoding';Label='Farbformat'},@{Name='BitsPerColorChannel';Label='Bit/Kanal'},@{Name='EstimatedTmdsTransportGbps';Label='Geschätzt Gbit/s'},@{Name='Classification';Label='Einordnung'},@{Name='Method';Label='Methode'}))</div></details>
<details><summary>HDMI-/Display-Audio: $(@($State.Audio).Count)</summary><div class="body">$(ConvertTo-HdmiTableHtml -Rows $State.Audio -Columns @(@{Name='Type';Label='Typ'},@{Name='Name';Label='Gerät'},@{Name='Status';Label='Status'},@{Name='Present';Label='Vorhanden'},@{Name='PnpDeviceId';Label='PNP-ID'},@{Name='Source';Label='Quelle'}))</div></details>
<details><summary>Relevante Ereignisprotokolle: $(@($Events).Count)</summary><div class="body">$(ConvertTo-HdmiTableHtml -Rows $Events -Columns @(@{Name='TimeCreated';Label='Zeit'},@{Name='Window';Label='Zeitraum'},@{Name='Category';Label='Kategorie'},@{Name='ProviderName';Label='Quelle'},@{Name='Id';Label='ID'},@{Name='RecordId';Label='Datensatz'},@{Name='Level';Label='Stufe'},@{Name='Message';Label='Meldung'},@{Name='Source';Label='Herkunft'}))</div></details>
<details><summary>Grenzen der Softwarediagnose</summary><div class="body"><div class="notice">Windows kann keine HDMI-Bitfehlerrate, kein Augenmuster, keine elektrische Kabeldämpfung und keine physikalische Signalreserve messen. Auch HDMI-Version, HDCP-Verlauf, tatsächlicher TMDS-/FRL-Modus, VRR und Chroma-Unterabtastung sind nicht auf jedem Treiber zuverlässig verfügbar. Solche Werte werden nicht erfunden.</div></div></details>
</main></body></html>
"@
    [IO.File]::WriteAllText($Path, $html, [Text.UTF8Encoding]::new($false))
}

function New-HdmiTextReport {
    param($State,$Diagnostics,[object[]]$Events,[string]$Path)
    $lines = New-Object Collections.Generic.List[string]
    $lines.Add("HDMI-/Display-Diagnose")
    $lines.Add("Erfasst: $($State.CapturedAt)")
    $lines.Add("Read-only; keine physikalische HDMI-Signalqualitätsmessung.")
    $lines.Add("")
    $lines.Add("AUFFÄLLIGKEITEN")
    foreach ($finding in $Diagnostics.Findings) {
        $lines.Add("[$($finding.Severity)] $($finding.Title) - $($finding.Confidence)")
        $lines.Add("  $($finding.Explanation)")
        $lines.Add("  Beleg: $($finding.Evidence)")
        $lines.Add("  Quelle: $($finding.Source)")
    }
    $lines.Add("")
    $lines.Add("DISPLAYS")
    foreach ($display in $State.Displays) {
        $lines.Add("- $($display.FriendlyName): $($display.Width)x$($display.Height) @ $($display.RefreshRateHz) Hz, $($display.ConnectorType), HDR=$($display.HdrEnabled), $($display.ColorEncoding), $($display.BitsPerColorChannel) Bit/Kanal")
        $lines.Add("  Quelle: $($display.Source)")
    }
    $lines.Add("")
    $lines.Add("EVENTS: $(@($Events).Count)")
    $lines.Add("Rohdaten stehen in den JSON-Dateien des Ergebnisordners.")
    [IO.File]::WriteAllLines($Path, [string[]]$lines, [Text.UTF8Encoding]::new($false))
}

function Invoke-HdmiFullDiagnostic {
    [CmdletBinding()]
    param(
        [string]$OutputRoot = (Join-Path $env:SystemDrive "Temp\HDMIDiagnose"),
        [switch]$NoOpen
    )
    $timestamp = Get-Date -Format "yyyyMMdd_HHmmss"
    $computer = ConvertTo-HdmiSafeFileName -Value $env:COMPUTERNAME
    $runRoot = Join-Path $OutputRoot ("HDMIDiagnose_{0}_{1}" -f $computer,$timestamp)
    $edidRoot = Join-Path $runRoot "EDID"
    New-Item -ItemType Directory -Force -Path $edidRoot | Out-Null
    Write-Host "Erfasse Displaypfade, EDID, GPU, Audio und Ereignisse..." -ForegroundColor Cyan
    $state = Get-HdmiSnapshotState -EdidOutputDirectory $edidRoot
    $events = @(Get-HdmiRelevantEvents -Since (Get-Date).AddDays(-7))
    $diagnostics = Get-HdmiDiagnostics -State $state -Events $events

    Write-HdmiJson -Path (Join-Path $runRoot "System.json") -InputObject $state.System
    Write-HdmiJson -Path (Join-Path $runRoot "GPU.json") -InputObject $state.Gpus
    Write-HdmiJson -Path (Join-Path $runRoot "Displays.json") -InputObject $state.Displays
    Write-HdmiJson -Path (Join-Path $runRoot "EDID.json") -InputObject $state.Edid
    Write-HdmiJson -Path (Join-Path $runRoot "Audio.json") -InputObject $state.Audio
    Write-HdmiJson -Path (Join-Path $runRoot "Events.json") -InputObject $events
    Write-HdmiJson -Path (Join-Path $runRoot "Diagnostics.json") -InputObject $diagnostics
    Write-HdmiJson -Path (Join-Path $runRoot "Snapshot.json") -InputObject $state
    $htmlPath = Join-Path $runRoot "HDMIDiagnose_Result.html"
    $textPath = Join-Path $runRoot "HDMIDiagnose_Result.txt"
    New-HdmiHtmlReport -State $state -Diagnostics $diagnostics -Events $events -Path $htmlPath
    New-HdmiTextReport -State $state -Diagnostics $diagnostics -Events $events -Path $textPath
    $zipPath = "$runRoot.zip"
    try { Compress-Archive -LiteralPath $runRoot -DestinationPath $zipPath -Force -ErrorAction Stop } catch { Write-Warning "ZIP konnte nicht erstellt werden: $($_.Exception.Message)" }
    Write-Host "Bericht: $htmlPath" -ForegroundColor Green
    if (Test-Path -LiteralPath $zipPath) { Write-Host "Paket:   $zipPath" -ForegroundColor Green }
    if (-not $NoOpen) { Start-Process -FilePath $htmlPath | Out-Null }
    return [pscustomobject]@{ RunRoot=$runRoot; HtmlPath=$htmlPath; TextPath=$textPath; ZipPath=$zipPath; State=$state; Events=$events; Diagnostics=$diagnostics }
}

function Save-HdmiSnapshot {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory=$true)][string]$Name,
        [string]$OutputRoot = (Join-Path $env:SystemDrive "Temp\HDMIDiagnose")
    )
    $safeName = ConvertTo-HdmiSafeFileName -Value $Name
    $snapshotRoot = Join-Path $OutputRoot "Snapshots"
    $edidRoot = Join-Path $snapshotRoot ($safeName + "_EDID")
    New-Item -ItemType Directory -Force -Path $edidRoot | Out-Null
    $state = Get-HdmiSnapshotState -EdidOutputDirectory $edidRoot
    $path = Join-Path $snapshotRoot ($safeName + ".json")
    Write-HdmiJson -Path $path -InputObject $state
    Write-Host "Snapshot gespeichert: $path" -ForegroundColor Green
    return $path
}

function Compare-HdmiSnapshots {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory=$true)][string]$BeforeName,
        [Parameter(Mandatory=$true)][string]$AfterName,
        [string]$OutputRoot = (Join-Path $env:SystemDrive "Temp\HDMIDiagnose"),
        [switch]$NoOpen
    )
    $snapshotRoot = Join-Path $OutputRoot "Snapshots"
    $beforePath = if (Test-Path -LiteralPath $BeforeName) { $BeforeName } else { Join-Path $snapshotRoot ((ConvertTo-HdmiSafeFileName $BeforeName) + ".json") }
    $afterPath = if (Test-Path -LiteralPath $AfterName) { $AfterName } else { Join-Path $snapshotRoot ((ConvertTo-HdmiSafeFileName $AfterName) + ".json") }
    if (-not (Test-Path -LiteralPath $beforePath)) { throw "Snapshot nicht gefunden: $beforePath" }
    if (-not (Test-Path -LiteralPath $afterPath)) { throw "Snapshot nicht gefunden: $afterPath" }
    $before = Get-Content -LiteralPath $beforePath -Raw | ConvertFrom-Json
    $after = Get-Content -LiteralPath $afterPath -Raw | ConvertFrom-Json
    $changes = @(Compare-HdmiSnapshotState -Before $before -After $after)
    $timestamp = Get-Date -Format "yyyyMMdd_HHmmss"
    $resultRoot = Join-Path $OutputRoot ("SnapshotCompare_{0}" -f $timestamp)
    New-Item -ItemType Directory -Force -Path $resultRoot | Out-Null
    Write-HdmiJson -Path (Join-Path $resultRoot "Changes.json") -InputObject $changes
    $rows = ConvertTo-HdmiTableHtml -Rows $changes -Columns @(@{Name='Timestamp';Label='Zeit'},@{Name='EventType';Label='Änderung'},@{Name='Device';Label='Gerät'},@{Name='Property';Label='Eigenschaft'},@{Name='Before';Label='Vorher'},@{Name='After';Label='Nachher'},@{Name='Key';Label='Schlüssel'})
    $html = "<!doctype html><html lang='de'><head><meta charset='utf-8'><title>Display-Snapshotvergleich</title><style>body{font:14px Segoe UI,Arial;margin:24px;color:#172033}table{border-collapse:collapse;width:100%}th,td{padding:8px;border:1px solid #cfd9e8;text-align:left;vertical-align:top}th{background:#edf2f8}.table-wrap{overflow:auto}.empty{padding:12px;border:1px solid #cfd9e8}</style></head><body><h1>Display-Snapshotvergleich</h1><p>$(ConvertTo-HdmiHtml $beforePath)<br>gegen<br>$(ConvertTo-HdmiHtml $afterPath)</p><h2>Änderungen: $($changes.Count)</h2>$rows</body></html>"
    $htmlPath = Join-Path $resultRoot "SnapshotCompare.html"
    [IO.File]::WriteAllText($htmlPath, $html, [Text.UTF8Encoding]::new($false))
    Write-Host "Vergleich: $htmlPath" -ForegroundColor Green
    if (-not $NoOpen) { Start-Process -FilePath $htmlPath | Out-Null }
    return $changes
}

function Write-HdmiMonitorEntry {
    param([string]$TextPath,[string]$JsonPath,$Entry)
    $line = "{0}  {1}  {2}  {3}: {4} -> {5}" -f $Entry.Timestamp,$Entry.EventType,$Entry.Device,$Entry.Property,$Entry.Before,$Entry.After
    [IO.File]::AppendAllText($TextPath, $line + [Environment]::NewLine, [Text.UTF8Encoding]::new($false))
    [IO.File]::AppendAllText($JsonPath, (($Entry | ConvertTo-Json -Compress -Depth 6) + [Environment]::NewLine), [Text.UTF8Encoding]::new($false))
    Write-Host $line -ForegroundColor Yellow
}

function Start-HdmiLiveMonitor {
    [CmdletBinding()]
    param(
        [string]$OutputRoot = (Join-Path $env:SystemDrive "Temp\HDMIDiagnose"),
        [int]$MonitorSeconds = 0,
        [ValidateRange(500,10000)][int]$PollMilliseconds = 1000
    )
    $timestamp = Get-Date -Format "yyyyMMdd_HHmmss"
    $monitorRoot = Join-Path $OutputRoot ("Monitor_{0}_{1}" -f (ConvertTo-HdmiSafeFileName $env:COMPUTERNAME),$timestamp)
    New-Item -ItemType Directory -Force -Path $monitorRoot | Out-Null
    $textPath = Join-Path $monitorRoot "HDMI-Monitor.log"
    $jsonPath = Join-Path $monitorRoot "HDMI-Monitor.jsonl"
    [IO.File]::WriteAllText($textPath, "HDMI-/Display-Livemonitor gestartet: $((Get-Date).ToString('yyyy-MM-dd HH:mm:ss.fff'))`r`n", [Text.UTF8Encoding]::new($false))
    [IO.File]::WriteAllText($jsonPath, "", [Text.UTF8Encoding]::new($false))
    $before = Get-HdmiSnapshotState -SkipSystem
    Write-HdmiJson -Path (Join-Path $monitorRoot "InitialState.json") -InputObject $before
    $start = Get-Date
    $lastEventPoll = $start
    $seenEvents = @{}
    Write-Host "Live-Monitor aktiv. Q drücken, um ihn sauber zu beenden." -ForegroundColor Cyan
    try {
        while ($true) {
            Start-Sleep -Milliseconds $PollMilliseconds
            $after = Get-HdmiSnapshotState -SkipSystem
            foreach ($change in @(Compare-HdmiSnapshotState -Before $before -After $after)) {
                Write-HdmiMonitorEntry -TextPath $textPath -JsonPath $jsonPath -Entry $change
            }
            $before = $after

            if (((Get-Date) - $lastEventPoll).TotalSeconds -ge 5) {
                foreach ($event in @(Get-HdmiRelevantEvents -Since $lastEventPoll.AddSeconds(-1) -MaxEventsPerLog 200)) {
                    $eventKey = "$($event.LogName)|$($event.RecordId)"
                    if ($seenEvents.ContainsKey($eventKey)) { continue }
                    $seenEvents[$eventKey] = $true
                    $entry = [pscustomobject]@{
                        Timestamp = $event.TimeCreated
                        EventType = "WINDOWS_EVENT_$($event.Category)"
                        Device = $event.ProviderName
                        Property = "Event $($event.Id), Record $($event.RecordId)"
                        Before = ""
                        After = ($event.Message -replace '\s+', ' ').Trim()
                        Source = $event.Source
                    }
                    Write-HdmiMonitorEntry -TextPath $textPath -JsonPath $jsonPath -Entry $entry
                }
                $lastEventPoll = Get-Date
            }

            if ($MonitorSeconds -gt 0 -and ((Get-Date) - $start).TotalSeconds -ge $MonitorSeconds) { break }
            try {
                if ([Console]::KeyAvailable) {
                    $key = [Console]::ReadKey($true)
                    if ($key.Key -eq [ConsoleKey]::Q) { break }
                }
            } catch {}
        }
    } finally {
        Write-HdmiJson -Path (Join-Path $monitorRoot "FinalState.json") -InputObject $before
        [IO.File]::AppendAllText($textPath, "Monitor beendet: $((Get-Date).ToString('yyyy-MM-dd HH:mm:ss.fff'))`r`n", [Text.UTF8Encoding]::new($false))
        Write-Host "Monitorprotokoll: $textPath" -ForegroundColor Green
    }
    return $monitorRoot
}

function Show-HdmiEdid {
    [CmdletBinding()]
    param([string]$OutputRoot = (Join-Path $env:SystemDrive "Temp\HDMIDiagnose"))
    $root = Join-Path $OutputRoot ("EDID_{0}" -f (Get-Date -Format "yyyyMMdd_HHmmss"))
    New-Item -ItemType Directory -Force -Path $root | Out-Null
    $edids = @(Get-HdmiEdidData -OutputDirectory $root)
    Write-HdmiJson -Path (Join-Path $root "EDID.json") -InputObject $edids
    $edids | Select-Object DisplayName,ManufacturerId,ProductId,SerialNumber,EdidVersion,Cta861Present,HdrStaticMetadata,HdmiVsdb,HdmiForumVsdb,MaxTmdsClockMHz,BaseChecksumValid,RawFile | Format-Table -Wrap -AutoSize
    Write-Host "EDID-Rohdaten: $root" -ForegroundColor Green
    return $edids
}

function Show-HdmiEvents {
    [CmdletBinding()]
    param([string]$OutputRoot = (Join-Path $env:SystemDrive "Temp\HDMIDiagnose"),[int]$Days=7)
    New-Item -ItemType Directory -Force -Path $OutputRoot | Out-Null
    $events = @(Get-HdmiRelevantEvents -Since (Get-Date).AddDays(-1 * [math]::Abs($Days)))
    $path = Join-Path $OutputRoot ("HDMI_Events_{0}.json" -f (Get-Date -Format "yyyyMMdd_HHmmss"))
    Write-HdmiJson -Path $path -InputObject $events
    $events | Select-Object TimeCreated,Category,ProviderName,Id,RecordId,Level | Format-Table -AutoSize
    Write-Host "Ereignisse: $path" -ForegroundColor Green
    return $events
}

function Start-HdmiBandwidthAssistant {
    [CmdletBinding()]
    param([string]$OutputRoot = (Join-Path $env:SystemDrive "Temp\HDMIDiagnose"))
    $profiles = @(
        [pscustomobject]@{Id="A";Resolution="3840x2160";Refresh="120 Hz";HDR="Ein";Depth="10 Bit";Load="Sehr hoch"},
        [pscustomobject]@{Id="B";Resolution="3840x2160";Refresh="60 Hz";HDR="Ein";Depth="10 Bit";Load="Hoch"},
        [pscustomobject]@{Id="C";Resolution="3840x2160";Refresh="120 Hz";HDR="Aus";Depth="8 Bit";Load="Hoch"},
        [pscustomobject]@{Id="D";Resolution="3840x2160";Refresh="60 Hz";HDR="Aus";Depth="8 Bit";Load="Mittel"}
    )
    $root = Join-Path $OutputRoot ("BandwidthTest_{0}" -f (Get-Date -Format "yyyyMMdd_HHmmss"))
    New-Item -ItemType Directory -Force -Path $root | Out-Null
    $results = New-Object Collections.Generic.List[object]
    Write-Host "Der Assistent ändert keine Displayeinstellungen." -ForegroundColor Cyan
    foreach ($profile in $profiles) {
        Write-Host ""
        Write-Host ("TEST {0}: {1}, {2}, HDR {3}, {4} ({5})" -f $profile.Id,$profile.Resolution,$profile.Refresh,$profile.HDR,$profile.Depth,$profile.Load) -ForegroundColor Yellow
        $answer = Read-Host "Einstellung manuell setzen und Enter drücken; S überspringt den Test"
        if ($answer -match '^(?i)s') { continue }
        $before = Get-HdmiSnapshotState -SkipSystem
        $minutesText = Read-Host "Beobachtungszeit in Minuten [5]"
        $minutes = 5.0
        if ($minutesText) { [void][double]::TryParse($minutesText, [Globalization.NumberStyles]::Float, [Globalization.CultureInfo]::CurrentCulture, [ref]$minutes) }
        Write-Host "Beobachten. Das Tool wartet $minutes Minute(n)..." -ForegroundColor Cyan
        Start-Sleep -Milliseconds ([int]([math]::Max(1,$minutes * 60 * 1000)))
        $after = Get-HdmiSnapshotState -SkipSystem
        $changes = @(Compare-HdmiSnapshotState -Before $before -After $after)
        $blackoutsText = Read-Host "Wie viele Schwarzbilder/Abbrüche wurden beobachtet? [0]"
        $blackouts = 0
        [void][int]::TryParse($blackoutsText, [ref]$blackouts)
        $results.Add([pscustomobject]@{ Test=$profile.Id;Resolution=$profile.Resolution;Refresh=$profile.Refresh;HDR=$profile.HDR;Depth=$profile.Depth;Load=$profile.Load;Minutes=$minutes;ObservedBlackouts=$blackouts;WindowsStateChanges=$changes.Count;Changes=$changes })
    }
    $highFailures = @($results | Where-Object { $_.Load -match 'Sehr hoch|Hoch' -and $_.ObservedBlackouts -gt 0 }).Count
    $lowerFailures = @($results | Where-Object { $_.Load -eq 'Mittel' -and $_.ObservedBlackouts -gt 0 }).Count
    $conclusion = if ($highFailures -gt 0 -and $lowerFailures -eq 0) {
        "Fehler korrelieren mit höheren Datenraten. Kabel, Steckverbindung, Port, AVR/Switch oder Signalreserve werden wahrscheinlicher; kein Beweis für ein defektes Kabel."
    } elseif (@($results | Where-Object { $_.ObservedBlackouts -gt 0 }).Count -gt 0) {
        "Fehler sind nicht ausschließlich auf die höchste getestete Datenrate begrenzt. GPU/Treiber, Handshake, Display oder allgemeiner Signalpfad bleiben möglich."
    } else {
        "Während der protokollierten Tests wurde kein Schwarzbild angegeben."
    }
    $output = [pscustomobject]@{CapturedAt=(Get-Date).ToString("yyyy-MM-dd HH:mm:ss.fff");Results=[object[]]$results.ToArray();Conclusion=$conclusion;Source="User observations plus read-only Windows state snapshots"}
    $path = Join-Path $root "BandwidthTest.json"
    Write-HdmiJson -Path $path -InputObject $output
    [IO.File]::WriteAllText((Join-Path $root "Conclusion.txt"), $conclusion, [Text.UTF8Encoding]::new($false))
    Write-Host $conclusion -ForegroundColor Green
    Write-Host "Testergebnis: $path" -ForegroundColor Green
    return $output
}

function Open-HdmiLatestReport {
    param([string]$OutputRoot = (Join-Path $env:SystemDrive "Temp\HDMIDiagnose"))
    $report = Get-ChildItem -LiteralPath $OutputRoot -Filter "HDMIDiagnose_Result.html" -Recurse -File -ErrorAction SilentlyContinue | Sort-Object LastWriteTime -Descending | Select-Object -First 1
    if (-not $report) { throw "Kein HDMI-/Display-Bericht unter $OutputRoot gefunden." }
    Start-Process -FilePath $report.FullName | Out-Null
    return $report.FullName
}

Export-ModuleMember -Function @(
    'ConvertFrom-HdmiEdid',
    'Get-HdmiSystemInfo',
    'Get-HdmiGpuInfo',
    'Get-HdmiDisplayState',
    'Get-HdmiEdidData',
    'Get-HdmiAudioInfo',
    'Get-HdmiRelevantEvents',
    'Get-HdmiBandwidthEstimate',
    'Get-HdmiSnapshotState',
    'Compare-HdmiSnapshotState',
    'Get-HdmiDiagnostics',
    'Invoke-HdmiFullDiagnostic',
    'Save-HdmiSnapshot',
    'Compare-HdmiSnapshots',
    'Start-HdmiLiveMonitor',
    'Show-HdmiEdid',
    'Show-HdmiEvents',
    'Start-HdmiBandwidthAssistant',
    'Open-HdmiLatestReport'
)
