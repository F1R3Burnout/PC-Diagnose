[CmdletBinding()]
param(
    [string]$OutputRoot = "",
    [string]$ToolCacheRoot = ""
)

# Smoke run of the REAL stress test tools (needs Administrator rights and
# internet): FurMark 2 (SHA256 from the winget manifest), the Visual C++
# runtime installer (SHA256 + Microsoft signature, downloaded only, not run
# here) are downloaded and verified exactly as in a real run, then
# StressTest.ps1 runs a short GPU test with the real
# FurMark. A CI VM has no real GPU, so FurMark may end early - this checks
# that the tool chain works and the script reports cleanly, not the hardware.

$ErrorActionPreference = "Stop"
$repoRoot = Resolve-Path (Join-Path $PSScriptRoot "..\..")
$libRoot = Join-Path $repoRoot "lib\HardwareStability"
$configPath = Join-Path $repoRoot "config\HardwareStabilityTools.json"
if (-not $OutputRoot) { $OutputRoot = Join-Path ([IO.Path]::GetTempPath()) "PC-Diagnose-StressSmoke" }
if (-not $ToolCacheRoot) { $ToolCacheRoot = Join-Path ([IO.Path]::GetTempPath()) "PC-Diagnose-StressSmokeTools" }
New-Item -ItemType Directory -Force -Path $OutputRoot, $ToolCacheRoot | Out-Null

Import-Module (Join-Path $libRoot "Common.psm1") -Force
Import-Module (Join-Path $libRoot "ToolManager.psm1") -Force
Import-Module (Join-Path $libRoot "StressTest.psm1") -Force

$failures = @()
$config = Get-HsToolConfig -ConfigPath $configPath
foreach ($toolId in @("furmark2", "vcredist_x64")) {
    $tool = Resolve-HsTool -ToolId $toolId -ToolConfig $config -ToolCacheRoot $ToolCacheRoot
    Write-Host ("{0}: available={1} - {2} ({3})" -f $toolId, $tool.Available, $tool.Reason, $tool.ExecutablePath)
    if (-not $tool.Available) { $failures += "${toolId}: $($tool.Reason)" }
}
$vcInstaller = Join-Path $ToolCacheRoot "vcredist_x64\VC_redist.x64.exe"
if (Test-Path -LiteralPath $vcInstaller) {
    $vcSignature = Test-HsAuthenticodeSigner -Path $vcInstaller -SubjectPattern "O=Microsoft Corporation"
    Write-Host "VC++ runtime installer signature: $($vcSignature.Status) $($vcSignature.Subject)"
    if (-not $vcSignature.Valid) { $failures += "VC++ runtime installer is not validly signed by Microsoft" }
}
Write-Host "Visual C++ runtime present on this machine: $(Test-HsVcRuntimeInstalled)"

$before = @(Get-ChildItem -LiteralPath $OutputRoot -Directory -Filter "PCStress_*" -ErrorAction SilentlyContinue | ForEach-Object { $_.FullName })
& (Join-Path $repoRoot "scripts\diagnostics\StressTest.ps1") -Mode GPU -Minutes 0.3 -NoPrompt -SkipTelemetry `
    -OutputRoot $OutputRoot -ToolCacheRoot $ToolCacheRoot
$runDir = @(Get-ChildItem -LiteralPath $OutputRoot -Directory -Filter "PCStress_*" | Where-Object { $before -notcontains $_.FullName } | Select-Object -Last 1)
if ($runDir.Count -eq 0) {
    $failures += "No result folder was created"
} else {
    $resultPath = Join-Path $runDir[0].FullName "00_Result.json"
    if (-not (Test-Path -LiteralPath $resultPath)) {
        $failures += "00_Result.json is missing"
    } else {
        $result = Get-Content -Raw -LiteralPath $resultPath | ConvertFrom-Json
        Write-Host "Stress test result: $($result.Status); FurMark: $($result.Gpu.Status) - $($result.Gpu.Reason)"
        if ($null -eq $result.Gpu -or [string]$result.Gpu.Reason -match "nicht verfuegbar") { $failures += "FurMark did not run: $($result.Gpu.Reason)" }
        $output = Get-Content -Raw -LiteralPath (Join-Path $runDir[0].FullName "FurMark_output.txt") -ErrorAction SilentlyContinue
        if ($output) { Write-Host "FurMark output (last lines):"; ($output -split "`r?`n" | Select-Object -Last 12) | ForEach-Object { Write-Host "  $_" } }
    }
}
if (@(Get-Process -Name "furmark" -ErrorAction SilentlyContinue).Count -gt 0) { $failures += "FurMark is still running after the test" }

if ($failures.Count -gt 0) {
    $failures | ForEach-Object { Write-Host "FAIL: $_" -ForegroundColor Red }
    exit 1
}
Write-Host "Stress test smoke run passed on $($PSVersionTable.PSEdition) $($PSVersionTable.PSVersion)." -ForegroundColor Green
exit 0
