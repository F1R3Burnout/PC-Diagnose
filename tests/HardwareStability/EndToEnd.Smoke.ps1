[CmdletBinding()]
param(
    [string]$OutputRoot = "",
    [double]$StageMinutes = 0.5,
    [string]$Components = "CPU,Cache,CoreCycle,RAM,GPU,Storage,PCIe,System",
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
    foreach ($file in @("00_Result.html", "00_Summary.txt", "00_TestStages.csv", "02_Telemetry\TelemetryStatus.json", "02_Telemetry\StageTelemetry.csv")) {
        if (-not (Test-Path -LiteralPath (Join-Path $run $file))) { $failures += "Missing $file" }
    }
    if (-not (Test-Path -LiteralPath "$run.zip")) { $failures += "Missing result ZIP" }
    $stages = @(Import-Csv -LiteralPath (Join-Path $run "00_TestStages.csv"))
    Write-Host ""
    $stages | Format-Table Status, Component, Coverage -AutoSize | Out-String -Width 220 | Write-Host
    foreach ($stage in @($stages | Where-Object { $_.Status -ne "PASS" })) {
        Write-Host ("{0} {1}: {2}" -f $stage.Status, $stage.Component, $stage.Assessment) -ForegroundColor Yellow
    }
    $unhandled = @($stages | Where-Object { [string]$_.Assessment -match "unexpected error" })
    foreach ($stage in $unhandled) { $failures += "Unhandled script error in '$($stage.Component)': $($stage.Assessment)" }
    $surface = @($stages | Where-Object { $_.StageName -eq "STORAGE_SURFACE" -and $_.Status -ne "SKIPPED" })
    if ($RetestComponents -match "Storage" -and $surface.Count -eq 0) { $failures += "The surface scan never ran (physical disk could not be opened)" }
    $retests = @($stages | Where-Object { [string]$_.Component -match "\(Retest 1" })
    if ($retests.Count -eq 0) { $failures += "No retest stage was recorded" }
    $system = @($stages | Where-Object { $_.StageName -eq "SYSTEM_STABILITY" })
    if ($Components -match "System" -and ($system.Count -eq 0 -or [string]$system[0].Coverage -notmatch "RAM:")) { $failures += "System stability did not include the RAM load" }
    $runtimeLog = Get-Content -Raw -LiteralPath (Join-Path $run "99_Runtime\runtime.log") -ErrorAction SilentlyContinue
    if ($runtimeLog -match "Temperature display failed") { $failures += "Temperature display threw during the run (see runtime.log)" }
    # Surface scan and write/verify run in a background runspace during the
    # GPU stages; their results must still arrive at the Storage stages.
    if ($Components -match "GPU" -and $Components -match "Storage" -and [string]$runtimeLog -notmatch "Parallel gestartet") { $failures += "The storage checks were not started in parallel with the GPU stages" }
    foreach ($stage in @($stages | Where-Object { $_.StageName -in @("STORAGE_SURFACE","STORAGE_WRITE_VERIFY") -and [string]$_.Assessment -match "did not complete" })) {
        $failures += "Background storage check returned no result in '$($stage.Component)': $($stage.Assessment)"
    }
    $coreCycle = @($stages | Where-Object { $_.StageName -eq "CPU_CORE_CYCLE" })
    if ($Components -match "CoreCycle" -and $coreCycle.Count -eq 0) { $failures += "The core-by-core stage did not run" }
    $writeVerify = @($stages | Where-Object { $_.StageName -eq "STORAGE_WRITE_VERIFY" })
    if ($Components -match "Storage" -and ($writeVerify.Count -eq 0 -or @($writeVerify | Where-Object { $_.Status -ne "PASS" }).Count -gt 0)) { $failures += "Write/read verification did not PASS in every round ($(@($writeVerify | ForEach-Object { $_.Status }) -join ', '))" }
    $html = Get-Content -Raw -LiteralPath (Join-Path $run "00_Result.html")
    if ($html -notmatch "Temperature monitoring") { $failures += "Report lacks the temperature monitoring section" }
}

if ($failures.Count -gt 0) {
    $failures | ForEach-Object { Write-Host "FAIL: $_" -ForegroundColor Red }
    exit 1
}
Write-Host "End-to-end smoke run passed on $($PSVersionTable.PSEdition) $($PSVersionTable.PSVersion)." -ForegroundColor Green
exit 0
