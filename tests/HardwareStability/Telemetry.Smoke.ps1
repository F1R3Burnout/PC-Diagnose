[CmdletBinding()]
param(
    [string]$ToolCacheRoot = "",
    [switch]$RequireCpuTemperature
)

# Smoke test for the telemetry load path on the CURRENT host (run it once under
# powershell.exe and once under pwsh). It downloads LibreHardwareMonitorLib and,
# under Windows PowerShell 5.1, its hash-verified .NET Framework dependencies,
# loads the library, opens CPU/GPU/motherboard sensors and takes one sample.
# It starts no load and changes nothing outside the tool cache folder.
# CPU temperature is only required with -RequireCpuTemperature, because it
# depends on the separately installed PawnIO driver.

$ErrorActionPreference = "Stop"
$repoRoot = Resolve-Path (Join-Path $PSScriptRoot "..\..")
$libRoot = Join-Path $repoRoot "lib\HardwareStability"
$configPath = Join-Path $repoRoot "config\HardwareStabilityTools.json"
if (-not $ToolCacheRoot) { $ToolCacheRoot = Join-Path ([IO.Path]::GetTempPath()) "PC-Diagnose-TelemetrySmoke" }

Import-Module (Join-Path $libRoot "ToolManager.psm1") -Force
Import-Module (Join-Path $libRoot "Telemetry.psm1") -Force

$failures = @()
$ok = Initialize-HsTelemetry -ConfigPath $configPath -ToolCacheRoot $ToolCacheRoot
$status = Get-HsTelemetryStatus
$status | ConvertTo-Json -Depth 4 | Write-Host

if (-not $ok) { $failures += "Initialize-HsTelemetry returned false" }
if ($null -eq $status) { $failures += "No telemetry status recorded" }
elseif (@($status.MissingDependencies).Count -gt 0) { $failures += "Missing dependencies: $(@($status.MissingDependencies) -join '; ')" }
if (-not ("LibreHardwareMonitor.Hardware.Computer" -as [type])) { $failures += "LibreHardwareMonitorLib was not loaded" }

if ($ok) {
    $rows = Get-HsTelemetrySample -Stage "SMOKE"
    Write-Host "Sensor values in one sample: $(@($rows).Count)"
    @($rows) | Select-Object -First 25 | Format-Table HardwareType, HardwareName, SensorType, SensorName, Value -AutoSize | Out-String | Write-Host
    if (@($rows | Where-Object { $null -eq $_ }).Count -gt 0) { $failures += "Sample contains null rows" }
}
if ($RequireCpuTemperature -and ($null -eq $status -or -not $status.CpuTemperatureAvailable)) {
    $failures += "No CPU temperature (PawnIO installed: $(if ($status) { $status.PawnIoInstalled } else { 'unknown' }))"
}

Close-HsTelemetry

if ($failures.Count -gt 0) {
    $failures | ForEach-Object { Write-Host "FAIL: $_" -ForegroundColor Red }
    exit 1
}
Write-Host "Telemetry smoke test passed on $($PSVersionTable.PSEdition) $($PSVersionTable.PSVersion)." -ForegroundColor Green
exit 0
