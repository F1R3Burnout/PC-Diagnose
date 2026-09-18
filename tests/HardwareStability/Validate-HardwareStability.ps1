<#
.SYNOPSIS
    Automated acceptance-gate runner for the Hardware-Stabilitaetstest
    (docs/HARDWARE_STABILITY_ACCEPTANCE.md). Exit code 0 = all mandatory
    automatable gates passed; non-zero = at least one gate failed.
#>

[CmdletBinding()]
param(
    [switch]$SkipRegression
)

$ErrorActionPreference = "Stop"
$RepoRoot = Resolve-Path (Join-Path $PSScriptRoot "..\..")
$script:GateResults = New-Object System.Collections.ArrayList

function Set-Gate {
    param([string]$Id, [bool]$Passed, [string]$Detail = "")
    [void]$script:GateResults.Add([pscustomobject]@{ Id = $Id; Passed = $Passed; Detail = $Detail })
    $color = if ($Passed) { "Green" } else { "Red" }
    $status = if ($Passed) { "PASS" } else { "FAIL" }
    Write-Host ("{0} [{1}] {2}" -f $Id, $status, $Detail) -ForegroundColor $color
}

Write-Host "=== HS-001: PowerShell files parse successfully ===" -ForegroundColor Cyan
$psFiles = Get-ChildItem -Path $RepoRoot -Recurse -File | Where-Object {
    $_.Extension -in ".ps1", ".psm1" -or $_.Name -eq "r"
} | Where-Object { $_.FullName -notmatch '\\node_modules\\' }
$parseFailures = @()
foreach ($file in $psFiles) {
    $tokens = $null; $errors = $null
    [System.Management.Automation.Language.Parser]::ParseFile($file.FullName, [ref]$tokens, [ref]$errors) | Out-Null
    if ($errors.Count -gt 0) { $parseFailures += $file.FullName }
}
Set-Gate "HS-001" ($parseFailures.Count -eq 0) "$($psFiles.Count) file(s) checked, $($parseFailures.Count) parse failure(s): $($parseFailures -join ', ')"

Write-Host "`n=== HS-002: manifest.json is valid JSON with existing paths ===" -ForegroundColor Cyan
$manifestOk = $true
$manifestDetail = ""
try {
    $manifest = Get-Content -Raw -Path (Join-Path $RepoRoot "manifest.json") | ConvertFrom-Json
    foreach ($tool in $manifest.tools) {
        if (-not (Test-Path -LiteralPath (Join-Path $RepoRoot $tool.path))) { $manifestOk = $false; $manifestDetail = "Missing path: $($tool.path)" }
        foreach ($dep in @($tool.dependencies)) {
            if ($dep -and -not (Test-Path -LiteralPath (Join-Path $RepoRoot $dep))) { $manifestOk = $false; $manifestDetail = "Missing dependency: $dep" }
        }
    }
} catch {
    $manifestOk = $false
    $manifestDetail = $_.Exception.Message
}
Set-Gate "HS-002" $manifestOk $manifestDetail

Write-Host "`n=== HS-003: Hardware-Stabilitaetstest is registered in the main menu ===" -ForegroundColor Cyan
$hsEntry = $manifest.tools | Where-Object { $_.id -eq "hardwarestability" }
Set-Gate "HS-003" ($null -ne $hsEntry -and $hsEntry.name -eq "Hardware-Stabilitätstest") "manifest entry present with public name 'Hardware-Stabilitätstest'"

Write-Host "`n=== HS-004 / HS-005 / HS-006 / HS-007: Direct invocation, DryRun, no active load, Unicode ===" -ForegroundColor Cyan
$dryRunOutput = & pwsh -NoProfile -File (Join-Path $RepoRoot "scripts\diagnostics\HardwareStability.ps1") -DryRun -Profile Quick 2>&1
$dryRunExit = $LASTEXITCODE
$dryRunText = $dryRunOutput -join "`n"
Set-Gate "HS-004" ($dryRunExit -eq 0) "Direct invocation via -File exits 0"
Set-Gate "HS-005" ($dryRunText -match "DRY RUN") "DryRun banner present in output"
$outputRootHasStabilityDirs = @(Get-ChildItem -Path "C:\Temp" -Directory -Filter "PCStability_*" -ErrorAction SilentlyContinue)
Set-Gate "HS-006" ($outputRootHasStabilityDirs.Count -eq 0) "DryRun created no PCStability_* result folders under C:\Temp"

Write-Host "`n=== HS-008 through HS-047: fixture suite ===" -ForegroundColor Cyan
& pwsh -NoProfile -File (Join-Path $PSScriptRoot "HardwareStability.Fixtures.Tests.ps1")
Set-Gate "HS-008..047" ($LASTEXITCODE -eq 0) "tests/HardwareStability/HardwareStability.Fixtures.Tests.ps1 exit code $LASTEXITCODE (covers HS-007..HS-047; see its own PASS/FAIL lines for the exact gate list)"

Write-Host "`n=== HS-048: existing PC-Diagnose tools still work (regression) ===" -ForegroundColor Cyan
if (-not $SkipRegression) {
    $regressionOk = $true
    $regressionDetail = @()
    try {
        & pwsh -NoProfile -File (Join-Path $RepoRoot "tests\HDMIDiagnose.Tests.ps1") | Out-Null
        if ($LASTEXITCODE -ne 0) { $regressionOk = $false; $regressionDetail += "HDMIDiagnose.Tests.ps1 exit $LASTEXITCODE" }
    } catch {
        $regressionOk = $false
        $regressionDetail += "HDMIDiagnose.Tests.ps1 threw: $($_.Exception.Message)"
    }
    Set-Gate "HS-048" $regressionOk ($regressionDetail -join "; ")
} else {
    Set-Gate "HS-048" $true "Skipped by -SkipRegression"
}

Write-Host "`n=== HS-049: git diff --check ===" -ForegroundColor Cyan
Push-Location $RepoRoot
try {
    $diffCheck = git diff --check 2>&1
    $diffCheckStaged = git diff --cached --check 2>&1
    Set-Gate "HS-049" ([string]::IsNullOrWhiteSpace(($diffCheck -join "")) -and [string]::IsNullOrWhiteSpace(($diffCheckStaged -join ""))) (($diffCheck + $diffCheckStaged) -join " | ")
} finally {
    Pop-Location
}

Write-Host "`n=== HS-050: no accidentally versioned temp/download/test artifacts ===" -ForegroundColor Cyan
Push-Location $RepoRoot
try {
    $status = git status --porcelain
    $suspicious = @($status | Where-Object { $_ -match '\.(zip|dmp|log)$' -or $_ -match 'HsToolCache|PCStability_|hwstability_writeverify' })
    Set-Gate "HS-050" ($suspicious.Count -eq 0) "$($suspicious.Count) suspicious path(s): $($suspicious -join '; ')"
} finally {
    Pop-Location
}

Write-Host ""
$failedGates = @($script:GateResults | Where-Object { -not $_.Passed })
Write-Host ("Gates: {0} passed, {1} failed." -f (@($script:GateResults | Where-Object Passed).Count), $failedGates.Count) -ForegroundColor $(if ($failedGates.Count -eq 0) { "Green" } else { "Red" })
if ($failedGates.Count -gt 0) {
    Write-Host "Failed gates:" -ForegroundColor Red
    foreach ($g in $failedGates) { Write-Host "  $($g.Id): $($g.Detail)" -ForegroundColor Red }
    exit 1
}
exit 0
