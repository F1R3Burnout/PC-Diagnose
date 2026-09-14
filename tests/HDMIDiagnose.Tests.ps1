[CmdletBinding()]
param()

$ErrorActionPreference = "Stop"
$modulePath = Join-Path $PSScriptRoot "..\lib\HDMIDiagnostics.Core.psm1"
Import-Module $modulePath -Force

function Assert-True {
    param([bool]$Condition,[string]$Message)
    if (-not $Condition) { throw "Assertion failed: $Message" }
}

$edid = New-Object byte[] 128
$header = [byte[]](0x00,0xFF,0xFF,0xFF,0xFF,0xFF,0xFF,0x00)
[Array]::Copy($header,0,$edid,0,8)
$edid[8] = 0x1E
$edid[9] = 0x6D
$edid[10] = 0x34
$edid[11] = 0x12
$edid[18] = 1
$edid[19] = 4
$edid[21] = 60
$edid[22] = 34
$edid[54] = 0x02
$edid[55] = 0x3A
$edid[56] = 0x80
$edid[57] = 0x18
$edid[58] = 0x71
$edid[59] = 0x38
$edid[60] = 0x2D
$edid[61] = 0x40
$edid[72] = 0
$edid[73] = 0
$edid[74] = 0
$edid[75] = 0xFC
$edid[76] = 0
$nameBytes = [Text.Encoding]::ASCII.GetBytes("TEST DISPLAY`n")
[Array]::Copy($nameBytes,0,$edid,77,[math]::Min(13,$nameBytes.Length))
$sum = 0
foreach ($value in $edid[0..126]) { $sum = ($sum + $value) -band 0xFF }
$edid[127] = [byte]((256 - $sum) -band 0xFF)

$parsed = ConvertFrom-HdmiEdid -Bytes $edid
Assert-True $parsed.ValidHeader "EDID header should be valid"
Assert-True $parsed.BaseChecksumValid "EDID checksum should be valid"
Assert-True ($parsed.DisplayName -eq "TEST DISPLAY") "display name should be decoded"
Assert-True ($parsed.PreferredTiming.Width -eq 1920 -and $parsed.PreferredTiming.Height -eq 1080) "preferred timing should be decoded"

$display = [pscustomobject]@{FriendlyName="Mock 4K";Width=3840;Height=2160;RefreshRateHz=120;BitsPerColorChannel=10;ColorEncoding="RGB";PixelRateHz=1188000000}
$bandwidth = Get-HdmiBandwidthEstimate -Display $display
Assert-True ($bandwidth.Classification -match "HDMI-2.1") "4K120 10-bit RGB estimate should reach the FRL range"

$beforeDisplay = [pscustomobject]@{Key="DISPLAY\ABC\1";FriendlyName="Mock";Width=3840;Height=2160;RefreshRateHz=60;ConnectorType="HDMI";HdrEnabled=$false;HdrSupported=$true;ColorEncoding="RGB";BitsPerColorChannel=8;PixelRateHz=594000000;EdidSha256="A";AdapterDevicePath="GPU"}
$afterDisplay = $beforeDisplay | Select-Object *
$afterDisplay.RefreshRateHz = 120
$before = [pscustomobject]@{CapturedAt="2026-01-01 10:00:00.000";Displays=@($beforeDisplay);Audio=@();Gpus=@()}
$after = [pscustomobject]@{CapturedAt="2026-01-01 10:01:00.000";Displays=@($afterDisplay);Audio=@();Gpus=@()}
$changes = @(Compare-HdmiSnapshotState -Before $before -After $after)
Assert-True (@($changes | Where-Object EventType -eq "REFRESH_RATE_CHANGED").Count -eq 1) "refresh change should be detected"

$secondDisplay = $beforeDisplay | Select-Object *
$secondDisplay.Key = "DISPLAY\XYZ\2"
$secondDisplay.FriendlyName = "Second Mock"
$multiBefore = [pscustomobject]@{CapturedAt="2026-01-01 10:00:00.000";Displays=@($beforeDisplay,$secondDisplay);Audio=@();Gpus=@()}
$disconnectChanges = @(Compare-HdmiSnapshotState -Before $multiBefore -After $after)
Assert-True (@($disconnectChanges | Where-Object EventType -eq "DISPLAY_DISCONNECTED").Count -eq 1) "a disconnected display in a multi-display snapshot should be detected"

$state = [pscustomobject]@{Displays=@($afterDisplay);Edid=@();Audio=@();Gpus=@()}
$events = @([pscustomobject]@{Category="GPU_DRIVER_RESET";TimeCreated="2026-01-01 10:00:30.000";ProviderName="Display";Id=4101;Source="Mock event"})
$diagnostics = Get-HdmiDiagnostics -State $state -Events $events
Assert-True (@($diagnostics.Findings | Where-Object Category -eq "GPU-Treiber").Count -eq 1) "GPU reset should produce a high-confidence finding"

Write-Host "HDMIDiagnose unit tests passed." -ForegroundColor Green
