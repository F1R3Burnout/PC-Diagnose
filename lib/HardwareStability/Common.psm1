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
