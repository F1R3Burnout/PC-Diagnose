Set-StrictMode -Version 2.0

$moduleDir = $PSScriptRoot
Import-Module (Join-Path $moduleDir "ToolManager.psm1") -Force
Import-Module (Join-Path $moduleDir "ProcessRunner.psm1") -Force

function Invoke-HsRamVerification {
    <#
    .SYNOPSIS
        RAM verification stage using MemoryChecker (lordmulder): write a
        pattern, read it back, compare, count verification errors (spec
        section 10). Never claims 100% of Windows-visible RAM is tested and
        never claims a RAM module is "definitely" defective.
    #>
    param(
        [Parameter(Mandatory=$true)][string]$ConfigPath,
        [Parameter(Mandatory=$true)][string]$ToolCacheRoot,
        [Parameter(Mandatory=$true)][string]$OutputDirectory,
        [Parameter(Mandatory=$true)][int]$Passes,
        [Parameter(Mandatory=$true)][int]$PercentOfPhysicalRam,
        [int]$TimeoutSeconds = 3600,
        [switch]$NoDownload,
        [scriptblock]$OnOutputLine = $null,
        [scriptblock]$CancelCheck = $null
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

    $args = @("--batch", "$PercentOfPhysicalRam%")
    $result.Command = "$($tool.ExecutablePath) $($args -join ' ')"

    $run = Invoke-HsProcess -FilePath $tool.ExecutablePath -ArgumentList $args -TimeoutSeconds $TimeoutSeconds `
        -StdOutPath $logPath -Stage "RAM" -OnOutputLine $OnOutputLine -CancelCheck $CancelCheck `
        -EnvironmentVariables @{ MEMCHCK_PASSES = "$Passes" }

    $result.DurationSeconds = $run.DurationSeconds
    $result.ExitCode = $run.ExitCode
    $result.RawOutputTail = ($run.StdOut -split "`r?`n" | Select-Object -Last 40) -join "`n"

    if ($run.Cancelled) {
        $result.Status = "INTERRUPTED"
        $result.Reason = "MemoryChecker was cancelled (Ctrl+C, timeout, or thermal abort)."
        return $result
    }
    if ($run.TimedOut) {
        $result.Status = "INTERRUPTED"
        $result.Reason = "MemoryChecker did not finish within $TimeoutSeconds seconds and was stopped."
        return $result
    }

    switch ($run.ExitCode) {
        0 {
            $result.Status = "PASS"
            $result.VerificationErrors = 0
            $result.Reason = "$Passes passes completed against $PercentOfPhysicalRam% of physical RAM with 0 verification errors. Note: a Windows user-space test cannot cover 100% of installed RAM; consider MemTest86 (offline) for full coverage."
        }
        1 {
            $result.Status = "FAIL"
            $result.VerificationErrors = 1
            $result.Reason = "Memory verification errors occurred. Possible causes include RAM, the memory controller, the CPU memory path, memory settings, or board-level signal integrity."
        }
        default {
            $result.Status = "WARNING"
            $result.Reason = "MemoryChecker exited with unexpected code $($run.ExitCode)."
        }
    }

    return $result
}

Export-ModuleMember -Function * -Variable *
