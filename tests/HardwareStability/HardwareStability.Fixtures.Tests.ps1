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
Import-Module (Join-Path $LibRoot "StorageBackground.psm1") -Force
Import-Module (Join-Path $LibRoot "StressTest.psm1") -Force
Import-Module (Join-Path $LibRoot "StorageTests.psm1") -Force
Import-Module (Join-Path $LibRoot "Reporting.psm1") -Force
Import-Module (Join-Path $LibRoot "Telemetry.psm1") -Force
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
Assert-True ($ramFail.Status -eq "FAIL") "HS-010 RAM corruption fixture ('Memory corrupted', exit code 1) => FAIL"

Write-Host "`n=== HS-055 / HS-056 / HS-057 RAM verdicts, duration mode, progress parsing ===" -ForegroundColor Cyan
Remove-Item -Recurse -Force $mcCache -ErrorAction SilentlyContinue
New-HsFakeMemoryChecker -Path (Join-Path $mcCache "MemoryChecker.exe") -Mode "allocfail"
$ramAlloc = Invoke-HsRamVerification -ConfigPath $ConfigPath -ToolCacheRoot $FixtureCache -OutputDirectory (Join-Path $FixtureCache "ram_alloc_out") -Passes 1 -PercentOfPhysicalRam 1 -NoDownload
Assert-True ($ramAlloc.Status -eq "BLOCKED") "HS-055 Exit code 1 without 'Memory corrupted' (allocation failure) => BLOCKED, not a RAM FAIL (got $($ramAlloc.Status))"

Remove-Item -Recurse -Force $mcCache -ErrorAction SilentlyContinue
New-HsFakeMemoryChecker -Path (Join-Path $mcCache "MemoryChecker.exe") -Mode "continuous"
$ramTimed = Invoke-HsRamVerification -ConfigPath $ConfigPath -ToolCacheRoot $FixtureCache -OutputDirectory (Join-Path $FixtureCache "ram_timed_out") -Passes 1 -PercentOfPhysicalRam 1 -DurationSeconds 4 -NoDownload
Assert-True ($ramTimed.Status -eq "PASS" -and $ramTimed.Command -match "--continuous") "HS-056 Duration mode runs --continuous and reaching the time limit without errors => PASS (got $($ramTimed.Status))"

Remove-Item -Recurse -Force $mcCache -ErrorAction SilentlyContinue
New-HsFakeMemoryChecker -Path (Join-Path $mcCache "MemoryChecker.exe") -Mode "continuous-corrupt"
$ramTimedFail = Invoke-HsRamVerification -ConfigPath $ConfigPath -ToolCacheRoot $FixtureCache -OutputDirectory (Join-Path $FixtureCache "ram_timedfail_out") -Passes 1 -PercentOfPhysicalRam 1 -DurationSeconds 15 -NoDownload
Assert-True ($ramTimedFail.Status -eq "FAIL") "HS-056 Duration mode reports corruption during the run => FAIL (got $($ramTimedFail.Status))"

$mcState = New-HsMemoryCheckerState
foreach ($line in @("--- [ Pass 2 of 4 ] ---", "Writing memory, please be patient...", "0.0%", "100.0% [OK]", "Reading memory, please be patient...", "50.0%")) {
    Update-HsMemoryCheckerState -State $mcState -Line $line
}
$mcProgress = Get-HsMemoryCheckerProgress -State $mcState
Assert-True ([math]::Abs($mcProgress.Percent - 43.75) -lt 0.01 -and $mcProgress.Text -match "Durchlauf 2/4") "HS-057 MemoryChecker output is turned into overall progress (pass 2 of 4, reading 50% => 43.75%, got $($mcProgress.Percent))"
Update-HsMemoryCheckerState -State $mcState -Line "Error: Sorry, not enough physical memory!"
Assert-True (-not $mcState.Corrupted -and $mcState.ErrorLine -match "not enough") "HS-057 A tool error line is recorded but is not memory corruption"
Update-HsMemoryCheckerState -State $mcState -Line "Error: 2 hash check(s) have failed. Memory corrupted :-("
Assert-True ($mcState.Corrupted) "HS-057 'Memory corrupted' is recognized as verification evidence"

Write-Host "`n=== HS-058 RAM load during the combined system test ===" -ForegroundColor Cyan
Remove-Item -Recurse -Force $mcCache -ErrorAction SilentlyContinue
New-HsFakeMemoryChecker -Path (Join-Path $mcCache "MemoryChecker.exe") -Mode "continuous"
$bgLoad = Start-HsRamBackgroundLoad -ConfigPath $ConfigPath -ToolCacheRoot $FixtureCache -OutputDirectory (Join-Path $FixtureCache "ram_bg_out") -PercentOfPhysicalRam 1 -NoDownload
Start-Sleep -Seconds 3
$bgResult = Complete-HsRamBackgroundLoad -Load $bgLoad
Assert-True ($bgResult.Status -eq "PASS" -and $bgResult.Passes -ge 1) "HS-058 Background RAM load still running at the end without errors => PASS (got $($bgResult.Status), $($bgResult.Passes) pass(es))"
Assert-True (@(Get-HsTrackedProcesses | Where-Object { $_.Stage -eq "SYSTEM_STABILITY_RAM" }).Count -eq 0) "HS-058 Background RAM process is stopped and unregistered"

Remove-Item -Recurse -Force $mcCache -ErrorAction SilentlyContinue
New-HsFakeMemoryChecker -Path (Join-Path $mcCache "MemoryChecker.exe") -Mode "continuous-corrupt"
$bgLoad = Start-HsRamBackgroundLoad -ConfigPath $ConfigPath -ToolCacheRoot $FixtureCache -OutputDirectory (Join-Path $FixtureCache "ram_bgfail_out") -PercentOfPhysicalRam 1 -NoDownload
Start-Sleep -Seconds 4
$bgResult = Complete-HsRamBackgroundLoad -Load $bgLoad
Assert-True ($bgResult.Status -eq "FAIL") "HS-058 Corruption reported during the combined test => FAIL (got $($bgResult.Status))"

Remove-Item -Recurse -Force $mcCache -ErrorAction SilentlyContinue
New-HsFakeMemoryChecker -Path (Join-Path $mcCache "MemoryChecker.exe") -Mode "allocfail"
$bgLoad = Start-HsRamBackgroundLoad -ConfigPath $ConfigPath -ToolCacheRoot $FixtureCache -OutputDirectory (Join-Path $FixtureCache "ram_bgalloc_out") -PercentOfPhysicalRam 1 -NoDownload
Start-Sleep -Seconds 2
$bgResult = Complete-HsRamBackgroundLoad -Load $bgLoad
Assert-True ($bgResult.Status -eq "BLOCKED") "HS-058 RAM load that ended on its own without corruption => BLOCKED, never PASS (got $($bgResult.Status))"

Write-Host "`n=== HS-011 / HS-012 / HS-013 / HS-014 Prime95 fixtures ===" -ForegroundColor Cyan
$p95Cache = Join-Path $FixtureCache "prime95"
# Runs longer than the 3 s test duration, so the harness stops it at the
# deadline - the normal end of a clean torture test.
New-HsFakePrime95 -Path (Join-Path $p95Cache "prime95.exe") -FailureText "" -RunMilliseconds 30000
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

Remove-Item -Recurse -Force $p95Cache -ErrorAction SilentlyContinue
New-HsFakePrime95 -Path (Join-Path $p95Cache "prime95.exe") -FailureText "" -RunMilliseconds 1000
$cpuEarly = Invoke-HsCpuTortureTest -StageName "CPU_COMPUTE" -ConfigPath $ConfigPath -ToolCacheRoot $FixtureCache -OutputDirectory (Join-Path $FixtureCache "cpu_early_out") -DurationMinutes 0.25 -LogicalProcessors 8 -PhysicalCores 4 -NoDownload
Assert-True ($cpuEarly.Status -eq "BLOCKED") "HS-051 Prime95 exiting before the planned duration without errors => BLOCKED, never PASS (got $($cpuEarly.Status))"

Write-Host "`n=== HS-061 Console progress is emitted and fills ===" -ForegroundColor Cyan
# Runs a stage in a separate runspace and collects its progress records, with
# the global ProgressPreference set to SilentlyContinue exactly like the
# launcher does. Rendering itself is the console's job and cannot be tested
# here; this proves the records exist, are not suppressed, use ONE top-level
# bar (no -ParentId child that a console may not show) and actually advance.
Remove-Item -Recurse -Force $p95Cache -ErrorAction SilentlyContinue
New-HsFakePrime95 -Path (Join-Path $p95Cache "prime95.exe") -FailureText "" -RunMilliseconds 30000
$progressRunspace = [powershell]::Create()
try {
    [void]$progressRunspace.AddScript({
        param($libRoot, $cacheRoot, $configPath)
        $global:ProgressPreference = "SilentlyContinue"
        Import-Module (Join-Path $libRoot "Common.psm1") -Force
        Import-Module (Join-Path $libRoot "CpuTests.psm1") -Force
        Write-HsOverallProgress -Activity "Fixture" -Status "Komponente 1 von 1" -Stage "CPU Compute"
        $global:HsRunPlanState = @{ LaterKnownSeconds = 600; LaterUnknownText = "RAM" }
        $global:HsTemperatureProvider = { "Temperaturen: CPU 50 C" }
        $r = Invoke-HsCpuTortureTest -StageName "CPU_COMPUTE" -ConfigPath $configPath -ToolCacheRoot $cacheRoot `
            -OutputDirectory (Join-Path $cacheRoot "cpu_progress_out") -DurationMinutes 0.1 -LogicalProcessors 2 -PhysicalCores 1 -NoDownload
        Write-HsOverallProgress -Activity "Fixture" -Completed
        $r.Status
    }).AddArgument([string]$LibRoot).AddArgument([string]$FixtureCache).AddArgument([string]$ConfigPath)
    # Bounded wait: a hang must fail this check, not block the whole suite.
    $progressAsync = $progressRunspace.BeginInvoke()
    $progressFinished = $progressAsync.AsyncWaitHandle.WaitOne(120000)
    if ($progressFinished) {
        $progressStatus = @($progressRunspace.EndInvoke($progressAsync))
    } else {
        $progressStatus = @("TIMEOUT")
        Write-Host "  HS-061 runspace did not finish within 120 s. Last output:" -ForegroundColor Yellow
        @($progressRunspace.Streams.Information | Select-Object -Last 5) | ForEach-Object { Write-Host "    $_" }
        @($progressRunspace.Streams.Error | Select-Object -Last 5) | ForEach-Object { Write-Host "    ERROR: $_" }
        try { $progressRunspace.Stop() } catch {}
    }
    $progressRecords = @($progressRunspace.Streams.Progress)
} finally {
    $progressRunspace.Dispose()
}
Assert-True ($progressFinished) "HS-061 Progress check finished within 120 s"
$filled = @($progressRecords | Where-Object { $_.PercentComplete -ge 0 -and $_.Activity -match "Fixture, Komponente 1 von 1: " })
$percentValues = @($filled | ForEach-Object { $_.PercentComplete })
Assert-True ($progressStatus -contains "PASS") "HS-061 Stage still PASSes while reporting progress (got $($progressStatus -join ','))"
Assert-True ($filled.Count -ge 3) "HS-061 Progress records are emitted despite a global SilentlyContinue ($($filled.Count) record(s) with a percentage)"
Assert-True (@($progressRecords | Where-Object { $_.ParentActivityId -ge 0 }).Count -eq 0) "HS-061 Only one top-level bar is used (no child records)"
Assert-True ($percentValues.Count -ge 2 -and $percentValues[-1] -gt $percentValues[0]) "HS-061 The bar fills over time ($($percentValues -join ' -> ')%)"
Assert-True (@($filled | Where-Object { $_.StatusDescription -match "\d+:\d\d von \d+:\d\d" }).Count -ge 1) "HS-061 Status shows elapsed and planned time"
Assert-True (@($filled | Where-Object { $_.StatusDescription -match "Phase noch \d+:\d\d" -and $_.StatusDescription -match "Gesamt noch mind\. 1\d:\d\d \+ RAM" }).Count -ge 1) "HS-061 Status shows remaining stage time and remaining total (planned later stages + unknown parts) ($(@($filled)[0].StatusDescription))"
Assert-True (@($filled | Where-Object { $_.CurrentOperation -eq "Temperaturen: CPU 50 C" }).Count -ge 1) "HS-061 Current temperatures are shown under the bar"

Write-Host "`n=== HS-062 Maximum load: heavy GPU kernel and available-RAM sizing ===" -ForegroundColor Cyan
$gpuHeavy = Invoke-HsGpuLoadThermalValidation -DurationSeconds 5 -Quiet
if ($gpuHeavy.Status -eq "UNSUPPORTED") {
    Assert-True $true "HS-062 GPU load reports UNSUPPORTED on a machine without Direct3D 11 compute ($($gpuHeavy.Reason))"
} else {
    Assert-True ($gpuHeavy.Status -eq "PASS" -and $gpuHeavy.HeavyKernel) "HS-062 Sustained GPU load uses the calibrated heavy kernel and PASSes (got $($gpuHeavy.Status), heavy=$($gpuHeavy.HeavyKernel): $($gpuHeavy.Reason))"
    Assert-True ($gpuHeavy.Rounds -ge 16 -and $gpuHeavy.Iterations -ge 3 -and $gpuHeavy.VerifiedValues -gt 0) "HS-062 Heavy kernel ran calibrated dispatches with sampled bit-exact verification ($($gpuHeavy.Iterations) dispatches x $($gpuHeavy.Rounds) rounds, $($gpuHeavy.VerifiedValues) values)"
}
$ramMax = Get-HsMaxRamPercent
Assert-True ($ramMax.Percent -ge 10 -and $ramMax.Percent -le 90 -and $ramMax.TotalMB -gt 0) "HS-062 RAM share is sized from the available memory ($($ramMax.Percent)% of $($ramMax.TotalMB) MB, $($ramMax.FreeMB) MB available)"
$ramMaxSystem = Get-HsMaxRamPercent -ExtraReserveMB 1536
Assert-True ($ramMaxSystem.Percent -le $ramMax.Percent) "HS-062 The combined test keeps extra headroom for Prime95 and the GPU load"

Write-Host "`n=== HS-063 Storage checks in the background (parallel to the GPU stages) ===" -ForegroundColor Cyan
# Write/read verification stops cleanly when asked to: INTERRUPTED, not a
# false FAIL, and the test file is gone.
$wvCancelled = Invoke-HsStorageWriteReadVerify -Directory (Join-Path $FixtureCache "writeverify_cancel") -SizeMB 16 -CancelCheck { $true }
Assert-True ($wvCancelled.Status -eq "INTERRUPTED" -and -not (Test-Path -LiteralPath $wvCancelled.TestFilePath)) "HS-063 A cancelled write/read verification is INTERRUPTED (not FAIL) and leaves no test file (got $($wvCancelled.Status))"

# Full background run: surface scan of disk 0 (only with admin rights, as in
# the real run) followed by write/verify, in a runspace of this process.
$isAdmin = $false
try { $isAdmin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator) } catch {}
$bgDir = Join-Path $FixtureCache "bg_writeverify"
$bg = Start-HsStorageBackgroundChecks -ModuleRoot $LibRoot -SurfaceEnabled $isAdmin -DriveIndex 0 -SurfaceMaxBytes 64MB `
    -SurfaceLabel "Fixture Surface" -WriteVerifyDirectory $bgDir -WriteVerifySizeMB 64 -WriteVerifyLabel "Fixture WriteVerify"
$bgStartShort = (Get-HsStorageBackgroundStatus -Handle $bg).ShortText
$bgDeadline = (Get-Date).AddSeconds(120)
$bgPhases = New-Object System.Collections.ArrayList
while ((Get-Date) -lt $bgDeadline) {
    $bgStatus = Get-HsStorageBackgroundStatus -Handle $bg
    if ($bgPhases.Count -eq 0 -or $bgPhases[$bgPhases.Count - 1] -ne $bgStatus.Phase) { [void]$bgPhases.Add($bgStatus.Phase) }
    if ($bgStatus.Phase -eq "Done") { break }
    Start-Sleep -Milliseconds 100
}
$bgDoneStatus = Get-HsStorageBackgroundStatus -Handle $bg
$bgLastRecord = $bg.LastProgress
$bgResult = Complete-HsStorageBackgroundChecks -Handle $bg -TimeoutSeconds 10
Assert-True ($bgStartShort -like "Parallel: *") "HS-063 The background status yields a short text for the progress line ($bgStartShort)"
Assert-True ($bgDoneStatus.Phase -eq "Done" -and $bgDoneStatus.ShortText -eq "Parallel: Storage-Pruefung fertig") "HS-063 The background checks finish within 120 s (phases: $($bgPhases -join ' -> '))"
Assert-True ($null -ne $bgResult.WriteVerify -and $bgResult.WriteVerify.Status -eq "PASS" -and -not $bgResult.Error) "HS-063 Write/read verification in the background PASSes (got $(if ($bgResult.WriteVerify) { $bgResult.WriteVerify.Status } else { 'no result' }) $($bgResult.Error) $($bgResult.WriteError))"
Assert-True ($bgResult.WriteStarted -is [datetime] -and $bgResult.WriteEnded -ge $bgResult.WriteStarted) "HS-063 Start and end of the background part are recorded for the report"
Assert-True ($null -ne $bgLastRecord -and $bgLastRecord.Activity -eq "Fixture WriteVerify" -and $bgLastRecord.PercentComplete -ge 50) "HS-063 Background progress stays in the runspace's own stream and is read from there (last: $(if ($bgLastRecord) { "$($bgLastRecord.Activity) $($bgLastRecord.PercentComplete)%" } else { 'none' }))"
if ($isAdmin) {
    Assert-True ($null -ne $bgResult.Surface -and $bgResult.Surface.Status -eq "PASS" -and $bgResult.Surface.BytesRead -ge 64MB) "HS-063 Surface scan of PhysicalDrive0 runs in the background runspace (got $(if ($bgResult.Surface) { "$($bgResult.Surface.Status): $($bgResult.Surface.Reason)" } else { "no result: $($bgResult.SurfaceError)" }))"
} else {
    Assert-True ($null -eq $bgResult.Surface -and $bgPhases -notcontains "Surface") "HS-063 Without a surface scan the background goes straight to write/read verification"
}
Assert-True (@(Get-ChildItem -LiteralPath $bgDir -Filter "*.tmp" -ErrorAction SilentlyContinue).Count -eq 0) "HS-063 No test file is left behind by the background run"
Assert-True ($bg.Closed -and $null -ne (Complete-HsStorageBackgroundChecks -Handle $bg)) "HS-063 Completing twice is harmless (finally block after the Storage stage)"

# Cancel right after the start (Ctrl+C / thermal guard): ends quickly without a false FAIL.
$bgCancelDir = Join-Path $FixtureCache "bg_cancel"
$bgCancel = Start-HsStorageBackgroundChecks -ModuleRoot $LibRoot -SurfaceEnabled $false -WriteVerifyDirectory $bgCancelDir -WriteVerifySizeMB 4096 -WriteVerifyLabel "Fixture Cancel"
$bgCancelWatch = [Diagnostics.Stopwatch]::StartNew()
$bgCancelResult = Complete-HsStorageBackgroundChecks -Handle $bgCancel -TimeoutSeconds 30
$bgCancelWatch.Stop()
Assert-True ($bgCancelResult.Stopped -and $bgCancelWatch.Elapsed.TotalSeconds -lt 30) "HS-063 A running background check stops on request ($([math]::Round($bgCancelWatch.Elapsed.TotalSeconds,1)) s)"
Assert-True ($null -eq $bgCancelResult.WriteVerify -or $bgCancelResult.WriteVerify.Status -eq "INTERRUPTED") "HS-063 A stopped background check reports no result or INTERRUPTED, never FAIL (got $(if ($bgCancelResult.WriteVerify) { $bgCancelResult.WriteVerify.Status } else { 'no result' }))"
Assert-True (@(Get-ChildItem -LiteralPath $bgCancelDir -Filter "*.tmp" -ErrorAction SilentlyContinue).Count -eq 0) "HS-063 A stopped background check leaves no test file"

# The running stage shows the background state next to the temperatures.
$opRunspace = [powershell]::Create()
try {
    [void]$opRunspace.AddScript({
        param($libRoot)
        Import-Module (Join-Path $libRoot "Common.psm1") -Force
        $global:HsTemperatureProvider = { "Temperaturen: CPU 50 C" }
        $global:HsParallelStatusProvider = { "Parallel: Surface-Scan 37 %" }
        Write-HsStageProgress -Activity "Fixture" -Status "laeuft" -Percent 10 -Force
    }).AddArgument([string]$LibRoot)
    [void]$opRunspace.Invoke()
    $opRecords = @($opRunspace.Streams.Progress)
} finally {
    $opRunspace.Dispose()
}
Assert-True (@($opRecords | Where-Object { $_.CurrentOperation -eq "Temperaturen: CPU 50 C | Parallel: Surface-Scan 37 %" }).Count -ge 1) "HS-063 The progress line shows temperatures and the parallel storage check together"

# Only the GPU stages share the machine with the storage checks; CPU, Cache
# and RAM stay isolated (static check of the main script).
$mainScriptText = Get-Content -Raw (Join-Path $RepoRoot "scripts\diagnostics\HardwareStability.ps1")
Assert-True ($mainScriptText -match '\$parallelStartKey = @\(\$keys \| Where-Object \{ \$_ -in @\("GPU","VRAM","VRAMMemory","GPULoad"\) \}\)') "HS-063 Background storage checks start only at a GPU stage, never next to CPU, Cache or RAM"

Write-Host "`n=== HS-064 Stresstest (Prime95 + FurMark) ===" -ForegroundColor Cyan
$fmArgs = Get-HsFurMarkArguments -Seconds 1800 -Width 1920 -Height 1080
Assert-True (($fmArgs -join " ") -eq "--demo furmark-gl --width 1920 --height 1080 --max-time 1800") "HS-064 FurMark 2 is started as OpenGL stress test with size and end time ($($fmArgs -join ' '))"
$vcDir = Join-Path $FixtureCache "vcruntime_check"
New-Item -ItemType Directory -Force -Path $vcDir | Out-Null
Assert-True (-not (Test-HsVcRuntimeInstalled -SystemDirectory $vcDir)) "HS-064 A missing Visual C++ runtime is detected"
foreach ($dll in @("vcruntime140.dll","vcruntime140_1.dll","msvcp140.dll")) { Set-Content -LiteralPath (Join-Path $vcDir $dll) -Value "x" }
Assert-True (Test-HsVcRuntimeInstalled -SystemDirectory $vcDir) "HS-064 An installed Visual C++ runtime is recognised"

# The VC++ runtime installer is run only with a valid Microsoft signature.
$cmdSigned = Test-HsAuthenticodeSigner -Path (Join-Path $env:SystemRoot "System32\cmd.exe") -SubjectPattern "O=Microsoft Corporation"
Assert-True ($cmdSigned.Valid) "HS-064 A Windows binary validates against its publisher ($($cmdSigned.Status), $($cmdSigned.Subject))"
$cmdWrongPublisher = Test-HsAuthenticodeSigner -Path (Join-Path $env:SystemRoot "System32\cmd.exe") -SubjectPattern "O=Some Other Publisher"
Assert-True (-not $cmdWrongPublisher.Valid) "HS-064 A valid signature of another publisher is rejected"
$unsignedExe = Join-Path $FixtureCache "sig_check\unsigned.exe"
New-HsFakeFurMark -Path $unsignedExe -RunMilliseconds 0
Assert-True (-not (Test-HsAuthenticodeSigner -Path $unsignedExe -SubjectPattern "O=Microsoft Corporation").Valid) "HS-064 An unsigned installer is never accepted"
$stressConfig = Get-HsToolConfig -ConfigPath $ConfigPath
Assert-True ($stressConfig.tools.furmark2.sha256 -match '^[0-9a-f]{64}$' -and $stressConfig.tools.vcredist_x64.sha256 -match '^[0-9a-f]{64}$') "HS-064 FurMark and the VC++ runtime are hash-pinned"

$verdictPass = Get-HsStressVerdict -Mode Both -CpuResult ([pscustomobject]@{ Status = "PASS"; Reason = "" }) -GpuResult ([pscustomobject]@{ Status = "PASS"; Reason = "" })
$verdictCpuFail = Get-HsStressVerdict -Mode Both -CpuResult ([pscustomobject]@{ Status = "FAIL"; Reason = "ROUNDOFF" }) -GpuResult ([pscustomobject]@{ Status = "WARNING"; Reason = "early" })
$verdictReset = Get-HsStressVerdict -Mode GPU -GpuResult ([pscustomobject]@{ Status = "PASS"; Reason = "" }) -DriverResets 1
$verdictThermal = Get-HsStressVerdict -Mode CPU -CpuResult ([pscustomobject]@{ Status = "INTERRUPTED"; Reason = "" }) -ThermalAbortReason "CPU 101 C"
Assert-True ($verdictPass.Status -eq "PASS" -and $verdictPass.Findings.Count -eq 0) "HS-064 Both parts running their full time is a PASS"
Assert-True ($verdictCpuFail.Status -eq "FAIL" -and $verdictCpuFail.Findings.Count -eq 2) "HS-064 A Prime95 calculation error makes the run FAIL"
Assert-True ($verdictReset.Status -eq "WARNING") "HS-064 A graphics driver reset during the test is a WARNING"
Assert-True ($verdictThermal.Status -eq "THERMAL_ABORT") "HS-064 A thermal abort is reported as THERMAL_ABORT"

# The real script end to end with fake Prime95/FurMark (child process: the
# script may call exit). Needs admin rights like the real tool.
if ($isAdmin) {
    $stressCache = Join-Path $FixtureCache "stress_cache"
    $stressOut = Join-Path $FixtureCache "stress_out"
    New-HsFakePrime95 -Path (Join-Path $stressCache "prime95\prime95.exe") -FailureText "" -RunMilliseconds 30000
    New-HsFakeFurMark -Path (Join-Path $stressCache "furmark2\FurMark_win64\furmark.exe") -RunMilliseconds -1
    $hostExe = (Get-Process -Id $PID).Path
    $stressScript = Join-Path $RepoRoot "scripts\diagnostics\StressTest.ps1"
    $stressArgs = @("-NoProfile", "-ExecutionPolicy", "Bypass", "-File", $stressScript, "-Mode", "Both", "-Minutes", "0.1", "-NoPrompt", "-NoDownload",
        "-SkipTelemetry", "-ToolCacheRoot", $stressCache, "-OutputRoot", $stressOut, "-ModuleRootOverride", [string]$LibRoot, "-ConfigPathOverride", [string]$ConfigPath)
    $stressRun = Start-Process -FilePath $hostExe -ArgumentList $stressArgs -Wait -PassThru -WindowStyle Hidden `
        -RedirectStandardOutput (Join-Path $FixtureCache "stress_stdout.txt") -RedirectStandardError (Join-Path $FixtureCache "stress_stderr.txt")
    $stressResultFile = @(Get-ChildItem -LiteralPath $stressOut -Recurse -Filter "00_Result.json" -ErrorAction SilentlyContinue) | Select-Object -First 1
    $stressResult = if ($stressResultFile) { Get-Content -Raw -LiteralPath $stressResultFile.FullName | ConvertFrom-Json } else { $null }
    if (-not $stressResult) { Get-Content -LiteralPath (Join-Path $FixtureCache "stress_stdout.txt"), (Join-Path $FixtureCache "stress_stderr.txt") -ErrorAction SilentlyContinue | Select-Object -Last 15 | ForEach-Object { Write-Host "    $_" } }
    Assert-True ($null -ne $stressResult -and $stressResult.Status -eq "PASS" -and $stressResult.Cpu.Status -eq "PASS" -and $stressResult.Gpu.Status -eq "PASS") "HS-064 Stress test CPU + GPU runs Prime95 and FurMark for the chosen time and PASSes (exit $($stressRun.ExitCode), got $(if ($stressResult) { "$($stressResult.Status) / CPU $($stressResult.Cpu.Status) / GPU $($stressResult.Gpu.Status)" } else { 'no result' }))"
    $fmSeen = Get-Content -LiteralPath (Join-Path $stressCache "furmark2\FurMark_win64\furmark_fixture_args.txt") -ErrorAction SilentlyContinue
    Assert-True ($fmSeen.Count -ge 2 -and $fmSeen[0] -eq "--demo furmark-gl --width 1280 --height 720 --max-time 66" -and $fmSeen[1] -like "*FurMark_win64") "HS-064 FurMark gets the stress test arguments and its own folder as working directory ($($fmSeen -join ' | '))"
    Assert-True (@(Get-Process -Name "furmark","prime95" -ErrorAction SilentlyContinue | Where-Object { $_.Path -like "$stressCache*" }).Count -eq 0) "HS-064 No Prime95 or FurMark process is left running"

    # FurMark ending on its own long before the planned end (crash under load).
    New-HsFakeFurMark -Path (Join-Path $stressCache "furmark2\FurMark_win64\furmark.exe") -RunMilliseconds 500 -ExitCode 3
    $stressOut2 = Join-Path $FixtureCache "stress_out2"
    $stressArgs2 = @("-NoProfile", "-ExecutionPolicy", "Bypass", "-File", $stressScript, "-Mode", "GPU", "-Minutes", "0.2", "-NoPrompt", "-NoDownload",
        "-SkipTelemetry", "-ToolCacheRoot", $stressCache, "-OutputRoot", $stressOut2, "-ModuleRootOverride", [string]$LibRoot, "-ConfigPathOverride", [string]$ConfigPath)
    Start-Process -FilePath $hostExe -ArgumentList $stressArgs2 -Wait -WindowStyle Hidden | Out-Null
    $stressResult2File = @(Get-ChildItem -LiteralPath $stressOut2 -Recurse -Filter "00_Result.json" -ErrorAction SilentlyContinue) | Select-Object -First 1
    $stressResult2 = if ($stressResult2File) { Get-Content -Raw -LiteralPath $stressResult2File.FullName | ConvertFrom-Json } else { $null }
    Assert-True ($null -ne $stressResult2 -and $stressResult2.Status -eq "WARNING" -and $stressResult2.Gpu.Status -eq "WARNING" -and [string]$stressResult2.Gpu.Reason -match "selbst beendet") "HS-064 FurMark ending early is reported, never a PASS (got $(if ($stressResult2) { "$($stressResult2.Status): $($stressResult2.Gpu.Reason)" } else { 'no result' }))"
} else {
    Write-Host "  (HS-064 end-to-end part skipped: needs Administrator rights)" -ForegroundColor DarkGray
}

Write-Host "`n=== HS-052 / HS-053 Tool integrity checks ===" -ForegroundColor Cyan
$nugetBase64 = "NXcNYlWoXe5cz9sb8Huo6x2dCZVYkhwKtgE00n/MoI8V4ZI/7/t+EI5bOhQFlZfFjjqM8+U6prjU/aARt7H/tA=="
Assert-True ((ConvertTo-HsHexHash -Value $nugetBase64 -ByteLength 64) -eq "35770d6255a85dee5ccfdb1bf07ba8eb1d9d099558921c0ab60134d27fcca08f15e1923feffb7e108e5b3a14059597c58e3a8cf3e53aa6b8d4fda011b7b1ffb4") "HS-052 NuGet base64 SHA512 is converted to the matching hex digest"
Assert-True ((ConvertTo-HsHexHash -Value ("35770d6255a85dee5ccfdb1bf07ba8eb1d9d099558921c0ab60134d27fcca08f15e1923feffb7e108e5b3a14059597c58e3a8cf3e53aa6b8d4fda011b7b1ffb4".ToUpperInvariant()) -ByteLength 64) -eq "35770d6255a85dee5ccfdb1bf07ba8eb1d9d099558921c0ab60134d27fcca08f15e1923feffb7e108e5b3a14059597c58e3a8cf3e53aa6b8d4fda011b7b1ffb4") "HS-052 Hex SHA512 is accepted case-insensitively"
Assert-True ((ConvertTo-HsHexHash -Value "not-a-hash" -ByteLength 64) -eq "") "HS-052 Malformed hash never yields a comparable digest"
Assert-True ((ConvertTo-HsHexHash -Value "AAAA" -ByteLength 64) -eq "") "HS-052 Base64 of the wrong length is rejected"
$noHashConfig = [pscustomobject]@{ tools = [pscustomobject]@{ nohash = [pscustomobject]@{
    version = "1"; license = "test"; executable = "nohash.exe"; archiveType = "exe"; downloadUrl = "https://example.invalid/nohash.exe" } } }
$noHash = Resolve-HsTool -ToolId "nohash" -ToolConfig $noHashConfig -ToolCacheRoot (Join-Path $FixtureCache "nohash_cache")
Assert-True ((-not $noHash.Available) -and $noHash.Reason -match "No integrity hash") "HS-053 A tool without any configured hash is never downloaded (fail closed)"
$realConfig = Get-HsToolConfig -ConfigPath $ConfigPath
$unhashed = @($realConfig.tools.PSObject.Properties | Where-Object {
    $t = $_.Value
    [string]::IsNullOrWhiteSpace([string](Get-HsPropertyOrDefault -InputObject $t -Name "sha256")) -and
    [string]::IsNullOrWhiteSpace([string](Get-HsPropertyOrDefault -InputObject $t -Name "sha512")) -and
    [string]::IsNullOrWhiteSpace([string](Get-HsPropertyOrDefault -InputObject $t -Name "md5"))
} | ForEach-Object { $_.Name })
Assert-True ($unhashed.Count -eq 0) "HS-053 Every configured third-party tool has an integrity hash ($($unhashed -join ', '))"
$lhmEntry = $realConfig.tools.librehardwaremonitor
$missingDeps = @(@($lhmEntry.desktopDependencies) | Where-Object { -not ($realConfig.tools.PSObject.Properties.Name -contains $_) })
Assert-True ([string]$lhmEntry.executableDesktop -match "\\net472\\" -and $missingDeps.Count -eq 0) "HS-053 PS 5.1 telemetry uses the net472 build and every desktop dependency is defined ($($missingDeps -join ', '))"

Write-Host "`n=== HS-054 Telemetry status reporting ===" -ForegroundColor Cyan
$pawnStatus = Get-HsPawnIoStatus
Assert-True ($pawnStatus.Installed -is [bool]) "HS-054 PawnIO detection returns a boolean without throwing"
$noCpuStatus = New-HsTelemetryStatus
$noCpuStatus.Initialized = $true
$noCpuStatus.GpuTemperatureAvailable = $true
$noCpuStatus.Notes = @("No CPU temperature: test <note>")
$card = New-HsTelemetryHtmlCard -TelemetryStatus $noCpuStatus
Assert-True ($card -match "CPU temperature:</strong> no" -and $card -match "test &lt;note&gt;") "HS-054 Report states a missing CPU temperature and HTML-encodes notes"
$fakeCpu = [pscustomobject]@{
    HardwareType = "Cpu"; Name = "Fixture CPU"
    Sensors = @(
        [pscustomobject]@{ SensorType = "Temperature"; Name = "Core (Tctl/Tdie)"; Value = 0 },
        [pscustomobject]@{ SensorType = "Temperature"; Name = "Package"; Value = 61.5 },
        [pscustomobject]@{ SensorType = "Load"; Name = "CPU Total"; Value = 0 },
        [pscustomobject]@{ SensorType = "Temperature"; Name = "No value"; Value = $null }
    )
}
$fakeRows = Get-HsHardwareSensorRows -Hardware $fakeCpu -Stage "FIXTURE" -Timestamp (Get-Date)
$fakeTemps = @($fakeRows | Where-Object { $_.SensorType -eq "Temperature" })
Assert-True ($fakeTemps.Count -eq 1 -and $fakeTemps[0].Value -eq 61.5) "HS-054 A 0 C placeholder temperature (no PawnIO) is not reported as a reading"
Assert-True (@($fakeRows | Where-Object { $_.SensorType -eq "Load" }).Count -eq 1) "HS-054 A 0 % load value is still a valid reading"
$skippedCard = New-HsTelemetryHtmlCard -TelemetrySkipped
Assert-True ($skippedCard -match "SkipTelemetry") "HS-054 Report states that telemetry was disabled"

Write-Host "`n=== HS-059 SMART self-test progress parsing ===" -ForegroundColor Cyan
$ataRunning = "Self-test execution status:      ( 249)`tSelf-test routine in progress...`r`n`t`t`t`t`t70% of test remaining."
$ataProgress = Get-HsSmartSelfTestProgress -SmartOutput $ataRunning
Assert-True ($ataProgress.InProgress -and $ataProgress.PercentDone -eq 30) "HS-059 ATA 'in progress / 70% remaining' (two lines) => running, 30% done"
$nvmeRunning = "Self-test status: Short self-test in progress (40% completed)`r`nNum  Test_Description  Status`r`n 0   Short             Completed without error"
$nvmeProgress = Get-HsSmartSelfTestProgress -SmartOutput $nvmeRunning
Assert-True ($nvmeProgress.InProgress -and $nvmeProgress.PercentDone -eq 40) "HS-059 NVMe 'self-test in progress (40% completed)' => running, even though an older log entry says 'Completed without error'"
Assert-True (Test-HsSmartSelfTestStarted -SmartOutput "=== START OF OFFLINE IMMEDIATE AND SELF-TEST SECTION ===`r`nSelf-test has begun`r`nUse smartctl -X to abort test") "HS-059 NVMe 'Self-test has begun' counts as started (was UNSUPPORTED)"
Assert-True (Test-HsSmartSelfTestStarted -SmartOutput "Sending command: `"Execute SMART Short self-test routine immediately in off-line mode`".`r`nDrive command successful.`r`nTesting has begun.`r`nPlease wait 2 minutes for test to complete.") "HS-059 ATA 'Testing has begun / Please wait' counts as started"
Assert-True (-not (Test-HsSmartSelfTestStarted -SmartOutput "SMART Self-test not supported")) "HS-059 'not supported' is not a started test"
$nvmeIdle = Get-HsSmartSelfTestProgress -SmartOutput "Self-test status: No self-test in progress"
Assert-True (-not $nvmeIdle.InProgress) "HS-059 NVMe 'No self-test in progress' => not running"

Write-Host "`n=== HS-060 Retest profile and progress helpers ===" -ForegroundColor Cyan
$baseProfile = Get-HsProfile -Name "Quick"
$retest = Get-HsRetestProfile -BaseProfile $baseProfile -Minutes 30
Assert-True ($retest.CpuCacheImcMinutes -eq 30 -and $retest.RamDurationMinutes -eq 30 -and $retest.SurfaceScanMaxMinutes -eq 30 -and $retest.SurfaceScanEnabled) "HS-060 Retest profile applies the chosen duration to CPU, RAM and the surface scan"
Assert-True ($baseProfile.CpuCacheImcMinutes -eq 5 -and $baseProfile.RamDurationMinutes -eq 0) "HS-060 Retest profile does not change the base profile"
Assert-True (@(Get-HsProfileChoice).Count -eq 3 -and ((@(Get-HsProfileChoice) | ForEach-Object { $_.Label }) -join ",") -eq "Kurz,Mittel,Lang") "HS-060 Start offers Kurz, Mittel, Lang"
Assert-True ((Get-HsProfileEstimateMinutes -ProfileConfig (Get-HsProfile -Name "Standard") -Components @("CPU","Cache","System")) -eq 55) "HS-060 Duration estimate adds the time-bound stages (20+20+15)"
$tp = Get-HsTimeProgress -ElapsedSeconds 90 -TotalSeconds 360
Assert-True ([math]::Abs($tp.Percent - 25) -lt 0.01 -and $tp.Remaining -eq 270 -and $tp.Text -eq "1:30 von 6:00") "HS-060 Time-based progress text and percentage"
Assert-True ((Format-HsDuration 3725) -eq "1:02:05") "HS-060 Durations over an hour are shown as h:mm:ss"

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

# The thermal guard now also watches the VRAM test (it had no telemetry for
# its 15 minutes in the second real run).
Remove-Item -Recurse -Force $mvCache -ErrorAction SilentlyContinue
New-HsFakeMemtestVulkan -Path (Join-Path $mvCache "memtest_vulkan-v0.5.0.exe") -Behavior "pass" -RunMilliseconds 20000
$vramWatch = [Diagnostics.Stopwatch]::StartNew()
$vramCancelled = Invoke-HsVramVerification -ConfigPath $ConfigPath -ToolCacheRoot $FixtureCache -OutputDirectory (Join-Path $FixtureCache "vram_cancel_out") -DurationMinutes 1 -NoDownload -CancelCheck { $true }
$vramWatch.Stop()
Assert-True ($vramCancelled.Status -eq "INTERRUPTED" -and $vramWatch.Elapsed.TotalSeconds -lt 10) "HS-021 The thermal guard can stop the VRAM test: INTERRUPTED, not PASS (got $($vramCancelled.Status) after $([math]::Round($vramWatch.Elapsed.TotalSeconds,1)) s)"

Write-Host "`n=== HS-065 Evidence when a helper process dies ===" -ForegroundColor Cyan
$crashLines = @(Get-HsProcessCrashEvidence -Since (Get-Date).AddMinutes(-2) -ProcessName "pcdiag-fixture-not-running.exe")
Assert-True (@($crashLines | Where-Object { $_ -isnot [string] }).Count -eq 0 -and @($crashLines | Where-Object { $_ -notmatch "Low memory" }).Count -eq 0) "HS-065 Crash evidence is collected without errors and only names the asked process ($($crashLines.Count) line(s))"

Write-Host "`n=== HS-030 / HS-031 Storage Write/Read Verification ===" -ForegroundColor Cyan
$wv = Invoke-HsStorageWriteReadVerify -Directory (Join-Path $FixtureCache "writeverify") -SizeMB 8
Assert-True ($wv.Status -eq "PASS") "HS-030 Storage Write/Read Verification uses only a normal test file and PASSes"
Assert-True (-not (Test-Path $wv.TestFilePath)) "HS-030 Test file is removed after the run"
$crcA = Get-HsCrc32 -Bytes ([byte[]](1,2,3,4,5))
$crcB = Get-HsCrc32 -Bytes ([byte[]](1,2,3,4,6))
Assert-True ($crcA -ne $crcB) "HS-031 Checksum comparison detects a single-byte difference (mismatch => FAIL path)"
Assert-True ((Get-HsCrc32 -Bytes ([Text.Encoding]::ASCII.GetBytes("123456789"))) -eq [uint32]3421780262) "HS-031 CRC32 of '123456789' is the standard check value 0xCBF43926"

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
# Real sensor names from an AMD RX 6700 / Gigabyte B450 (IT8686E) run.
$amdHot = @([pscustomobject]@{ HardwareType = "GpuAmd"; SensorType = "Temperature"; SensorName = "GPU Hot Spot"; Value = 99 })
Assert-True ((Test-HsThermalState -Rows $amdHot -Thresholds $thresholds).State -eq "OK") "HS-041 AMD 'GPU Hot Spot' 99 C is judged as hotspot (limit 110), not as GPU core (was a false abort)"
$amdCore = @([pscustomobject]@{ HardwareType = "GpuAmd"; SensorType = "Temperature"; SensorName = "GPU Core"; Value = 96 })
Assert-True ((Test-HsThermalState -Rows $amdCore -Thresholds $thresholds).State -eq "ABORT") "HS-041 'GPU Core' above 95 C still aborts"
$gpuMem = @([pscustomobject]@{ HardwareType = "GpuNvidia"; SensorType = "Temperature"; SensorName = "GPU Memory Junction"; Value = 102 })
$gpuMemState = Test-HsThermalState -Rows $gpuMem -Thresholds $thresholds
Assert-True ($gpuMemState.State -eq "WARNING" -and $gpuMemState.Reason -match "GPU Memory") "HS-041 GPU memory junction uses its own limits (102 C => WARNING, not ABORT)"
$superIoVrm = @([pscustomobject]@{ HardwareType = "SuperIO"; SensorType = "Temperature"; SensorName = "VRM MOS"; Value = 116 })
Assert-True ((Test-HsThermalState -Rows $superIoVrm -Thresholds $thresholds).State -eq "ABORT") "HS-041 VRM sensors reported by the Super I/O chip are guarded too"
# Shared by the Hardware-Stabilitaetstest and the Stresstest: warning
# throttling, telemetry CSV, temperature line and peaks.
$guardState = @{ Reason = ""; At = [datetime]::MinValue }
$guardLog = Join-Path $FixtureCache "thermal_guard.log"
[void](Invoke-HsThermalGuard -Rows $warnRows -Thresholds $thresholds -State $guardState -LogPath $guardLog)
[void](Invoke-HsThermalGuard -Rows $warnRows -Thresholds $thresholds -State $guardState -LogPath $guardLog)
$guardAbort = Invoke-HsThermalGuard -Rows $abortRows -Thresholds $thresholds -State $guardState -LogPath $guardLog
$guardLines = @(Get-Content -LiteralPath $guardLog -ErrorAction SilentlyContinue)
Assert-True ($guardAbort.State -eq "ABORT" -and @($guardLines | Where-Object { $_ -match "Thermal warning" }).Count -eq 1 -and @($guardLines | Where-Object { $_ -match "THERMAL ABORT" }).Count -eq 1) "HS-041 The thermal guard logs an unchanged warning once and every abort ($($guardLines.Count) line(s))"
$csvState = @{}
$csvPath = Join-Path $FixtureCache "telemetry_rows.csv"
Save-HsTelemetryRows -Rows $warnRows -Path $csvPath -State $csvState
Save-HsTelemetryRows -Rows $warnRows -Path $csvPath -State $csvState
Assert-True (@(Import-Csv -LiteralPath $csvPath).Count -eq 1) "HS-041 Telemetry rows are written at most every 5 s"
$lineRows = @(
    [pscustomobject]@{ HardwareType = "Cpu"; SensorType = "Temperature"; SensorName = "Core (Tctl/Tdie)"; Value = 78.4 },
    [pscustomobject]@{ HardwareType = "GpuAmd"; SensorType = "Temperature"; SensorName = "GPU Core"; Value = 70 },
    [pscustomobject]@{ HardwareType = "GpuAmd"; SensorType = "Temperature"; SensorName = "GPU Hot Spot"; Value = 85 }
)
$deg = "$([char]0x00B0)C"
Assert-True ((Format-HsTemperatureLine -Rows $lineRows -Extra "Platte 40$deg") -eq "Temperaturen: CPU 78$deg | GPU 70$deg (Hotspot 85$deg) | Platte 40$deg") "HS-041 One temperature line format for both tests ($(Format-HsTemperatureLine -Rows $lineRows -Extra "Platte 40$deg"))"
$peaks = @{}
Update-HsTemperaturePeaks -Peaks $peaks -Rows $lineRows
Update-HsTemperaturePeaks -Peaks $peaks -Rows @([pscustomobject]@{ HardwareType = "Cpu"; SensorType = "Temperature"; SensorName = "Core (Tctl/Tdie)"; Value = 60 })
Assert-True ($peaks.Cpu -eq 78.4 -and $peaks.Gpu -eq 70 -and $peaks.GpuHotspot -eq 85 -and -not $peaks.ContainsKey("Vrm")) "HS-041 Peak temperatures keep the maximum per sensor class"

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
