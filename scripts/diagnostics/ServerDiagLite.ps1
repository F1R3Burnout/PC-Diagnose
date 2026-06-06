<#
.SYNOPSIS
    Creates a small, robust diagnostics package for an unstable Windows PC or headless server.

.DESCRIPTION
    This version is intentionally analysis-friendly:
    - no full EVTX exports
    - no optional Operational logs
    - no Security log
    - no large MEMORY.DMP copy
    - limited event count
    - timeouts for potentially hanging steps
    - detailed progress output with runtime
    - local findings summary with a result window
    - optional privacy mode for masking typical personal and device values
    - HTML report and manifest for support handoff

    If a step hangs, it is skipped after a fixed timeout and the script continues.

.PARAMETER DaysBack
    Event range in days. Default: 30 days.

.PARAMETER OutputRoot
    Output folder. Default: C:\Temp

.PARAMETER MaxEvents
    Maximum number of detailed events per event query. Default: 2000.

.PARAMETER EventTimeoutSeconds
    Timeout for event log collection. Default: 180 seconds.

.PARAMETER StepTimeoutSeconds
    Timeout for larger local collection steps. Default: 90 seconds.

.PARAMETER PrivacyMode
    Masks typical IP addresses, user names, computer names, MACs, serial numbers, and device IDs before ZIP creation.
#>

[CmdletBinding()]
param(
    [int]$DaysBack = 30,
    [string]$OutputRoot = "C:\Temp",
    [int]$MaxEvents = 2000,
    [int]$EventTimeoutSeconds = 180,
    [int]$StepTimeoutSeconds = 90,
    [switch]$PrivacyMode
)

# ==================================================================================================
# Section 1: Start, admin check, and folder structure
# ==================================================================================================
# Why:
# Admin rights are helpful or required for event logs, driver information, powercfg, and minidumps.

$ErrorActionPreference = "Continue"
$ToolName = "ServerDiagLite"
$ToolVersion = "Lite v7 Local Analysis"
$RunStarted = Get-Date

function Test-IsAdmin {
    $currentIdentity = [Security.Principal.WindowsIdentity]::GetCurrent()
    $principal = New-Object Security.Principal.WindowsPrincipal($currentIdentity)
    return $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

if (-not (Test-IsAdmin)) {
    Write-Host "ERROR: Please run this tool as Administrator." -ForegroundColor Red
    exit 1
}

$Timestamp = Get-Date -Format "yyyyMMdd_HHmmss"
$ComputerSafe = ($env:COMPUTERNAME -replace '[\\/:*?"<>| ]', '_')
$Out = Join-Path $OutputRoot "ServerDiagLite_${ComputerSafe}_${Timestamp}"

$Dirs = @{
    Root      = $Out
    Events    = Join-Path $Out "01_Events"
    System    = Join-Path $Out "02_System_Hardware"
    Storage   = Join-Path $Out "03_Storage"
    Network   = Join-Path $Out "04_Network"
    Power     = Join-Path $Out "05_Power"
    Dumps     = Join-Path $Out "06_Minidumps"
    Runtime   = Join-Path $Out "99_Runtime"
}

foreach ($dir in $Dirs.Values) {
    New-Item -ItemType Directory -Force -Path $dir | Out-Null
}

$RuntimeLog = Join-Path $Dirs.Runtime "runtime.log"
Start-Transcript -Path (Join-Path $Dirs.Runtime "transcript.txt") -Force | Out-Null

function Write-ProgressLine {
    param(
        [string]$Text,
        [string]$Color = "Gray"
    )

    $line = "[{0}] {1}" -f (Get-Date -Format "HH:mm:ss"), $Text
    Write-Host $line -ForegroundColor $Color
    $line | Out-File $RuntimeLog -Encoding UTF8 -Append
}

function Stop-ProcessTreeSafe {
    param(
        [Parameter(Mandatory=$true)][int]$ProcessId,
        [string]$Reason = "cleanup"
    )

    # Beendet einen Prozess inklusive Kindprozessen.
    # Why:
    # Stop the full child process tree so older stuck runs cannot block a new run.
    try {
        $children = Get-CimInstance Win32_Process -Filter "ParentProcessId=$ProcessId" -ErrorAction SilentlyContinue
        foreach ($child in $children) {
            Stop-ProcessTreeSafe -ProcessId ([int]$child.ProcessId) -Reason $Reason
        }

        if ($ProcessId -ne $PID) {
            Stop-Process -Id $ProcessId -Force -ErrorAction SilentlyContinue
            Write-ProgressLine "Process stopped: PID $ProcessId ($Reason)" "Yellow"
        }
    } catch {
        Write-ProgressLine "Could not stop process tree PID $ProcessId`: $($_.Exception.Message)" "DarkYellow"
    }
}

function Stop-OldDiagnosticProcesses {
    # Cleans up clearly related diagnostics processes from older runs.

    Write-ProgressLine "Checking for stuck diagnostics processes from older runs..." "Cyan"

    $currentScript = ""
    try { $currentScript = [string]$PSCommandPath } catch {}

    $patterns = @(
        "Collect-ServerDiagnostics_OneClick",
        "Collect-ServerDiagnostics_Lite",
        "Collect-ServerDiagnostics-Lite",
        "Collect-ServerDiagnostics-OneClick",
        "ServerDiagLite_",
        "ServerDiag_"
    )

    $processNames = @("powershell.exe", "pwsh.exe", "wevtutil.exe")

    $old = Get-CimInstance Win32_Process -ErrorAction SilentlyContinue |
        Where-Object {
            $cmd = [string]$_.CommandLine

            if ($processNames -notcontains $_.Name) { return $false }
            if ($_.ProcessId -eq $PID) { return $false }
            if ([string]::IsNullOrWhiteSpace($cmd)) { return $false }
            if (-not [string]::IsNullOrWhiteSpace($currentScript) -and $cmd -like "*$currentScript*") { return $false }

            $matched = $false
            foreach ($pattern in $patterns) {
                if ($cmd -like "*$pattern*") {
                    $matched = $true
                    break
                }
            }

            return $matched
        }

    if (-not $old) {
        Write-ProgressLine "No old diagnostics processes found." "Green"
        return
    }

    foreach ($p in $old) {
        Write-ProgressLine "Old diagnostics process found: PID $($p.ProcessId), $($p.Name)" "Yellow"
        Write-ProgressLine "CommandLine: $($p.CommandLine)" "DarkGray"
        Stop-ProcessTreeSafe -ProcessId ([int]$p.ProcessId) -Reason "old diagnostics process"
    }
}

Write-Host ""
Write-ProgressLine "Creating lightweight diagnostics package..." "Cyan"
Write-ProgressLine "Output folder: $Out" "Gray"
Write-ProgressLine "Event range: last $DaysBack days" "Gray"
Write-ProgressLine "Max detailed events per query: $MaxEvents" "Gray"
Write-ProgressLine "Event timeout: $EventTimeoutSeconds seconds" "Gray"
Write-ProgressLine "Step timeout: $StepTimeoutSeconds seconds" "Gray"
Write-ProgressLine "Privacy mode: $([bool]$PrivacyMode)" "Gray"
Write-Host ""

Stop-OldDiagnosticProcesses


@"
ServerDiagLite v7 Local Analysis
================================

Computer:      $env:COMPUTERNAME
User:          $env:USERNAME
Export time:   $(Get-Date -Format "yyyy-MM-dd HH:mm:ss")
DaysBack:      $DaysBack
MaxEvents:     $MaxEvents
Output folder: $Out
Privacy mode:  $([bool]$PrivacyMode)

Note:
This package contains only the most important diagnostics information for an initial analysis.
It may still contain IP addresses, device names, user names, serial numbers, and paths.
Do not upload it publicly.

Privacy mode:
If this script was started with -PrivacyMode, typical sensitive values are masked before ZIP creation.
This is a helper filter and does not replace manual review before public sharing.

Important:
This version does not store full EVTX logs and does not copy a large MEMORY.DMP file. Stuck old diagnostics processes are cleaned up at startup.
If more detail is needed later, it can be requested deliberately.
"@ | Out-File (Join-Path $Dirs.Root "README.txt") -Encoding UTF8

# ==================================================================================================
# Section 2: Helper functions with feedback and timeouts
# ==================================================================================================
# Why:
# Some Windows queries can hang on damaged logs, faulty storage, or problematic providers.
# Normal steps get clear start/OK/error output. Risky steps run in a child process with a timeout.

function Invoke-Step {
    param(
        [Parameter(Mandatory=$true)][string]$Name,
        [Parameter(Mandatory=$true)][scriptblock]$ScriptBlock
    )

    $sw = [System.Diagnostics.Stopwatch]::StartNew()
    Write-ProgressLine "START: $Name" "Cyan"

    try {
        & $ScriptBlock
        $sw.Stop()
        Write-ProgressLine ("OK: {0} ({1:n1}s)" -f $Name, $sw.Elapsed.TotalSeconds) "Green"
    } catch {
        $sw.Stop()
        $msg = "ERROR: $Name after $([math]::Round($sw.Elapsed.TotalSeconds,1))s - $($_.Exception.Message)"
        Write-ProgressLine $msg "Red"
        $msg | Out-File (Join-Path $Dirs.Runtime "errors.txt") -Encoding UTF8 -Append
        ($_ | Out-String) | Out-File (Join-Path $Dirs.Runtime "errors.txt") -Encoding UTF8 -Append
    }
}

function Invoke-ExternalWithTimeout {
    param(
        [Parameter(Mandatory=$true)][string]$Name,
        [Parameter(Mandatory=$true)][string]$Command,
        [Parameter(Mandatory=$true)][string]$OutputFile,
        [int]$TimeoutSeconds = 30
    )

    $sw = [System.Diagnostics.Stopwatch]::StartNew()
    Write-ProgressLine "START: $Name (Timeout ${TimeoutSeconds}s)" "Cyan"

    $stdout = Join-Path $Dirs.Runtime ("stdout_" + ($Name -replace '[\\/:*?""<>| ]','_') + ".txt")
    $stderr = Join-Path $Dirs.Runtime ("stderr_" + ($Name -replace '[\\/:*?""<>| ]','_') + ".txt")

    try {
        $cmdLine = "/c $Command > `"$OutputFile`" 2>&1"
        $p = Start-Process -FilePath "cmd.exe" -ArgumentList $cmdLine -PassThru -WindowStyle Hidden

        while (-not $p.HasExited) {
            Start-Sleep -Seconds 2
            if ($sw.Elapsed.TotalSeconds -ge $TimeoutSeconds) {
                Stop-ProcessTreeSafe -ProcessId ([int]$p.Id) -Reason "Timeout"
                $sw.Stop()
                $msg = "SKIPPED/TIMEOUT: $Name after $TimeoutSeconds seconds"
                Write-ProgressLine $msg "Yellow"
                $msg | Out-File $OutputFile -Encoding UTF8 -Append
                return
            }
        }

        $sw.Stop()
        Write-ProgressLine ("OK: {0} ({1:n1}s)" -f $Name, $sw.Elapsed.TotalSeconds) "Green"
    } catch {
        $sw.Stop()
        $msg = "ERROR: $Name - $($_.Exception.Message)"
        Write-ProgressLine $msg "Red"
        $msg | Out-File (Join-Path $Dirs.Runtime "errors.txt") -Encoding UTF8 -Append
    }
}

function Invoke-ChildPowerShellWithTimeout {
    param(
        [Parameter(Mandatory=$true)][string]$Name,
        [Parameter(Mandatory=$true)][string]$ScriptContent,
        [int]$TimeoutSeconds = 120
    )

    $safe = ($Name -replace '[\\/:*?""<>| ]','_')
    $child = Join-Path $Dirs.Runtime "${safe}.ps1"
    $stdout = Join-Path $Dirs.Runtime "${safe}_stdout.txt"
    $stderr = Join-Path $Dirs.Runtime "${safe}_stderr.txt"

    [System.IO.File]::WriteAllText($child, $ScriptContent, [System.Text.UTF8Encoding]::new($true))

    $sw = [System.Diagnostics.Stopwatch]::StartNew()
    Write-ProgressLine "START: $Name (Timeout ${TimeoutSeconds}s)" "Cyan"

    try {
        $argLine = "-NoProfile -ExecutionPolicy Bypass -File `"$child`""
        $p = Start-Process -FilePath "powershell.exe" -ArgumentList $argLine `
            -RedirectStandardOutput $stdout -RedirectStandardError $stderr `
            -PassThru -WindowStyle Hidden

        $lastInfo = 0
        while (-not $p.HasExited) {
            Start-Sleep -Seconds 3
            $elapsed = [int]$sw.Elapsed.TotalSeconds

            if (($elapsed - $lastInfo) -ge 15) {
                $lastInfo = $elapsed
                Write-ProgressLine "STILL RUNNING: $Name for ${elapsed}s..." "DarkGray"
            }

            if ($elapsed -ge $TimeoutSeconds) {
                Stop-ProcessTreeSafe -ProcessId ([int]$p.Id) -Reason "Timeout"
                $sw.Stop()
                $msg = "SKIPPED/TIMEOUT: $Name after $TimeoutSeconds seconds"
                Write-ProgressLine $msg "Yellow"
                $msg | Out-File (Join-Path $Dirs.Runtime "timeouts.txt") -Encoding UTF8 -Append
                return $false
            }
        }

        $sw.Stop()
        try {
            $p.WaitForExit()
            $p.Refresh()
        } catch {}

        $exitCode = $null
        try { $exitCode = $p.ExitCode } catch {}
        $exitCodeText = [string]$exitCode

        if ([string]::IsNullOrWhiteSpace($exitCodeText)) {
            $stderrText = ""
            if (Test-Path $stderr) {
                try { $stderrText = Get-Content $stderr -Raw -ErrorAction SilentlyContinue } catch {}
            }

            if ([string]::IsNullOrWhiteSpace($stderrText)) {
                Write-ProgressLine ("OK: {0} ({1:n1}s)" -f $Name, $sw.Elapsed.TotalSeconds) "Green"
                return $true
            }

            Write-ProgressLine "WARNING: $Name finished, exit code unavailable" "Yellow"
            "Exit code unavailable" | Out-File (Join-Path $Dirs.Runtime "errors.txt") -Encoding UTF8 -Append
            $stderrText | Out-File (Join-Path $Dirs.Runtime "errors.txt") -Encoding UTF8 -Append
            return $false
        }

        if ([int]$exitCode -eq 0) {
            Write-ProgressLine ("OK: {0} ({1:n1}s)" -f $Name, $sw.Elapsed.TotalSeconds) "Green"
            return $true
        } else {
            Write-ProgressLine "WARNING: $Name finished with exit code $exitCode" "Yellow"
            "ExitCode $exitCode" | Out-File (Join-Path $Dirs.Runtime "errors.txt") -Encoding UTF8 -Append
            if (Test-Path $stderr) {
                Get-Content $stderr -ErrorAction SilentlyContinue | Out-File (Join-Path $Dirs.Runtime "errors.txt") -Encoding UTF8 -Append
            }
            return $false
        }
    } catch {
        $sw.Stop()
        $msg = "ERROR: $Name - $($_.Exception.Message)"
        Write-ProgressLine $msg "Red"
        $msg | Out-File (Join-Path $Dirs.Runtime "errors.txt") -Encoding UTF8 -Append
        return $false
    }
}

function ConvertTo-PSStringLiteral {
    param([AllowNull()][string]$Value)

    if ($null -eq $Value) { return "''" }
    return "'" + ($Value -replace "'", "''") + "'"
}

function New-ChildScript {
    param([Parameter(Mandatory=$true)][string]$Body)

    $dirLines = foreach ($key in $Dirs.Keys) {
        "    $key = $(ConvertTo-PSStringLiteral ([string]$Dirs[$key]))"
    }

@"
`$ErrorActionPreference = 'Continue'
`$ProgressPreference = 'SilentlyContinue'
`$DaysBack = $DaysBack
`$MaxEvents = $MaxEvents
`$ToolVersion = $(ConvertTo-PSStringLiteral $ToolVersion)
`$Dirs = @{
$($dirLines -join "`r`n")
}

$Body
"@
}

function Read-CsvSafe {
    param([Parameter(Mandatory=$true)][string]$Path)

    if (-not (Test-Path -LiteralPath $Path)) { return @() }

    try {
        return @(Import-Csv -LiteralPath $Path -ErrorAction Stop)
    } catch {
        return @()
    }
}

function Add-Finding {
    param(
        [Parameter(Mandatory=$true)][ref]$Findings,
        [Parameter(Mandatory=$true)][string]$Severity,
        [Parameter(Mandatory=$true)][string]$Category,
        [Parameter(Mandatory=$true)][string]$Title,
        [Parameter(Mandatory=$true)][string]$Evidence,
        [Parameter(Mandatory=$true)][string]$Recommendation,
        [object[]]$EventRows = @(),
        [string]$TimeContext = "",
        [AllowNull()][string]$FirstSeen = "",
        [AllowNull()][string]$LastSeen = ""
    )

    if ($EventRows.Count -gt 0) {
        $eventTimeInfo = Get-EventTimeInfo -Rows $EventRows
        $FirstSeen = $eventTimeInfo.FirstSeen
        $LastSeen = $eventTimeInfo.LastSeen
        $TimeContext = $eventTimeInfo.TimeContext
    }

    if ([string]::IsNullOrWhiteSpace($TimeContext)) {
        $TimeContext = "Observed during this run: $(Format-FindingDate (Get-Date))"
    }

    $Findings.Value += [PSCustomObject]@{
        Severity       = $Severity
        Category       = $Category
        Title          = $Title
        TimeContext    = $TimeContext
        FirstSeen      = $FirstSeen
        LastSeen       = $LastSeen
        Evidence       = $Evidence
        Recommendation = $Recommendation
    }
}

function ConvertTo-DateTimeSafe {
    param([AllowNull()][string]$Value)

    if ([string]::IsNullOrWhiteSpace($Value)) { return $null }

    $text = ([string]$Value).Trim()
    $cultures = @(
        [System.Globalization.CultureInfo]::CurrentCulture,
        [System.Globalization.CultureInfo]::GetCultureInfo("de-DE"),
        [System.Globalization.CultureInfo]::InvariantCulture
    )

    foreach ($culture in $cultures) {
        $date = [datetime]::MinValue
        if ([datetime]::TryParse($text, $culture, [System.Globalization.DateTimeStyles]::AssumeLocal, [ref]$date)) {
            return $date
        }
    }

    return $null
}

function Format-FindingDate {
    param([AllowNull()][datetime]$Date)

    if ($null -eq $Date -or $Date -eq [datetime]::MinValue) { return "" }
    return $Date.ToString("yyyy-MM-dd HH:mm:ss")
}

function Get-EventTimeInfo {
    param([object[]]$Rows)

    $dates = @()
    foreach ($row in @($Rows)) {
        $date = ConvertTo-DateTimeSafe ([string]$row.TimeCreated)
        if ($null -ne $date) {
            $dates += $date
        }
    }

    if ($dates.Count -eq 0) {
        return [PSCustomObject]@{
            FirstSeen = ""
            LastSeen = ""
            TimeContext = "No event timestamp available"
        }
    }

    $ordered = @($dates | Sort-Object)
    $first = $ordered[0]
    $last = $ordered[-1]

    return [PSCustomObject]@{
        FirstSeen = Format-FindingDate $first
        LastSeen = Format-FindingDate $last
        TimeContext = "First seen: $(Format-FindingDate $first); last seen: $(Format-FindingDate $last)"
    }
}

function Get-MatchCount {
    param(
        [object[]]$Rows,
        [Parameter(Mandatory=$true)][scriptblock]$Predicate
    )

    return @($Rows | Where-Object $Predicate).Count
}

function Test-EventLevelAtMost {
    param(
        [Parameter(Mandatory=$true)]$Event,
        [int]$MaxLevel = 3
    )

    try {
        return ([int]$Event.Level -le $MaxLevel)
    } catch {
        return $false
    }
}

function Get-FindingSeverityRank {
    param([AllowNull()][string]$Severity)

    switch ([string]$Severity) {
        "Critical" { return 4 }
        "High"     { return 3 }
        "Medium"   { return 2 }
        "Info"     { return 1 }
        default    { return 0 }
    }
}

function Get-FindingSeverityColor {
    param([AllowNull()][string]$Severity)

    switch ([string]$Severity) {
        "Critical" { return "Red" }
        "High"     { return "Yellow" }
        "Medium"   { return "DarkYellow" }
        "Info"     { return "Gray" }
        default    { return "Gray" }
    }
}

function Get-SortedFindings {
    param([object[]]$Findings)

    $sortProperties = @(
        @{ Expression = { Get-FindingSeverityRank $_.Severity }; Descending = $true }
        "Category"
        "Title"
    )

    return @($Findings | Sort-Object -Property $sortProperties)
}

function Get-FindingCountsText {
    param([object[]]$Findings)

    $parts = @()
    foreach ($severity in @("Critical", "High", "Medium", "Info")) {
        $count = @($Findings | Where-Object { $_.Severity -eq $severity }).Count
        if ($count -gt 0) {
            $parts += ("{0}: {1}" -f $severity, $count)
        }
    }

    if ($parts.Count -eq 0) { return "none" }
    return ($parts -join ", ")
}

function Get-PrimaryCategoriesText {
    param([object[]]$Findings)

    $important = @($Findings | Where-Object { (Get-FindingSeverityRank $_.Severity) -ge 2 })
    if ($important.Count -eq 0) {
        return "No major categories."
    }

    $groups = @($important | Group-Object Category)
    $groups = @($groups | Sort-Object -Property @{ Expression = "Count"; Descending = $true } | Select-Object -First 3)
    return (($groups | ForEach-Object { "{0} ({1})" -f $_.Name, $_.Count }) -join ", ")
}

function Get-AnalysisStatus {
    param([object[]]$Findings)

    $maxRank = 0
    foreach ($finding in @($Findings)) {
        $rank = Get-FindingSeverityRank $finding.Severity
        if ($rank -gt $maxRank) {
            $maxRank = $rank
        }
    }

    if ($maxRank -ge 4) {
        return [PSCustomObject]@{
            Label = "Critical"
            Color = "Red"
            Text  = "At least one critical finding was detected. Review crash, hardware, and storage signals first."
        }
    }

    if ($maxRank -eq 3) {
        return [PSCustomObject]@{
            Label = "Attention"
            Color = "Yellow"
            Text  = "Notable findings were detected. Review the highest priority items soon."
        }
    }

    if ($maxRank -eq 2) {
        return [PSCustomObject]@{
            Label = "Warning"
            Color = "DarkYellow"
            Text  = "Medium-priority findings were detected, but the heuristic did not find a clear high-risk pattern."
        }
    }

    return [PSCustomObject]@{
        Label = "OK"
        Color = "Green"
        Text  = "The local heuristic did not find clear critical patterns in the core data."
    }
}

function Write-AnalysisResultLine {
    param(
        [AllowNull()][string]$Text,
        [string]$Color = "Gray"
    )

    $line = if ($null -eq $Text) { "" } else { [string]$Text }
    Write-Host $line -ForegroundColor $Color
    try {
        $line | Out-File $RuntimeLog -Encoding UTF8 -Append
    } catch {}
}

function Show-LocalAnalysisResult {
    param([object[]]$Findings)

    $items = @(Get-SortedFindings @($Findings))
    $status = Get-AnalysisStatus $items
    $topFindings = @($items | Select-Object -First 5)

    Write-AnalysisResultLine "" "Gray"
    Write-AnalysisResultLine "Local Analysis Result" "Cyan"
    Write-AnalysisResultLine "========================" "Cyan"
    Write-AnalysisResultLine ("Overall status: {0}" -f $status.Label) $status.Color
    Write-AnalysisResultLine ("Summary: {0}" -f $status.Text) "Gray"
    Write-AnalysisResultLine ("Findings: {0}" -f (Get-FindingCountsText $items)) "Gray"
    Write-AnalysisResultLine ("Primary areas: {0}" -f (Get-PrimaryCategoriesText $items)) "Gray"

    if ($topFindings.Count -gt 0) {
        Write-AnalysisResultLine "" "Gray"
        Write-AnalysisResultLine "Most important findings:" "Cyan"
        foreach ($finding in $topFindings) {
            $color = Get-FindingSeverityColor $finding.Severity
            Write-AnalysisResultLine ("- [{0}] {1}: {2}" -f $finding.Severity, $finding.Category, $finding.Title) $color
            Write-AnalysisResultLine ("  Time: {0}" -f $finding.TimeContext) "Gray"
            Write-AnalysisResultLine ("  Evidence: {0}" -f $finding.Evidence) "Gray"
            Write-AnalysisResultLine ("  Next step: {0}" -f $finding.Recommendation) "Gray"
        }
    }

    Write-AnalysisResultLine "" "Gray"
    Write-AnalysisResultLine "Details in the ZIP: 00_Findings_Summary.txt and 00_Report.html" "Cyan"
}

function ConvertTo-NumberSafe {
    param([AllowNull()][string]$Value)

    if ([string]::IsNullOrWhiteSpace($Value)) { return $null }

    $text = ([string]$Value).Trim()
    $styles = [System.Globalization.NumberStyles]::Float
    $cultures = @(
        [System.Globalization.CultureInfo]::CurrentCulture,
        [System.Globalization.CultureInfo]::GetCultureInfo("de-DE"),
        [System.Globalization.CultureInfo]::InvariantCulture
    )

    foreach ($culture in $cultures) {
        $number = 0.0
        if ([double]::TryParse($text, $styles, $culture, [ref]$number)) {
            return $number
        }
    }

    if ($text -match '^\d+,\d+$') {
        $number = 0.0
        if ([double]::TryParse(($text -replace ',', '.'), $styles, [System.Globalization.CultureInfo]::InvariantCulture, [ref]$number)) {
            return $number
        }
    }

    return $null
}

function Format-NumberInvariant {
    param(
        [AllowNull()][string]$Value,
        [string]$Format = "0.##"
    )

    $number = ConvertTo-NumberSafe $Value
    if ($null -eq $number) {
        return [string]$Value
    }

    return $number.ToString($Format, [System.Globalization.CultureInfo]::InvariantCulture)
}

function Escape-Html {
    param([AllowNull()][string]$Text)

    if ($null -eq $Text) { return "" }
    return [System.Net.WebUtility]::HtmlEncode([string]$Text)
}

function New-HtmlTable {
    param(
        [object[]]$Rows,
        [string[]]$Columns,
        [int]$MaxRows = 50
    )

    if (-not $Rows -or $Rows.Count -eq 0) {
        return "<p class=""muted"">No data found.</p>"
    }

    $sb = New-Object System.Text.StringBuilder
    [void]$sb.AppendLine("<table>")
    [void]$sb.AppendLine("<thead><tr>")
    foreach ($column in $Columns) {
        [void]$sb.AppendLine("<th>$(Escape-Html $column)</th>")
    }
    [void]$sb.AppendLine("</tr></thead>")
    [void]$sb.AppendLine("<tbody>")

    foreach ($row in ($Rows | Select-Object -First $MaxRows)) {
        [void]$sb.AppendLine("<tr>")
        foreach ($column in $Columns) {
            $value = ""
            try { $value = [string]$row.$column } catch {}
            [void]$sb.AppendLine("<td>$(Escape-Html $value)</td>")
        }
        [void]$sb.AppendLine("</tr>")
    }

    [void]$sb.AppendLine("</tbody></table>")
    return $sb.ToString()
}

function Get-StatusCssClass {
    param([AllowNull()][string]$Status)

    switch ([string]$Status) {
        "Critical"  { return "status-critical" }
        "Attention" { return "status-high" }
        "Warning"   { return "status-medium" }
        "OK"        { return "status-ok" }
        default     { return "status-neutral" }
    }
}

function Get-SeverityCssClass {
    param([AllowNull()][string]$Severity)

    switch ([string]$Severity) {
        "Critical" { return "sev-critical" }
        "High"     { return "sev-high" }
        "Medium"   { return "sev-medium" }
        "Info"     { return "sev-info" }
        default    { return "sev-info" }
    }
}

function New-FindingCardsHtml {
    param(
        [object[]]$Findings,
        [int]$MaxRows = 6
    )

    $items = @(Get-SortedFindings $Findings | Select-Object -First $MaxRows)
    if ($items.Count -eq 0) {
        return '<p class="muted">No findings available.</p>'
    }

    $sb = New-Object System.Text.StringBuilder
    [void]$sb.AppendLine('<div class="finding-list">')

    foreach ($finding in $items) {
        $class = Get-SeverityCssClass $finding.Severity
        [void]$sb.AppendLine("<section class=""finding $class"">")
        [void]$sb.AppendLine('  <div class="finding-head">')
        [void]$sb.AppendLine("    <span class=""badge"">$(Escape-Html $finding.Severity)</span>")
        [void]$sb.AppendLine("    <span class=""category"">$(Escape-Html $finding.Category)</span>")
        [void]$sb.AppendLine('  </div>')
        [void]$sb.AppendLine("  <h3>$(Escape-Html $finding.Title)</h3>")
        [void]$sb.AppendLine("  <p><strong>Time:</strong> $(Escape-Html $finding.TimeContext)</p>")
        [void]$sb.AppendLine("  <p><strong>Evidence:</strong> $(Escape-Html $finding.Evidence)</p>")
        [void]$sb.AppendLine("  <p><strong>Next step:</strong> $(Escape-Html $finding.Recommendation)</p>")
        [void]$sb.AppendLine('</section>')
    }

    [void]$sb.AppendLine('</div>')
    return $sb.ToString()
}

function Write-InitialFindingsReport {
    $findings = @()
    $currentObservation = "Observed during this run: $(Format-FindingDate (Get-Date))"

    $targetedPath = Join-Path $Dirs.Events "System_Targeted_Stability_Storage_Network_${DaysBack}d.csv"
    $systemPath = Join-Path $Dirs.Events "System_WARN_ERR_CRIT_${DaysBack}d.csv"
    $applicationPath = Join-Path $Dirs.Events "Application_WARN_ERR_CRIT_${DaysBack}d.csv"

    $targeted = Read-CsvSafe $targetedPath
    $systemEvents = Read-CsvSafe $systemPath
    $applicationEvents = Read-CsvSafe $applicationPath
    $allEvents = @($targeted + $systemEvents + $applicationEvents) |
        Group-Object { "$($_.TimeCreated)|$($_.LogName)|$($_.ProviderName)|$($_.Id)" } |
        ForEach-Object { $_.Group[0] }

    $bugCheckEvents = @($allEvents | Where-Object { (Test-EventLevelAtMost $_ 3) -and ($_.ProviderName -match 'BugCheck' -or $_.Id -eq '1001') })
    if ($bugCheckEvents.Count -gt 0) {
        Add-Finding ([ref]$findings) "Critical" "Crash" "BugCheck / blue screen indicators found" "$($bugCheckEvents.Count) matching event(s), for example BugCheck provider or event ID 1001." "Analyze minidumps in 06_Minidumps with a driver and hardware focus. Then check storage, RAM, and driver versions." -EventRows $bugCheckEvents
    }

    $kernelPowerEvents = @($allEvents | Where-Object { (Test-EventLevelAtMost $_ 3) -and $_.ProviderName -match 'Kernel-Power' -and $_.Id -eq '41' })
    if ($kernelPowerEvents.Count -gt 0) {
        Add-Finding ([ref]$findings) "High" "Stability" "Unexpected restart or power loss" "$($kernelPowerEvents.Count) Kernel-Power 41 event(s)." "Check PSU/UPS, thermals, BIOS/UEFI, RAM/CPU, and the events immediately before the restart." -EventRows $kernelPowerEvents
    }

    $unexpectedShutdownEvents = @($allEvents | Where-Object { (Test-EventLevelAtMost $_ 3) -and ($_.Id -eq '6008' -or ($_.ProviderName -match 'EventLog' -and $_.Id -eq '6008')) })
    if ($unexpectedShutdownEvents.Count -gt 0) {
        Add-Finding ([ref]$findings) "High" "Stability" "Windows reports an unexpected shutdown" "$($unexpectedShutdownEvents.Count) event(s) with ID 6008." "Correlate these timestamps with Kernel-Power, BugCheck, WHEA, Disk/Ntfs, and service errors." -EventRows $unexpectedShutdownEvents
    }

    $wheaEvents = @($allEvents | Where-Object { (Test-EventLevelAtMost $_ 3) -and $_.ProviderName -match 'WHEA-Logger' })
    if ($wheaEvents.Count -gt 0) {
        Add-Finding ([ref]$findings) "High" "Hardware" "WHEA hardware error events found" "$($wheaEvents.Count) WHEA-Logger event(s)." "Check CPU/RAM/PCIe/NVMe/GPU and BIOS/UEFI. Repeated WHEA events often point to hardware, firmware, or overclocking/XMP instability." -EventRows $wheaEvents
    }

    $storageEvents = @($allEvents | Where-Object {
        (Test-EventLevelAtMost $_ 3) -and
        (
            ($_.ProviderName -match 'disk|Ntfs|storahci|stornvme|iaStor|volmgr') -or
            ($_.Id -in @('51','55','98','129','153','154','157','161','162'))
        )
    })
    if ($storageEvents.Count -gt 0) {
        Add-Finding ([ref]$findings) "High" "Storage" "Storage or file system events found" "$($storageEvents.Count) matching Disk/Ntfs/Storage/volmgr event(s) or typical storage event ID(s)." "Check SMART/vendor diagnostics, cables/backplane, controller/NVMe/SATA drivers, and file system health. For NTFS 55/98 or Disk 51/153, verify backups soon." -EventRows $storageEvents
    }

    $networkEvents = @($allEvents | Where-Object { (Test-EventLevelAtMost $_ 3) -and $_.ProviderName -match 'Tcpip|Dhcp|DNS Client Events|NDIS|Netwtw|e1|e2f|e2fnexpress' })
    if ($networkEvents.Count -gt 0) {
        Add-Finding ([ref]$findings) "Medium" "Network" "Network or NIC driver events found" "$($networkEvents.Count) matching network event(s)." "Check NIC driver/firmware, power saving settings, link speed, switch port, DHCP, and DNS." -EventRows $networkEvents
    }

    $serviceEvents = @($allEvents | Where-Object {
        (Test-EventLevelAtMost $_ 3) -and
        $_.ProviderName -match 'Service Control Manager' -and
        $_.Id -in @('7000','7001','7009','7011','7022','7023','7024','7031','7032','7034')
    })
    if ($serviceEvents.Count -gt 0) {
        Add-Finding ([ref]$findings) "Medium" "Services" "Service errors or crashes found" "$($serviceEvents.Count) Service Control Manager event(s)." "Open the top events and check whether a specific service repeatedly hangs, crashes, or blocks startup." -EventRows $serviceEvents
    }

    $disks = Read-CsvSafe (Join-Path $Dirs.Storage "Disks.csv")
    $badDisks = @($disks | Where-Object {
        (($_.HealthStatus) -and ($_.HealthStatus -notmatch 'Healthy|Unknown')) -or
        (($_.OperationalStatus) -and ($_.OperationalStatus -notmatch 'Online|OK|No Media'))
    })
    if ($badDisks.Count -gt 0) {
        Add-Finding ([ref]$findings) "High" "Storage" "Disk status is not healthy" "$($badDisks.Count) disk row(s) have HealthStatus or OperationalStatus other than Healthy/Online." "Review Disks.csv and PhysicalDisks.csv and prioritize the affected disk(s)." -TimeContext $currentObservation
    }

    $physicalDisks = Read-CsvSafe (Join-Path $Dirs.Storage "PhysicalDisks.csv")
    $badPhysical = @($physicalDisks | Where-Object {
        (($_.HealthStatus) -and ($_.HealthStatus -notmatch 'Healthy|Unknown')) -or
        (($_.OperationalStatus) -and ($_.OperationalStatus -notmatch 'OK|No Media'))
    })
    if ($badPhysical.Count -gt 0) {
        Add-Finding ([ref]$findings) "High" "Storage" "PhysicalDisk status is suspicious" "$($badPhysical.Count) PhysicalDisk row(s) look suspicious." "Review Storage Reliability Counter output and run the vendor diagnostic tool." -TimeContext $currentObservation
    }

    $volumes = Read-CsvSafe (Join-Path $Dirs.Storage "Volumes.csv")
    $badVolumes = @($volumes | Where-Object {
        (($_.HealthStatus) -and ($_.HealthStatus -notmatch 'Healthy|Unknown')) -or
        (($_.OperationalStatus) -and ($_.OperationalStatus -notmatch 'OK|Online|No Media'))
    })
    if ($badVolumes.Count -gt 0) {
        Add-Finding ([ref]$findings) "Medium" "Storage" "Volume status is not healthy" "$($badVolumes.Count) volume row(s) have HealthStatus or OperationalStatus other than Healthy/OK." "Review Volumes.csv. For Full Repair Needed, verify file system health and identify the affected partition." -TimeContext $currentObservation
    }

    $lowVolumes = @($volumes | Where-Object {
        $freePercent = ConvertTo-NumberSafe $_.FreePercent
        $sizeGb = ConvertTo-NumberSafe $_.SizeGB
        $null -ne $freePercent -and $null -ne $sizeGb -and $sizeGb -ge 10 -and $freePercent -lt 10
    })
    if ($lowVolumes.Count -gt 0) {
        $lowVolumeSummary = (($lowVolumes | Select-Object -First 5 | ForEach-Object {
            $drive = if ([string]::IsNullOrWhiteSpace([string]$_.DriveLetter)) { "(no drive letter)" } else { "$($_.DriveLetter):" }
            "{0} {1} GB free ({2}% free)" -f $drive, (Format-NumberInvariant $_.FreeGB), (Format-NumberInvariant $_.FreePercent)
        }) -join "; ")
        Add-Finding ([ref]$findings) "Medium" "Storage" "Low free disk space" "$($lowVolumes.Count) volume(s) of at least 10 GB are below 10% free. $lowVolumeSummary" "Free disk space, review logs/temp data, and identify growth drivers. Because this is a current-state finding, rerun the tool after cleanup to confirm it is gone." -TimeContext $currentObservation
    }

    $dumpRows = Read-CsvSafe (Join-Path $Dirs.Dumps "DumpFiles.csv")
    $copiedDumps = @($dumpRows | Where-Object { $_.Type -match 'Minidump copied' })
    if ($copiedDumps.Count -gt 0) {
        $dumpEvents = @($copiedDumps | ForEach-Object { [PSCustomObject]@{ TimeCreated = $_.LastWriteTime } })
        Add-Finding ([ref]$findings) "High" "Crash" "Minidumps are included in the package" "$($copiedDumps.Count) minidump(s) copied." "Analyze minidumps with WinDbg/DebugDiag. The driver name and BugCheck code are often the fastest next clue." -EventRows $dumpEvents
    }

    $memoryDump = @($dumpRows | Where-Object { $_.Type -match 'MEMORY\.DMP' })
    if ($memoryDump.Count -gt 0) {
        $memoryDumpEvents = @($memoryDump | ForEach-Object { [PSCustomObject]@{ TimeCreated = $_.LastWriteTime } })
        Add-Finding ([ref]$findings) "Info" "Crash" "Large MEMORY.DMP exists but was not copied" "MEMORY.DMP was listed only for size and privacy reasons." "Request it only if minidumps are not enough." -EventRows $memoryDumpEvents
    }

    $timeoutsPath = Join-Path $Dirs.Runtime "timeouts.txt"
    if (Test-Path -LiteralPath $timeoutsPath) {
        $timeoutLines = @(Get-Content -LiteralPath $timeoutsPath -ErrorAction SilentlyContinue)
        if ($timeoutLines.Count -gt 0) {
            Add-Finding ([ref]$findings) "Medium" "Collection" "One or more collection steps timed out" "$($timeoutLines.Count) timeout line(s) in 99_Runtime\timeouts.txt." "Review the timeout file. A hanging provider can itself be a symptom." -TimeContext $currentObservation
        }
    }

    $errorsPath = Join-Path $Dirs.Runtime "errors.txt"
    if (Test-Path -LiteralPath $errorsPath) {
        $errorLines = @(Get-Content -LiteralPath $errorsPath -ErrorAction SilentlyContinue)
        if ($errorLines.Count -gt 0) {
            Add-Finding ([ref]$findings) "Info" "Collection" "Collection errors were logged" "$($errorLines.Count) line(s) in 99_Runtime\errors.txt." "Review errors.txt. Individual missing providers are not automatically critical." -TimeContext $currentObservation
        }
    }

    if ($findings.Count -eq 0) {
        Add-Finding ([ref]$findings) "Info" "Overview" "No clear high-risk pattern found by the local heuristic" "The heuristic did not find the typical signatures in the collected core data." "Still review top events, targeted events, and exact incident timestamps." -TimeContext $currentObservation
    }

    $findingsPath = Join-Path $Dirs.Runtime "Findings.csv"
    $findings | Export-Csv $findingsPath -NoTypeInformation -Encoding UTF8

    $analysisStatus = Get-AnalysisStatus $findings
    $sortedFindings = @(Get-SortedFindings $findings)
    $topFindings = @($sortedFindings | Select-Object -First 5)

    $reportPath = Join-Path $Dirs.Root "00_Findings_Summary.txt"
@"
Local Findings Summary
======================

Tool:          $ToolName $ToolVersion
Created:       $(Format-FindingDate (Get-Date))
Computer:      $env:COMPUTERNAME
Event range:   last $DaysBack days
PrivacyMode:   $([bool]$PrivacyMode)

Important:
This file is a heuristic first assessment based on the collected data.
It does not replace manual analysis, but it prioritizes the likely relevant signals.

Overall status: $($analysisStatus.Label)
Summary:        $($analysisStatus.Text)
Findings:      $(Get-FindingCountsText $findings)
Primary areas: $(Get-PrimaryCategoriesText $findings)

"@ | Out-File $reportPath -Encoding UTF8

    if ($topFindings.Count -gt 0) {
        "Most Important Findings:`r`n" | Out-File $reportPath -Encoding UTF8 -Append
        foreach ($finding in $topFindings) {
@"
[$($finding.Severity)] $($finding.Category): $($finding.Title)
Time:          $($finding.TimeContext)
Evidence:      $($finding.Evidence)
Next step:     $($finding.Recommendation)

"@ | Out-File $reportPath -Encoding UTF8 -Append
        }
    }

    "All Findings:`r`n" | Out-File $reportPath -Encoding UTF8 -Append

    foreach ($finding in $sortedFindings) {
@"
[$($finding.Severity)] $($finding.Category): $($finding.Title)
Time:          $($finding.TimeContext)
Evidence:      $($finding.Evidence)
Next step:     $($finding.Recommendation)

"@ | Out-File $reportPath -Encoding UTF8 -Append
    }

@"
Files for manual review:
- 00_Quick_Summary.txt
- 00_Report.html
- 01_Events\System_Targeted_Stability_Storage_Network_${DaysBack}d.csv
- 01_Events\System_Targeted_TopEvents_${DaysBack}d.csv
- 99_Runtime\runtime.log
- 99_Runtime\errors.txt and timeouts.txt, if present
"@ | Out-File $reportPath -Encoding UTF8 -Append

    return $findings
}

function Write-HtmlReport {
    $htmlPath = Join-Path $Dirs.Root "00_Report.html"
    $findings = Read-CsvSafe (Join-Path $Dirs.Runtime "Findings.csv")
    $analysisStatus = Get-AnalysisStatus $findings
    $disks = Read-CsvSafe (Join-Path $Dirs.Storage "Disks.csv")
    $volumes = Read-CsvSafe (Join-Path $Dirs.Storage "Volumes.csv")
    $netAdapters = Read-CsvSafe (Join-Path $Dirs.Network "NetAdapters.csv")
    $topSystem = Read-CsvSafe (Join-Path $Dirs.Events "System_TopEvents_${DaysBack}d.csv")
    $targetedTop = Read-CsvSafe (Join-Path $Dirs.Events "System_Targeted_TopEvents_${DaysBack}d.csv")
    $dumps = Read-CsvSafe (Join-Path $Dirs.Dumps "DumpFiles.csv")

    $osText = ""
    $overviewPath = Join-Path $Dirs.System "System_Overview.txt"
    if (Test-Path -LiteralPath $overviewPath) {
        $osText = (Get-Content -LiteralPath $overviewPath -ErrorAction SilentlyContinue | Select-Object -First 40) -join "`r`n"
    }

    $findingsHtml = New-HtmlTable $findings @("Severity","Category","Title","TimeContext","Evidence","Recommendation") 50
    $diskHtml = New-HtmlTable $disks @("Number","FriendlyName","HealthStatus","OperationalStatus","BusType","SizeGB") 20
    $volumeHtml = New-HtmlTable $volumes @("DriveLetter","FileSystemLabel","FileSystem","HealthStatus","OperationalStatus","SizeGB","FreeGB","FreePercent") 30
    $netHtml = New-HtmlTable $netAdapters @("Name","InterfaceDescription","Status","LinkSpeed","DriverVersion","DriverDate") 30
    $topHtml = New-HtmlTable $topSystem @("Count","Name") 25
    $targetedHtml = New-HtmlTable $targetedTop @("Count","Name") 25
    $dumpHtml = New-HtmlTable $dumps @("Type","Path","SizeMB","LastWriteTime") 10

@"
<!doctype html>
<html lang="de">
<head>
  <meta charset="utf-8">
  <title>ServerDiagLite Report</title>
  <style>
    :root { color-scheme: light; --ink:#17202a; --muted:#5d6978; --line:#d8dde6; --soft:#f3f6fa; --accent:#0f766e; --warn:#a16207; --bad:#b42318; }
    body { margin:0; font-family: Segoe UI, Arial, sans-serif; color:var(--ink); background:#ffffff; }
    header { padding:28px 34px 18px; border-bottom:1px solid var(--line); background:#f8fafc; }
    main { padding:24px 34px 40px; max-width:1360px; }
    h1 { margin:0 0 8px; font-size:26px; font-weight:650; letter-spacing:0; }
    h2 { margin:30px 0 10px; font-size:18px; }
    p { line-height:1.45; }
    .meta { color:var(--muted); font-size:13px; }
    .grid { display:grid; grid-template-columns:repeat(auto-fit,minmax(260px,1fr)); gap:14px; margin-top:16px; }
    .stat { border:1px solid var(--line); border-radius:8px; padding:14px; background:#fff; }
    .label { font-size:12px; color:var(--muted); text-transform:uppercase; letter-spacing:.04em; }
    .value { margin-top:6px; font-size:18px; font-weight:650; }
    .summary { margin:18px 0 6px; padding:12px 14px; border-left:4px solid var(--accent); background:#f8fafc; }
    table { border-collapse:collapse; width:100%; font-size:12px; table-layout:auto; }
    th, td { border:1px solid var(--line); padding:7px 8px; vertical-align:top; text-align:left; overflow-wrap:anywhere; }
    th { background:var(--soft); font-weight:650; }
    pre { white-space:pre-wrap; overflow-wrap:anywhere; background:#0f172a; color:#e5e7eb; padding:14px; border-radius:8px; font-size:12px; }
    .muted { color:var(--muted); }
  </style>
</head>
<body>
  <header>
    <h1>ServerDiagLite Report</h1>
    <div class="meta">$ToolVersion | Created: $(Escape-Html (Format-FindingDate (Get-Date))) | Event range: last $DaysBack days | PrivacyMode: $([bool]$PrivacyMode)</div>
    <div class="grid">
      <div class="stat"><div class="label">Computer</div><div class="value">$(Escape-Html $env:COMPUTERNAME)</div></div>
      <div class="stat"><div class="label">Overall Status</div><div class="value">$(Escape-Html $analysisStatus.Label)</div></div>
      <div class="stat"><div class="label">Findings</div><div class="value">$($findings.Count)</div></div>
      <div class="stat"><div class="label">Disks</div><div class="value">$($disks.Count)</div></div>
      <div class="stat"><div class="label">Network Adapters</div><div class="value">$($netAdapters.Count)</div></div>
    </div>
  </header>
  <main>
    <h2>Local Assessment</h2>
    <div class="summary">
      <p><strong>Overall status:</strong> $(Escape-Html $analysisStatus.Label)</p>
      <p><strong>Summary:</strong> $(Escape-Html $analysisStatus.Text)</p>
      <p><strong>Findings:</strong> $(Escape-Html (Get-FindingCountsText $findings))</p>
      <p><strong>Primary areas:</strong> $(Escape-Html (Get-PrimaryCategoriesText $findings))</p>
    </div>
    $findingsHtml
    <h2>System</h2>
    <pre>$(Escape-Html $osText)</pre>
    <h2>Disks</h2>
    $diskHtml
    <h2>Volumes</h2>
    $volumeHtml
    <h2>Network Adapters</h2>
    $netHtml
    <h2>Top System Events</h2>
    $topHtml
    <h2>Targeted Stability / Storage / Network Events</h2>
    $targetedHtml
    <h2>Dumps</h2>
    $dumpHtml
  </main>
</body>
</html>
"@ | Out-File $htmlPath -Encoding UTF8
}

function Write-ResultWindowReport {
    param(
        [string]$OutputPath = (Join-Path $Dirs.Root "00_Result.html"),
        [string]$PackagePath = ""
    )

    $findings = Read-CsvSafe (Join-Path $Dirs.Runtime "Findings.csv")
    $sortedFindings = @(Get-SortedFindings $findings)
    $analysisStatus = Get-AnalysisStatus $sortedFindings
    $statusClass = Get-StatusCssClass $analysisStatus.Label
    $findingCardsHtml = New-FindingCardsHtml -Findings $sortedFindings -MaxRows 6
    $allFindingsHtml = New-HtmlTable $sortedFindings @("Severity","Category","Title","TimeContext","Evidence","Recommendation") 80
    $packageDisplay = if ([string]::IsNullOrWhiteSpace($PackagePath)) { "Will be created after completion." } else { $PackagePath }
    $reportPath = "00_Report.html"
    $textReportPath = "00_Findings_Summary.txt"

@"
<!doctype html>
<html lang="de">
<head>
  <meta charset="utf-8">
  <title>ServerDiagLite Result</title>
  <style>
    :root { color-scheme: light; --ink:#17202a; --muted:#607083; --line:#d7dee8; --soft:#f5f7fa; --ok:#0f766e; --warn:#a16207; --high:#b45309; --bad:#b42318; --info:#475569; }
    * { box-sizing:border-box; }
    body { margin:0; font-family: Segoe UI, Arial, sans-serif; color:var(--ink); background:#ffffff; }
    header { padding:30px 34px 22px; border-bottom:1px solid var(--line); background:#f8fafc; }
    main { padding:24px 34px 42px; max-width:1180px; }
    h1 { margin:0 0 8px; font-size:28px; font-weight:700; letter-spacing:0; }
    h2 { margin:30px 0 12px; font-size:19px; }
    h3 { margin:8px 0 9px; font-size:16px; }
    p { line-height:1.45; margin:7px 0; }
    table { border-collapse:collapse; width:100%; font-size:12px; table-layout:auto; }
    th, td { border:1px solid var(--line); padding:7px 8px; text-align:left; vertical-align:top; overflow-wrap:anywhere; }
    th { background:var(--soft); font-weight:650; }
    .meta { color:var(--muted); font-size:13px; }
    .status { margin-top:18px; padding:16px 18px; border-radius:8px; border:1px solid var(--line); background:#fff; border-left-width:6px; }
    .status-critical { border-left-color:var(--bad); }
    .status-high { border-left-color:var(--high); }
    .status-medium { border-left-color:var(--warn); }
    .status-ok { border-left-color:var(--ok); }
    .status-neutral { border-left-color:var(--info); }
    .status-label { font-size:12px; color:var(--muted); text-transform:uppercase; letter-spacing:.04em; }
    .status-value { margin-top:4px; font-size:25px; font-weight:750; }
    .summary-grid { display:grid; grid-template-columns:repeat(auto-fit,minmax(220px,1fr)); gap:12px; margin-top:16px; }
    .summary-item { border:1px solid var(--line); border-radius:8px; padding:12px 13px; background:#fff; }
    .summary-item .label { color:var(--muted); font-size:12px; text-transform:uppercase; letter-spacing:.04em; }
    .summary-item .value { margin-top:5px; font-size:16px; font-weight:650; }
    .finding-list { display:grid; gap:12px; }
    .finding { border:1px solid var(--line); border-radius:8px; padding:14px 15px; background:#fff; border-left-width:5px; }
    .sev-critical { border-left-color:var(--bad); }
    .sev-high { border-left-color:var(--high); }
    .sev-medium { border-left-color:var(--warn); }
    .sev-info { border-left-color:var(--info); }
    .finding-head { display:flex; align-items:center; gap:8px; flex-wrap:wrap; }
    .badge { display:inline-block; min-width:72px; text-align:center; border-radius:999px; padding:3px 9px; background:#eef2f7; font-size:12px; font-weight:650; }
    .category { color:var(--muted); font-size:13px; }
    .paths { border:1px solid var(--line); border-radius:8px; padding:12px 13px; background:#f8fafc; overflow-wrap:anywhere; }
    .muted { color:var(--muted); }
  </style>
</head>
<body>
  <header>
    <h1>ServerDiagLite Result</h1>
    <div class="meta">$ToolVersion | Created: $(Escape-Html (Format-FindingDate (Get-Date))) | Computer: $(Escape-Html $env:COMPUTERNAME) | Event range: last $DaysBack days</div>
    <section class="status $statusClass">
      <div class="status-label">Overall status</div>
      <div class="status-value">$(Escape-Html $analysisStatus.Label)</div>
      <p>$(Escape-Html $analysisStatus.Text)</p>
    </section>
    <div class="summary-grid">
      <div class="summary-item"><div class="label">Findings</div><div class="value">$(Escape-Html (Get-FindingCountsText $sortedFindings))</div></div>
      <div class="summary-item"><div class="label">Primary areas</div><div class="value">$(Escape-Html (Get-PrimaryCategoriesText $sortedFindings))</div></div>
      <div class="summary-item"><div class="label">Privacy mode</div><div class="value">$([bool]$PrivacyMode)</div></div>
    </div>
  </header>
  <main>
    <h2>Most Important Findings and Next Steps</h2>
    $findingCardsHtml

    <h2>All Findings</h2>
    $allFindingsHtml

    <h2>Files</h2>
    <div class="paths">
      <p><strong>ZIP package:</strong> $(Escape-Html $packageDisplay)</p>
      <p><strong>Detailed report inside the package:</strong> $(Escape-Html $reportPath)</p>
      <p><strong>Text findings summary inside the package:</strong> $(Escape-Html $textReportPath)</p>
    </div>
  </main>
</body>
</html>
"@ | Out-File $OutputPath -Encoding UTF8

    return $OutputPath
}

function Write-Manifest {
    param([Parameter(Mandatory=$true)][datetime]$RunEnded)

    $manifestPath = Join-Path $Dirs.Root "manifest.json"
    $files = Get-ChildItem -LiteralPath $Out -Recurse -File -ErrorAction SilentlyContinue |
        Where-Object { $_.FullName -ne $manifestPath } |
        Sort-Object FullName |
        ForEach-Object {
            $relative = $_.FullName.Substring($Out.Length).TrimStart('\','/')
            [PSCustomObject]@{
                Path = $relative
                SizeBytes = $_.Length
                LastWriteTime = $_.LastWriteTime
            }
        }

    [PSCustomObject][ordered]@{
        ToolName = $ToolName
        ToolVersion = $ToolVersion
        RunStarted = $RunStarted
        RunEnded = $RunEnded
        DurationSeconds = [math]::Round(($RunEnded - $RunStarted).TotalSeconds, 1)
        ComputerName = $env:COMPUTERNAME
        UserName = $env:USERNAME
        DaysBack = $DaysBack
        MaxEvents = $MaxEvents
        EventTimeoutSeconds = $EventTimeoutSeconds
        StepTimeoutSeconds = $StepTimeoutSeconds
        PrivacyMode = [bool]$PrivacyMode
        OutputFolderName = Split-Path -Path $Out -Leaf
        FileCount = @($files).Count
        Files = @($files)
    } | ConvertTo-Json -Depth 6 | Out-File $manifestPath -Encoding UTF8
}

function Get-RedactionTokens {
    $tokens = @()

    foreach ($value in @($env:COMPUTERNAME, $env:USERNAME, $env:USERDOMAIN, $env:USERPROFILE)) {
        if (-not [string]::IsNullOrWhiteSpace($value)) { $tokens += [string]$value }
    }

    $sensitiveColumns = 'Serial|DeviceID|PNP|PhysicalAddress|MacAddress|UniqueId|ObjectId|Guid|Path|User|ComputerName|CsName'
    foreach ($file in Get-ChildItem -LiteralPath $Out -Recurse -Filter *.csv -File -ErrorAction SilentlyContinue) {
        try {
            foreach ($row in @(Import-Csv -LiteralPath $file.FullName -ErrorAction Stop)) {
                foreach ($prop in $row.PSObject.Properties) {
                    if ($prop.Name -match $sensitiveColumns) {
                        $value = [string]$prop.Value
                        if (-not [string]::IsNullOrWhiteSpace($value) -and $value.Length -gt 2) {
                            $tokens += $value
                        }
                    }
                }
            }
        } catch {}
    }

    $unique = @{}
    foreach ($token in $tokens) {
        $t = ([string]$token).Trim()
        if ($t.Length -gt 2 -and -not $unique.ContainsKey($t)) {
            $unique[$t] = $true
        }
    }

    return @($unique.Keys | Sort-Object Length -Descending)
}

function Protect-TextValue {
    param(
        [AllowNull()][string]$Text,
        [string[]]$Tokens
    )

    if ($null -eq $Text) { return $null }

    $value = [string]$Text
    foreach ($token in $Tokens) {
        if (-not [string]::IsNullOrWhiteSpace($token)) {
            $value = $value -replace [regex]::Escape($token), "<REDACTED>"
        }
    }

    $value = $value -replace '(?<!\d)(?:25[0-5]|2[0-4]\d|1?\d?\d)(?:\.(?:25[0-5]|2[0-4]\d|1?\d?\d)){3}(?!\d)', '<IPv4>'
    $value = $value -replace '\b(?:[0-9A-Fa-f]{2}[:-]){5}[0-9A-Fa-f]{2}\b', '<MAC>'
    $value = $value -replace '\b(?:[0-9A-Fa-f]{1,4}:){2,7}[0-9A-Fa-f]{1,4}\b', '<IPv6>'
    $value = $value -replace 'C:\\Users\\[^\\\r\n"]+', 'C:\Users\<USER>'

    return $value
}

function Invoke-PrivacyScrub {
    if (-not $PrivacyMode) { return }

    Write-ProgressLine "Privacy mode active: masking typical sensitive values before ZIP creation..." "Cyan"

    $tokens = @(Get-RedactionTokens)
    $sensitiveColumns = 'Serial|DeviceID|PNP|PhysicalAddress|MacAddress|UniqueId|ObjectId|Guid|Path|User|ComputerName|CsName|IPAddress|IP|Dns'

    foreach ($file in Get-ChildItem -LiteralPath $Out -Recurse -Filter *.csv -File -ErrorAction SilentlyContinue) {
        try {
            $rows = @(Import-Csv -LiteralPath $file.FullName -ErrorAction Stop)
            if ($rows.Count -eq 0) { continue }

            foreach ($row in $rows) {
                foreach ($prop in $row.PSObject.Properties) {
                    if ($prop.Name -match $sensitiveColumns -and -not [string]::IsNullOrWhiteSpace([string]$prop.Value)) {
                        $prop.Value = "<REDACTED_$($prop.Name)>"
                    } else {
                        $prop.Value = Protect-TextValue ([string]$prop.Value) $tokens
                    }
                }
            }

            $rows | Export-Csv -LiteralPath $file.FullName -NoTypeInformation -Encoding UTF8
        } catch {
            "Privacy CSV scrub failed: $($file.FullName) - $($_.Exception.Message)" |
                Out-File (Join-Path $Dirs.Runtime "privacy_errors.txt") -Encoding UTF8 -Append
        }
    }

    $textExtensions = @(".txt",".log",".json",".html",".ps1")
    foreach ($file in Get-ChildItem -LiteralPath $Out -Recurse -File -ErrorAction SilentlyContinue | Where-Object { $textExtensions -contains $_.Extension.ToLowerInvariant() }) {
        try {
            $content = [System.IO.File]::ReadAllText($file.FullName, [System.Text.Encoding]::UTF8)
            $content = Protect-TextValue $content $tokens
            [System.IO.File]::WriteAllText($file.FullName, $content, [System.Text.UTF8Encoding]::new($true))
        } catch {
            "Privacy text scrub failed: $($file.FullName) - $($_.Exception.Message)" |
                Out-File (Join-Path $Dirs.Runtime "privacy_errors.txt") -Encoding UTF8 -Append
        }
    }

@"
PrivacyMode was active.
Typical IP addresses, MAC addresses, computer names, user names, paths, serial numbers, and device IDs were masked.
Please still review manually before public sharing.
"@ | Out-File (Join-Path $Dirs.Runtime "privacy_mode.txt") -Encoding UTF8
}

# ==================================================================================================
# Section 3: Operating system, uptime, and basic hardware data
# ==================================================================================================
# Why:
# For freezes and crashes, Windows build, last boot, BIOS version, board, CPU, and RAM are important.

$SystemInventoryScript = New-ChildScript @'
$os = Get-CimInstance Win32_OperatingSystem
$cs = Get-CimInstance Win32_ComputerSystem
$bios = Get-CimInstance Win32_BIOS
$bb = Get-CimInstance Win32_BaseBoard
$cpu = Get-CimInstance Win32_Processor | Select-Object -First 1
$uptime = (Get-Date) - $os.LastBootUpTime

[PSCustomObject]@{
    ComputerName   = $env:COMPUTERNAME
    Windows        = $os.Caption
    Version        = $os.Version
    BuildNumber    = $os.BuildNumber
    Architecture   = $os.OSArchitecture
    InstallDate    = $os.InstallDate
    LastBootUpTime = $os.LastBootUpTime
    UptimeDays     = [math]::Round($uptime.TotalDays, 2)
    Manufacturer   = $cs.Manufacturer
    Model          = $cs.Model
    Mainboard      = "$($bb.Manufacturer) $($bb.Product)"
    BiosVersion    = $bios.SMBIOSBIOSVersion
    BiosDate       = $bios.ReleaseDate
    CPU            = $cpu.Name
    TotalRAM_GB    = [math]::Round($cs.TotalPhysicalMemory / 1GB, 2)
} | Format-List | Out-File (Join-Path $Dirs.System "System_Overview.txt") -Encoding UTF8

Get-CimInstance Win32_PhysicalMemory |
    Select-Object BankLabel, DeviceLocator, Manufacturer, PartNumber,
                  @{Name="CapacityGB";Expression={[math]::Round($_.Capacity / 1GB, 2)}},
                  Speed, ConfiguredClockSpeed |
    Export-Csv (Join-Path $Dirs.System "RAM_Modules.csv") -NoTypeInformation -Encoding UTF8

Get-ComputerInfo |
    Select-Object CsName, WindowsProductName, WindowsVersion, OsBuildNumber, OsArchitecture,
                  BiosFirmwareType, CsManufacturer, CsModel, CsProcessors, CsTotalPhysicalMemory |
    Format-List |
    Out-File (Join-Path $Dirs.System "ComputerInfo_Short.txt") -Encoding UTF8
'@

Invoke-ChildPowerShellWithTimeout -Name "OS, uptime, and basic hardware inventory" -ScriptContent $SystemInventoryScript -TimeoutSeconds $StepTimeoutSeconds | Out-Null

# ==================================================================================================
# Section 4: Storage / disks
# ==================================================================================================
# Why:
# Storage errors are a common cause of headless-server hangs.
# The key question is which disk number belongs to which physical drive and drive letter.

$StorageInventoryScript = New-ChildScript @'
Get-Disk |
    Select-Object Number, FriendlyName, SerialNumber, FirmwareVersion, HealthStatus,
                  OperationalStatus, PartitionStyle, BusType,
                  @{Name="SizeGB";Expression={[math]::Round($_.Size / 1GB, 2)}} |
    Export-Csv (Join-Path $Dirs.Storage "Disks.csv") -NoTypeInformation -Encoding UTF8

Get-PhysicalDisk |
    Select-Object FriendlyName, SerialNumber, MediaType, BusType, HealthStatus,
                  OperationalStatus, Usage,
                  @{Name="SizeGB";Expression={[math]::Round($_.Size / 1GB, 2)}} |
    Export-Csv (Join-Path $Dirs.Storage "PhysicalDisks.csv") -NoTypeInformation -Encoding UTF8

Get-Volume |
    Select-Object DriveLetter, FileSystemLabel, FileSystem, HealthStatus, OperationalStatus,
                  @{Name="SizeGB";Expression={if ($_.Size) {[math]::Round($_.Size / 1GB, 2)} else {$null}}},
                  @{Name="FreeGB";Expression={if ($_.SizeRemaining) {[math]::Round($_.SizeRemaining / 1GB, 2)} else {$null}}},
                  @{Name="FreePercent";Expression={if ($_.Size -gt 0) {[math]::Round(($_.SizeRemaining / $_.Size) * 100, 2)} else {$null}}} |
    Export-Csv (Join-Path $Dirs.Storage "Volumes.csv") -NoTypeInformation -Encoding UTF8

Get-Partition |
    Select-Object DiskNumber, PartitionNumber, DriveLetter, Type, GptType,
                  @{Name="SizeGB";Expression={[math]::Round($_.Size / 1GB, 2)}} |
    Export-Csv (Join-Path $Dirs.Storage "Partitions.csv") -NoTypeInformation -Encoding UTF8

Get-CimInstance Win32_DiskDrive |
    Select-Object Index, Model, SerialNumber, FirmwareRevision, InterfaceType, MediaType,
                  Status, PNPDeviceID,
                  @{Name="SizeGB";Expression={[math]::Round($_.Size / 1GB, 2)}} |
    Export-Csv (Join-Path $Dirs.Storage "DiskDrive_WMI.csv") -NoTypeInformation -Encoding UTF8

Get-CimInstance Win32_DiskDrive | ForEach-Object {
    $disk = $_
    $partitions = Get-CimAssociatedInstance -InputObject $disk -Association Win32_DiskDriveToDiskPartition -ErrorAction SilentlyContinue
    foreach ($partition in $partitions) {
        $logicalDisks = Get-CimAssociatedInstance -InputObject $partition -Association Win32_LogicalDiskToPartition -ErrorAction SilentlyContinue
        foreach ($logicalDisk in $logicalDisks) {
            [PSCustomObject]@{
                DiskIndex     = $disk.Index
                DiskModel     = $disk.Model
                SerialNumber  = $disk.SerialNumber
                InterfaceType = $disk.InterfaceType
                Partition     = $partition.DeviceID
                DriveLetter   = $logicalDisk.DeviceID
                VolumeName    = $logicalDisk.VolumeName
                FileSystem    = $logicalDisk.FileSystem
            }
        }
    }
} | Export-Csv (Join-Path $Dirs.Storage "Disk_To_DriveLetter_Mapping.csv") -NoTypeInformation -Encoding UTF8
'@

Invoke-ChildPowerShellWithTimeout -Name "Storage and drive mapping" -ScriptContent $StorageInventoryScript -TimeoutSeconds $StepTimeoutSeconds | Out-Null

# StorageReliabilityCounter runs in a child process with a timeout because storage providers can hang.
$StorageReliabilityScript = @"
`$ErrorActionPreference = 'Continue'
`$outFile = '$($Dirs.Storage.Replace("'","''"))\StorageReliabilityCounter.csv'
`$result = foreach (`$pd in Get-PhysicalDisk) {
    try {
        Get-StorageReliabilityCounter -PhysicalDisk `$pd -ErrorAction Stop |
            Select-Object @{Name='FriendlyName';Expression={`$pd.FriendlyName}},
                          @{Name='SerialNumber';Expression={`$pd.SerialNumber}},
                          *
    } catch {
        [PSCustomObject]@{
            FriendlyName = `$pd.FriendlyName
            SerialNumber = `$pd.SerialNumber
            Error = `$_.Exception.Message
        }
    }
}
`$result | Export-Csv `$outFile -NoTypeInformation -Encoding UTF8
"@

Invoke-ChildPowerShellWithTimeout -Name "Storage Reliability Counter" -ScriptContent $StorageReliabilityScript -TimeoutSeconds 45 | Out-Null

# ==================================================================================================
# Section 5: Network
# ==================================================================================================
# Why:
# If a headless server is unreachable, Windows may still be running while the NIC is stuck.
# Therefore we collect driver version, link speed, IPs, offload settings, and power saving options.

$NetworkInventoryScript = New-ChildScript @'
Get-NetAdapter |
    Select-Object Name, InterfaceDescription, Status, LinkSpeed, MacAddress,
                  DriverInformation, DriverFileName, DriverVersion, DriverDate, PnPDeviceID |
    Export-Csv (Join-Path $Dirs.Network "NetAdapters.csv") -NoTypeInformation -Encoding UTF8

Get-NetAdapterPowerManagement -ErrorAction SilentlyContinue |
    Export-Csv (Join-Path $Dirs.Network "NetAdapterPowerManagement.csv") -NoTypeInformation -Encoding UTF8

Get-NetAdapterAdvancedProperty -ErrorAction SilentlyContinue |
    Select-Object Name, DisplayName, DisplayValue, RegistryKeyword, RegistryValue |
    Export-Csv (Join-Path $Dirs.Network "NetAdapterAdvancedProperties.csv") -NoTypeInformation -Encoding UTF8

Get-NetIPConfiguration |
    Format-List * |
    Out-File (Join-Path $Dirs.Network "NetIPConfiguration.txt") -Encoding UTF8

Get-NetIPAddress |
    Export-Csv (Join-Path $Dirs.Network "NetIPAddress.csv") -NoTypeInformation -Encoding UTF8

Get-DnsClientServerAddress |
    Export-Csv (Join-Path $Dirs.Network "DnsClientServerAddress.csv") -NoTypeInformation -Encoding UTF8
'@

Invoke-ChildPowerShellWithTimeout -Name "Network adapters, IPs, and NIC settings" -ScriptContent $NetworkInventoryScript -TimeoutSeconds $StepTimeoutSeconds | Out-Null

Invoke-ExternalWithTimeout -Name "ipconfig /all" -Command "ipconfig /all" -OutputFile (Join-Path $Dirs.Network "ipconfig_all.txt") -TimeoutSeconds 20

# ==================================================================================================
# Section 6: Power, sleep, wake
# ==================================================================================================
# Why:
# For a headless server, standby, hibernate, wake timers, and device wake state are relevant.
# Each powercfg command gets its own timeout so nothing can block the full run.

Invoke-ExternalWithTimeout -Name "powercfg available sleepstates" -Command "powercfg /a" -OutputFile (Join-Path $Dirs.Power "powercfg_available_sleepstates.txt") -TimeoutSeconds 20
Invoke-ExternalWithTimeout -Name "powercfg active scheme" -Command "powercfg /getactivescheme" -OutputFile (Join-Path $Dirs.Power "powercfg_active_scheme.txt") -TimeoutSeconds 20
Invoke-ExternalWithTimeout -Name "powercfg requests" -Command "powercfg /requests" -OutputFile (Join-Path $Dirs.Power "powercfg_requests.txt") -TimeoutSeconds 20
Invoke-ExternalWithTimeout -Name "powercfg lastwake" -Command "powercfg /lastwake" -OutputFile (Join-Path $Dirs.Power "powercfg_lastwake.txt") -TimeoutSeconds 20
Invoke-ExternalWithTimeout -Name "powercfg waketimers" -Command "powercfg /waketimers" -OutputFile (Join-Path $Dirs.Power "powercfg_waketimers.txt") -TimeoutSeconds 20
Invoke-ExternalWithTimeout -Name "powercfg wake armed devices" -Command "powercfg /devicequery wake_armed" -OutputFile (Join-Path $Dirs.Power "powercfg_wake_armed_devices.txt") -TimeoutSeconds 20

# ==================================================================================================
# Section 7: Relevant drivers instead of a full driver list
# ==================================================================================================
# Why:
# For this failure pattern, network, storage, disk, and system drivers are most relevant.
# A full driver list would make the package larger and harder to read.

$DriverInventoryScript = New-ChildScript @'
$wantedClasses = @("Net", "SCSIAdapter", "HDC", "DiskDrive", "Storage", "System")

Get-CimInstance Win32_PnPSignedDriver |
    Where-Object { $wantedClasses -contains $_.DeviceClass } |
    Select-Object DeviceName, DeviceClass, Manufacturer, DriverVersion, DriverDate, InfName, DeviceID |
    Export-Csv (Join-Path $Dirs.System "Relevant_Drivers_Network_Storage_System.csv") -NoTypeInformation -Encoding UTF8

Get-HotFix |
    Sort-Object InstalledOn -Descending |
    Select-Object -First 40 |
    Export-Csv (Join-Path $Dirs.System "Recent_Hotfixes_Last40.csv") -NoTypeInformation -Encoding UTF8
'@

Invoke-ChildPowerShellWithTimeout -Name "Relevant driver classes and updates" -ScriptContent $DriverInventoryScript -TimeoutSeconds $StepTimeoutSeconds | Out-Null

# ==================================================================================================
# Section 8: Event logs with timeout and limits
# ==================================================================================================
# Why:
# Event logs are the part that can take a long time or hang on some systems.
# Therefore this part runs separately with a timeout.
#
# This version does NOT export full EVTX files.
# Instead it creates CSV/TXT files:
# - System/Application critical/error/warning events
# - Top-Events
# - targeted stability/storage/network events
# This is usually better and much smaller for an initial analysis.

$EventScript = @"
`$ErrorActionPreference = 'Continue'
`$DaysBack = $DaysBack
`$MaxEvents = $MaxEvents
`$EventsDir = '$($Dirs.Events.Replace("'","''"))'
`$StartTime = (Get-Date).AddDays(-`$DaysBack)

function Get-EventLevelName {
    param([Parameter(Mandatory=`$true)]`$Event)
    try {
        `$name = `$Event.LevelDisplayName
        if ([string]::IsNullOrWhiteSpace(`$name)) { return "Level_`$(`$Event.Level)" }
        return `$name
    } catch {
        return "Level_`$(`$Event.Level)"
    }
}

function Select-EventForCsv {
    param([Parameter(ValueFromPipeline=`$true)]`$Event)
    process {
        [PSCustomObject]@{
            TimeCreated = `$Event.TimeCreated
            LogName = `$Event.LogName
            Level = `$Event.Level
            LevelDisplayName = Get-EventLevelName `$Event
            ProviderName = `$Event.ProviderName
            Id = `$Event.Id
            Message = try { `$Event.Message } catch { "" }
        }
    }
}

foreach (`$log in @('System','Application')) {
    `$safe = `$log -replace '[\\/:*?"<>|]', '_'

    `$events = Get-WinEvent -FilterHashtable @{
        LogName = `$log
        Level = 1,2,3
        StartTime = `$StartTime
    } -MaxEvents `$MaxEvents -ErrorAction SilentlyContinue

    `$events |
        Select-EventForCsv |
        Export-Csv (Join-Path `$EventsDir "`${safe}_WARN_ERR_CRIT_`$(`$DaysBack)d.csv") -NoTypeInformation -Encoding UTF8

    `$events |
        Group-Object ProviderName, Id, Level |
        Sort-Object Count -Descending |
        Select-Object Count, Name |
        Export-Csv (Join-Path `$EventsDir "`${safe}_TopEvents_`$(`$DaysBack)d.csv") -NoTypeInformation -Encoding UTF8
}

`$rawSystem = Get-WinEvent -FilterHashtable @{
    LogName = 'System'
    StartTime = `$StartTime
} -MaxEvents 7000 -ErrorAction SilentlyContinue

`$targeted = `$rawSystem | Where-Object {
    (
        `$_.ProviderName -match 'Kernel-Power|EventLog|BugCheck|volmgr|WHEA-Logger|disk|Ntfs|storahci|stornvme|iaStor|e1|e2f|e2fnexpress|NDIS|Tcpip|Dhcp|DNS Client Events|Netwtw|Service Control Manager|Power-Troubleshooter|Kernel-General|Kernel-Boot'
    ) -or
    (
        `$_.Id -in 1,12,13,27,41,42,51,55,98,129,153,154,157,161,162,5007,6005,6006,6008,7000,7001,7009,7011,7022,7023,7024,7031,7032,7034,1001
    )
} | Select-Object -First `$MaxEvents

`$targeted |
    Select-EventForCsv |
    Export-Csv (Join-Path `$EventsDir "System_Targeted_Stability_Storage_Network_`$(`$DaysBack)d.csv") -NoTypeInformation -Encoding UTF8

`$targeted |
    Group-Object ProviderName, Id, Level |
    Sort-Object Count -Descending |
    Select-Object Count, Name |
    Export-Csv (Join-Path `$EventsDir "System_Targeted_TopEvents_`$(`$DaysBack)d.csv") -NoTypeInformation -Encoding UTF8

`$targeted |
    Select-Object -First 200 TimeCreated, Level, ProviderName, Id |
    Format-Table -AutoSize |
    Out-String -Width 300 |
    Out-File (Join-Path `$EventsDir "System_Targeted_Last200.txt") -Encoding UTF8
"@

Invoke-ChildPowerShellWithTimeout -Name "Event log analysis System Application Targeted" -ScriptContent $EventScript -TimeoutSeconds $EventTimeoutSeconds | Out-Null

# ==================================================================================================
# Section 9: Minidumps, but no huge MEMORY.DMP
# ==================================================================================================
# Why:
# Small minidumps are very useful for blue screens.
# MEMORY.DMP can be several GB in size and is listed only, not copied.

Invoke-Step "Collect minidumps and list large dumps only" {
    $dumpList = @()

    if (Test-Path "C:\Windows\Minidump") {
        $mini = Get-ChildItem "C:\Windows\Minidump\*.dmp" -ErrorAction SilentlyContinue |
            Sort-Object LastWriteTime -Descending |
            Select-Object -First 5

        foreach ($d in $mini) {
            Copy-Item $d.FullName $Dirs.Dumps -ErrorAction SilentlyContinue
            $dumpList += [PSCustomObject]@{
                Type = "Minidump copied"
                Path = $d.FullName
                SizeMB = [math]::Round($d.Length / 1MB, 2)
                LastWriteTime = $d.LastWriteTime
            }
        }
    }

    if (Test-Path "C:\Windows\MEMORY.DMP") {
        $mem = Get-Item "C:\Windows\MEMORY.DMP"
        $dumpList += [PSCustomObject]@{
            Type = "MEMORY.DMP not copied"
            Path = $mem.FullName
            SizeMB = [math]::Round($mem.Length / 1MB, 2)
            LastWriteTime = $mem.LastWriteTime
        }
    }

    $dumpList | Export-Csv (Join-Path $Dirs.Dumps "DumpFiles.csv") -NoTypeInformation -Encoding UTF8

    Get-ItemProperty "HKLM:\SYSTEM\CurrentControlSet\Control\CrashControl" -ErrorAction SilentlyContinue |
        Select-Object CrashDumpEnabled, AlwaysKeepMemoryDump, AutoReboot, DumpFile, MinidumpDir, LogEvent |
        Format-List |
        Out-File (Join-Path $Dirs.Dumps "CrashControl_Settings.txt") -Encoding UTF8
}

# ==================================================================================================
# Section 10: Quick summary
# ==================================================================================================
# Why:
# This file shows the most important facts and top events without opening CSV files first.

$SummaryScript = New-ChildScript @'
$summaryPath = Join-Path $Dirs.Root "00_Quick_Summary.txt"

$os = Get-CimInstance Win32_OperatingSystem
$cs = Get-CimInstance Win32_ComputerSystem
$bios = Get-CimInstance Win32_BIOS
$bb = Get-CimInstance Win32_BaseBoard
$cpu = Get-CimInstance Win32_Processor | Select-Object -First 1
$uptime = (Get-Date) - $os.LastBootUpTime

@"
Quick Summary
=============

Computer:       $env:COMPUTERNAME
Windows:        $($os.Caption) $($os.Version) Build $($os.BuildNumber)
Last boot:      $($os.LastBootUpTime)
Uptime:         $([math]::Round($uptime.TotalDays,2)) days
Manufacturer:   $($cs.Manufacturer)
Model:          $($cs.Model)
Mainboard:      $($bb.Manufacturer) $($bb.Product)
BIOS:           $($bios.SMBIOSBIOSVersion) from $($bios.ReleaseDate)
CPU:            $($cpu.Name)
Total RAM:      $([math]::Round($cs.TotalPhysicalMemory / 1GB,2)) GB

Package type:   $ToolVersion
Event range:    last $DaysBack days
MaxEvents:      $MaxEvents

This package contains only the most important data:
- local findings summary
- result window, HTML report, and manifest
- System/Application errors and warnings as CSV
- targeted stability, storage, and network events
- hardware, storage, network, and power information
- minidumps, if present

"@ | Out-File $summaryPath -Encoding UTF8

"`r`nDisks:`r`n" | Out-File $summaryPath -Encoding UTF8 -Append
Get-Disk |
    Select-Object Number, FriendlyName, SerialNumber, HealthStatus, OperationalStatus, BusType,
                  @{Name="SizeGB";Expression={[math]::Round($_.Size / 1GB, 2)}} |
    Format-Table -AutoSize |
    Out-String -Width 240 |
    Out-File $summaryPath -Encoding UTF8 -Append

"`r`nVolumes:`r`n" | Out-File $summaryPath -Encoding UTF8 -Append
Get-Volume |
    Select-Object DriveLetter, FileSystemLabel, FileSystem, HealthStatus, OperationalStatus,
                  @{Name="SizeGB";Expression={if ($_.Size) {[math]::Round($_.Size / 1GB, 2)} else {$null}}},
                  @{Name="FreeGB";Expression={if ($_.SizeRemaining) {[math]::Round($_.SizeRemaining / 1GB, 2)} else {$null}}} |
    Format-Table -AutoSize |
    Out-String -Width 240 |
    Out-File $summaryPath -Encoding UTF8 -Append

"`r`nNetwork adapters:`r`n" | Out-File $summaryPath -Encoding UTF8 -Append
Get-NetAdapter |
    Select-Object Name, InterfaceDescription, Status, LinkSpeed, DriverVersion, DriverDate |
    Format-Table -AutoSize |
    Out-String -Width 240 |
    Out-File $summaryPath -Encoding UTF8 -Append

$topSystem = Join-Path $Dirs.Events "System_TopEvents_${DaysBack}d.csv"
if (Test-Path $topSystem) {
    "`r`nTop System events, critical/error/warning:`r`n" | Out-File $summaryPath -Encoding UTF8 -Append
    Import-Csv $topSystem |
        Select-Object -First 25 |
        Format-Table -AutoSize |
        Out-String -Width 300 |
        Out-File $summaryPath -Encoding UTF8 -Append
}

$targetedTxt = Join-Path $Dirs.Events "System_Targeted_Last200.txt"
if (Test-Path $targetedTxt) {
    "`r`nLatest targeted stability events:`r`n" | Out-File $summaryPath -Encoding UTF8 -Append
    Get-Content $targetedTxt -ErrorAction SilentlyContinue |
        Select-Object -First 80 |
        Out-File $summaryPath -Encoding UTF8 -Append
}
'@

Invoke-ChildPowerShellWithTimeout -Name "Create quick summary" -ScriptContent $SummaryScript -TimeoutSeconds $StepTimeoutSeconds | Out-Null

# ==================================================================================================
# Section 11: Findings, HTML report, manifest, and optional privacy mode
# ==================================================================================================
# Why:
# From here, the collected raw data is converted into an initial prioritization and readable overview.
# Privacy mode runs at the end before ZIP creation so reports and manifest are masked too.

$script:LatestFindings = @()
Invoke-Step "Create local findings summary" {
    $script:LatestFindings = @(Write-InitialFindingsReport)
}

Invoke-Step "Create HTML report" {
    Write-HtmlReport
}

Invoke-Step "Prepare result window" {
    Write-ResultWindowReport | Out-Null
}

Invoke-Step "Show local analysis result" {
    Show-LocalAnalysisResult -Findings $script:LatestFindings
}

Write-ProgressLine "Finalizing transcript before manifest/ZIP..." "Gray"
try {
    Stop-Transcript | Out-Null
} catch {}

Invoke-Step "Create manifest" {
    Write-Manifest -RunEnded (Get-Date)
}

if ($PrivacyMode) {
    Invoke-Step "Apply privacy mode" {
        Invoke-PrivacyScrub
    }
}

# ==================================================================================================
# Section 12: Create ZIP
# ==================================================================================================
# Why:
# At the end, only one package file should need to be shared.

Write-Host ""
Write-ProgressLine "Creating ZIP file..." "Cyan"

$Zip = "$Out.zip"
$ResultWindowSource = Join-Path $Out "00_Result.html"
$ResultWindow = "${Out}_Result.html"

try {
    if (Test-Path $Zip) {
        Remove-Item $Zip -Force
    }

    Compress-Archive -Path (Join-Path $Out "*") -DestinationPath $Zip -Force

    try {
        if (Test-Path -LiteralPath $ResultWindowSource) {
            Write-ResultWindowReport -OutputPath $ResultWindow -PackagePath $Zip | Out-Null
            if ($PrivacyMode -and (Test-Path -LiteralPath $ResultWindow)) {
                $tokens = @(Get-RedactionTokens)
                $content = [System.IO.File]::ReadAllText($ResultWindow, [System.Text.Encoding]::UTF8)
                $content = Protect-TextValue $content $tokens
                [System.IO.File]::WriteAllText($ResultWindow, $content, [System.Text.UTF8Encoding]::new($true))
            }
        }
    } catch {
        Write-Warning "Result window file could not be created: $($_.Exception.Message)"
    }

    # Delete the working folder after successful ZIP creation.
    try {
        Remove-Item -Path $Out -Recurse -Force -ErrorAction Stop
        Write-Host "Working folder was deleted after successful ZIP creation." -ForegroundColor DarkGray
    } catch {
        Write-Warning "ZIP was created, but the working folder could not be deleted: $($_.Exception.Message)"
    }

    Write-Host ""
    Write-Host "Done." -ForegroundColor Green
    Write-Host "Lightweight diagnostics package:"
    Write-Host $Zip -ForegroundColor Yellow
    Write-Host ""
    Write-Host "This ZIP file is usually enough for the first analysis." -ForegroundColor Cyan
    if (Test-Path -LiteralPath $ResultWindow) {
        Write-Host ""
        Write-Host "Result window:"
        Write-Host $ResultWindow -ForegroundColor Yellow
        try {
            Start-Process -FilePath $ResultWindow
        } catch {
            Write-Warning "Result window could not be opened automatically: $($_.Exception.Message)"
        }
    }
} catch {
    Write-Warning "ZIP could not be created: $($_.Exception.Message)"
    Write-Host "The uncompressed folder is here:"
    Write-Host $Out -ForegroundColor Yellow
    $fallbackResultWindow = Join-Path $Out "00_Result.html"
    if (Test-Path -LiteralPath $fallbackResultWindow) {
        Write-Host "Result window:"
        Write-Host $fallbackResultWindow -ForegroundColor Yellow
        try {
            Start-Process -FilePath $fallbackResultWindow
        } catch {
            Write-Warning "Result window could not be opened automatically: $($_.Exception.Message)"
        }
    }
}
