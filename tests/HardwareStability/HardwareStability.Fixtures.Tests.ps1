[CmdletBinding()]
param()

$ErrorActionPreference = "Stop"
$RepoRoot = Resolve-Path (Join-Path $PSScriptRoot "..\..")
$LibRoot = Join-Path $RepoRoot "lib\HardwareStability"
$ConfigPath = Join-Path $RepoRoot "config\HardwareStabilityTools.json"

Import-Module (Join-Path $LibRoot "Common.psm1") -Force
Import-Module (Join-Path $LibRoot "ProcessRunner.psm1") -Force
Import-Module (Join-Path $LibRoot "ToolManager.psm1") -Force
Import-Module (Join-Path $LibRoot "Profiles.psm1") -Force
Import-Module (Join-Path $LibRoot "Inventory.psm1") -Force
Import-Module (Join-Path $LibRoot "ThermalGuard.psm1") -Force
Import-Module (Join-Path $LibRoot "EventCorrelation.psm1") -Force
Import-Module (Join-Path $LibRoot "CrashRecovery.psm1") -Force
Import-Module (Join-Path $LibRoot "CpuTests.psm1") -Force
Import-Module (Join-Path $LibRoot "MemoryTests.psm1") -Force
Import-Module (Join-Path $LibRoot "GpuTests.psm1") -Force
Import-Module (Join-Path $LibRoot "StorageWriteVerify.psm1") -Force
Import-Module (Join-Path $LibRoot "Reporting.psm1") -Force
Import-Module (Join-Path $PSScriptRoot "FixtureTools.psm1") -Force

$script:PassCount = 0
$script:FailCount = 0

function Assert-True {
    param([bool]$Condition, [string]$Message)
    if ($Condition) {
        $script:PassCount++
        Write-Host "  PASS: $Message" -ForegroundColor Green
    } else {
        $script:FailCount++
        Write-Host "  FAIL: $Message" -ForegroundColor Red
    }
}

$FixtureCache = Join-Path $env:TEMP "HsFixtureToolCache_$([guid]::NewGuid().ToString('N'))"
New-Item -ItemType Directory -Force -Path $FixtureCache | Out-Null

try {

Write-Host "`n=== HS-008 Hardware inventory ===" -ForegroundColor Cyan
$inv = Get-HsHardwareInventory
Assert-True (-not [string]::IsNullOrWhiteSpace($inv.ComputerName)) "HS-008 inventory returns a computer name"
Assert-True ($inv.PhysicalRamBytes -gt 0) "HS-008 inventory returns physical RAM size"
Assert-True (@($inv.Cpus).Count -ge 1) "HS-008 inventory returns at least one CPU"

Write-Host "`n=== HS-007 Unicode-safe process execution ===" -ForegroundColor Cyan
$uniDir = Join-Path $env:TEMP "Ünicode Test Öl"
New-Item -ItemType Directory -Force -Path $uniDir | Out-Null
$r = Invoke-HsProcess -FilePath "pwsh" -ArgumentList @("-NoProfile","-Command","exit 0") -WorkingDirectory $uniDir -TimeoutSeconds 15
Assert-True ($r.ExitCode -eq 0) "HS-007 process runs correctly with a Unicode working directory"
Remove-Item -Recurse -Force $uniDir -ErrorAction SilentlyContinue

Write-Host "`n=== HS-009 / HS-010 RAM verification fixtures ===" -ForegroundColor Cyan
$mcCache = Join-Path $FixtureCache "memorychecker"
New-HsFakeMemoryChecker -Path (Join-Path $mcCache "MemoryChecker.exe") -ExitCode 0
$ramPass = Invoke-HsRamVerification -ConfigPath $ConfigPath -ToolCacheRoot $FixtureCache -OutputDirectory (Join-Path $FixtureCache "ram_pass_out") -Passes 1 -PercentOfPhysicalRam 1 -NoDownload
Assert-True ($ramPass.Status -eq "PASS") "HS-009 RAM PASS fixture (exit code 0) => PASS"

Remove-Item -Recurse -Force $mcCache -ErrorAction SilentlyContinue
New-HsFakeMemoryChecker -Path (Join-Path $mcCache "MemoryChecker.exe") -ExitCode 1
$ramFail = Invoke-HsRamVerification -ConfigPath $ConfigPath -ToolCacheRoot $FixtureCache -OutputDirectory (Join-Path $FixtureCache "ram_fail_out") -Passes 1 -PercentOfPhysicalRam 1 -NoDownload
Assert-True ($ramFail.Status -eq "FAIL") "HS-010 RAM Error fixture (exit code 1) => FAIL"

Write-Host "`n=== HS-011 / HS-012 / HS-013 / HS-014 Prime95 fixtures ===" -ForegroundColor Cyan
$p95Cache = Join-Path $FixtureCache "prime95"
New-HsFakePrime95 -Path (Join-Path $p95Cache "prime95.exe") -FailureText ""
$cpuPass = Invoke-HsCpuTortureTest -StageName "CPU_COMPUTE" -ConfigPath $ConfigPath -ToolCacheRoot $FixtureCache -OutputDirectory (Join-Path $FixtureCache "cpu_pass_out") -DurationMinutes 0.05 -LogicalProcessors 8 -PhysicalCores 4 -NoDownload
Assert-True ($cpuPass.Status -eq "PASS") "HS-011 Prime95 PASS fixture (no failure text) => PASS"
Assert-True ($cpuPass.Workers -eq 4) "HS-014 CPU_COMPUTE uses one worker per physical core (4)"

Remove-Item -Recurse -Force $p95Cache -ErrorAction SilentlyContinue
New-HsFakePrime95 -Path (Join-Path $p95Cache "prime95.exe") -FailureText "FATAL ERROR: hardware failure detected"
$cpuFatal = Invoke-HsCpuTortureTest -StageName "CPU_COMPUTE" -ConfigPath $ConfigPath -ToolCacheRoot $FixtureCache -OutputDirectory (Join-Path $FixtureCache "cpu_fatal_out") -DurationMinutes 0.1 -LogicalProcessors 8 -PhysicalCores 4 -NoDownload
Assert-True ($cpuFatal.Status -eq "FAIL") "HS-012 Prime95 FATAL ERROR fixture => FAIL"

Remove-Item -Recurse -Force $p95Cache -ErrorAction SilentlyContinue
New-HsFakePrime95 -Path (Join-Path $p95Cache "prime95.exe") -FailureText "ROUND OFF error exceeds threshold"
$cpuRoundoff = Invoke-HsCpuTortureTest -StageName "CPU_CACHE_IMC" -ConfigPath $ConfigPath -ToolCacheRoot $FixtureCache -OutputDirectory (Join-Path $FixtureCache "cpu_roundoff_out") -DurationMinutes 0.1 -LogicalProcessors 8 -PhysicalCores 4 -NoDownload
Assert-True ($cpuRoundoff.Status -eq "FAIL") "HS-013 Prime95 ROUND OFF fixture => FAIL"
Assert-True ($cpuRoundoff.Workers -eq 8) "HS-014 CPU_CACHE_IMC uses one worker per logical processor (8), distinct from CPU_COMPUTE (4)"

Write-Host "`n=== HS-015 / HS-016 / HS-018 / HS-019 GPU Compute ===" -ForegroundColor Cyan
$gpuPass = Invoke-HsGpuComputeVerification -ElementCount 1024 -Iterations 1
Assert-True ($gpuPass.Status -in @("PASS","UNSUPPORTED")) "HS-015 GPU Compute real run completes as PASS or (if no D3D11) UNSUPPORTED"
Assert-True (Test-HsGpuComputeMismatchDetection) "HS-016 GPU Compute mismatch-detection fixture correctly flags a differing result"
Write-Host "  NOTE: HS-018/HS-019 (Device Lost / TDR) code path exists (DXGI_ERROR_DEVICE_REMOVED handling in D3D11ComputeVerifier.cs) but was not exercised against a real TDR - forcing a real driver reset was judged unsafe on this production machine. See docs/HARDWARE_STABILITY_STATE.md." -ForegroundColor Yellow

Write-Host "`n=== HS-020 / HS-021 VRAM fixtures ===" -ForegroundColor Cyan
$mvCache = Join-Path $FixtureCache "memtest_vulkan"
New-HsFakeMemtestVulkan -Path (Join-Path $mvCache "memtest_vulkan-v0.5.0.exe") -Behavior "pass"
$vramPass = Invoke-HsVramVerification -ConfigPath $ConfigPath -ToolCacheRoot $FixtureCache -OutputDirectory (Join-Path $FixtureCache "vram_pass_out") -DurationMinutes 0.05 -NoDownload
Assert-True ($vramPass.Status -eq "PASS") "HS-020 VRAM PASS fixture => PASS"

Remove-Item -Recurse -Force $mvCache -ErrorAction SilentlyContinue
New-HsFakeMemtestVulkan -Path (Join-Path $mvCache "memtest_vulkan-v0.5.0.exe") -Behavior "error"
$vramFail = Invoke-HsVramVerification -ConfigPath $ConfigPath -ToolCacheRoot $FixtureCache -OutputDirectory (Join-Path $FixtureCache "vram_fail_out") -DurationMinutes 0.05 -NoDownload
Assert-True ($vramFail.Status -eq "FAIL") "HS-021 VRAM Error fixture ('Error found') => FAIL"

Write-Host "`n=== HS-030 / HS-031 Storage Write/Read Verification ===" -ForegroundColor Cyan
$wv = Invoke-HsStorageWriteReadVerify -Directory (Join-Path $FixtureCache "writeverify") -SizeMB 8
Assert-True ($wv.Status -eq "PASS") "HS-030 Storage Write/Read Verification uses only a normal test file and PASSes"
Assert-True (-not (Test-Path $wv.TestFilePath)) "HS-030 Test file is removed after the run"
$crcA = Get-HsCrc32 -Bytes ([byte[]](1,2,3,4,5))
$crcB = Get-HsCrc32 -Bytes ([byte[]](1,2,3,4,6))
Assert-True ($crcA -ne $crcB) "HS-031 Checksum comparison detects a single-byte difference (mismatch => FAIL path)"

Write-Host "`n=== HS-027 / HS-028 / HS-029 Raw disk read-only safety (static check) ===" -ForegroundColor Cyan
$rawDiskSource = Get-Content -Raw (Join-Path $LibRoot "Native\RawDiskReader.cs")
Assert-True ($rawDiskSource -match "GENERIC_READ") "HS-027 RawDiskReader references GENERIC_READ"
Assert-True ($rawDiskSource -notmatch "GENERIC_WRITE") "HS-028 RawDiskReader never references GENERIC_WRITE"
Assert-True ($rawDiskSource -notmatch "WriteFile\(") "HS-029 RawDiskReader never calls WriteFile"
Assert-True ($rawDiskSource -notmatch "FileAccess\.Write") "HS-029 RawDiskReader never uses FileAccess.Write"

Write-Host "`n=== HS-032 / HS-033 WHEA classification ===" -ForegroundColor Cyan
$whea17Pcie = [pscustomobject]@{ ProviderName = "Microsoft-Windows-WHEA-Logger"; Id = 17; Message = "A corrected hardware error has occurred. Reported by component: PCI Express Root Port"; EventData = "" }
$cat17 = Get-HsWheaCategory -Event $whea17Pcie
Assert-True ($cat17 -eq "PCIe") "HS-032 WHEA 17 with PCIe text is categorized as PCIe, not over-interpreted as a generic mainboard defect"
$wheaAssessment = Get-HsWheaAssessment -Category $cat17
Assert-True ($wheaAssessment -notmatch "(?i)mainboard is defective|definitely defective") "HS-032 WHEA assessment does not claim a definitive mainboard defect"
$whea18Cache = [pscustomobject]@{ ProviderName = "Microsoft-Windows-WHEA-Logger"; Id = 18; Message = "cache hierarchy error"; EventData = "" }
Assert-True ((Get-HsWheaCategory -Event $whea18Cache) -eq "Machine Check Exception") "HS-033 WHEA CPU/cache-related event (ID 18) is recognized"

Write-Host "`n=== HS-034 / HS-035 / HS-036 / HS-037 Crash recovery / SYSTEM_RESET ===" -ForegroundColor Cyan
$pendingPath = Get-HsPendingRunPath
Set-HsPendingRun -RunId "fixture-run" -ResultDirectory $FixtureCache -Profile "Quick" -Stage "RAM" -ExpectedEnd (Get-Date).AddMinutes(5) -Status "Running" | Out-Null
Assert-True (Test-Path -LiteralPath $pendingPath) "HS-034 PendingRun.json is persisted before an active stage"
$pendingRead = Get-HsPendingRun
Clear-HsPendingRun

$pendingBase = [pscustomobject]@{ Status = "Running"; StageStarted = "2026-01-01T10:00:00"; BootTimeAtStageStart = "2026-01-01T08:00:00" }
$resetRows = @(
    [pscustomobject]@{ ProviderName = "Microsoft-Windows-Kernel-Power"; Id = 41; Message = ""; EventData = ""; RecordId = 1; TimeCreated = "2026-01-01T10:05:00" },
    [pscustomobject]@{ ProviderName = "EventLog"; Id = 6008; Message = ""; EventData = ""; RecordId = 2; TimeCreated = "2026-01-01T10:05:05" }
)
$resetCheck = Test-HsSystemResetSinceRun -PendingRun $pendingBase -EventRowsOverride $resetRows -CurrentBootTimeOverride ([datetime]"2026-01-01T10:05:00")
Assert-True ($resetCheck.Classification -eq "SYSTEM_RESET") "HS-035 PendingRun + reboot + 41 + 6008 (no 1074) => SYSTEM_RESET"

$plannedRows = @(
    [pscustomobject]@{ ProviderName = "User32"; Id = 1074; Message = "planned"; EventData = ""; RecordId = 3; TimeCreated = "2026-01-01T10:00:30" },
    [pscustomobject]@{ ProviderName = "EventLog"; Id = 6006; Message = ""; EventData = ""; RecordId = 4; TimeCreated = "2026-01-01T10:00:35" }
)
$plannedCheck = Test-HsSystemResetSinceRun -PendingRun $pendingBase -EventRowsOverride $plannedRows -CurrentBootTimeOverride ([datetime]"2026-01-01T10:05:00")
Assert-True ($plannedCheck.Classification -eq "PLANNED") "HS-036 1074 + 6006 => not classified as a hardware crash"

$bugcheckRows = @(
    [pscustomobject]@{ ProviderName = "Microsoft-Windows-WER-SystemErrorReporting"; Id = 1001; Message = "The computer has rebooted from a bugcheck. The bugcheck was 0x0000009c"; EventData = ""; RecordId = 5; TimeCreated = "2026-01-01T10:05:00" }
)
$bugcheckCheck = Test-HsSystemResetSinceRun -PendingRun $pendingBase -EventRowsOverride $bugcheckRows -CurrentBootTimeOverride ([datetime]"2026-01-01T10:05:00")
Assert-True ($bugcheckCheck.Classification -eq "SYSTEM_RESET") "HS-037 BugCheck 1001 is correctly distinguished (=> SYSTEM_RESET, blue screen evidence)"
Assert-True ($bugcheckCheck.Notes -match "0x0000009c") "HS-037 BugCheck code is extracted from the event"

Write-Host "`n=== HS-039 Timeout kills the process tree ===" -ForegroundColor Cyan
$sw = [Diagnostics.Stopwatch]::StartNew()
$timeoutResult = Invoke-HsProcess -FilePath "pwsh" -ArgumentList @("-NoProfile","-Command","Start-Sleep -Seconds 30") -TimeoutSeconds 2
$sw.Stop()
Assert-True ($timeoutResult.TimedOut -eq $true) "HS-039 Invoke-HsProcess reports TimedOut for a process exceeding its timeout"
Assert-True ($sw.Elapsed.TotalSeconds -lt 10) "HS-039 The process is actually stopped near the timeout, not left running for the full 30s"

Write-Host "`n=== HS-040 / HS-041 Thermal Guard ===" -ForegroundColor Cyan
$thresholds = Get-HsThermalDefaults
$okRows = @([pscustomobject]@{ HardwareType = "Cpu"; SensorType = "Temperature"; SensorName = "CPU Package"; Value = 60 })
Assert-True ((Test-HsThermalState -Rows $okRows -Thresholds $thresholds).State -eq "OK") "HS-040 Normal temperature => OK"
$warnRows = @([pscustomobject]@{ HardwareType = "Cpu"; SensorType = "Temperature"; SensorName = "CPU Package"; Value = 96 })
Assert-True ((Test-HsThermalState -Rows $warnRows -Thresholds $thresholds).State -eq "WARNING") "HS-040 Temperature above warning threshold => WARNING"
$abortRows = @([pscustomobject]@{ HardwareType = "Cpu"; SensorType = "Temperature"; SensorName = "CPU Package"; Value = 101 })
Assert-True ((Test-HsThermalState -Rows $abortRows -Thresholds $thresholds).State -eq "ABORT") "HS-041 Temperature above abort threshold => ABORT"

Write-Host "`n=== HS-042 / HS-043 / HS-045 / HS-046 Reporting ===" -ForegroundColor Cyan
$partialStage = New-HsStage -StageName "RAM" -Component "RAM"
Start-HsStage $partialStage
Complete-HsStage $partialStage -Status "INTERRUPTED" -Assessment "Cancelled"
$partialHtml = New-HsHtmlReport -Stages @($partialStage) -Inventory $inv -Profile "Quick"
Assert-True ($partialHtml -match "INTERRUPTED") "HS-042 A partial (interrupted) report can still be generated"
Assert-True ($partialHtml -match "(?i)<html") "HS-043 HTML report is well-formed HTML"

$coverageStage = New-HsStage -StageName "RAM" -Component "RAM"
$coverageStage.Coverage = "31.2 GB tested, 8 passes, 0 errors"
$coverageStage.Status = "PASS"
$coverageHtml = New-HsHtmlReport -Stages @($coverageStage) -Inventory $inv -Profile "Standard"
Assert-True ($coverageHtml -match "31\.2 GB tested") "HS-045 Coverage text appears in the HTML report"

$resetInfo = [pscustomobject]@{ Classification = "SYSTEM_RESET"; Notes = "Kernel-Power 41 without a planned shutdown request." }
$resetHtml = New-HsHtmlReport -Stages @($coverageStage) -Inventory $inv -Profile "Standard" -SystemResetInfo $resetInfo
Assert-True ($resetHtml -match "SYSTEM_RESET detected") "HS-046 SYSTEM_RESET is rendered as a prominent banner in the report"

Write-Host "`n=== HS-047 No unfounded definitive-defect claims (static scan) ===" -ForegroundColor Cyan
$forbiddenPhrases = @("RAM-Modul definitiv defekt", "ist definitiv defekt", "CPU definitiv defekt", "GPU definitiv defekt", "Mainboard defekt", "PSU ist defekt")
$scanFiles = Get-ChildItem $LibRoot -Recurse -Include *.psm1
$violations = @()
foreach ($file in $scanFiles) {
    $text = Get-Content -Raw $file.FullName
    foreach ($phrase in $forbiddenPhrases) {
        if ($text -match [regex]::Escape($phrase)) { $violations += "$($file.Name): $phrase" }
    }
}
Assert-True ($violations.Count -eq 0) "HS-047 No module text makes an unfounded definitive hardware-defect claim ($($violations -join '; '))"

} finally {
    Remove-Item -Recurse -Force $FixtureCache -ErrorAction SilentlyContinue
}

Write-Host ""
Write-Host "Fixture results: $script:PassCount passed, $script:FailCount failed." -ForegroundColor $(if ($script:FailCount -eq 0) { "Green" } else { "Red" })
if ($script:FailCount -gt 0) { exit 1 }
exit 0
