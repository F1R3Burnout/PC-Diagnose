Set-StrictMode -Version 2.0

$moduleDir = $PSScriptRoot
Import-Module (Join-Path $moduleDir "ToolManager.psm1") -Force
Import-Module (Join-Path $moduleDir "ProcessRunner.psm1") -Force
Import-Module (Join-Path $moduleDir "Common.psm1") -Force

function Invoke-HsSmartQuery {
    <#
    .SYNOPSIS
        Queries SMART data for a physical drive via smartctl -x (spec
        section 17). Unsupported drives/controllers are reported as
        UNSUPPORTED, never as FAIL (HS-023).
    #>
    param(
        [Parameter(Mandatory=$true)][string]$ConfigPath,
        [Parameter(Mandatory=$true)][string]$ToolCacheRoot,
        [Parameter(Mandatory=$true)][int]$DriveIndex,
        [Parameter(Mandatory=$true)][string]$OutputDirectory,
        [switch]$NoDownload
    )

    $result = [pscustomobject]@{
        Status        = "SKIPPED"
        Tool          = "smartctl"
        ToolVersion   = ""
        HealthStatus  = ""
        Attributes    = @()
        RawOutputPath = ""
        Reason        = ""
        ExitCode      = $null
    }

    $cfg = Get-HsToolConfig -ConfigPath $ConfigPath
    $tool = Resolve-HsTool -ToolId "smartmontools" -ToolConfig $cfg -ToolCacheRoot $ToolCacheRoot -NoDownload:$NoDownload
    $result.ToolVersion = $tool.Version
    if (-not $tool.Available) {
        $result.Status = "SKIPPED"
        $result.Reason = "smartctl not available: $($tool.Reason)"
        return $result
    }

    New-Item -ItemType Directory -Force -Path $OutputDirectory | Out-Null
    $rawPath = Join-Path $OutputDirectory "smartctl_drive$DriveIndex.txt"
    $result.RawOutputPath = $rawPath

    $run = Invoke-HsProcess -FilePath $tool.ExecutablePath -ArgumentList @("-x", "/dev/pd$DriveIndex") -TimeoutSeconds 60 -StdOutPath $rawPath -Stage "STORAGE_SMART"
    $result.ExitCode = $run.ExitCode
    $output = $run.StdOut

    # smartctl's bitmask exit code: bit 0 (cmdline) / bit 1 (device open
    # failed) indicate the drive/controller could not be queried at all.
    if (($run.ExitCode -band 0x03) -ne 0 -or [string]::IsNullOrWhiteSpace($output)) {
        $result.Status = "UNSUPPORTED"
        $result.Reason = "smartctl could not query PhysicalDrive$DriveIndex (exit code $($run.ExitCode)). This is common for USB bridges, RAID controllers, or virtual disks and is not a failure."
        return $result
    }

    if ($output -notmatch "(?i)SMART support is:\s*Available|SMART overall-health") {
        $result.Status = "UNSUPPORTED"
        $result.Reason = "Drive does not report SMART support."
        return $result
    }

    $overallHealth = "Unsupported"
    if ($output -match "(?im)SMART overall-health self-assessment test result:\s*(\S+)") {
        $overallHealth = $matches[1]
    } elseif ($output -match "(?im)health status:\s*(\S+)") {
        $overallHealth = $matches[1]
    }
    $result.HealthStatus = $overallHealth

    $attributes = @()
    foreach ($line in ($output -split "`r?`n")) {
        if ($line -match "(?i)Reallocated_Sector|Current_Pending_Sector|Offline_Uncorrectable|Media_Wearout|Percentage Used|Available Spare|Critical Warning|Unsafe Shutdowns|Media and Data Integrity Errors|Temperature") {
            $attributes += $line.Trim()
        }
    }
    $result.Attributes = $attributes

    if ($overallHealth -match "(?i)FAILED") {
        $result.Status = "FAIL"
        $result.Reason = "SMART overall-health self-assessment reports FAILED."
    } elseif ($overallHealth -match "(?i)PASSED|OK") {
        $result.Status = "PASS"
        $result.Reason = "SMART overall-health self-assessment: $overallHealth."
    } else {
        $result.Status = "WARNING"
        $result.Reason = "SMART overall-health could not be conclusively determined ('$overallHealth')."
    }

    return $result
}

function Test-HsSmartSelfTestStarted {
    <#
        Did "smartctl -t short|long" start a self-test? ATA prints "Testing
        has begun." plus "Please wait N minutes", NVMe prints "Self-test has
        begun" without a "please wait" line. Only "begin"/"started" were
        matched before, so every NVMe drive (e.g. a WD SN570 that lists
        Self_Test in its optional admin commands) was reported as
        UNSUPPORTED.
    #>
    param([AllowNull()][string]$SmartOutput)
    return ([string]$SmartOutput -match '(?i)\b(has begun|has started|test (?:begun|started))\b|please wait|self-test.*(?:begun|started)')
}

function Get-HsSmartSelfTestProgress {
    <#
        Reads "is a self-test still running, and how far" from smartctl -a.
        ATA drives report "Self-test routine in progress... 70% of test
        remaining."; NVMe drives report "Self-test status: Short self-test in
        progress (30% completed)". Only the ATA wording was recognized before,
        so on NVMe the old log entry of an EARLIER test ("Completed without
        error") could be read as the result of a test that was still running.
    #>
    param([AllowNull()][string]$SmartOutput)
    $text = [string]$SmartOutput
    $inProgress = $false
    $percentDone = -1
    # ATA prints the percentage on the line after the status text.
    $ata = [regex]::Match($text, '(?i)Self-test routine in progress[\s\S]{0,160}?(\d{1,3})%\s+of test remaining')
    $nvme = [regex]::Match($text, '(?i)(?<!No )self-test in progress\s*\((\d{1,3})%\s*completed\)')
    if ($ata.Success) {
        $inProgress = $true
        $percentDone = 100 - [int]$ata.Groups[1].Value
    } elseif ($nvme.Success) {
        $inProgress = $true
        $percentDone = [int]$nvme.Groups[1].Value
    } elseif ($text -match '(?i)Self-test routine in progress|(?<!No )self-test in progress') {
        $inProgress = $true
    }
    return [pscustomobject]@{ InProgress = $inProgress; PercentDone = $percentDone }
}

function Start-HsSmartSelfTestRun {
    <#
    .SYNOPSIS
        Starts a SMART short or extended self-test and returns at once. The
        test runs inside the drive (no CPU/RAM use), so the hardware test
        starts it at the very beginning and collects the result with
        Wait-HsSmartSelfTestResult once the storage stages are reached.
    #>
    param(
        [Parameter(Mandatory=$true)][string]$ConfigPath,
        [Parameter(Mandatory=$true)][string]$ToolCacheRoot,
        [Parameter(Mandatory=$true)][int]$DriveIndex,
        [Parameter(Mandatory=$true)][ValidateSet("Short","Extended")][string]$TestType,
        [switch]$NoDownload
    )

    $run = [pscustomobject]@{
        Started     = $false
        Status      = "SKIPPED"
        Reason      = ""
        DriveIndex  = $DriveIndex
        TestType    = $TestType
        StartedAt   = $null
        ToolPath    = ""
    }

    $cfg = Get-HsToolConfig -ConfigPath $ConfigPath
    $tool = Resolve-HsTool -ToolId "smartmontools" -ToolConfig $cfg -ToolCacheRoot $ToolCacheRoot -NoDownload:$NoDownload
    if (-not $tool.Available) {
        $run.Reason = "smartctl not available: $($tool.Reason)"
        return $run
    }
    $run.ToolPath = $tool.ExecutablePath

    $testArg = if ($TestType -eq "Short") { "short" } else { "long" }
    $start = Invoke-HsProcess -FilePath $tool.ExecutablePath -ArgumentList @("-t", $testArg, "/dev/pd$DriveIndex") -TimeoutSeconds 30 -Stage "STORAGE_SMART_SELFTEST"
    if ($start.ExitCode -band 0x03) {
        $run.Status = "UNSUPPORTED"
        $run.Reason = "Could not start SMART $TestType self-test (exit code $($start.ExitCode))."
        return $run
    }
    if (-not (Test-HsSmartSelfTestStarted -SmartOutput $start.StdOut)) {
        $lastLines = (($start.StdOut -split "`r?`n") | Where-Object { $_.Trim() } | Select-Object -Last 3) -join " / "
        $run.Status = "UNSUPPORTED"
        $run.Reason = "Drive/controller does not appear to support self-tests (smartctl: $lastLines)."
        return $run
    }
    $run.Started = $true
    $run.Status = "RUNNING"
    $run.StartedAt = Get-Date
    return $run
}

function Wait-HsSmartSelfTestResult {
    <#
    .SYNOPSIS
        Polls a self-test started with Start-HsSmartSelfTestRun until it is
        finished (instead of a fixed sleep, spec section 18) and judges it.
        A test that was started at the beginning of the run has usually
        finished by the time the Storage stages are reached, so there is
        nothing left to wait for; otherwise this waits at most MaxWaitMinutes.
    #>
    param(
        [Parameter(Mandatory=$true)]$Run,
        [int]$MaxWaitMinutes = 0,
        [string]$ProgressLabel = "SMART-Selbsttest"
    )

    $result = [pscustomobject]@{
        Status    = $Run.Status
        Reason    = $Run.Reason
        RawOutput = ""
    }
    if (-not $Run.Started) { return $result }

    # Short tests take about 2 minutes; an extended test takes from several
    # minutes (NVMe) to hours (HDD) - 5 minutes could never be enough there.
    if ($MaxWaitMinutes -le 0) { $MaxWaitMinutes = if ($Run.TestType -eq "Short") { 5 } else { 120 } }
    $deadline = [datetime]::Now.AddMinutes($MaxWaitMinutes)
    $lastOutput = ""
    $percentDone = -1
    try {
        while ($true) {
            $poll = Invoke-HsProcess -FilePath $Run.ToolPath -ArgumentList @("-a", "/dev/pd$($Run.DriveIndex)") -TimeoutSeconds 30 -Stage "STORAGE_SMART_SELFTEST"
            $lastOutput = $poll.StdOut
            $progress = Get-HsSmartSelfTestProgress -SmartOutput $lastOutput
            if (-not $progress.InProgress -or [datetime]::Now -ge $deadline) { break }
            $percentDone = $progress.PercentDone
            for ($wait = 0; $wait -lt 15 -and [datetime]::Now -lt $deadline; $wait++) {
                Start-Sleep -Seconds 1
                $statusText = if ($percentDone -ge 0) { "$percentDone % erledigt" } else { "laeuft" }
                $elapsed = ([datetime]::Now - [datetime]$Run.StartedAt).TotalSeconds
                Write-HsStageProgress -Activity $ProgressLabel -Status "$($Run.TestType), $statusText, seit $(Format-HsDuration $elapsed)" -Percent $percentDone
            }
        }
    } finally {
        Write-HsStageProgress -Activity $ProgressLabel -Completed
    }

    $result.RawOutput = $lastOutput
    # Judge the NEWEST self-test log entry (ATA "# 1 ...", NVMe " 0 ...")
    # rather than the whole output: older entries from earlier tests are
    # listed too and must not decide this test's result.
    $stillRunning = (Get-HsSmartSelfTestProgress -SmartOutput $lastOutput).InProgress
    $verdictText = [string]$lastOutput
    $newestEntry = [regex]::Match([string]$lastOutput, '(?im)^\s*(?:#\s*1|0)\s+(?:Short|Extended|Offline|Conveyance)\b.*$')
    if ($newestEntry.Success) { $verdictText = $newestEntry.Value }
    $testType = $Run.TestType
    if ($stillRunning) {
        $result.Status = "WARNING"
        $result.Reason = "SMART $testType self-test was still in progress $([math]::Round(([datetime]::Now - [datetime]$Run.StartedAt).TotalMinutes)) minute(s) after its start (waited up to $MaxWaitMinutes minute(s) for it)."
    } elseif ($verdictText -match "(?i)completed without error") {
        $result.Status = "PASS"
        $result.Reason = "SMART $testType self-test completed without error."
    } elseif ($verdictText -match "(?i)completed.*read failure|completed.*error|failed") {
        $result.Status = "FAIL"
        $result.Reason = "SMART $testType self-test reported a failure."
    } else {
        $result.Status = "WARNING"
        $result.Reason = "SMART $testType self-test status could not be conclusively determined."
    }
    return $result
}

function Start-HsSmartSelfTest {
    <#
    .SYNOPSIS
        Starts a SMART self-test and waits for its result (start + wait in
        one call).
    #>
    param(
        [Parameter(Mandatory=$true)][string]$ConfigPath,
        [Parameter(Mandatory=$true)][string]$ToolCacheRoot,
        [Parameter(Mandatory=$true)][int]$DriveIndex,
        [Parameter(Mandatory=$true)][ValidateSet("Short","Extended")][string]$TestType,
        [int]$MaxWaitMinutes = 0,
        [switch]$NoDownload,
        [string]$ProgressLabel = "SMART-Selbsttest"
    )
    $run = Start-HsSmartSelfTestRun -ConfigPath $ConfigPath -ToolCacheRoot $ToolCacheRoot -DriveIndex $DriveIndex -TestType $TestType -NoDownload:$NoDownload
    return Wait-HsSmartSelfTestResult -Run $run -MaxWaitMinutes $MaxWaitMinutes -ProgressLabel $ProgressLabel
}

function Invoke-HsChkdskScan {
    <#
    .SYNOPSIS
        Read-only file-system scan (chkdsk /scan - no /f /r /x /b, no
        automatic repair), spec section 19.
    #>
    param(
        [Parameter(Mandatory=$true)][string]$DriveLetter,
        [Parameter(Mandatory=$true)][string]$OutputDirectory,
        [int]$TimeoutSeconds = 1800
    )

    $result = [pscustomobject]@{
        Status   = "SKIPPED"
        ExitCode = $null
        Reason   = ""
        LogPath  = ""
    }

    New-Item -ItemType Directory -Force -Path $OutputDirectory | Out-Null
    $logPath = Join-Path $OutputDirectory "chkdsk_$($DriveLetter.TrimEnd(':')).txt"
    $result.LogPath = $logPath

    $driveArg = if ($DriveLetter.EndsWith(":")) { $DriveLetter } else { "$DriveLetter`:" }
    $run = Invoke-HsProcess -FilePath "$env:SystemRoot\System32\chkdsk.exe" -ArgumentList @($driveArg, "/scan") -TimeoutSeconds $TimeoutSeconds -StdOutPath $logPath -Stage "STORAGE_FS"
    $result.ExitCode = $run.ExitCode

    if ($run.TimedOut) {
        $result.Status = "INTERRUPTED"
        $result.Reason = "chkdsk /scan did not finish within $TimeoutSeconds seconds."
        return $result
    }

    if ($run.StdOut -match "(?i)Zugriff verweigert|Access is denied|run this utility in elevated mode|erweiterten Modus") {
        $result.Status = "SKIPPED"
        $result.Reason = "chkdsk /scan requires Administrator rights (this process was not elevated)."
        return $result
    }

    switch ($run.ExitCode) {
        0 { $result.Status = "PASS"; $result.Reason = "chkdsk /scan reported no problems on $driveArg." }
        1 { $result.Status = "WARNING"; $result.Reason = "chkdsk /scan reported that errors were found and fixed automatically (online self-healing), not a raw uncorrected error." }
        2 { $result.Status = "WARNING"; $result.Reason = "chkdsk /scan indicates further offline repair may be needed (not performed automatically)." }
        default { $result.Status = "WARNING"; $result.Reason = "chkdsk /scan exited with unexpected code $($run.ExitCode)." }
    }

    return $result
}

Export-ModuleMember -Function * -Variable *
