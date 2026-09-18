Set-StrictMode -Version 2.0

$moduleDir = $PSScriptRoot
Import-Module (Join-Path $moduleDir "ToolManager.psm1") -Force
Import-Module (Join-Path $moduleDir "ProcessRunner.psm1") -Force

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
        [int]$MaxWaitMinutes = 5,
        [switch]$NoDownload
    )

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
    $lastOutput = ""
    while ([datetime]::Now -lt $deadline) {
        Start-Sleep -Seconds 15
        $poll = Invoke-HsProcess -FilePath $tool.ExecutablePath -ArgumentList @("-a", "/dev/pd$DriveIndex") -TimeoutSeconds 30 -Stage "STORAGE_SMART_SELFTEST"
        $lastOutput = $poll.StdOut
        if ($lastOutput -match "(?i)Self-test routine in progress") { continue }
        break
    }

    $result.RawOutput = $lastOutput
    if ($lastOutput -match "(?i)completed without error") {
        $result.Status = "PASS"
        $result.Reason = "SMART $TestType self-test completed without error."
    } elseif ($lastOutput -match "(?i)Self-test routine in progress") {
        $result.Status = "WARNING"
        $result.Reason = "SMART $TestType self-test did not finish within $MaxWaitMinutes minute(s) (still in progress)."
    } elseif ($lastOutput -match "(?i)completed.*read failure|completed.*error") {
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
