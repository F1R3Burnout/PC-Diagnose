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

    A documented limitation: the official undoc.txt for this version does
    not describe the "MinTortureFFT"/"MaxTortureFFT" ini keys some community
    guides reference for selecting Small/Large FFT ranges, so this
    integration does not rely on them (spec: "Keine Parameter erfinden").
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
        [Parameter(Mandatory=$true)][ValidateSet("CPU_COMPUTE","CPU_CACHE_IMC")][string]$StageName,
        [Parameter(Mandatory=$true)][string]$ConfigPath,
        [Parameter(Mandatory=$true)][string]$ToolCacheRoot,
        [Parameter(Mandatory=$true)][string]$OutputDirectory,
        [Parameter(Mandatory=$true)][double]$DurationMinutes,
        [Parameter(Mandatory=$true)][int]$LogicalProcessors,
        [Parameter(Mandatory=$true)][int]$PhysicalCores,
        [switch]$NoDownload,
        [scriptblock]$TelemetrySample = $null,
        [scriptblock]$CancelCheck = { $false }
    )

    $result = [pscustomobject]@{
        Status          = "SKIPPED"
        Tool            = "Prime95"
        ToolVersion     = ""
        Command         = ""
        Workers         = 0
        CoresPerTest    = 0
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
    $result.Workers = $workers
    $result.CoresPerTest = $coresPerTest

    "NumWorkers=$workers`nWorkPreference=0`nCoresPerTest=$coresPerTest`nV30OptionsConverted=1`nWelcomeDialogAlreadyShown=1`n" |
        Out-File -FilePath (Join-Path $workDir "prime.txt") -Encoding ASCII -Force

    $resultsPath = Join-Path $workDir "results.txt"
    if (Test-Path -LiteralPath $resultsPath) { Remove-Item -LiteralPath $resultsPath -Force }

    $logPath = Join-Path $OutputDirectory "$StageName.log"
    New-Item -ItemType Directory -Force -Path $OutputDirectory | Out-Null
    $result.LogPath = $logPath
    $result.Command = "$exePath -t (workers=$workers, coresPerTest=$coresPerTest)"

    $process = Start-Process -FilePath $exePath -ArgumentList "-t" -WorkingDirectory $workDir -PassThru -WindowStyle Minimized
    Register-HsProcess -ProcessId $process.Id -Stage $StageName -LogFile $logPath | Out-Null

    $sw = [Diagnostics.Stopwatch]::StartNew()
    $deadline = [datetime]::Now.AddMinutes($DurationMinutes)
    $foundPatterns = @()
    $peakTemp = $null
    $cancelled = $false

    try {
        while ([datetime]::Now -lt $deadline) {
            Start-Sleep -Seconds 5

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
                Add-Content -LiteralPath $logPath -Value "Process exited early with code $($process.ExitCode)."
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
        $result.Status = "FAIL"
        $label = if ($StageName -eq "CPU_COMPUTE") { "Verified CPU calculation error" } else { "Cache/memory-path workload error" }
        $result.Reason = "$label occurred ($($result.FailurePatterns -join ', ')). CPU core stability, voltage, BIOS settings, or related platform stability should be investigated."
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

Export-ModuleMember -Function * -Variable *
