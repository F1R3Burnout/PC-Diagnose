Set-StrictMode -Version 2.0

Import-Module (Join-Path $PSScriptRoot "Common.psm1") -Force

<#
    Storage checks in the background.

    The surface scan and the write/read verification only load the disk and
    the storage controller. They run while the GPU stages load the graphics
    card, so their time no longer adds to the run. CPU, Cache and RAM stages
    stay isolated: disk I/O takes CPU time and the file cache takes memory,
    which would blur what an error in those stages points to.

    A runspace in THIS process is used instead of Start-Job: it shares the
    elevated token, needs no second powershell.exe, ends with the process if
    the window is closed, and can be stopped cooperatively through a
    synchronized flag (the native surface reader cannot be interrupted by
    PowerShell's Stop(), only by its cancel callback).

    Progress written inside the runspace lands in its own progress stream,
    never on the console; the main script reads the newest record and shows
    it next to the running GPU stage.
#>

function Start-HsStorageBackgroundChecks {
    <#
    .SYNOPSIS
        Starts the surface scan (optional) followed by the write/read
        verification in a background runspace and returns a handle at once.
    #>
    param(
        [string]$ModuleRoot = $PSScriptRoot,
        [bool]$SurfaceEnabled = $true,
        [int]$DriveIndex = -1,
        [long]$SurfaceMaxBytes = 0,
        [int]$SurfaceMaxSeconds = 0,
        [string]$SurfaceLabel = "Surface-Scan (nur lesen)",
        [Parameter(Mandatory=$true)][string]$WriteVerifyDirectory,
        [int]$WriteVerifySizeMB = 256,
        [string]$WriteVerifyLabel = "Schreib-/Lesepruefung (Testdatei)",
        # Started next to the GPU stages (shown as "parallel seit ...") rather
        # than at the Storage stage itself.
        [switch]$DuringGpu
    )

    $settings = @{
        SurfaceEnabled       = ($SurfaceEnabled -and $DriveIndex -ge 0)
        DriveIndex           = $DriveIndex
        SurfaceMaxBytes      = $SurfaceMaxBytes
        SurfaceMaxSeconds    = $SurfaceMaxSeconds
        SurfaceLabel         = $SurfaceLabel
        WriteVerifyDirectory = $WriteVerifyDirectory
        WriteVerifySizeMB    = $WriteVerifySizeMB
        WriteVerifyLabel     = $WriteVerifyLabel
    }
    $sync = [hashtable]::Synchronized(@{
        Cancel         = $false
        Phase          = "Start"
        Surface        = $null
        SurfaceStarted = $null
        SurfaceEnded   = $null
        WriteVerify    = $null
        WriteStarted   = $null
        WriteEnded     = $null
        SurfaceError   = ""
        WriteError     = ""
        Error          = ""
    })

    $ps = [powershell]::Create()
    [void]$ps.AddScript({
        param($moduleRoot, $sync, $settings)
        try {
            Import-Module (Join-Path $moduleRoot "Common.psm1") -Force
            Import-Module (Join-Path $moduleRoot "StorageSurface.psm1") -Force
            Import-Module (Join-Path $moduleRoot "StorageWriteVerify.psm1") -Force
            $cancelCheck = { [bool]$sync.Cancel }.GetNewClosure()

            # Each part has its own error handling: a surface scan that cannot
            # run (e.g. the raw disk cannot be opened) must not take the
            # write/read verification with it.
            if ($settings.SurfaceEnabled -and -not $sync.Cancel) {
                $sync.Phase = "Surface"
                $sync.SurfaceStarted = Get-Date
                try {
                    $sync.Surface = Invoke-HsStorageSurfaceScan -DriveIndex $settings.DriveIndex -MaxBytes $settings.SurfaceMaxBytes `
                        -MaxSeconds $settings.SurfaceMaxSeconds -CancelCheck $cancelCheck -ProgressLabel $settings.SurfaceLabel
                } catch {
                    $sync.SurfaceError = $_.Exception.Message
                }
                $sync.SurfaceEnded = Get-Date
            }
            if (-not $sync.Cancel) {
                $sync.Phase = "WriteVerify"
                $sync.WriteStarted = Get-Date
                try {
                    $sync.WriteVerify = Invoke-HsStorageWriteReadVerify -Directory $settings.WriteVerifyDirectory -SizeMB $settings.WriteVerifySizeMB `
                        -CancelCheck $cancelCheck -ProgressLabel $settings.WriteVerifyLabel
                } catch {
                    $sync.WriteError = $_.Exception.Message
                }
                $sync.WriteEnded = Get-Date
            }
        } catch {
            $sync.Error = $_.Exception.Message
        } finally {
            $sync.Phase = "Done"
        }
    }).AddArgument([string]$ModuleRoot).AddArgument($sync).AddArgument($settings)

    $async = $ps.BeginInvoke()
    return [pscustomobject]@{
        PowerShell     = $ps
        Async          = $async
        Sync           = $sync
        Settings       = $settings
        DuringGpu      = [bool]$DuringGpu
        StartedAt      = Get-Date
        LastProgress   = $null
        LastPhase      = ""
        MilestonePhase = ""
        MilestoneStep  = -1
        DoneReported   = $false
        Closed         = $false
        Result         = $null
    }
}

function Get-HsStorageBackgroundPhaseName {
    param([string]$Phase)
    switch ($Phase) {
        "Surface"     { return "Surface-Scan" }
        "WriteVerify" { return "Schreib-/Lesepruefung" }
        "Done"        { return "Storage-Pruefung fertig" }
        default       { return "Storage-Pruefung startet" }
    }
}

function Get-HsStorageBackgroundStatus {
    <#
    .SYNOPSIS
        Current state of the background checks: phase, percentage and a short
        text for the progress line of the running stage. Milestone is set
        once per 10 % (and once when everything is done) so the caller can
        write a plain line into the run log.
    #>
    param([Parameter(Mandatory=$true)]$Handle)

    # ReadAll() empties the stream, so a scan that runs for hours does not
    # pile up records in memory.
    $records = $null
    try { $records = $Handle.PowerShell.Streams.Progress.ReadAll() } catch {}
    if ($records) {
        for ($i = $records.Count - 1; $i -ge 0; $i--) {
            if ($records[$i].RecordType -eq [System.Management.Automation.ProgressRecordType]::Processing) {
                $Handle.LastProgress = $records[$i]
                break
            }
        }
    }

    $phase = [string]$Handle.Sync.Phase
    if ($Handle.Async.IsCompleted) { $phase = "Done" }
    # A record belongs to the phase whose label it carries; right after the
    # switch from surface scan to write/verify the newest record may still be
    # the scan's.
    $label = switch ($phase) { "Surface" { $Handle.Settings.SurfaceLabel } "WriteVerify" { $Handle.Settings.WriteVerifyLabel } default { "" } }
    $record = $null
    if ($Handle.LastProgress -and $label -and $Handle.LastProgress.Activity -eq $label) { $record = $Handle.LastProgress }

    $percent = -1
    $detail = ""
    $secondsRemaining = -1
    if ($record) {
        $percent = [int]$record.PercentComplete
        $detail = (([string]$record.StatusDescription) -split ' \| ')[0]
        $secondsRemaining = [int]$record.SecondsRemaining
    }

    $name = Get-HsStorageBackgroundPhaseName -Phase $phase
    $short = if ($percent -ge 0) { "Parallel: $name $percent %" } else { "Parallel: $name" }

    $milestone = ""
    if ($phase -eq "Done") {
        if (-not $Handle.DoneReported) {
            $Handle.DoneReported = $true
            $milestone = "Storage-Pruefung im Hintergrund abgeschlossen - das Ergebnis folgt bei den Storage-Stufen."
        }
    } elseif ($percent -ge 0) {
        $step = [int][math]::Floor([math]::Min(100, $percent) / 10)
        if ($Handle.MilestonePhase -ne $phase) {
            $Handle.MilestonePhase = $phase
            $Handle.MilestoneStep = $step
        } elseif ($step -gt $Handle.MilestoneStep) {
            $Handle.MilestoneStep = $step
            $milestone = "$name $($step * 10) % - $detail"
        }
    }
    $Handle.LastPhase = $phase

    return [pscustomobject]@{
        Phase            = $phase
        Running          = ($phase -ne "Done")
        Percent          = $percent
        Detail           = $detail
        SecondsRemaining = $secondsRemaining
        ShortText        = $short
        Milestone        = $milestone
    }
}

function Wait-HsStorageBackgroundChecks {
    <#
    .SYNOPSIS
        Waits until the surface scan (-Until Surface) or everything
        (-Until All) has finished, mirroring the background progress as the
        bar of the current stage. The cancel check (thermal guard, Ctrl+C
        state) is evaluated every 2 s; when it fires, the background checks
        are asked to stop and the wait ends once they did.
    #>
    param(
        [Parameter(Mandatory=$true)]$Handle,
        [ValidateSet("Surface","All")][string]$Until = "All",
        [scriptblock]$CancelCheck = { $false },
        [string]$ProgressLabel = "Storage-Pruefung",
        [int]$CancelGraceSeconds = 60
    )

    $lastCheck = [datetime]::MinValue
    $cancelledAt = $null
    try {
        while ($true) {
            $status = Get-HsStorageBackgroundStatus -Handle $Handle
            if ($status.Phase -eq "Done") { break }
            if ($Until -eq "Surface" -and $status.Phase -eq "WriteVerify") { break }

            $now = Get-Date
            if ($null -eq $cancelledAt -and ($now - $lastCheck).TotalSeconds -ge 2) {
                $lastCheck = $now
                if (& $CancelCheck) {
                    $Handle.Sync.Cancel = $true
                    $cancelledAt = $now
                }
            }
            if ($null -ne $cancelledAt -and ($now - $cancelledAt).TotalSeconds -ge $CancelGraceSeconds) { break }

            $statusText = if ($status.Detail) { $status.Detail } else { Get-HsStorageBackgroundPhaseName -Phase $status.Phase }
            if ($Handle.DuringGpu) { $statusText = "$statusText (parallel seit $(([datetime]$Handle.StartedAt).ToString('HH:mm')))" }
            if ($null -ne $cancelledAt) { $statusText = "wird abgebrochen ... $statusText" }
            Write-HsStageProgress -Activity $ProgressLabel -Status $statusText -Percent $status.Percent -SecondsRemaining $status.SecondsRemaining
            Start-Sleep -Milliseconds 250
        }
    } finally {
        Write-HsStageProgress -Activity $ProgressLabel -Completed
    }
}

function Complete-HsStorageBackgroundChecks {
    <#
    .SYNOPSIS
        Ends the background checks and returns their results. If they are
        still running they are asked to stop first (cooperatively, then with
        Stop() after TimeoutSeconds). Safe to call more than once.
    #>
    param(
        [Parameter(Mandatory=$true)]$Handle,
        [int]$TimeoutSeconds = 30
    )
    if ($Handle.Closed) { return $Handle.Result }

    $stopped = $false
    if (-not $Handle.Async.IsCompleted) {
        $Handle.Sync.Cancel = $true
        $stopped = $true
        [void]$Handle.Async.AsyncWaitHandle.WaitOne([math]::Max(0, $TimeoutSeconds) * 1000)
    }
    if (-not $Handle.Async.IsCompleted) {
        try { $Handle.PowerShell.Stop() } catch {}
    }
    $errorText = [string]$Handle.Sync.Error
    try {
        [void]$Handle.PowerShell.EndInvoke($Handle.Async)
    } catch {
        if (-not $errorText) { $errorText = $_.Exception.Message }
    }
    if (-not $errorText) {
        try {
            $firstError = @($Handle.PowerShell.Streams.Error) | Select-Object -First 1
            if ($firstError) { $errorText = [string]$firstError }
        } catch {}
    }
    try { $Handle.PowerShell.Dispose() } catch {}

    $Handle.Result = [pscustomobject]@{
        Surface        = $Handle.Sync.Surface
        SurfaceStarted = $Handle.Sync.SurfaceStarted
        SurfaceEnded   = $Handle.Sync.SurfaceEnded
        WriteVerify    = $Handle.Sync.WriteVerify
        WriteStarted   = $Handle.Sync.WriteStarted
        WriteEnded     = $Handle.Sync.WriteEnded
        SurfaceError   = $(if ($Handle.Sync.SurfaceError) { [string]$Handle.Sync.SurfaceError } else { $errorText })
        WriteError     = $(if ($Handle.Sync.WriteError) { [string]$Handle.Sync.WriteError } else { $errorText })
        Error          = $errorText
        Stopped        = $stopped
    }
    $Handle.Closed = $true
    return $Handle.Result
}

Export-ModuleMember -Function * -Variable *
