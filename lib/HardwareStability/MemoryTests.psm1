Set-StrictMode -Version 2.0

$moduleDir = $PSScriptRoot
Import-Module (Join-Path $moduleDir "ToolManager.psm1") -Force
Import-Module (Join-Path $moduleDir "ProcessRunner.psm1") -Force
Import-Module (Join-Path $moduleDir "Common.psm1") -Force

function New-HsMemoryCheckerState {
    <# Shared, mutable parse state for one MemoryChecker run. #>
    param([int]$Passes = 0)
    return [hashtable]::Synchronized(@{
        Pass        = 0
        Passes      = $Passes
        Phase       = "Allocating"
        Percent     = 0.0
        Corrupted   = $false
        ErrorLine   = ""
        LastLine    = ""
    })
}

function Update-HsMemoryCheckerState {
    <#
    .SYNOPSIS
        Parses one MemoryChecker output line into the run state.

    .DESCRIPTION
        MemoryChecker (lordmulder, src/memory_checker.c) prints
        "--- [ Pass N of M ] ---" (or "--- [ Testing pass N ] ---" in
        --continuous mode), "Writing memory..." / "Reading memory...", and the
        phase progress as "\r12.3%". .NET's redirected-output reader treats a
        bare carriage return as a line end, so every percentage arrives as its
        own line. Only "Error: N hash check(s) have failed. Memory corrupted"
        is verification evidence; every other "Error:"/"System error:" line
        is a tool/allocation problem and must not be reported as bad RAM.
    #>
    param([Parameter(Mandatory=$true)][hashtable]$State, [AllowNull()][string]$Line)

    if ([string]::IsNullOrWhiteSpace($Line)) { return }
    $text = $Line.Trim()
    if ($text -notmatch '^\d+(\.\d+)?%$') { $State.LastLine = $text }

    if ($text -match '(?i)hash check\(s\) have failed|memory corrupted') {
        $State.Corrupted = $true
        $State.ErrorLine = $text
        return
    }
    if ($text -match '(?i)^(system )?error:' -and -not $State.ErrorLine) {
        $State.ErrorLine = $text
    }
    if ($text -match '(?i)---\s*\[\s*Pass\s+(\d+)\s+of\s+(\d+)\s*\]') {
        $State.Pass = [int]$Matches[1]
        $State.Passes = [int]$Matches[2]
        $State.Phase = "Pass"
        $State.Percent = 0.0
        return
    }
    if ($text -match '(?i)---\s*\[\s*Testing pass\s+(\d+)\s*\]') {
        $State.Pass = [int]$Matches[1]
        $State.Phase = "Pass"
        $State.Percent = 0.0
        return
    }
    if ($text -match '(?i)^Writing memory') { $State.Phase = "Writing"; $State.Percent = 0.0; return }
    if ($text -match '(?i)^Reading memory') { $State.Phase = "Reading"; $State.Percent = 0.0; return }
    if ($text -match '^(\d+(?:\.\d+)?)%') {
        $State.Percent = [double]::Parse($Matches[1], [Globalization.CultureInfo]::InvariantCulture)
    }
}

function Get-HsMemoryCheckerProgress {
    <#
        Converts the parse state into overall percent and a status line. In
        pass mode the percentage covers all passes (each pass = write + read
        phase); in duration mode the caller uses time instead.
    #>
    param([Parameter(Mandatory=$true)][hashtable]$State)

    $phaseText = switch ($State.Phase) {
        "Allocating" { "Speicher wird reserviert" }
        "Writing"    { "schreibt Muster" }
        "Reading"    { "liest zurueck und vergleicht" }
        default      { "startet Durchlauf" }
    }
    $percent = -1.0
    if ($State.Passes -gt 0 -and $State.Pass -gt 0) {
        $phaseShare = switch ($State.Phase) { "Writing" { $State.Percent / 200.0 } "Reading" { 0.5 + $State.Percent / 200.0 } default { 0.0 } }
        $percent = 100.0 * (([double]$State.Pass - 1.0) + $phaseShare) / [double]$State.Passes
    }
    $passText = if ($State.Passes -gt 0 -and $State.Pass -gt 0) { "Durchlauf $($State.Pass)/$($State.Passes)" } elseif ($State.Pass -gt 0) { "Durchlauf $($State.Pass)" } else { "Vorbereitung" }
    $phasePercent = if ($State.Phase -in @("Writing","Reading","Allocating")) { " {0:0.0}%" -f $State.Percent } else { "" }
    return [pscustomobject]@{
        Percent = $percent
        Text    = "$passText, $phaseText$phasePercent"
    }
}

function Get-HsRamResultFromRun {
    <#
        Shared verdict for MemoryChecker runs. FAIL only with verification
        evidence ("Memory corrupted"); a non-zero exit without that evidence
        (e.g. "Failed to allocate the requested amount of physical memory")
        means the test could not run and is BLOCKED, not a RAM error.
    #>
    param(
        [Parameter(Mandatory=$true)][hashtable]$State,
        $ExitCode,
        [bool]$StoppedAfterPlannedDuration = $false
    )
    if ($State.Corrupted) {
        return [pscustomobject]@{
            Status = "FAIL"
            Reason = "Memory verification errors occurred ($($State.ErrorLine)). Possible causes include RAM, the memory controller, the CPU memory path, memory settings, or board-level signal integrity."
        }
    }
    if ($StoppedAfterPlannedDuration) {
        return [pscustomobject]@{ Status = "PASS"; Reason = "" }
    }
    if ($null -eq $ExitCode) {
        return [pscustomobject]@{ Status = "BLOCKED"; Reason = "MemoryChecker did not report an exit code." }
    }
    if ([int]$ExitCode -eq 0) {
        return [pscustomobject]@{ Status = "PASS"; Reason = "" }
    }
    $detail = if ($State.ErrorLine) { $State.ErrorLine } elseif ($State.LastLine) { "last output: $($State.LastLine)" } else { "no error text" }
    return [pscustomobject]@{
        Status = "BLOCKED"
        Reason = "MemoryChecker stopped with exit code $ExitCode without reporting a memory verification error ($detail). The RAM range was not verified - typically not enough free memory for the requested share; close other programs or choose a shorter profile."
    }
}

function Get-HsMaxRamPercent {
    <#
    .SYNOPSIS
        Largest share of physical RAM MemoryChecker can test right now: the
        currently available memory minus a reserve for Windows (and for the
        other workloads of the combined test via -ExtraReserveMB), capped by
        the profile. Using a fixed share either left most RAM untested or
        failed on machines with less free memory.
    #>
    param([int]$ExtraReserveMB = 0, [int]$MaxPercent = 90, [int]$MinPercent = 10)
    $totalMB = 0.0
    $freeMB = 0.0
    try {
        $os = Get-CimInstance Win32_OperatingSystem -ErrorAction Stop
        $totalMB = [double]$os.TotalVisibleMemorySize / 1024
        $freeMB = [double]$os.FreePhysicalMemory / 1024
    } catch {}
    if ($totalMB -le 0) {
        return [pscustomobject]@{ Percent = [math]::Min(50, $MaxPercent); TotalMB = 0; FreeMB = 0; ReserveMB = 0 }
    }
    $reserveMB = [math]::Max(1536.0, $totalMB * 0.06) + $ExtraReserveMB
    $percent = [int][math]::Floor(100.0 * ($freeMB - $reserveMB) / $totalMB)
    $percent = [math]::Max($MinPercent, [math]::Min($MaxPercent, $percent))
    return [pscustomobject]@{
        Percent   = $percent
        TotalMB   = [math]::Round($totalMB)
        FreeMB    = [math]::Round($freeMB)
        ReserveMB = [math]::Round($reserveMB)
    }
}

function Invoke-HsRamVerification {
    <#
    .SYNOPSIS
        RAM verification stage using MemoryChecker (lordmulder): write a
        pattern, read it back, compare, count verification errors (spec
        section 10). Never claims 100% of Windows-visible RAM is tested and
        never claims a RAM module is "definitely" defective.

    .PARAMETER DurationSeconds
        0 = run the configured number of passes. A positive value runs
        MemoryChecker in --continuous mode for that long (used for targeted
        retests where the user picks a duration); reaching the time limit
        without a verification error is a PASS for the time actually tested.
    #>
    param(
        [Parameter(Mandatory=$true)][string]$ConfigPath,
        [Parameter(Mandatory=$true)][string]$ToolCacheRoot,
        [Parameter(Mandatory=$true)][string]$OutputDirectory,
        [Parameter(Mandatory=$true)][int]$Passes,
        [Parameter(Mandatory=$true)][int]$PercentOfPhysicalRam,
        [int]$TimeoutSeconds = 3600,
        [int]$DurationSeconds = 0,
        [switch]$NoDownload,
        [scriptblock]$OnOutputLine = $null,
        [scriptblock]$CancelCheck = $null,
        [string]$ProgressLabel = "RAM (MemoryChecker)"
    )

    $result = [pscustomobject]@{
        Status         = "SKIPPED"
        Tool           = "MemoryChecker"
        ToolVersion    = ""
        Command        = ""
        ExitCode       = $null
        VerificationErrors = $null
        TargetPercent  = $PercentOfPhysicalRam
        Passes         = $Passes
        DurationSeconds = 0
        Reason         = ""
        LogPath        = ""
        RawOutputTail  = ""
    }

    $cfg = Get-HsToolConfig -ConfigPath $ConfigPath
    $tool = Resolve-HsTool -ToolId "memorychecker" -ToolConfig $cfg -ToolCacheRoot $ToolCacheRoot -NoDownload:$NoDownload
    $result.ToolVersion = $tool.Version
    if (-not $tool.Available) {
        $result.Status = "SKIPPED"
        $result.Reason = "MemoryChecker not available: $($tool.Reason)"
        return $result
    }

    New-Item -ItemType Directory -Force -Path $OutputDirectory | Out-Null
    $logPath = Join-Path $OutputDirectory "MemoryChecker.log"
    $result.LogPath = $logPath

    # Not named $args: that is PowerShell's automatic variable for unbound
    # arguments and shadowing it is easy to break in later edits.
    $durationMode = ($DurationSeconds -gt 0)
    $toolArguments = if ($durationMode) { @("--batch", "--continuous", "$PercentOfPhysicalRam%") } else { @("--batch", "$PercentOfPhysicalRam%") }
    $result.Command = "$($tool.ExecutablePath) $($toolArguments -join ' ')"
    if ($durationMode) { $result.Passes = 0 }

    # Callback/tick state lives in module script scope on purpose: these
    # scriptblocks are invoked from the output-event handler and from
    # Invoke-HsProcess's loop, and module-scoped variables resolve reliably
    # there (same pattern as the VRAM stage). Only one RAM stage runs at a time.
    $script:HsRamState = New-HsMemoryCheckerState -Passes $(if ($durationMode) { 0 } else { $Passes })
    $script:HsRamUserCallback = $OnOutputLine
    $script:HsRamProgressLabel = $ProgressLabel
    $script:HsRamPlannedSeconds = [double]$DurationSeconds
    $parseLine = {
        param($line)
        Update-HsMemoryCheckerState -State $script:HsRamState -Line $line
        if ($script:HsRamUserCallback) { & $script:HsRamUserCallback $line }
    }
    $tick = {
        param($elapsed)
        $p = Get-HsMemoryCheckerProgress -State $script:HsRamState
        if ($script:HsRamPlannedSeconds -gt 0) {
            $tp = Get-HsTimeProgress -ElapsedSeconds $elapsed -TotalSeconds $script:HsRamPlannedSeconds
            Write-HsStageProgress -Activity $script:HsRamProgressLabel -Status "$($p.Text), $($tp.Text)" -Percent $tp.Percent -SecondsRemaining $tp.Remaining
        } else {
            Write-HsStageProgress -Activity $script:HsRamProgressLabel -Status "$($p.Text), laeuft seit $(Format-HsDuration $elapsed)" -Percent $p.Percent
        }
    }
    $state = $script:HsRamState
    $label = $ProgressLabel

    $effectiveTimeout = if ($durationMode) { $DurationSeconds } else { $TimeoutSeconds }
    try {
        $run = Invoke-HsProcess -FilePath $tool.ExecutablePath -ArgumentList $toolArguments -TimeoutSeconds $effectiveTimeout `
            -StdOutPath $logPath -Stage "RAM" -OnOutputLine $parseLine -CancelCheck $CancelCheck -OnTick $tick `
            -EnvironmentVariables @{ MEMCHCK_PASSES = "$Passes" }
    } finally {
        Write-HsStageProgress -Activity $label -Completed
    }

    # Parse the complete output once more on this thread: output events can
    # still be queued when the process ends, and the verdict must not depend
    # on that timing.
    $finalState = New-HsMemoryCheckerState -Passes $state.Passes
    foreach ($line in ($run.StdOut -split "`r?`n|`r")) { Update-HsMemoryCheckerState -State $finalState -Line $line }
    if ($state.Corrupted) { $finalState.Corrupted = $true; if (-not $finalState.ErrorLine) { $finalState.ErrorLine = $state.ErrorLine } }

    $result.DurationSeconds = $run.DurationSeconds
    $result.ExitCode = $run.ExitCode
    $result.RawOutputTail = (($run.StdOut -split "`r?`n|`r") | Where-Object { $_ -notmatch '^\s*\d+(\.\d+)?%\s*$' } | Select-Object -Last 40) -join "`n"

    if ($finalState.Corrupted) {
        $verdict = Get-HsRamResultFromRun -State $finalState -ExitCode $run.ExitCode
        $result.Status = $verdict.Status
        $result.VerificationErrors = 1
        $result.Reason = $verdict.Reason
        return $result
    }
    if ($run.Cancelled) {
        $result.Status = "INTERRUPTED"
        $result.Reason = "MemoryChecker was cancelled (Ctrl+C or thermal abort)."
        return $result
    }
    if ($run.TimedOut -and $durationMode) {
        $result.Status = "PASS"
        $result.VerificationErrors = 0
        $passText = if ($finalState.Pass -gt 1) { "$($finalState.Pass - 1) complete pass(es)" } else { "no complete pass" }
        $result.Reason = "MemoryChecker ran continuously for $([math]::Round($run.DurationSeconds/60,1)) minute(s) against $PercentOfPhysicalRam% of physical RAM ($passText) with 0 verification errors. A Windows user-space test cannot cover 100% of installed RAM."
        return $result
    }
    if ($run.TimedOut) {
        $result.Status = "INTERRUPTED"
        $result.Reason = "MemoryChecker did not finish within $TimeoutSeconds seconds and was stopped."
        return $result
    }

    $verdict = Get-HsRamResultFromRun -State $finalState -ExitCode $run.ExitCode
    $result.Status = $verdict.Status
    if ($verdict.Status -eq "PASS") {
        $result.VerificationErrors = 0
        $result.Reason = "$Passes passes completed against $PercentOfPhysicalRam% of physical RAM with 0 verification errors. Note: a Windows user-space test cannot cover 100% of installed RAM; consider MemTest86 (offline) for full coverage."
    } else {
        $result.Reason = $verdict.Reason
    }
    return $result
}

function Start-HsRamBackgroundLoad {
    <#
    .SYNOPSIS
        Starts MemoryChecker in --continuous mode without waiting, so RAM is
        verified WHILE the CPU and GPU are loaded (combined System Stability
        test). Stop it with Complete-HsRamBackgroundLoad.
    #>
    param(
        [Parameter(Mandatory=$true)][string]$ConfigPath,
        [Parameter(Mandatory=$true)][string]$ToolCacheRoot,
        [Parameter(Mandatory=$true)][string]$OutputDirectory,
        [Parameter(Mandatory=$true)][int]$PercentOfPhysicalRam,
        [switch]$NoDownload
    )

    $cfg = Get-HsToolConfig -ConfigPath $ConfigPath
    $tool = Resolve-HsTool -ToolId "memorychecker" -ToolConfig $cfg -ToolCacheRoot $ToolCacheRoot -NoDownload:$NoDownload
    $load = [pscustomobject]@{
        Available     = $tool.Available
        Reason        = if ($tool.Available) { "" } else { "MemoryChecker not available: $($tool.Reason)" }
        Handle        = $null
        State         = New-HsMemoryCheckerState
        PercentOfRam  = $PercentOfPhysicalRam
        LogPath       = ""
    }
    if (-not $tool.Available) { return $load }

    New-Item -ItemType Directory -Force -Path $OutputDirectory | Out-Null
    $load.LogPath = Join-Path $OutputDirectory "MemoryChecker_SystemStability.log"
    $script:HsRamBackgroundState = $load.State
    $parseLine = { param($line) Update-HsMemoryCheckerState -State $script:HsRamBackgroundState -Line $line }
    try {
        $load.Handle = Start-HsBackgroundProcess -FilePath $tool.ExecutablePath -ArgumentList @("--batch", "--continuous", "$PercentOfPhysicalRam%") `
            -StdOutPath $load.LogPath -Stage "SYSTEM_STABILITY_RAM" -OnOutputLine $parseLine
    } catch {
        $load.Available = $false
        $load.Reason = "MemoryChecker could not be started: $($_.Exception.Message)"
    }
    return $load
}

function Complete-HsRamBackgroundLoad {
    <#
        Stops the background MemoryChecker and returns its verdict. PASS means
        it was still verifying when the combined test ended and reported no
        corruption; ending on its own before that is never a PASS.
    #>
    param([Parameter(Mandatory=$true)]$Load)

    if (-not $Load.Available -or $null -eq $Load.Handle) {
        return [pscustomobject]@{ Status = "SKIPPED"; Reason = $Load.Reason; Passes = 0 }
    }
    $stop = Stop-HsBackgroundProcess -Handle $Load.Handle -Reason "System stability end"
    $finalState = New-HsMemoryCheckerState
    foreach ($line in ($stop.StdOut -split "`r?`n|`r")) { Update-HsMemoryCheckerState -State $finalState -Line $line }
    if ($Load.State.Corrupted) { $finalState.Corrupted = $true; if (-not $finalState.ErrorLine) { $finalState.ErrorLine = $Load.State.ErrorLine } }

    $completedPasses = [math]::Max(0, $finalState.Pass - 1)
    if ($finalState.Corrupted) {
        $verdict = Get-HsRamResultFromRun -State $finalState -ExitCode $stop.ExitCode
        return [pscustomobject]@{ Status = $verdict.Status; Reason = $verdict.Reason; Passes = $completedPasses }
    }
    if ($stop.ExitedOnItsOwn) {
        $verdict = Get-HsRamResultFromRun -State $finalState -ExitCode $stop.ExitCode
        $status = if ($verdict.Status -eq "PASS") { "BLOCKED" } else { $verdict.Status }
        return [pscustomobject]@{ Status = $status; Reason = "MemoryChecker ended before the combined test finished. $($verdict.Reason)".Trim(); Passes = $completedPasses }
    }
    return [pscustomobject]@{
        Status = "PASS"
        Reason = "MemoryChecker verified $($Load.PercentOfRam)% of physical RAM continuously during the combined load ($completedPasses complete pass(es)) with 0 verification errors."
        Passes = $completedPasses
    }
}

Export-ModuleMember -Function * -Variable *
