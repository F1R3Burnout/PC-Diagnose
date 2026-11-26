Set-StrictMode -Version 2.0

$moduleDir = $PSScriptRoot
Import-Module (Join-Path $moduleDir "ToolManager.psm1") -Force
Import-Module (Join-Path $moduleDir "ProcessRunner.psm1") -Force
Import-Module (Join-Path $moduleDir "Common.psm1") -Force

<#
    Prime95 (GIMPS) torture test wrapper for CPU_COMPUTE and CPU_CACHE_IMC.

    Verified against the official readme.txt of Prime95 30.19 build 20:
    "-t  Run the torture test. Same as Options/Torture Test." An empirical
    test during implementation confirmed "prime95.exe -t" starts the torture
    test directly (no first-run dialog to dismiss) and drives all logical
    processors to near-100% load (observed via Process.TotalProcessorTime).

    CPU_COMPUTE and CPU_CACHE_IMC are deliberately NOT the same invocation
    (HS-014): they differ in worker/core configuration written to prime.txt
    before launch, using the "NumWorkers" / "CoresPerTest" keys that Prime95
    itself generates into prime.txt (confirmed by inspecting the file it
    wrote after a real run). CPU_COMPUTE uses one worker per physical core
    (compute-focused, minimal cross-core traffic); CPU_CACHE_IMC uses one
    worker per logical processor, including SMT/Hyperthreading siblings,
    which increases L2/L3/interconnect and memory-controller contention.

    The FFT range / memory keys ("MinTortureFFT", "MaxTortureFFT",
    "TortureMem", ...) are not described in undoc.txt, so the stability
    stages do not set them. They are used only for the classic stress test
    (-TortureMemoryMB, "Blend" over the free RAM), with exactly the keys and
    values Prime95 itself wrote to prime.txt when Blend with a custom memory
    size was chosen in its dialog.
    Results.txt was observed to only appear after several minutes of torture
    testing (or on an actual failure) in real testing on this machine - a
    short run producing no results.txt is expected and is reported as such,
    not silently treated as "more thoroughly tested than it was".
#>

$script:HsPrimeFailurePatterns = @(
    "FATAL ERROR",
    "Hardware failure",
    "Possible hardware failure",
    "ROUND OFF",
    "ROUNDOFF",
    "SUMOUT",
    "Worker stopped unexpectedly"
)

function Invoke-HsCpuTortureTest {
    param(
        [Parameter(Mandatory=$true)][ValidateSet("CPU_COMPUTE","CPU_CACHE_IMC","CPU_CORE_CYCLE")][string]$StageName,
        [Parameter(Mandatory=$true)][string]$ConfigPath,
        [Parameter(Mandatory=$true)][string]$ToolCacheRoot,
        [Parameter(Mandatory=$true)][string]$OutputDirectory,
        [Parameter(Mandatory=$true)][double]$DurationMinutes,
        [Parameter(Mandatory=$true)][int]$LogicalProcessors,
        [Parameter(Mandatory=$true)][int]$PhysicalCores,
        [switch]$NoDownload,
        [scriptblock]$TelemetrySample = $null,
        [scriptblock]$CancelCheck = { $false },
        [string]$ProgressLabel = "",
        # > 0: Prime95 "Blend" over this much RAM (MB) - CPU and RAM under
        # load at the same time, as in the classic stress test. 0 = Prime95's
        # default torture test (the Hardware-Stabilitaetstest checks RAM
        # separately with MemoryChecker).
        [int]$TortureMemoryMB = 0,
        # > 0: number of Prime95 workers instead of the stage default.
        [int]$WorkerCount = 0,
        # > 0: Prime95 runs only on these logical processors (bit mask);
        # Prime95's own affinity setting is switched off (EnableSetAffinity=0).
        [long]$AffinityMask = 0,
        # Small FFTs (36K-248K, in cache) on the SSE code path: the least heat
        # per core, so a single loaded core reaches its highest boost clock.
        [switch]$SmallFftSse
    )

    $result = [pscustomobject]@{
        Status          = "SKIPPED"
        Tool            = "Prime95"
        ToolVersion     = ""
        Command         = ""
        Workers         = 0
        CoresPerTest    = 0
        TortureMemoryMB = 0
        AffinityMask    = 0
        DurationSeconds = 0
        FailurePatterns = @()
        PeakTemperature = $null
        Reason          = ""
        LogPath         = ""
    }

    $cfg = Get-HsToolConfig -ConfigPath $ConfigPath
    $tool = Resolve-HsTool -ToolId "prime95" -ToolConfig $cfg -ToolCacheRoot $ToolCacheRoot -NoDownload:$NoDownload
    $result.ToolVersion = $tool.Version
    if (-not $tool.Available) {
        $result.Reason = "Prime95 not available: $($tool.Reason)"
        return $result
    }

    $workDir = Join-Path $ToolCacheRoot "prime95_$StageName"
    New-Item -ItemType Directory -Force -Path $workDir | Out-Null
    Copy-Item -Path (Join-Path (Split-Path $tool.ExecutablePath -Parent) "*") -Destination $workDir -Recurse -Force -ErrorAction SilentlyContinue

    $exePath = Join-Path $workDir (Split-Path $tool.ExecutablePath -Leaf)

    if ($StageName -eq "CPU_COMPUTE") {
        $workers = [math]::Max(1, $PhysicalCores)
        $coresPerTest = 1
    } else {
        $workers = [math]::Max(1, $LogicalProcessors)
        $coresPerTest = 1
    }
    if ($WorkerCount -gt 0) { $workers = $WorkerCount }
    $result.Workers = $workers
    $result.CoresPerTest = $coresPerTest

    $primeConfig = "NumWorkers=$workers`nWorkPreference=0`nCoresPerTest=$coresPerTest`nV30OptionsConverted=1`nWelcomeDialogAlreadyShown=1`n"
    if ($TortureMemoryMB -gt 0) {
        # The keys Prime95 itself writes to prime.txt when "Blend" with a
        # custom memory size is chosen in its torture test dialog (taken from
        # a prime.txt Prime95 30.19 wrote): FFT sizes 4K-8192K, memory in MB,
        # 6 minutes per FFT size, hyperthreads included.
        $primeConfig += "StressTester=1`nUsePrimenet=0`nTortureHyperthreading=1`nMinTortureFFT=4`nMaxTortureFFT=8192`nTortureMem=$TortureMemoryMB`nTortureTime=6`nTortureWeak=0`n"
        $result.TortureMemoryMB = $TortureMemoryMB
    } elseif ($SmallFftSse) {
        # Same keys as above; 36K-248K is Prime95's "Small FFTs" range (in
        # cache), 1 minute per FFT size so a short per-core slot covers several.
        $primeConfig += "StressTester=1`nUsePrimenet=0`nTortureHyperthreading=0`nMinTortureFFT=36`nMaxTortureFFT=248`nTortureMem=0`nTortureTime=1`nTortureWeak=0`n"
    }
    if ($AffinityMask -gt 0) {
        # undoc.txt: "EnableSetAffinity=0 or 1 (default is 1)" in prime.txt.
        $primeConfig += "EnableSetAffinity=0`n"
        $result.AffinityMask = $AffinityMask
    }
    $primeConfig | Out-File -FilePath (Join-Path $workDir "prime.txt") -Encoding ASCII -Force

    # Code path: undoc.txt documents "CpuSupportsAVX=0 or 1" etc. in local.txt.
    # Prime95 writes its own values (CPU speed, GUID) there, so only these
    # lines are added or removed - an earlier SSE run must not stay in effect.
    $localPath = Join-Path $workDir "local.txt"
    $localLines = @()
    $localExists = Test-Path -LiteralPath $localPath
    if ($localExists) {
        $localLines = @(Get-Content -LiteralPath $localPath -ErrorAction SilentlyContinue | Where-Object { $_ -notmatch '^\s*CpuSupports(AVX|AVX2|FMA3|AVX512F)\s*=' })
    }
    if ($SmallFftSse) { $localLines += @("CpuSupportsAVX=0", "CpuSupportsAVX2=0", "CpuSupportsFMA3=0", "CpuSupportsAVX512F=0") }
    if ($localLines.Count -gt 0) {
        $localLines | Out-File -FilePath $localPath -Encoding ASCII -Force
    } elseif ($localExists) {
        # Nothing but our own lines was in it.
        Remove-Item -LiteralPath $localPath -Force -ErrorAction SilentlyContinue
    }

    $resultsPath = Join-Path $workDir "results.txt"
    if (Test-Path -LiteralPath $resultsPath) { Remove-Item -LiteralPath $resultsPath -Force }

    $logPath = Join-Path $OutputDirectory "$StageName.log"
    New-Item -ItemType Directory -Force -Path $OutputDirectory | Out-Null
    $result.LogPath = $logPath
    $result.Command = "$exePath -t (workers=$workers, coresPerTest=$coresPerTest$(if ($TortureMemoryMB -gt 0) { ", blend over $TortureMemoryMB MB RAM" }))"

    $process = Start-Process -FilePath $exePath -ArgumentList "-t" -WorkingDirectory $workDir -PassThru -WindowStyle Minimized
    Register-HsProcess -ProcessId $process.Id -Stage $StageName -LogFile $logPath | Out-Null
    if ($AffinityMask -gt 0) {
        # The process mask restricts every thread of prime95.exe, including
        # the worker it starts right after launch.
        try {
            $process.ProcessorAffinity = [IntPtr]$AffinityMask
        } catch {
            Add-Content -LiteralPath $logPath -Value "Could not set the processor affinity: $($_.Exception.Message)"
        }
    }

    $sw = [Diagnostics.Stopwatch]::StartNew()
    $deadline = [datetime]::Now.AddMinutes($DurationMinutes)
    $foundPatterns = @()
    $peakTemp = $null
    $cancelled = $false
    $exitedEarly = $false
    $earlyExitCode = $null

    $plannedSeconds = [double]$DurationMinutes * 60
    $activity = if ($ProgressLabel) { $ProgressLabel } else { "$StageName (Prime95)" }
    try {
        while ([datetime]::Now -lt $deadline) {
            # Sleep in 1 s steps so the console progress stays live; the
            # actual checks below still run every 5 s as before.
            for ($tick = 0; $tick -lt 5 -and [datetime]::Now -lt $deadline; $tick++) {
                Start-Sleep -Seconds 1
                $timeProgress = Get-HsTimeProgress -ElapsedSeconds $sw.Elapsed.TotalSeconds -TotalSeconds $plannedSeconds
                $tempText = if ($null -ne $peakTemp) { ", Spitze $peakTemp C" } else { "" }
                Write-HsStageProgress -Activity $activity -Status ("{0} Worker, {1}{2}" -f $workers, $timeProgress.Text, $tempText) `
                    -Percent $timeProgress.Percent -SecondsRemaining $timeProgress.Remaining
                if ($process.HasExited) { break }
            }

            $processHasExited = $process.HasExited

            # Check results.txt BEFORE the exit check short-circuits the loop:
            # a short torture-test run (or a fixture) can write its result and
            # exit within the same polling interval, and the failure evidence
            # must not be skipped just because the process is already gone by
            # the time this iteration runs.
            if (Test-Path -LiteralPath $resultsPath) {
                $content = Get-Content -LiteralPath $resultsPath -Raw -ErrorAction SilentlyContinue
                if ($content) {
                    Set-Content -LiteralPath $logPath -Value $content -Encoding UTF8
                    foreach ($pattern in $script:HsPrimeFailurePatterns) {
                        if ($content -match [regex]::Escape($pattern)) {
                            $foundPatterns += $pattern
                        }
                    }
                }
            }

            if ($foundPatterns.Count -gt 0) { break }

            if ($processHasExited) {
                $earlyExitCode = try { $process.ExitCode } catch { $null }
                Add-Content -LiteralPath $logPath -Value "Process exited early with code $earlyExitCode."
                # Exiting before the planned duration means the torture test
                # did not run for the tested range - that must never be
                # reported as PASS (a crashed or blocked prime95.exe would
                # otherwise look like a clean result). Exiting only after the
                # deadline was reached is a normal end of the run.
                if ([datetime]::Now -lt $deadline) { $exitedEarly = $true }
                break
            }

            if ($TelemetrySample) {
                $rows = & $TelemetrySample $StageName
                $temp = ($rows | Where-Object { $_.SensorType -eq "Temperature" } | Select-Object -ExpandProperty Value | Measure-Object -Maximum).Maximum
                if ($temp) { $peakTemp = if ($null -eq $peakTemp) { $temp } else { [math]::Max($peakTemp, $temp) } }
            }

            if (& $CancelCheck) {
                $cancelled = $true
                break
            }
        }
    } finally {
        Write-HsStageProgress -Activity $activity -Completed
        Stop-HsProcessTree -ProcessId $process.Id -Reason "Stage end" -LogPath $logPath
        Unregister-HsProcess -ProcessId $process.Id
        $sw.Stop()
    }

    $result.DurationSeconds = $sw.Elapsed.TotalSeconds
    $result.FailurePatterns = @($foundPatterns | Select-Object -Unique)
    $result.PeakTemperature = $peakTemp

    if ($cancelled) {
        $result.Status = "INTERRUPTED"
        $result.Reason = "$StageName was cancelled (Ctrl+C or thermal abort) after $([math]::Round($result.DurationSeconds,1))s."
    } elseif ($result.FailurePatterns.Count -gt 0) {
        # Verified failure evidence always wins, even if the process then exited.
        $result.Status = "FAIL"
        $label = switch ($StageName) { "CPU_COMPUTE" { "Verified CPU calculation error" } "CPU_CORE_CYCLE" { "Verified calculation error on this core under single-core load" } default { "Cache/memory-path workload error" } }
        $result.Reason = "$label occurred ($($result.FailurePatterns -join ', ')). CPU core stability, voltage, BIOS settings, or related platform stability should be investigated."
    } elseif ($exitedEarly) {
        $result.Status = "BLOCKED"
        $result.Reason = "Prime95 exited after $([math]::Round($result.DurationSeconds,1))s (exit code $earlyExitCode) before the planned $DurationMinutes minute(s) were reached and without logging a calculation error. The planned test range was not covered, so no PASS can be given. Check whether antivirus, missing permissions, or an instant crash stopped prime95.exe."
    } else {
        $result.Status = "PASS"
        $note = if (Test-Path -LiteralPath $resultsPath) {
            "No verified calculation errors found in Prime95's results.txt after $([math]::Round($result.DurationSeconds/60,1)) minute(s) with $workers worker(s)."
        } else {
            "No verified calculation errors observed after $([math]::Round($result.DurationSeconds/60,1)) minute(s) with $workers worker(s). Prime95 did not produce results.txt in this run duration, which is expected behavior when no self-test failure occurs; a longer (Extended profile) run increases the chance of surfacing intermittent errors."
        }
        $result.Reason = $note
    }

    return $result
}

function Get-HsCoreLogicalProcessor {
    <#
        First logical processor of a physical core. Windows numbers the SMT
        threads of a core consecutively (core 0 = logical 0 and 1), so with
        SMT this is core * 2. The same holds for the APIC IDs of a Ryzen
        5000 with one CCD, which is how WHEA entries are mapped to cores.
    #>
    param([Parameter(Mandatory=$true)][int]$Core, [Parameter(Mandatory=$true)][int]$PhysicalCores, [Parameter(Mandatory=$true)][int]$LogicalProcessors)
    $threadsPerCore = if ($PhysicalCores -gt 0 -and $LogicalProcessors -ge 2 * $PhysicalCores) { 2 } else { 1 }
    return $Core * $threadsPerCore
}

function Invoke-HsCoreCycleTest {
    <#
    .SYNOPSIS
        Single-core stability test, one physical core after the other (the
        CoreCycler principle): one Prime95 worker, pinned to one core, Small
        FFTs on the SSE code path. With only one core loaded it boosts to the
        top of its voltage/frequency curve - where a too aggressive Curve
        Optimizer / PBO setting or a weak core fails, which an all-core test
        (lower clocks) does not show.
    #>
    param(
        [Parameter(Mandatory=$true)][string]$ConfigPath,
        [Parameter(Mandatory=$true)][string]$ToolCacheRoot,
        [Parameter(Mandatory=$true)][string]$OutputDirectory,
        [Parameter(Mandatory=$true)][double]$MinutesPerCore,
        [Parameter(Mandatory=$true)][int]$PhysicalCores,
        [Parameter(Mandatory=$true)][int]$LogicalProcessors,
        [int[]]$Cores = @(),
        [switch]$NoDownload,
        [scriptblock]$TelemetrySample = $null,
        [scriptblock]$CancelCheck = { $false },
        [string]$ProgressLabel = "Kern fuer Kern"
    )

    if ($Cores.Count -eq 0) { $Cores = @(0..([math]::Max(1, $PhysicalCores) - 1)) }
    $perCore = New-Object System.Collections.ArrayList
    $index = 0
    foreach ($core in $Cores) {
        $index++
        $logical = Get-HsCoreLogicalProcessor -Core $core -PhysicalCores $PhysicalCores -LogicalProcessors $LogicalProcessors
        if ($logical -gt 62) {
            [void]$perCore.Add([pscustomobject]@{ Core = $core; LogicalProcessor = $logical; Status = "UNSUPPORTED"; Reason = "Cores beyond the first 63 logical processors are not supported."; MaxClockMHz = $null; FailurePatterns = @() })
            continue
        }
        # Highest clock LibreHardwareMonitor reports for this core ("Core #n").
        $clock = @{ Max = 0.0 }
        $sensorName = "Core #$($core + 1)"
        $sample = $null
        if ($TelemetrySample) {
            $innerSample = $TelemetrySample
            $sample = {
                param($stageName)
                $rows = & $innerSample $stageName
                foreach ($row in @($rows)) {
                    if ($null -ne $row -and $row.SensorType -eq "Clock" -and $row.HardwareType -eq "Cpu" -and $row.SensorName -eq $sensorName -and [double]$row.Value -gt $clock.Max) { $clock.Max = [double]$row.Value }
                }
                return ,$rows
            }.GetNewClosure()
        }
        $r = Invoke-HsCpuTortureTest -StageName "CPU_CORE_CYCLE" -ConfigPath $ConfigPath -ToolCacheRoot $ToolCacheRoot `
            -OutputDirectory (Join-Path $OutputDirectory ("Core{0}" -f $core)) -DurationMinutes $MinutesPerCore `
            -LogicalProcessors $LogicalProcessors -PhysicalCores $PhysicalCores -NoDownload:$NoDownload `
            -TelemetrySample $sample -CancelCheck $CancelCheck -WorkerCount 1 -AffinityMask ([long]1 -shl $logical) -SmallFftSse `
            -ProgressLabel ("{0}: Kern {1} ({2} von {3}), 1 Thread, Small FFT" -f $ProgressLabel, $core, $index, $Cores.Count)
        [void]$perCore.Add([pscustomobject]@{
            Core             = $core
            LogicalProcessor = $logical
            Status           = $r.Status
            Reason           = $r.Reason
            MaxClockMHz      = $(if ($clock.Max -gt 0) { [math]::Round($clock.Max) } else { $null })
            FailurePatterns  = @($r.FailurePatterns)
        })
        # A thermal abort / Ctrl+C stops the whole cycle; a missing Prime95
        # would fail every core the same way.
        if ($r.Status -eq "INTERRUPTED") { break }
        if ($r.Status -eq "SKIPPED" -or [string]$r.Reason -match "not available") { break }
    }

    $failed = @($perCore | Where-Object { $_.Status -eq "FAIL" } | ForEach-Object { $_.Core })
    $parts = @($perCore | ForEach-Object {
        $clockText = if ($_.MaxClockMHz) { ", max $($_.MaxClockMHz) MHz" } else { "" }
        $errorText = if (@($_.FailurePatterns).Count -gt 0) { " ($(@($_.FailurePatterns) -join ', '))" } else { "" }
        "Core $($_.Core): $($_.Status)$clockText$errorText"
    })
    $tested = $perCore.Count
    if ($failed.Count -gt 0) {
        $status = "FAIL"
        $reason = "Calculation error under single-core load on core(s) $($failed -join ', '): at its highest boost clock this core does not compute correctly. Typical causes: Curve Optimizer / PBO too aggressive for this core, boost override, or (at stock settings) a weak core."
    } elseif (@($perCore | Where-Object { $_.Status -eq "INTERRUPTED" }).Count -gt 0) {
        $status = "INTERRUPTED"
        $reason = "The core-by-core test was stopped after $tested of $($Cores.Count) core(s)."
    } elseif ($tested -lt $Cores.Count -or @($perCore | Where-Object { $_.Status -ne "PASS" }).Count -gt 0) {
        $status = "BLOCKED"
        $first = @($perCore | Where-Object { $_.Status -ne "PASS" } | Select-Object -First 1)
        $reason = "Not every core could be tested$(if ($first.Count -gt 0) { ": $($first[0].Reason)" })"
    } else {
        $status = "PASS"
        $reason = "All $tested core(s) ran $MinutesPerCore minute(s) each under single-core load (1 thread, Small FFT, SSE) without a calculation error."
    }
    return [pscustomobject]@{
        Status         = $status
        Reason         = "$reason $($parts -join '; ')."
        Cores          = @($perCore)
        FailedCores    = @($failed)
        MinutesPerCore = $MinutesPerCore
    }
}

Export-ModuleMember -Function * -Variable *
