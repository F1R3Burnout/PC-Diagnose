Set-StrictMode -Version 2.0

# Central status model shared by every Hardware-Stabilitätstest stage.
$script:HsStatusValues = @(
    "PASS", "FAIL", "WARNING", "SKIPPED", "UNSUPPORTED",
    "INTERRUPTED", "THERMAL_ABORT", "SYSTEM_RESET", "BLOCKED"
)

function Get-HsStatusValues {
    return $script:HsStatusValues
}

function Test-HsIsAdmin {
    $currentIdentity = [Security.Principal.WindowsIdentity]::GetCurrent()
    $principal = New-Object Security.Principal.WindowsPrincipal($currentIdentity)
    return $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

function ConvertTo-HsHtml {
    param([AllowNull()]$Value)
    if ($null -eq $Value) { return "" }
    return [Net.WebUtility]::HtmlEncode([string]$Value)
}

function ConvertTo-HsSafeFileName {
    param([AllowNull()][string]$Value)
    if ([string]::IsNullOrWhiteSpace($Value)) { return "Unknown" }
    $safe = $Value
    foreach ($character in [IO.Path]::GetInvalidFileNameChars()) {
        $safe = $safe.Replace([string]$character, "_")
    }
    return ($safe -replace '\s+', '_').Trim('_')
}

function New-HsStage {
    <#
    .SYNOPSIS
        Creates a new stage result record with the fields required by
        docs/HARDWARE_STABILITY_SPEC.md section "Statusmodell".
    #>
    param(
        [Parameter(Mandatory=$true)][string]$StageName,
        [Parameter(Mandatory=$true)][string]$Component,
        [string]$Tool = "",
        [string]$ToolVersion = ""
    )

    return [pscustomobject]@{
        StageName       = $StageName
        Component       = $Component
        Started         = $null
        Ended           = $null
        Duration        = $null
        Tool            = $Tool
        ToolVersion     = $ToolVersion
        Command         = ""
        ExitCode        = $null
        Status          = "SKIPPED"
        ErrorCount      = 0
        WarningCount    = 0
        Coverage        = ""
        PeakTemperature = $null
        EventsFound     = @()
        SystemReset     = $false
        Notes           = @()
        Assessment      = ""
        LogPaths        = @()
    }
}

function Start-HsStage {
    param([Parameter(Mandatory=$true)]$Stage)
    $Stage.Started = Get-Date
}

function Complete-HsStage {
    param(
        [Parameter(Mandatory=$true)]$Stage,
        [Parameter(Mandatory=$true)][ValidateSet("PASS","FAIL","WARNING","SKIPPED","UNSUPPORTED","INTERRUPTED","THERMAL_ABORT","SYSTEM_RESET","BLOCKED")][string]$Status,
        [string]$Assessment = ""
    )
    $Stage.Ended = Get-Date
    if ($Stage.Started) {
        $Stage.Duration = ($Stage.Ended - $Stage.Started).ToString()
    }
    $Stage.Status = $Status
    if (-not [string]::IsNullOrWhiteSpace($Assessment)) {
        $Stage.Assessment = $Assessment
    }
}

function Add-HsNote {
    param([Parameter(Mandatory=$true)]$Stage, [Parameter(Mandatory=$true)][string]$Note)
    $Stage.Notes = @($Stage.Notes) + $Note
}

$script:HsProgressLastRender = [datetime]::MinValue

function Format-HsDuration {
    <# Formats seconds as m:ss or h:mm:ss for console progress text. #>
    param([double]$Seconds)
    if ($Seconds -lt 0) { $Seconds = 0 }
    $span = [TimeSpan]::FromSeconds([math]::Round($Seconds))
    if ($span.TotalHours -ge 1) { return "{0}:{1:00}:{2:00}" -f [int][math]::Floor($span.TotalHours), $span.Minutes, $span.Seconds }
    return "{0}:{1:00}" -f [int][math]::Floor($span.TotalMinutes), $span.Seconds
}

function Write-HsStageProgress {
    <#
    .SYNOPSIS
        Live console progress for the running stage, throttled to a few
        updates per second so tight loops (surface scan, write/verify) are not
        slowed down by rendering.

    .DESCRIPTION
        Uses ONE progress record (Id 1). The run position ("Komponente 2 von
        8") is part of the activity text via $global:HsProgressContext, and
        the bar itself shows the stage's own progress. An earlier version drew
        the stage as a child record (-ParentId) under an overall record; on a
        real Windows PowerShell 5.1 console only the overall bar appeared and
        sat at 0% for the whole stage, so nothing visibly moved.

        Every 10% a plain line is also written, so progress stays visible in
        the scrollback and in hosts that do not draw progress bars.

        $ProgressPreference is set locally on purpose: the launcher sets it to
        SilentlyContinue globally (to keep Invoke-WebRequest fast), which would
        otherwise hide the bar. Pass -Percent -1 when no real percentage is
        known; then only the status text is shown, never a guessed value.
    #>
    param(
        [Parameter(Mandatory=$true)][string]$Activity,
        [string]$Status = "",
        [double]$Percent = -1,
        [double]$SecondsRemaining = -1,
        [switch]$Completed,
        [switch]$Force
    )
    $ProgressPreference = "Continue"
    try {
        $context = [string](Get-Variable -Name HsProgressContext -Scope Global -ValueOnly -ErrorAction SilentlyContinue)
        $fullActivity = if ($context) { "${context}: $Activity" } else { $Activity }

        if ($Completed) {
            # Inside a run the next stage simply replaces the record; outside
            # a run (direct calls, tests) the bar is removed.
            if (-not $context) { Write-Progress -Id 1 -Activity $fullActivity -Completed }
            $global:HsProgressMilestone = $null
            return
        }

        $writeMilestone = $false
        $step = 0
        if ($Percent -ge 0) {
            $step = [int][math]::Floor([math]::Min(100, $Percent) / 10)
            $milestone = Get-Variable -Name HsProgressMilestone -Scope Global -ValueOnly -ErrorAction SilentlyContinue
            if ($null -eq $milestone -or $milestone.Activity -ne $fullActivity) {
                $global:HsProgressMilestone = @{ Activity = $fullActivity; Step = $step }
            } elseif ($step -gt $milestone.Step) {
                $milestone.Step = $step
                $writeMilestone = $true
            }
        }

        $now = [datetime]::UtcNow
        if (-not $Force -and -not $writeMilestone -and ($now - $script:HsProgressLastRender).TotalMilliseconds -lt 250) { return }
        $script:HsProgressLastRender = $now

        # Remaining time of this stage and of the whole run. The run plan is
        # set per stage by the main script ($global:HsRunPlanState): the sum
        # of the planned durations still ahead, plus whether some of them
        # cannot be known in advance (RAM passes, full surface scan, extended
        # SMART self-test) - then the total is shown as a minimum.
        $statusText = $Status
        if ($SecondsRemaining -ge 0) { $statusText = "$statusText | Phase noch $(Format-HsDuration $SecondsRemaining)" }
        $plan = Get-Variable -Name HsRunPlanState -Scope Global -ValueOnly -ErrorAction SilentlyContinue
        if ($null -ne $plan) {
            $totalSeconds = [double]$plan.LaterKnownSeconds + $(if ($SecondsRemaining -ge 0) { $SecondsRemaining } else { 0 })
            $isMinimum = ($SecondsRemaining -lt 0) -or [bool]$plan.LaterUnknownText
            $prefix = if ($isMinimum) { "mind. " } else { "ca. " }
            $statusText = "$statusText | Gesamt noch $prefix$(Format-HsDuration $totalSeconds)"
            if ($plan.LaterUnknownText) { $statusText = "$statusText + $($plan.LaterUnknownText)" }
        }

        # Current temperatures, supplied by the main script (it owns the
        # telemetry session and caches the readings for a few seconds).
        $temperatureLine = ""
        $provider = Get-Variable -Name HsTemperatureProvider -Scope Global -ValueOnly -ErrorAction SilentlyContinue
        if ($provider) {
            try {
                $temperatureLine = [string](& $provider)
            } catch {
                # Shown once in the run log by the main script; never fails a stage.
                $temperatureLine = ""
                if (-not (Get-Variable -Name HsTemperatureProviderError -Scope Global -ValueOnly -ErrorAction SilentlyContinue)) {
                    $global:HsTemperatureProviderError = $_.Exception.Message
                }
            }
        }

        # Checks running in the background next to this stage (storage scan
        # during the GPU stages), supplied by the main script as a short text.
        $parallelText = ""
        $parallelProvider = Get-Variable -Name HsParallelStatusProvider -Scope Global -ValueOnly -ErrorAction SilentlyContinue
        if ($parallelProvider) {
            try { $parallelText = [string](& $parallelProvider) } catch { $parallelText = "" }
        }
        $operationLine = (@($temperatureLine, $parallelText) | Where-Object { $_ }) -join " | "

        if ($writeMilestone) {
            $line = "    {0}: {1}% - {2}" -f $Activity, ($step * 10), $statusText
            if ($operationLine) { $line = "$line | $operationLine" }
            Write-Host $line -ForegroundColor DarkGray
        }

        $progressArgs = @{ Id = 1; Activity = $fullActivity; Status = $(if ($statusText) { $statusText } else { " " }) }
        if ($Percent -ge 0) { $progressArgs.PercentComplete = [int][math]::Min(100, [math]::Max(0, [math]::Floor($Percent))) }
        if ($SecondsRemaining -ge 0) { $progressArgs.SecondsRemaining = [int][math]::Ceiling($SecondsRemaining) }
        if ($operationLine) { $progressArgs.CurrentOperation = $operationLine }
        Write-Progress @progressArgs
    } catch {
        # Progress output is a convenience only and must never fail a stage.
    }
}

function Write-HsOverallProgress {
    <#
        Sets the run position shown in front of every stage's progress text
        (e.g. "Hardware-Stabilitaetstest (Extended (Lang)), Komponente 1 von 8")
        and shows the stage as started. -Completed clears it at the end.
    #>
    param(
        [Parameter(Mandatory=$true)][string]$Activity,
        [string]$Status = "",
        [string]$Stage = "",
        [switch]$Completed
    )
    $ProgressPreference = "Continue"
    try {
        if ($Completed) {
            $global:HsProgressContext = $null
            $global:HsProgressMilestone = $null
            Write-Progress -Id 1 -Activity $Activity -Completed
            return
        }
        $global:HsProgressContext = if ($Status) { "$Activity, $Status" } else { $Activity }
        $stageText = if ($Stage) { "${global:HsProgressContext}: $Stage" } else { $global:HsProgressContext }
        Write-Progress -Id 1 -Activity $stageText -Status "wird gestartet ..."
    } catch {}
}

function Get-HsTimeProgress {
    <#
        Percent/remaining seconds for time-bound stages (Prime95, VRAM, GPU
        load, combined system test): their only honest progress measure is
        elapsed time against the planned duration.
    #>
    param([Parameter(Mandatory=$true)][double]$ElapsedSeconds, [Parameter(Mandatory=$true)][double]$TotalSeconds)
    if ($TotalSeconds -le 0) { return [pscustomobject]@{ Percent = -1; Remaining = -1; Text = "" } }
    $percent = [math]::Min(100, 100.0 * $ElapsedSeconds / $TotalSeconds)
    $remaining = [math]::Max(0, $TotalSeconds - $ElapsedSeconds)
    return [pscustomobject]@{
        Percent   = $percent
        Remaining = $remaining
        Text      = "{0} von {1}" -f (Format-HsDuration $ElapsedSeconds), (Format-HsDuration $TotalSeconds)
    }
}

function Write-HsLog {
    param(
        [Parameter(Mandatory=$true)][string]$Path,
        [Parameter(Mandatory=$true)][string]$Text,
        [string]$Color = "Gray"
    )
    $line = "[{0}] {1}" -f (Get-Date -Format "HH:mm:ss"), $Text
    Write-Host $line -ForegroundColor $Color
    try {
        $line | Out-File -FilePath $Path -Encoding UTF8 -Append
    } catch {}
}

function Stop-HsProcessTree {
    <#
    .SYNOPSIS
        Stops a process and all of its descendants. Adapted from PCDiagLite's
        Stop-ProcessTreeSafe to avoid orphaned third-party tool processes
        (Prime95, MemoryChecker, memtest_vulkan, smartctl, telemetry helper).
    #>
    param(
        [Parameter(Mandatory=$true)][int]$ProcessId,
        [string]$Reason = "cleanup",
        [string]$LogPath = ""
    )

    try {
        $children = Get-CimInstance Win32_Process -Filter "ParentProcessId=$ProcessId" -ErrorAction SilentlyContinue
        foreach ($child in $children) {
            Stop-HsProcessTree -ProcessId ([int]$child.ProcessId) -Reason $Reason -LogPath $LogPath
        }

        if ($ProcessId -ne $PID) {
            Stop-Process -Id $ProcessId -Force -ErrorAction SilentlyContinue
            if ($LogPath) {
                Write-HsLog -Path $LogPath -Text "Process stopped: PID $ProcessId ($Reason)" -Color "Yellow"
            }
        }
    } catch {
        if ($LogPath) {
            Write-HsLog -Path $LogPath -Text "Could not stop process tree PID $ProcessId`: $($_.Exception.Message)" -Color "DarkYellow"
        }
    }
}

Export-ModuleMember -Function * -Variable *
