Set-StrictMode -Version 2.0

$moduleDir = $PSScriptRoot
Import-Module (Join-Path $moduleDir "EventCorrelation.psm1") -Force

function Get-HsPendingRunPath {
    return "C:\ProgramData\PC-Diagnose\HardwareStability\PendingRun.json"
}

function Get-HsCurrentBootTime {
    return (Get-CimInstance Win32_OperatingSystem).LastBootUpTime
}

function Set-HsPendingRun {
    <#
    .SYNOPSIS
        Persists the state needed to recognize an unexpected reset while a
        stage was actively running (spec section 28). Must be written to
        disk BEFORE the actual load-generating process is started.
    #>
    param(
        [Parameter(Mandatory=$true)][string]$RunId,
        [Parameter(Mandatory=$true)][string]$ResultDirectory,
        [Parameter(Mandatory=$true)][string]$Profile,
        [Parameter(Mandatory=$true)][string]$Stage,
        [Parameter(Mandatory=$true)][datetime]$ExpectedEnd,
        [Parameter(Mandatory=$true)][string]$Status
    )

    $path = Get-HsPendingRunPath
    $dir = Split-Path -Path $path -Parent
    New-Item -ItemType Directory -Force -Path $dir | Out-Null

    $record = [pscustomobject]@{
        RunId               = $RunId
        ResultDirectory     = $ResultDirectory
        Profile             = $Profile
        Stage               = $Stage
        StageStarted        = (Get-Date).ToString("o")
        ExpectedEnd         = $ExpectedEnd.ToString("o")
        BootTimeAtStageStart = (Get-HsCurrentBootTime).ToString("o")
        Status              = $Status
    }

    $json = $record | ConvertTo-Json -Depth 5
    [IO.File]::WriteAllText($path, $json, [Text.UTF8Encoding]::new($false))
    return $record
}

function Get-HsPendingRun {
    $path = Get-HsPendingRunPath
    if (-not (Test-Path -LiteralPath $path)) { return $null }
    try {
        return (Get-Content -LiteralPath $path -Raw -Encoding UTF8 | ConvertFrom-Json)
    } catch {
        return $null
    }
}

function Clear-HsPendingRun {
    $path = Get-HsPendingRunPath
    if (Test-Path -LiteralPath $path) {
        Remove-Item -LiteralPath $path -Force -ErrorAction SilentlyContinue
    }
}

function Test-HsSystemResetSinceRun {
    <#
    .SYNOPSIS
        Determines whether a previously pending, still-"Running" stage was
        interrupted by an unexpected system reset rather than a normal
        shutdown/restart, planned reboot, or a run that simply completed
        (spec sections 29/30/35/36/37 of the acceptance gates).

    .OUTPUTS
        pscustomobject with Classification ("SYSTEM_RESET", "PLANNED", "NONE")
        and Evidence (array of normalized event rows).
    #>
    param(
        [Parameter(Mandatory=$true)]$PendingRun,
        # Test hook: pre-built normalized event rows (see ConvertTo-HsEventRow),
        # used by tests/HardwareStability fixtures instead of querying the
        # live Windows event log for a real reboot/crash scenario.
        [AllowNull()][object[]]$EventRowsOverride = $null,
        [AllowNull()][Nullable[datetime]]$CurrentBootTimeOverride = $null
    )

    $result = [pscustomobject]@{
        Classification = "NONE"
        Evidence       = @()
        Notes          = ""
    }

    if ($null -eq $PendingRun -or [string]$PendingRun.Status -ne "Running") {
        return $result
    }

    $storedBootTime = [datetime]$PendingRun.BootTimeAtStageStart
    $currentBootTime = if ($CurrentBootTimeOverride) { $CurrentBootTimeOverride } else { Get-HsCurrentBootTime }

    if ($currentBootTime -le $storedBootTime.AddSeconds(5)) {
        # Same boot session - the process/host most likely just crashed or was
        # interrupted without a reboot (e.g. Ctrl+C, or the run never resumed).
        # That is INTERRUPTED, not SYSTEM_RESET, and is handled by the caller.
        return $result
    }

    # A reboot happened while the stage was marked Running. Inspect events
    # around the stage-started time to classify planned vs. unexpected.
    $windowStart = ([datetime]$PendingRun.StageStarted).AddMinutes(-1)
    $windowEnd = $currentBootTime.AddMinutes(10)

    $filter = @{
        LogName   = @("System")
        Id        = @(17,18,19,20,41,1001,1074,6005,6006,6008)
        StartTime = $windowStart
        EndTime   = $windowEnd
    }

    $rows = @()
    if ($null -ne $EventRowsOverride) {
        $rows = @($EventRowsOverride)
    } else {
        $rawEvents = @()
        try { $rawEvents = Get-HsEventsSafe -Filter $filter } catch { $rawEvents = @() }
        $rows = @($rawEvents | ForEach-Object { ConvertTo-HsEventRow -Event $_ })
    }

    $has41 = @($rows | Where-Object { $_.ProviderName -match "Kernel-Power" -and $_.Id -eq 41 }).Count -gt 0
    $has6008 = @($rows | Where-Object { $_.Id -eq 6008 }).Count -gt 0
    $has6005 = @($rows | Where-Object { $_.Id -eq 6005 }).Count -gt 0
    $has6006 = @($rows | Where-Object { $_.Id -eq 6006 }).Count -gt 0
    $has1074 = @($rows | Where-Object { $_.Id -eq 1074 }).Count -gt 0
    $bugcheckRows = @($rows | Where-Object { $_.Id -eq 1001 })
    $wheaRows = @($rows | Where-Object { $_.ProviderName -match "(?i)WHEA" })

    $result.Evidence = $rows

    if ($bugcheckRows.Count -gt 0) {
        $result.Classification = "SYSTEM_RESET"
        $bugcheckCode = Get-HsBugcheckCodeFromEvent -Event $bugcheckRows[0]
        $result.Notes = "BugCheck 1001 found (code $bugcheckCode) - blue screen evidence, not just an unclean shutdown."
        return $result
    }

    if ($has1074 -and $has6006) {
        $result.Classification = "PLANNED"
        $result.Notes = "User32 1074 (planned shutdown/restart request) together with a clean Event Log stop (6006) - not classified as a hardware crash."
        return $result
    }

    if (($has41 -or $has6008) -and -not $has1074) {
        $result.Classification = "SYSTEM_RESET"
        $notes = @()
        if ($has41) { $notes += "Kernel-Power 41 (previous session not shut down cleanly)" }
        if ($has6008) { $notes += "EventLog 6008 (unexpected previous shutdown)" }
        if ($wheaRows.Count -gt 0) { $notes += "$($wheaRows.Count) WHEA event(s) in the window" }
        $notes += "No User32 1074 planned-shutdown request found for this window."
        $result.Notes = ($notes -join "; ")
        return $result
    }

    if ($has1074) {
        $result.Classification = "PLANNED"
        $result.Notes = "User32 1074 planned shutdown/restart request found."
        return $result
    }

    $result.Notes = "Reboot detected but no conclusive restart/shutdown evidence found in the event window."
    return $result
}

Export-ModuleMember -Function * -Variable *
