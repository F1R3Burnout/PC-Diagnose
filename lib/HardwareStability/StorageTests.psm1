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

function Start-HsSmartSelfTest {
    <#
    .SYNOPSIS
        Starts a SMART short or extended self-test and polls until it
        completes instead of using a fixed sleep (spec section 18).
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

    # Short tests take about 2 minutes; an extended test takes from several
    # minutes (NVMe) to hours (HDD) - 5 minutes could never be enough there.
    if ($MaxWaitMinutes -le 0) { $MaxWaitMinutes = if ($TestType -eq "Short") { 5 } else { 120 } }

    $result = [pscustomobject]@{
        Status  = "SKIPPED"
        Reason  = ""
        RawOutput = ""
    }

    $cfg = Get-HsToolConfig -ConfigPath $ConfigPath
    $tool = Resolve-HsTool -ToolId "smartmontools" -ToolConfig $cfg -ToolCacheRoot $ToolCacheRoot -NoDownload:$NoDownload
    if (-not $tool.Available) {
        $result.Reason = "smartctl not available: $($tool.Reason)"
        return $result
    }

    $testArg = if ($TestType -eq "Short") { "short" } else { "long" }
    $start = Invoke-HsProcess -FilePath $tool.ExecutablePath -ArgumentList @("-t", $testArg, "/dev/pd$DriveIndex") -TimeoutSeconds 30 -Stage "STORAGE_SMART_SELFTEST"
    if ($start.ExitCode -band 0x03) {
        $result.Status = "UNSUPPORTED"
        $result.Reason = "Could not start SMART $TestType self-test (exit code $($start.ExitCode))."
        return $result
    }
    if ($start.StdOut -notmatch "(?i)test.*(begin|started)|please wait") {
        $result.Status = "UNSUPPORTED"
        $result.Reason = "Drive/controller does not appear to support self-tests."
        return $result
    }

    $deadline = [datetime]::Now.AddMinutes($MaxWaitMinutes)
    $waitWatch = [Diagnostics.Stopwatch]::StartNew()
    $lastOutput = ""
    $percentDone = -1
    try {
        while ([datetime]::Now -lt $deadline) {
            for ($wait = 0; $wait -lt 15 -and [datetime]::Now -lt $deadline; $wait++) {
                Start-Sleep -Seconds 1
                $statusText = if ($percentDone -ge 0) { "$percentDone % erledigt" } else { "laeuft" }
                Write-HsStageProgress -Activity $ProgressLabel -Status "$TestType, $statusText, seit $(Format-HsDuration $waitWatch.Elapsed.TotalSeconds)" -Percent $percentDone
            }
            $poll = Invoke-HsProcess -FilePath $tool.ExecutablePath -ArgumentList @("-a", "/dev/pd$DriveIndex") -TimeoutSeconds 30 -Stage "STORAGE_SMART_SELFTEST"
            $lastOutput = $poll.StdOut
            $progress = Get-HsSmartSelfTestProgress -SmartOutput $lastOutput
            if ($progress.InProgress) {
                $percentDone = $progress.PercentDone
                continue
            }
            break
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
    if ($stillRunning) {
        $result.Status = "WARNING"
        $result.Reason = "SMART $TestType self-test did not finish within $MaxWaitMinutes minute(s) (still in progress)."
    } elseif ($verdictText -match "(?i)completed without error") {
        $result.Status = "PASS"
        $result.Reason = "SMART $TestType self-test completed without error."
    } elseif ($verdictText -match "(?i)completed.*read failure|completed.*error|failed") {
        $result.Status = "FAIL"
        $result.Reason = "SMART $TestType self-test reported a failure."
    } else {
        $result.Status = "WARNING"
        $result.Reason = "SMART $TestType self-test status could not be conclusively determined."
    }

    return $result
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
