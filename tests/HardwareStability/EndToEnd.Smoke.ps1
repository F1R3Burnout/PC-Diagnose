[CmdletBinding()]
param(
    [string]$OutputRoot = "",
    [double]$StageMinutes = 0.5,
    [string]$Components = "CPU,Cache,RAM,GPU,Storage,PCIe,System",
    [string]$RetestComponents = "Cache,RAM,Storage"
)

# End-to-end smoke run of the REAL HardwareStability.ps1 (needs Administrator
# rights): real downloads, real Prime95/MemoryChecker/D3D11/disk stages, every
# time-bound stage capped to -StageMinutes, followed by an automatic targeted
# retest. It checks that the run completes, writes its report, runs the retest
# and never ends a stage on an unhandled script error. It does NOT judge the
# hardware - a CI VM may legitimately report UNSUPPORTED/SKIPPED stages.

$ErrorActionPreference = "Stop"
$repoRoot = Resolve-Path (Join-Path $PSScriptRoot "..\..")
if (-not $OutputRoot) { $OutputRoot = Join-Path ([IO.Path]::GetTempPath()) "PC-Diagnose-E2E" }
New-Item -ItemType Directory -Force -Path $OutputRoot | Out-Null
$before = @(Get-ChildItem -LiteralPath $OutputRoot -Directory -Filter "PCStability_*" -ErrorAction SilentlyContinue | ForEach-Object { $_.FullName })

& (Join-Path $repoRoot "scripts\diagnostics\HardwareStability.ps1") -Profile Quick -NoPrompt -OutputRoot $OutputRoot `
    -Components $Components -MaxStageMinutes $StageMinutes -RetestComponents $RetestComponents -RetestMinutes $StageMinutes

$runDir = @(Get-ChildItem -LiteralPath $OutputRoot -Directory -Filter "PCStability_*" | Where-Object { $before -notcontains $_.FullName } | Sort-Object LastWriteTime | Select-Object -Last 1)
$failures = @()
if ($runDir.Count -eq 0) {
    $failures += "No result folder was created"
} else {
    $run = $runDir[0].FullName
    foreach ($file in @("00_Result.html", "00_Summary.txt", "00_TestStages.csv", "02_Telemetry\TelemetryStatus.json")) {
        if (-not (Test-Path -LiteralPath (Join-Path $run $file))) { $failures += "Missing $file" }
    }
    if (-not (Test-Path -LiteralPath "$run.zip")) { $failures += "Missing result ZIP" }
    $stages = @(Import-Csv -LiteralPath (Join-Path $run "00_TestStages.csv"))
    Write-Host ""
    $stages | Format-Table Status, Component, Coverage -AutoSize | Out-String -Width 220 | Write-Host
    $unhandled = @($stages | Where-Object { [string]$_.Assessment -match "unexpected error" })
    foreach ($stage in $unhandled) { $failures += "Unhandled script error in '$($stage.Component)': $($stage.Assessment)" }
    $retests = @($stages | Where-Object { [string]$_.Component -match "\(Retest 1" })
    if ($retests.Count -eq 0) { $failures += "No retest stage was recorded" }
    $system = @($stages | Where-Object { $_.StageName -eq "SYSTEM_STABILITY" })
    if ($Components -match "System" -and ($system.Count -eq 0 -or [string]$system[0].Coverage -notmatch "RAM:")) { $failures += "System stability did not include the RAM load" }
    $html = Get-Content -Raw -LiteralPath (Join-Path $run "00_Result.html")
    if ($html -notmatch "Temperature monitoring") { $failures += "Report lacks the temperature monitoring section" }
}

if ($failures.Count -gt 0) {
    $failures | ForEach-Object { Write-Host "FAIL: $_" -ForegroundColor Red }
    exit 1
}
Write-Host "End-to-end smoke run passed on $($PSVersionTable.PSEdition) $($PSVersionTable.PSVersion)." -ForegroundColor Green
exit 0
