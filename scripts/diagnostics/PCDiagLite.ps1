<#
.SYNOPSIS
    Creates a small, robust diagnostics package for an unstable Windows desktop PC.

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
    Event range in days. 0 means all available Event Viewer entries.

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
    [int]$DaysBack = 0,
    [string]$OutputRoot = "C:\Temp",
    [int]$MaxEvents = 2000,
    [int]$EventTimeoutSeconds = 180,
    [int]$StepTimeoutSeconds = 90,
    [switch]$PrivacyMode,
    [switch]$AutoInstallDebugTools
)

# ==================================================================================================
# Section 1: Start, admin check, and folder structure
# ==================================================================================================
# Why:
# Admin rights are helpful or required for event logs, driver information, powercfg, and minidumps.

$ErrorActionPreference = "Continue"
$ToolName = "PCDiagLite"
$ToolVersion = "2.0 Shutdown Correlation"
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
$Out = Join-Path $OutputRoot "PCDiagLite_${ComputerSafe}_${Timestamp}"
$EventRangeLabel = if ($DaysBack -gt 0) { "${DaysBack}d" } else { "all" }
$EventRangeText = if ($DaysBack -gt 0) { "last $DaysBack days" } else { "all available entries" }

$Dirs = @{
    Root      = $Out
    Events    = Join-Path $Out "01_Events"
    System    = Join-Path $Out "02_System_Hardware"
    Storage   = Join-Path $Out "03_Storage"
    Network   = Join-Path $Out "04_Network"
    Power     = Join-Path $Out "05_Power"
    Dumps     = Join-Path $Out "06_Minidumps"
    Policies  = Join-Path $Out "07_Policies"
    WER       = Join-Path $Out "08_WER"
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
        "Collect-PCDiagnostics_OneClick",
        "Collect-PCDiagnostics_Lite",
        "Collect-PCDiagnostics-Lite",
        "Collect-PCDiagnostics-OneClick",
        "PCDiagLite_",
        "PCDiag_"
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
Write-ProgressLine "Event range: $EventRangeText" "Gray"
Write-ProgressLine "Max detailed events per query: $MaxEvents" "Gray"
Write-ProgressLine "Event timeout: $EventTimeoutSeconds seconds" "Gray"
Write-ProgressLine "Step timeout: $StepTimeoutSeconds seconds" "Gray"
Write-ProgressLine "Privacy mode: $([bool]$PrivacyMode)" "Gray"
Write-Host ""

Stop-OldDiagnosticProcesses


@"
$ToolName $ToolVersion
==============================

Computer:      $env:COMPUTERNAME
User:          $env:USERNAME
Export time:   $(Get-Date -Format "yyyy-MM-dd HH:mm:ss")
Event range:   $EventRangeText
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
    $launcher = Join-Path $Dirs.Runtime "${safe}.cmd"
    $stdout = Join-Path $Dirs.Runtime "${safe}_stdout.txt"
    $stderr = Join-Path $Dirs.Runtime "${safe}_stderr.txt"

    [System.IO.File]::WriteAllText($child, $ScriptContent, [System.Text.UTF8Encoding]::new($true))
    $psExe = ""
    try { $psExe = (Get-Command "powershell.exe" -ErrorAction Stop).Source } catch {}
    if ([string]::IsNullOrWhiteSpace($psExe)) {
        $psExe = Join-Path $PSHOME "powershell.exe"
    }
    $launcherLines = @(
        "@echo off",
        ('"{0}" -NoProfile -ExecutionPolicy Bypass -File "{1}" 1> "{2}" 2> "{3}"' -f $psExe, $child, $stdout, $stderr),
        "exit /b %ERRORLEVEL%"
    )
    [System.IO.File]::WriteAllLines($launcher, $launcherLines, [System.Text.Encoding]::ASCII)

    $sw = [System.Diagnostics.Stopwatch]::StartNew()
    Write-ProgressLine "START: $Name (Timeout ${TimeoutSeconds}s)" "Cyan"

    try {
        $argLine = "/d /c `"$launcher`""
        $p = Start-Process -FilePath "cmd.exe" -ArgumentList $argLine -PassThru -WindowStyle Hidden

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
        try { $p.Refresh() } catch {}

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
`$EventRangeLabel = $(ConvertTo-PSStringLiteral $EventRangeLabel)
`$EventRangeText = $(ConvertTo-PSStringLiteral $EventRangeText)
`$MaxEvents = $MaxEvents
`$ToolVersion = $(ConvertTo-PSStringLiteral $ToolVersion)
`$Dirs = @{
$($dirLines -join "`r`n")
}

$Body
"@
}

function ConvertTo-PackageRelativePath {
    param([AllowNull()][string]$Path)

    if ([string]::IsNullOrWhiteSpace($Path)) { return "" }

    try {
        $fullPath = [System.IO.Path]::GetFullPath([string]$Path)
        $rootPath = [System.IO.Path]::GetFullPath([string]$Dirs.Root).TrimEnd('\')
        if ($fullPath.StartsWith($rootPath, [System.StringComparison]::OrdinalIgnoreCase)) {
            return $fullPath.Substring($rootPath.Length).TrimStart('\')
        }
        return $fullPath
    } catch {
        return [string]$Path
    }
}

function Add-SourceInfoToRows {
    param(
        [object[]]$Rows,
        [string]$SourceFile,
        [int]$FirstEntryNumber = 1,
        [string]$EntryPrefix = "row"
    )

    $items = @($Rows)
    $sourceText = ConvertTo-PackageRelativePath $SourceFile
    $entryNumber = $FirstEntryNumber
    foreach ($row in $items) {
        try {
            if ($null -eq $row.PSObject.Properties["SourceFile"]) {
                $row | Add-Member -NotePropertyName "SourceFile" -NotePropertyValue $sourceText -Force
            }
            if ($null -eq $row.PSObject.Properties["SourceEntry"]) {
                $row | Add-Member -NotePropertyName "SourceEntry" -NotePropertyValue "$EntryPrefix $entryNumber" -Force
            }
        } catch {}
        $entryNumber++
    }

    return $items
}

function Read-CsvSafe {
    param([Parameter(Mandatory=$true)][string]$Path)

    if (-not (Test-Path -LiteralPath $Path)) { return @() }

    try {
        $rows = @(Import-Csv -LiteralPath $Path -ErrorAction Stop)
        return @(Add-SourceInfoToRows -Rows $rows -SourceFile $Path -FirstEntryNumber 2 -EntryPrefix "CSV row")
    } catch {
        return @()
    }
}

function Get-DumpDebuggerPath {
    $command = Get-Command "cdb.exe" -ErrorAction SilentlyContinue
    if ($command) { return [string]$command.Source }

    $candidateRoots = @(
        "${env:ProgramFiles(x86)}\Windows Kits\10\Debuggers\x64",
        "${env:ProgramFiles(x86)}\Windows Kits\10\Debuggers\arm64",
        "${env:ProgramFiles}\Windows Kits\10\Debuggers\x64",
        "${env:ProgramFiles}\Windows Kits\10\Debuggers\arm64"
    ) | Where-Object { -not [string]::IsNullOrWhiteSpace($_) }

    foreach ($root in $candidateRoots) {
        if (-not (Test-Path -LiteralPath $root)) { continue }
        try {
            $match = Get-ChildItem -LiteralPath $root -Filter "cdb.exe" -Recurse -ErrorAction SilentlyContinue |
                Sort-Object FullName |
                Select-Object -First 1
            if ($match) { return [string]$match.FullName }
        } catch {}
    }

    return ""
}

function Convert-DumpAnalysisTextToRow {
    param(
        [Parameter(Mandatory=$true)][string]$DumpFile,
        [Parameter(Mandatory=$true)][string]$AnalysisPath,
        [string]$Status = "Success",
        [string]$ExitCode = "",
        [string]$Note = ""
    )

    $text = ""
    if (Test-Path -LiteralPath $AnalysisPath) {
        $text = Get-Content -LiteralPath $AnalysisPath -Raw -ErrorAction SilentlyContinue
    }

    $bugCheck = ""
    if ($text -match '(?im)^\s*BUGCHECK_CODE:\s+(.+?)\s*$') { $bugCheck = $matches[1].Trim() }
    elseif ($text -match '(?im)^\s*BugCheck\s+([0-9a-fA-F]+)') { $bugCheck = $matches[1].Trim() }

    $probably = ""
    if ($text -match '(?im)^\s*Probably caused by\s*:\s*(.+?)\s*$') { $probably = $matches[1].Trim() }

    $processName = ""
    if ($text -match '(?im)^\s*PROCESS_NAME:\s+(.+?)\s*$') { $processName = $matches[1].Trim() }

    $moduleName = ""
    if ($text -match '(?im)^\s*MODULE_NAME:\s+(.+?)\s*$') { $moduleName = $matches[1].Trim() }

    $imageName = ""
    if ($text -match '(?im)^\s*IMAGE_NAME:\s+(.+?)\s*$') { $imageName = $matches[1].Trim() }

    $failureBucket = ""
    if ($text -match '(?im)^\s*FAILURE_BUCKET_ID:\s+(.+?)\s*$') { $failureBucket = $matches[1].Trim() }

    $symbolName = ""
    if ($text -match '(?im)^\s*SYMBOL_NAME:\s+(.+?)\s*$') { $symbolName = $matches[1].Trim() }

    $failureHash = ""
    if ($text -match '(?im)^\s*FAILURE_ID_HASH:\s+(.+?)\s*$') { $failureHash = $matches[1].Trim() }

    $suspectedArea = "Unknown"
    $recommendedAction = "Open the full DumpAnalysis_*.txt output and correlate the crash with recent driver, firmware, BIOS, Windows update, and hardware changes."
    $suspectText = @($probably, $imageName, $moduleName, $symbolName, $failureBucket) -join " "
    $bugCheckText = [string]$bugCheck

    if ($suspectText -match '(?i)usb|uasp|usbstor|usbhub|usbccgp|hidusb') {
        $suspectedArea = "USB / external devices"
        $recommendedAction = "Check USB devices, hubs, docks, front-panel ports, external drives, controller drivers, and BIOS/chipset firmware. Test with non-essential USB devices removed."
    } elseif ($suspectText -match '(?i)nvlddmkm|amdkmdag|atikmdag|igdkmdn|dxgkrnl|graphics|display') {
        $suspectedArea = "Graphics driver / GPU"
        $recommendedAction = "Perform a clean GPU driver install, check GPU stability, disable unstable overlays/overclocking, and correlate with game or display-driver events."
    } elseif ($suspectText -match '(?i)PciD3Cold|CorePowerRail|pci!PciD3|pci!.*Power') {
        $suspectedArea = "PCIe / chipset / device power management"
        $recommendedAction = "This points at a PCIe device power-state transition. Update BIOS/UEFI, chipset, GPU, storage, and dock/device firmware; then correlate with sleep/resume, Modern Standby, USB, GPU, and WHEA events."
    } elseif ($suspectText -match '(?i)stor|stornvme|storahci|iaStor|disk|ntfs|fltmgr|volmgr|partmgr') {
        $suspectedArea = "Storage / file system"
        $recommendedAction = "Back up important data, check SMART/vendor diagnostics, storage controller drivers, cabling/enclosure, and file-system health."
    } elseif ($suspectText -match '(?i)net|tcpip|ndis|wlan|wifi|e1|e2f|rt640|rtwlane|wintun|wireguard|tailscale') {
        $suspectedArea = "Network driver / VPN"
        $recommendedAction = "Update NIC/Wi-Fi/VPN drivers and firmware, simplify VPN/filter drivers, and correlate with network disconnect or DNS events."
    } elseif ($suspectText -match '(?i)memory_corruption|ntkrnlmp|ntoskrnl|hardware|whea|genuineintel|authenticamd') {
        $suspectedArea = "Kernel / hardware stability"
        $recommendedAction = "Check RAM stability, CPU/GPU/SoC overclocking, BIOS/UEFI, chipset drivers, thermals, PSU, and WHEA events around the crash."
    }

    if ($bugCheckText -match '^(9f|0x9f)$') {
        $suspectedArea = if ($suspectedArea -eq "Unknown") { "Power transition / driver timeout" } else { "$suspectedArea; power transition" }
        $recommendedAction = "BugCheck 9F usually means a driver did not complete a power transition. Check sleep/resume, USB, storage, Bluetooth, GPU, chipset, and power-management drivers."
    } elseif ($bugCheckText -match '^(116|0x116)$') {
        $suspectedArea = "Graphics driver / GPU timeout"
        $recommendedAction = "BugCheck 116 is a video TDR crash. Clean-install the GPU driver, disable overlays and unstable overclocks for one test, review GPU temperatures/power, and correlate with nvlddmkm or game crash events."
    } elseif ($bugCheckText -match '^(7e|0x7e|3b|0x3b|50|0x50|1a|0x1a)$' -and $suspectedArea -eq "Unknown") {
        $suspectedArea = "Kernel crash / memory or driver"
        $recommendedAction = "Correlate the named module with drivers and recent software changes. If no driver is named, test RAM stability and review WHEA/storage events."
    }

    return [PSCustomObject]@{
        DumpFile         = $DumpFile
        Status           = $Status
        BugCheck         = $bugCheck
        ProbablyCausedBy = $probably
        ProcessName      = $processName
        ModuleName       = $moduleName
        ImageName        = $imageName
        SymbolName       = $symbolName
        FailureBucket    = $failureBucket
        FailureHash      = $failureHash
        SuspectedArea    = $suspectedArea
        RecommendedAction = $recommendedAction
        ExitCode         = $ExitCode
        AnalysisFile     = if (Test-Path -LiteralPath $AnalysisPath) { Split-Path -Leaf $AnalysisPath } else { "" }
        Note             = $Note
    }
}

function Read-DumpAnalysisRows {
    $rows = @(Read-CsvSafe (Join-Path $Dirs.Dumps "DumpAnalysis.csv"))
    if ($rows.Count -gt 0) { return $rows }

    $analysisFiles = @(Get-ChildItem -LiteralPath $Dirs.Dumps -Filter "DumpAnalysis_*.txt" -ErrorAction SilentlyContinue |
        Where-Object { $_.Name -notmatch '_stderr\.txt$|_status\.txt$' } |
        Sort-Object LastWriteTime -Descending)

    $fallbackRows = @()
    foreach ($file in $analysisFiles) {
        $dumpFile = ($file.BaseName -replace '^DumpAnalysis_', '') + ".dmp"
        $fallbackRows += Convert-DumpAnalysisTextToRow -DumpFile $dumpFile -AnalysisPath $file.FullName -Status "ParsedFromText" -Note "DumpAnalysis.csv was missing or unreadable; parsed from analysis text"
    }

    return $fallbackRows
}

function Test-InteractivePromptAvailable {
    try {
        return [Environment]::UserInteractive -and -not [Console]::IsInputRedirected
    } catch {
        return $false
    }
}

function Install-WindowsDebuggingTools {
    param([string]$StatusPath = "")

    $installerUrl = "https://go.microsoft.com/fwlink/?linkid=2366211"
    $installerPath = Join-Path $Dirs.Runtime "winsdksetup.exe"

    try {
        Write-ProgressLine "Downloading Windows SDK installer for Debugging Tools..." "Cyan"
        Invoke-WebRequest -UseBasicParsing -Uri $installerUrl -OutFile $installerPath -ErrorAction Stop

        if (-not (Test-Path -LiteralPath $installerPath)) {
            throw "Windows SDK installer was not downloaded."
        }

        Write-ProgressLine "Installing Windows Debugging Tools only. This can take several minutes..." "Cyan"
        $arguments = "/features OptionId.WindowsDesktopDebuggers /quiet /norestart /ceip off"
        $process = Start-Process -FilePath $installerPath -ArgumentList $arguments -PassThru -WindowStyle Hidden
        $timeoutSeconds = 900
        if (-not $process.WaitForExit($timeoutSeconds * 1000)) {
            Stop-ProcessTreeSafe -ProcessId ([int]$process.Id) -Reason "Debugging Tools install timeout"
            throw "Windows Debugging Tools installer timed out after $timeoutSeconds seconds."
        }

        if ($process.ExitCode -notin 0, 3010) {
            throw "Windows Debugging Tools installer exit code $($process.ExitCode)."
        }

        $debugger = Get-DumpDebuggerPath
        if ([string]::IsNullOrWhiteSpace($debugger) -or -not (Test-Path -LiteralPath $debugger)) {
            throw "Installation finished, but cdb.exe was not found."
        }

        Write-ProgressLine "Windows Debugging Tools installed: $debugger" "Green"
        if (-not [string]::IsNullOrWhiteSpace($StatusPath)) {
            "Windows Debugging Tools installed: $debugger" | Out-File $StatusPath -Encoding UTF8 -Append
        }
        return $debugger
    } catch {
        $message = "Windows Debugging Tools installation failed: $($_.Exception.Message)"
        Write-ProgressLine $message "Yellow"
        if (-not [string]::IsNullOrWhiteSpace($StatusPath)) {
            $message | Out-File $StatusPath -Encoding UTF8 -Append
            "Installer URL: $installerUrl" | Out-File $StatusPath -Encoding UTF8 -Append
        }
        return ""
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
        [AllowNull()][string]$LastSeen = "",
        [string]$DetailText = ""
    )

    if ($EventRows.Count -gt 0) {
        $eventTimeInfo = Get-EventTimeInfo -Rows $EventRows
        $FirstSeen = $eventTimeInfo.FirstSeen
        $LastSeen = $eventTimeInfo.LastSeen
        $TimeContext = $eventTimeInfo.TimeContext
        if ([string]::IsNullOrWhiteSpace($DetailText)) {
            $DetailText = New-EventDetailsText -Rows $EventRows
        }
    }

    if ([string]::IsNullOrWhiteSpace($TimeContext)) {
        $TimeContext = "Current state at collection time: $(Format-FindingDate (Get-Date))"
    }

    if ([string]::IsNullOrWhiteSpace($DetailText)) {
        $DetailText = "No Event Viewer event details are available for this finding. It is based on current inventory or collection state."
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
        Details        = $DetailText
    }

    if ($EventRows.Count -gt 0 -and $null -ne $script:TimelineRows) {
        foreach ($eventRow in @(Select-LatestTimestampedRows -Rows $EventRows -MaxRows 40)) {
            $message = [string]$eventRow.Message
            if ($message.Length -gt 220) {
                $message = $message.Substring(0, 220) + "..."
            }

            $eventDate = ConvertTo-DateTimeSafe ([string]$eventRow.TimeCreated)
            $script:TimelineRows += [PSCustomObject]@{
                TimeCreated      = Format-FindingDate $eventDate
                Severity         = $Severity
                Category         = $Category
                FindingTitle     = $Title
                LogName          = [string]$eventRow.LogName
                ProviderName     = [string]$eventRow.ProviderName
                EventId          = [string]$eventRow.Id
                RecordId         = [string]$eventRow.RecordId
                LevelDisplayName = [string]$eventRow.LevelDisplayName
                SourceFile       = [string]$eventRow.SourceFile
                SourceEntry      = [string]$eventRow.SourceEntry
                Message          = $message
                EventDetails     = New-EventDetailsText -Rows @($eventRow)
            }
        }
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

function Select-LatestTimestampedRows {
    param(
        [object[]]$Rows,
        [int]$MaxRows = 100
    )

    $latest = @($Rows |
        Where-Object { -not [string]::IsNullOrWhiteSpace([string]$_.TimeCreated) } |
        Sort-Object @{ Expression = { ConvertTo-DateTimeSafe ([string]$_.TimeCreated) }; Descending = $true } |
        Select-Object -First $MaxRows)

    return @($latest | Sort-Object @{ Expression = { ConvertTo-DateTimeSafe ([string]$_.TimeCreated) }; Descending = $false })
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

function New-EventDetailsText {
    param([object[]]$Rows)

    $items = @($Rows | Sort-Object @{ Expression = { ConvertTo-DateTimeSafe ([string]$_.TimeCreated) }; Descending = $true })
    if ($items.Count -eq 0) {
        return "No matching Event Viewer records were captured for this finding."
    }

    $sb = New-Object System.Text.StringBuilder
    [void]$sb.AppendLine("Matching captured Event Viewer records: $($items.Count)")
    $sourceFiles = @($items | ForEach-Object { [string]$_.SourceFile } | Where-Object { -not [string]::IsNullOrWhiteSpace($_) } | Sort-Object -Unique)
    if ($sourceFiles.Count -gt 0) {
        [void]$sb.AppendLine("Captured from file(s): $($sourceFiles -join '; ')")
    }
    [void]$sb.AppendLine("")

    $summaryRows = @($items | ForEach-Object {
        $message = [string]$_.Message
        $subject = ""
        if ($_.ProviderName -match 'Service Control Manager') {
            if ($message -match '(?i)^The\s+(.+?)\s+service\s+(?:failed|was|terminated|entered|did not|could not)') { $subject = $matches[1].Trim() }
            elseif ($message -match '(?i)(?:service|dienst)\s+["'']([^"'']+)["'']') { $subject = $matches[1].Trim() }
            elseif ($message -match '(?i)^([^:]+?)\s+(?:service|dienst)') { $subject = $matches[1].Trim() }
        } elseif ($_.ProviderName -match 'WindowsUpdateClient') {
            if ($message -match '(?i)(?:Update|Updates?)\s+(?:for|für)\s+(.+?)(?:\s+failed|\s+fehlgeschlagen|\.|$)') { $subject = $matches[1].Trim() }
            elseif ($message -match '(?i)(?:error|Fehler)\s+0x[0-9a-f]+\s*(?:failed|fehlgeschlagen)?\s*:\s*([A-Za-z0-9_.-]+)') { $subject = $matches[1].Trim() }
            elseif ($message -match '(?i)(0x[0-9a-f]+)') { $subject = $matches[1] }
        } elseif ($_.ProviderName -match 'Application Error|Application Hang') {
            $appName = ""
            $moduleName = ""
            if ($message -match '(?im)(?:Faulting application name|Name der fehlerhaften Anwendung|Fehlerhafter Anwendungsname):\s*([^,\r\n]+)') { $appName = $matches[1].Trim() }
            if ($message -match '(?im)(?:Faulting module name|Name des fehlerhaften Moduls|Fehlerhafter Modulname):\s*([^,\r\n]+)') { $moduleName = $matches[1].Trim() }
            if (-not [string]::IsNullOrWhiteSpace($appName) -and -not [string]::IsNullOrWhiteSpace($moduleName)) {
                $subject = "$appName / $moduleName"
            } elseif (-not [string]::IsNullOrWhiteSpace($appName)) {
                $subject = $appName
            }
        } elseif ($_.ProviderName -match 'AppModel|AppX|Store') {
            if ($message -match '(?i)(?:package|Paket)\s+([^\s]+)') { $subject = $matches[1].Trim() }
            elseif ($message -match '(?i)([A-Za-z0-9_.-]+_[A-Za-z0-9_.-]+)') { $subject = $matches[1].Trim() }
        } elseif ($_.ProviderName -match 'DNS|Time') {
            if ($message -match '(?i)(?:name|Namen)\s+([^\s,;]+)') { $subject = $matches[1].Trim() }
            elseif ($message -match '(?i)([a-z0-9.-]+\.[a-z]{2,})') { $subject = $matches[1].Trim() }
        } elseif ($_.ProviderName -match 'disk|Ntfs|stor|volmgr') {
            if ($message -match '(?i)(?:device|Gerät|Volume)\s+["'']?([^,"''\r\n]+)') { $subject = $matches[1].Trim() }
        }

        if ([string]::IsNullOrWhiteSpace($subject)) {
            $subject = "same provider/event"
        } else {
            $subject = $subject.Trim().TrimEnd('.', ';', ',')
        }

        [PSCustomObject]@{
            Key = "$($_.ProviderName)|$($_.Id)|$subject"
            ProviderName = [string]$_.ProviderName
            EventId = [string]$_.Id
            Subject = $subject
            TimeCreated = [string]$_.TimeCreated
        }
    })

    $summaryGroups = @($summaryRows | Group-Object Key | Sort-Object Count -Descending | Select-Object -First 8)
    if ($summaryGroups.Count -gt 0) {
        [void]$sb.AppendLine("Top repeated event groups:")
        foreach ($group in $summaryGroups) {
            $firstRow = $group.Group[0]
            $dates = @($group.Group | ForEach-Object { ConvertTo-DateTimeSafe ([string]$_.TimeCreated) } | Where-Object { $null -ne $_ } | Sort-Object)
            $timeText = ""
            if ($dates.Count -gt 0) {
                $timeText = " first=$(Format-FindingDate $dates[0]); last=$(Format-FindingDate $dates[-1])"
            }
            [void]$sb.AppendLine(("- {0}x {1} {2}: {3}{4}" -f $group.Count, $firstRow.ProviderName, $firstRow.EventId, $firstRow.Subject, $timeText))
        }
        [void]$sb.AppendLine("")
    }

    $index = 1
    foreach ($row in $items) {
        $eventTime = ConvertTo-DateTimeSafe ([string]$row.TimeCreated)
        $timeText = if ($null -ne $eventTime) { Format-FindingDate $eventTime } else { [string]$row.TimeCreated }
        $levelText = [string]$row.Level
        if (-not [string]::IsNullOrWhiteSpace([string]$row.LevelDisplayName)) {
            $levelText = "$levelText ($($row.LevelDisplayName))"
        }

        [void]$sb.AppendLine("===== Event $index of $($items.Count) =====")
        if (-not [string]::IsNullOrWhiteSpace([string]$row.SourceFile)) {
            [void]$sb.AppendLine("Captured file:  $($row.SourceFile)")
        }
        if (-not [string]::IsNullOrWhiteSpace([string]$row.SourceEntry)) {
            [void]$sb.AppendLine("Captured entry: $($row.SourceEntry)")
        }
        [void]$sb.AppendLine("Log Name:      $($row.LogName)")
        [void]$sb.AppendLine("Source:        $($row.ProviderName)")
        [void]$sb.AppendLine("Event ID:      $($row.Id)")
        if (-not [string]::IsNullOrWhiteSpace([string]$row.RecordId)) {
            [void]$sb.AppendLine("Record ID:     $($row.RecordId)")
        }
        [void]$sb.AppendLine("Level:         $levelText")
        [void]$sb.AppendLine("Date and Time: $timeText")
        if (-not [string]::IsNullOrWhiteSpace([string]$row.EventData)) {
            [void]$sb.AppendLine("Event Data:    $($row.EventData)")
        }
        [void]$sb.AppendLine("")
        [void]$sb.AppendLine("Message:")
        if ([string]::IsNullOrWhiteSpace([string]$row.Message)) {
            [void]$sb.AppendLine("(No message text was captured for this record.)")
        } else {
            [void]$sb.AppendLine([string]$row.Message)
        }
        [void]$sb.AppendLine("")
        $index++
    }

    return $sb.ToString().TrimEnd()
}

function Get-StorageDiskContextFromEvents {
    param([object[]]$EventRows)

    $diskIndexes = New-Object System.Collections.Generic.List[int]
    foreach ($row in @($EventRows)) {
        $message = [string]$row.Message
        foreach ($match in [regex]::Matches($message, '(?i)\\Device\\Harddisk(\d+)')) {
            $diskIndexes.Add([int]$match.Groups[1].Value) | Out-Null
        }
        foreach ($match in [regex]::Matches($message, '(?i)\bdisk\s+(\d+)\b')) {
            $diskIndexes.Add([int]$match.Groups[1].Value) | Out-Null
        }
    }

    $uniqueIndexes = @($diskIndexes | Sort-Object -Unique)
    if ($uniqueIndexes.Count -eq 0) {
        return [PSCustomObject]@{ Summary = ""; DetailText = "" }
    }

    $diskRows = @(Read-CsvSafe (Join-Path $Dirs.Storage "DiskDrive_WMI.csv") | Where-Object {
        $idx = ConvertTo-NumberSafe ([string]$_.Index)
        $null -ne $idx -and ([int]$idx) -in $uniqueIndexes
    })
    $mappingRows = @(Read-CsvSafe (Join-Path $Dirs.Storage "Disk_To_DriveLetter_Mapping.csv") | Where-Object {
        $idx = ConvertTo-NumberSafe ([string]$_.DiskIndex)
        $null -ne $idx -and ([int]$idx) -in $uniqueIndexes
    })
    $diskRowsByIndex = @{}
    foreach ($disk in $diskRows) {
        $diskRowsByIndex[[string]$disk.Index] = $disk
    }

    $summaryParts = foreach ($idx in $uniqueIndexes) {
        $disk = $diskRowsByIndex[[string]$idx]
        $letters = @($mappingRows | Where-Object { [string]$_.DiskIndex -eq [string]$idx } | ForEach-Object { [string]$_.DriveLetter } | Where-Object { -not [string]::IsNullOrWhiteSpace($_) } | Sort-Object -Unique)
        $letterText = if ($letters.Count -gt 0) { "drives $($letters -join ', ')" } else { "no drive letter mapping captured" }
        if ($disk) {
            "Harddisk$idx = $($disk.Model) [$($disk.InterfaceType)], $letterText"
        } else {
            "Harddisk$idx, $letterText"
        }
    }

    $detailParts = @()
    if ($diskRows.Count -gt 0) {
        $detailParts += (New-ObjectDetailsText -Rows $diskRows -Title "Disk rows matching Event Viewer Harddisk references")
    }
    if ($mappingRows.Count -gt 0) {
        $detailParts += (New-ObjectDetailsText -Rows $mappingRows -Title "Drive-letter mappings for matching disks")
    }

    return [PSCustomObject]@{
        Summary = ($summaryParts -join "; ")
        DetailText = ($detailParts -join "`r`n`r`n")
    }
}

function New-ObjectDetailsText {
    param(
        [object[]]$Rows,
        [string]$Title = "Captured detail rows"
    )

    $items = @($Rows)
    if ($items.Count -eq 0) {
        return "No detail rows were captured for this finding."
    }

    $sb = New-Object System.Text.StringBuilder
    [void]$sb.AppendLine("$Title`: $($items.Count)")
    [void]$sb.AppendLine("")

    $index = 1
    foreach ($row in $items) {
        [void]$sb.AppendLine("===== Row $index of $($items.Count) =====")
        if (-not [string]::IsNullOrWhiteSpace([string]$row.SourceFile)) {
            [void]$sb.AppendLine("SourceFile: $($row.SourceFile)")
        }
        if (-not [string]::IsNullOrWhiteSpace([string]$row.SourceEntry)) {
            [void]$sb.AppendLine("SourceEntry: $($row.SourceEntry)")
        }
        foreach ($prop in $row.PSObject.Properties) {
            if ($prop.Name -in @("SourceFile","SourceEntry")) { continue }
            [void]$sb.AppendLine("$($prop.Name): $($prop.Value)")
        }
        [void]$sb.AppendLine("")
        $index++
    }

    return $sb.ToString().TrimEnd()
}

function Get-AppCrashInfoFromMessage {
    param([string]$Message)

    $faultingApp = ""
    $faultingModule = ""
    $exceptionCode = ""
    $faultOffset = ""
    $appPath = ""
    $modulePath = ""
    $reportId = ""
    if ($Message -match '(?im)(?:Faulting application name|Name der fehlerhaften Anwendung|Fehlerhafter Anwendungsname):\s*([^,\r\n]+)') { $faultingApp = $matches[1].Trim() }
    if ($Message -match '(?im)(?:Faulting module name|Name des fehlerhaften Moduls|Fehlerhafter Modulname):\s*([^,\r\n]+)') { $faultingModule = $matches[1].Trim() }
    if ($Message -match '(?im)(?:Exception code|Ausnahmecode):\s*(0x[0-9a-f]+)') { $exceptionCode = $matches[1].Trim() }
    if ($Message -match '(?im)(?:Fault offset|Fehleroffset):\s*(0x[0-9a-f]+)') { $faultOffset = $matches[1].Trim() }
    if ($Message -match '(?im)(?:Faulting application path|Pfad der fehlerhaften Anwendung|Fehlerhafter Anwendungspfad):\s*([^\r\n]+)') { $appPath = $matches[1].Trim() }
    if ($Message -match '(?im)(?:Faulting module path|Pfad des fehlerhaften Moduls|Fehlerhafter Modulpfad):\s*([^\r\n]+)') { $modulePath = $matches[1].Trim() }
    if ($Message -match '(?im)(?:Report Id|Berichtskennung|Berichts-ID):\s*([^\r\n]+)') { $reportId = $matches[1].Trim() }

    return [PSCustomObject]@{
        FaultingApplication = $faultingApp
        FaultingModule      = $faultingModule
        ExceptionCode       = $exceptionCode
        FaultOffset         = $faultOffset
        ApplicationPath     = $appPath
        FaultingModulePath  = $modulePath
        ReportId            = $reportId
    }
}

function Get-WerFieldValue {
    param(
        [hashtable]$Fields,
        [string[]]$Names
    )

    foreach ($name in @($Names)) {
        if ($Fields.ContainsKey($name) -and -not [string]::IsNullOrWhiteSpace([string]$Fields[$name])) {
            return [string]$Fields[$name]
        }
    }

    return ""
}

function Get-WerSignatureValue {
    param(
        [hashtable]$Fields,
        [string]$SignatureNamePattern
    )

    $sigIndexes = @($Fields.Keys |
        Where-Object { $_ -match '^Sig\[(\d+)\]\.Name$' -and [string]$Fields[$_] -match $SignatureNamePattern } |
        ForEach-Object { [int]([regex]::Match($_, '\d+').Value) } |
        Sort-Object)

    foreach ($index in $sigIndexes) {
        $valueKey = "Sig[$index].Value"
        if ($Fields.ContainsKey($valueKey) -and -not [string]::IsNullOrWhiteSpace([string]$Fields[$valueKey])) {
            return [string]$Fields[$valueKey]
        }
    }

    return ""
}

function Get-WerLoadedModuleHints {
    param([hashtable]$Fields)

    $modules = @($Fields.Keys |
        Where-Object { $_ -match '^LoadedModule\[\d+\]$' } |
        Sort-Object { [int]([regex]::Match($_, '\d+').Value) } |
        ForEach-Object { [string]$Fields[$_] } |
        Where-Object { -not [string]::IsNullOrWhiteSpace($_) })

    $hints = @()
    if ($modules | Where-Object { $_ -match '(?i)gameoverlayrenderer64\.dll' } | Select-Object -First 1) { $hints += "Steam overlay loaded" }
    if ($modules | Where-Object { $_ -match '(?i)nvapi64\.dll|nvldumdx\.dll|nvgpucomp64\.dll|nvppex\.dll|nvwgf2umx\.dll' } | Select-Object -First 1) { $hints += "NVIDIA user-mode graphics modules loaded" }
    if ($modules | Where-Object { $_ -match '(?i)amd_ags_x64\.dll' } | Select-Object -First 1) { $hints += "AMD AGS helper loaded by game" }
    if ($modules | Where-Object { $_ -match '(?i)rendersystemdx11\.dll|scenesystem\.dll|materialsystem2\.dll|worldrenderer\.dll' } | Select-Object -First 1) { $hints += "CS2 render/scene modules loaded" }

    return ($hints | Select-Object -Unique) -join "; "
}

function Get-ServiceNameFromEventMessage {
    param([string]$Message)

    if ($Message -match '(?im)(?:The|Der)\s+(?:service|Dienst)\s+["'']?([^"''\r\n]+?)["'']?\s+(?:failed|wurde|terminated|entered|did not|could not|konnte|beendete|ist)') { return $matches[1].Trim() }
    if ($Message -match '(?im)(?:service|Dienst)\s+["'']([^"''\r\n]+)["'']') { return $matches[1].Trim() }
    if ($Message -match '(?ims)von\s+Dienst\s+(.+?)\s+erreicht') { return (($matches[1] -replace '\s+', ' ').Trim()) }
    if ($Message -match '(?im)^["'']?([^"''\r\n]+?)["'']?\s+(?:service|Dienst)\s+(?:failed|terminated|entered|did not|could not)') { return $matches[1].Trim() }
    return "unknown service"
}

function New-TopCountSummary {
    param(
        [object[]]$Rows,
        [string]$PropertyName,
        [int]$MaxItems = 8
    )

    $parts = @($Rows |
        Where-Object { -not [string]::IsNullOrWhiteSpace([string]$_.PSObject.Properties[$PropertyName].Value) } |
        Group-Object -Property $PropertyName |
        Sort-Object Count -Descending |
        Select-Object -First $MaxItems |
        ForEach-Object { "$($_.Name)=$($_.Count)" })
    return ($parts -join "; ")
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

function Get-UnexpectedShutdownReportedTime {
    param([AllowNull()][string]$Message)

    $text = [string]$Message
    if ([string]::IsNullOrWhiteSpace($text)) { return $null }
    $text = $text -replace '[\u200e\u200f]', ''

    $deMatch = [regex]::Match($text, '(?i)am\s+(\d{1,2})\.\s*(\d{1,2})\.\s*(\d{4})\s+um\s+(\d{1,2}):(\d{2}):(\d{2})')
    if ($deMatch.Success) {
        try {
            return [datetime]::new(
                [int]$deMatch.Groups[3].Value,
                [int]$deMatch.Groups[2].Value,
                [int]$deMatch.Groups[1].Value,
                [int]$deMatch.Groups[4].Value,
                [int]$deMatch.Groups[5].Value,
                [int]$deMatch.Groups[6].Value
            )
        } catch {}
    }

    $enMatch = [regex]::Match($text, '(?i)previous system shutdown at\s+(\d{1,2}):(\d{2}):(\d{2})\s+(?:AM|PM)?\s+on\s+([^\.]+?)\s+was unexpected')
    if ($enMatch.Success) {
        $candidate = "$($enMatch.Groups[4].Value) $($enMatch.Groups[1].Value):$($enMatch.Groups[2].Value):$($enMatch.Groups[3].Value)"
        $parsed = [datetime]::MinValue
        if ([datetime]::TryParse($candidate, [ref]$parsed)) { return $parsed }
    }

    return $null
}

function Get-EventBriefText {
    param($Event)

    if ($null -eq $Event) { return "" }
    $time = ConvertTo-DateTimeSafe ([string]$Event.TimeCreated)
    $timeText = if ($null -ne $time) { Format-FindingDate $time } else { [string]$Event.TimeCreated }
    $provider = [string]$Event.ProviderName
    $id = [string]$Event.Id
    $message = ([string]$Event.Message -replace '\s+', ' ').Trim()
    if ($message.Length -gt 180) { $message = $message.Substring(0,180) + "..." }
    return "$timeText | $provider $id | $message"
}

function Get-EventDataValue {
    param(
        [AllowNull()][string]$EventData,
        [Parameter(Mandatory=$true)][string]$Name
    )

    if ([string]::IsNullOrWhiteSpace($EventData)) { return "" }
    $match = [regex]::Match([string]$EventData, "(^|;\s*)$([regex]::Escape($Name))=([^;]*)")
    if ($match.Success) { return $match.Groups[2].Value.Trim() }
    return ""
}

function New-KernelPowerSummaryRows {
    param([object[]]$Rows)

    return @($Rows | ForEach-Object {
        $eventTime = ConvertTo-DateTimeSafe ([string]$_.TimeCreated)
        $eventData = [string]$_.EventData
        $bugcheckCode = Get-EventDataValue -EventData $eventData -Name "BugcheckCode"
        $sleepInProgress = Get-EventDataValue -EventData $eventData -Name "SleepInProgress"
        $powerButtonTimestamp = Get-EventDataValue -EventData $eventData -Name "PowerButtonTimestamp"
        $longPowerButton = Get-EventDataValue -EventData $eventData -Name "LongPowerButtonPressDetected"
        $wheaBootCount = Get-EventDataValue -EventData $eventData -Name "WHEABootErrorCount"
        $connectedStandby = Get-EventDataValue -EventData $eventData -Name "ConnectedStandbyInProgress"

        $interpretation = "Kernel-Power 41 means Windows detected that the previous session did not shut down cleanly."
        if ($bugcheckCode -eq "0" -or [string]::IsNullOrWhiteSpace($bugcheckCode)) {
            $interpretation += " BugcheckCode is 0 or not available, so this event does not prove a blue screen."
        } else {
            $interpretation += " BugcheckCode $bugcheckCode was reported, so inspect minidumps and BugCheck events."
        }
        if ($powerButtonTimestamp -eq "0" -or [string]::IsNullOrWhiteSpace($powerButtonTimestamp)) {
            $interpretation += " No power-button timestamp was reported."
        }
        if ($sleepInProgress -eq "1" -or $connectedStandby -eq "true") {
            $interpretation += " A sleep or standby transition may be involved."
        }
        if ($wheaBootCount -match '^[1-9]') {
            $interpretation += " WHEA boot errors were reported; prioritize hardware/firmware stability."
        }

        [PSCustomObject]@{
            TimeCreated                    = if ($null -ne $eventTime) { Format-FindingDate $eventTime } else { [string]$_.TimeCreated }
            RecordId                       = [string]$_.RecordId
            BugcheckCode                   = $bugcheckCode
            SleepInProgress                = $sleepInProgress
            ConnectedStandbyInProgress     = $connectedStandby
            PowerButtonTimestamp           = $powerButtonTimestamp
            LongPowerButtonPressDetected   = $longPowerButton
            WHEABootErrorCount             = $wheaBootCount
            Interpretation                 = $interpretation
            SourceFile                     = [string]$_.SourceFile
            SourceEntry                    = [string]$_.SourceEntry
        }
    })
}

function Get-ShutdownSignalSummary {
    param(
        [object[]]$Rows,
        [datetime]$Center,
        [int]$WindowMinutes = 10
    )

    $signals = @($Rows | Where-Object {
        $eventTime = ConvertTo-DateTimeSafe ([string]$_.TimeCreated)
        $null -ne $eventTime -and
        [math]::Abs(($eventTime - $Center).TotalMinutes) -le $WindowMinutes -and
        (
            [string]$_.ProviderName -match '(?i)Kernel-Power|BugCheck|WHEA|disk|Ntfs|volmgr|storahci|stornvme|iaStor|Display|nvlddmkm|amdkmdag|EventLog|Service Control Manager|User32' -or
            [string]$_.Id -in @('41','51','55','98','1074','6005','6006','6008','1001','4101','7043')
        )
    } | Sort-Object @{ Expression = { ConvertTo-DateTimeSafe ([string]$_.TimeCreated) } })

    if ($signals.Count -eq 0) {
        return "No relevant System events found within +/-$WindowMinutes minutes."
    }

    return (@($signals | Select-Object -First 12 | ForEach-Object { Get-EventBriefText $_ }) -join "`r`n")
}

function New-ShutdownCorrelationRows {
    param(
        [object[]]$UnexpectedShutdownEvents,
        [object[]]$KernelPowerEvents,
        [object[]]$AllEvents
    )

    $rows = @()
    foreach ($event in @($UnexpectedShutdownEvents)) {
        $loggedAt = ConvertTo-DateTimeSafe ([string]$event.TimeCreated)
        $reportedAt = Get-UnexpectedShutdownReportedTime -Message ([string]$event.Message)

        $kernelNearLog = @($KernelPowerEvents | Where-Object {
            $time = ConvertTo-DateTimeSafe ([string]$_.TimeCreated)
            $null -ne $time -and $null -ne $loggedAt -and [math]::Abs(($time - $loggedAt).TotalMinutes) -le 2
        } | Sort-Object @{ Expression = { ConvertTo-DateTimeSafe ([string]$_.TimeCreated) } } | Select-Object -First 1)

        $lastPlannedRestart = $null
        $lastCleanStop = $null
        if ($null -ne $reportedAt) {
            $lastPlannedRestart = @($AllEvents | Where-Object {
                $time = ConvertTo-DateTimeSafe ([string]$_.TimeCreated)
                $null -ne $time -and $time -le $reportedAt -and [string]$_.Id -eq '1074'
            } | Sort-Object @{ Expression = { ConvertTo-DateTimeSafe ([string]$_.TimeCreated) }; Descending = $true } | Select-Object -First 1)
            $lastCleanStop = @($AllEvents | Where-Object {
                $time = ConvertTo-DateTimeSafe ([string]$_.TimeCreated)
                $null -ne $time -and $time -le $reportedAt -and [string]$_.Id -eq '6006'
            } | Sort-Object @{ Expression = { ConvertTo-DateTimeSafe ([string]$_.TimeCreated) }; Descending = $true } | Select-Object -First 1)
        }

        $gapText = ""
        if ($null -ne $reportedAt -and $null -ne $loggedAt) {
            $gap = New-TimeSpan -Start $reportedAt -End $loggedAt
            $gapText = "{0:n1} hours" -f $gap.TotalHours
        }

        $directSignals = if ($null -ne $reportedAt) { Get-ShutdownSignalSummary -Rows $AllEvents -Center $reportedAt -WindowMinutes 10 } else { "Could not parse the shutdown time from EventLog 6008." }

        $assessment = "Windows logged this at the next boot, not necessarily when the shutdown happened."
        if ($null -ne $reportedAt -and $directSignals -match 'No relevant System events') {
            $assessment += " No direct WHEA, disk, GPU reset, BugCheck, or Kernel-Power event was found near the reported shutdown timestamp."
        }
        if ($null -ne $lastPlannedRestart) {
            $assessment += " A planned Windows restart was seen earlier, but it had clean shutdown/start records."
        }

        $rows += [PSCustomObject]@{
            EventLogRecordTime       = if ($null -ne $loggedAt) { Format-FindingDate $loggedAt } else { [string]$event.TimeCreated }
            ReportedShutdownTime     = if ($null -ne $reportedAt) { Format-FindingDate $reportedAt } else { "Not parsed" }
            TimeUntilLogged          = $gapText
            KernelPower41NearBoot    = if ($kernelNearLog.Count -gt 0) { Get-EventBriefText $kernelNearLog[0] } else { "No Kernel-Power 41 within +/-2 minutes of this 6008 record." }
            LastPlannedRestartBefore = if ($null -ne $lastPlannedRestart) { Get-EventBriefText $lastPlannedRestart } else { "None found before reported shutdown time." }
            LastCleanEventLogStop    = if ($null -ne $lastCleanStop) { Get-EventBriefText $lastCleanStop } else { "None found before reported shutdown time." }
            NearbyReportedTimeEvents = $directSignals
            Assessment               = $assessment
        }
    }

    return $rows
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

function Get-CategoryCssClass {
    param([AllowNull()][string]$Category)

    switch ([string]$Category) {
        "Network"       { return "cat-network" }
        "Storage"       { return "cat-storage" }
        "Hardware"      { return "cat-hardware" }
        "Hardware Migration" { return "cat-migration" }
        "Crash"         { return "cat-crash" }
        "Stability"     { return "cat-stability" }
        "Services"      { return "cat-services" }
        "Drivers"       { return "cat-drivers" }
        "Games"         { return "cat-games" }
        "Windows Stack" { return "cat-windows" }
        "Remote Access" { return "cat-remote" }
        "Collection"    { return "cat-collection" }
        default         { return "cat-general" }
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
        $categoryClass = Get-CategoryCssClass $finding.Category
        $detailsText = [string]$finding.Details
        if ([string]::IsNullOrWhiteSpace($detailsText)) {
            $detailsText = "No further details were captured for this finding."
        }

        [void]$sb.AppendLine("<details class=""finding $class $categoryClass"">")
        [void]$sb.AppendLine('  <summary>')
        [void]$sb.AppendLine('    <div class="finding-head">')
        [void]$sb.AppendLine("      <span class=""badge"">$(Escape-Html $finding.Severity)</span>")
        [void]$sb.AppendLine("      <span class=""category $categoryClass"">$(Escape-Html $finding.Category)</span>")
        [void]$sb.AppendLine('    </div>')
        [void]$sb.AppendLine("    <h3>$(Escape-Html $finding.Title)</h3>")
        [void]$sb.AppendLine("    <p><strong>Time:</strong> $(Escape-Html $finding.TimeContext)</p>")
        [void]$sb.AppendLine("    <p><strong>Evidence:</strong> $(Escape-Html $finding.Evidence)</p>")
        [void]$sb.AppendLine("    <p><strong>Next step:</strong> $(Escape-Html $finding.Recommendation)</p>")
        [void]$sb.AppendLine('    <div class="open-hint">Click to show captured Event Viewer details</div>')
        [void]$sb.AppendLine('  </summary>')
        [void]$sb.AppendLine('  <div class="finding-details">')
        [void]$sb.AppendLine('    <h4>Captured Details</h4>')
        [void]$sb.AppendLine("    <pre class=""event-details"">$(Escape-Html $detailsText)</pre>")
        [void]$sb.AppendLine('  </div>')
        [void]$sb.AppendLine('</details>')
    }

    [void]$sb.AppendLine('</div>')
    return $sb.ToString()
}

function New-AreaGroupedFindingCardsHtml {
    param(
        [object[]]$Findings,
        [int]$MaxRowsPerArea = 80
    )

    $items = @(Get-SortedFindings $Findings)
    if ($items.Count -eq 0) {
        return '<p class="muted">No findings available.</p>'
    }

    $groups = @($items | Group-Object Category | ForEach-Object {
        $areaFindings = @($_.Group)
        [PSCustomObject]@{
            Area = $_.Name
            Count = $areaFindings.Count
            MaxSeverityRank = (@($areaFindings | ForEach-Object { Get-FindingSeverityRank $_.Severity } | Measure-Object -Maximum).Maximum)
            SeverityText = Get-FindingCountsText $areaFindings
            Findings = $areaFindings
        }
    })
    $areaSortProperties = @(
        @{ Expression = { $_.MaxSeverityRank }; Descending = $true }
        @{ Expression = { $_.Count }; Descending = $true }
        "Area"
    )
    $groups = @($groups | Sort-Object -Property $areaSortProperties)

    $sb = New-Object System.Text.StringBuilder
    [void]$sb.AppendLine('<div class="area-list">')

    foreach ($group in $groups) {
        $areaFindings = @(Get-SortedFindings $group.Findings | Select-Object -First $MaxRowsPerArea)
        $topSeverity = @($areaFindings | Sort-Object @{ Expression = { Get-FindingSeverityRank $_.Severity }; Descending = $true } | Select-Object -First 1)[0].Severity
        $class = Get-SeverityCssClass $topSeverity
        $categoryClass = Get-CategoryCssClass $group.Area
        $severitySb = New-Object System.Text.StringBuilder
        foreach ($severity in @("Critical", "High", "Medium", "Info")) {
            $severityFindings = @($areaFindings | Where-Object { $_.Severity -eq $severity })
            if ($severityFindings.Count -eq 0) { continue }

            [void]$severitySb.AppendLine('<section class="severity-section">')
            [void]$severitySb.AppendLine("  <h4>$(Escape-Html $severity) Findings</h4>")
            [void]$severitySb.AppendLine((New-FindingCardsHtml -Findings $severityFindings -MaxRows $MaxRowsPerArea))
            [void]$severitySb.AppendLine('</section>')
        }

        [void]$sb.AppendLine("<details class=""area-group $class $categoryClass"">")
        [void]$sb.AppendLine('  <summary class="area-summary">')
        [void]$sb.AppendLine('    <div>')
        [void]$sb.AppendLine("      <h3>$(Escape-Html $group.Area)</h3>")
        [void]$sb.AppendLine("      <p>$(Escape-Html $group.SeverityText)</p>")
        [void]$sb.AppendLine('    </div>')
        [void]$sb.AppendLine("    <span class=""area-count"">$($group.Count)</span>")
        [void]$sb.AppendLine('  </summary>')
        [void]$sb.AppendLine('  <div class="area-content">')
        [void]$sb.AppendLine($severitySb.ToString())
        [void]$sb.AppendLine('  </div>')
        [void]$sb.AppendLine('</details>')
    }

    [void]$sb.AppendLine('</div>')
    return $sb.ToString()
}

function New-TimelineHtml {
    param(
        [object[]]$Rows,
        [int]$MaxRows = 90
    )

    $timestampedCount = @($Rows | Where-Object { -not [string]::IsNullOrWhiteSpace([string]$_.TimeCreated) }).Count
    $items = @(Select-LatestTimestampedRows -Rows $Rows -MaxRows $MaxRows |
        Sort-Object @{ Expression = { ConvertTo-DateTimeSafe ([string]$_.TimeCreated) }; Descending = $true })

    if ($items.Count -eq 0) {
        return '<div class="timeline-empty">No timestamped Event Viewer records were captured for the current findings.</div>'
    }

    $sb = New-Object System.Text.StringBuilder
    [void]$sb.AppendLine('<div class="timeline-list">')
    if ($timestampedCount -gt $items.Count) {
        [void]$sb.AppendLine("<div class=""timeline-limit-note"">Showing newest $($items.Count) of $timestampedCount finding-linked Event Viewer records.</div>")
    }

    $lastDate = ""
    foreach ($item in $items) {
        $dt = ConvertTo-DateTimeSafe $item.TimeCreated
        $dateLabel = if ($dt) { $dt.ToString("yyyy-MM-dd") } else { "Unknown date" }
        $timeLabel = if ($dt) { $dt.ToString("HH:mm:ss") } else { [string]$item.TimeCreated }
        if ($dateLabel -ne $lastDate) {
            [void]$sb.AppendLine("<div class=""timeline-date"">$(Escape-Html $dateLabel)</div>")
            $lastDate = $dateLabel
        }

        $class = Get-SeverityCssClass $item.Severity
        $categoryClass = Get-CategoryCssClass $item.Category
        $source = [string]$item.ProviderName
        $eventId = [string]$item.EventId
        $sourceText = if ([string]::IsNullOrWhiteSpace($eventId)) { $source } else { "$source $eventId" }
        $sourceBits = @()
        if (-not [string]::IsNullOrWhiteSpace([string]$item.RecordId)) { $sourceBits += "Record $($item.RecordId)" }
        if (-not [string]::IsNullOrWhiteSpace([string]$item.SourceFile)) { $sourceBits += [string]$item.SourceFile }
        if (-not [string]::IsNullOrWhiteSpace([string]$item.SourceEntry)) { $sourceBits += [string]$item.SourceEntry }
        if ($sourceBits.Count -gt 0) {
            $sourceText = "$sourceText | $($sourceBits -join ' | ')"
        }
        $eventDetails = [string]$item.EventDetails
        if ([string]::IsNullOrWhiteSpace($eventDetails)) {
            $eventDetails = "No Event Viewer event details are available for this timeline entry."
        }

        [void]$sb.AppendLine("<details class=""timeline-item $class $categoryClass"">")
        [void]$sb.AppendLine('  <summary class="timeline-summary">')
        [void]$sb.AppendLine('    <div class="timeline-marker"></div>')
        [void]$sb.AppendLine('    <div class="timeline-card">')
        [void]$sb.AppendLine('      <div class="timeline-meta-row">')
        [void]$sb.AppendLine("        <div class=""timeline-time"">$(Escape-Html $timeLabel)</div>")
        [void]$sb.AppendLine('        <div class="timeline-chip-row">')
        [void]$sb.AppendLine("          <span class=""timeline-chip severity-chip $class"">$(Escape-Html $item.Severity)</span>")
        [void]$sb.AppendLine("          <span class=""timeline-chip category-chip $categoryClass"">$(Escape-Html $item.Category)</span>")
        [void]$sb.AppendLine('        </div>')
        [void]$sb.AppendLine('      </div>')
        [void]$sb.AppendLine("    <div class=""timeline-title"">$(Escape-Html $item.FindingTitle)</div>")
        [void]$sb.AppendLine("    <div class=""timeline-source"">$(Escape-Html $sourceText)</div>")
        if (-not [string]::IsNullOrWhiteSpace([string]$item.Message)) {
            [void]$sb.AppendLine("    <p>$(Escape-Html $item.Message)</p>")
        }
        [void]$sb.AppendLine('      <div class="timeline-open-hint">Click to show exact Event Viewer details</div>')
        [void]$sb.AppendLine('    </div>')
        [void]$sb.AppendLine('  </summary>')
        [void]$sb.AppendLine('  <div class="timeline-detail">')
        [void]$sb.AppendLine("    <pre class=""event-details"">$(Escape-Html $eventDetails)</pre>")
        [void]$sb.AppendLine('  </div>')
        [void]$sb.AppendLine('</details>')
    }

    [void]$sb.AppendLine('</div>')
    return $sb.ToString()
}

function Write-InitialFindingsReport {
    $findings = @()
    $script:TimelineRows = @()
    $currentObservation = "Current state at collection time: $(Format-FindingDate (Get-Date))"

    $targetedPath = Join-Path $Dirs.Events "System_Targeted_Stability_Storage_Network_${EventRangeLabel}.csv"
    $systemPath = Join-Path $Dirs.Events "System_WARN_ERR_CRIT_${EventRangeLabel}.csv"
    $applicationPath = Join-Path $Dirs.Events "Application_WARN_ERR_CRIT_${EventRangeLabel}.csv"

    $targeted = Read-CsvSafe $targetedPath
    $systemEvents = Read-CsvSafe $systemPath
    $applicationEvents = Read-CsvSafe $applicationPath
    $allEvents = @($targeted + $systemEvents + $applicationEvents) |
        Group-Object { "$($_.TimeCreated)|$($_.LogName)|$($_.ProviderName)|$($_.Id)" } |
        ForEach-Object { $_.Group[0] }
    $werReports = Read-CsvSafe (Join-Path $Dirs.WER "WindowsErrorReporting_RecentReports.csv")
    $relevantDriverRows = Read-CsvSafe (Join-Path $Dirs.System "Relevant_Drivers_Network_Storage_System.csv")
    $basicDisplayRows = @($relevantDriverRows | Where-Object {
        "$($_.DeviceName) $($_.Manufacturer) $($_.DriverProviderName) $($_.ClassName)" -match '(?i)Microsoft Basic Display Driver|Standard display types'
    })

    $bugCheckEvents = @($allEvents | Where-Object { (Test-EventLevelAtMost $_ 3) -and ($_.ProviderName -match 'BugCheck' -or $_.Id -eq '1001') })
    if ($bugCheckEvents.Count -gt 0) {
        Add-Finding ([ref]$findings) "Critical" "Crash" "BugCheck / blue screen indicators found" "$($bugCheckEvents.Count) matching event(s), for example BugCheck provider or event ID 1001." "Analyze minidumps in 06_Minidumps with a driver and hardware focus. Then check storage, RAM, and driver versions." -EventRows $bugCheckEvents
    }

    $kernelPowerEvents = @($allEvents | Where-Object { (Test-EventLevelAtMost $_ 3) -and $_.ProviderName -match 'Kernel-Power' -and $_.Id -eq '41' })
    if ($kernelPowerEvents.Count -gt 0) {
        $kernelPowerSummaryRows = @(New-KernelPowerSummaryRows -Rows $kernelPowerEvents)
        $bugcheckSummary = New-TopCountSummary -Rows $kernelPowerSummaryRows -PropertyName "BugcheckCode" -MaxItems 5
        $wheaBootSummary = New-TopCountSummary -Rows $kernelPowerSummaryRows -PropertyName "WHEABootErrorCount" -MaxItems 5
        $kernelPowerEvidence = "$($kernelPowerEvents.Count) Kernel-Power 41 event(s)."
        if (-not [string]::IsNullOrWhiteSpace($bugcheckSummary)) { $kernelPowerEvidence += " BugcheckCode summary: $bugcheckSummary." }
        if (-not [string]::IsNullOrWhiteSpace($wheaBootSummary)) { $kernelPowerEvidence += " WHEA boot error count summary: $wheaBootSummary." }
        $kernelPowerDetails = @()
        $kernelPowerDetails += (New-ObjectDetailsText -Rows $kernelPowerSummaryRows -Title "Kernel-Power 41 interpretation rows")
        $kernelPowerDetails += (New-EventDetailsText -Rows $kernelPowerEvents)
        Add-Finding ([ref]$findings) "High" "Stability" "Unexpected restart or power loss" $kernelPowerEvidence "If BugcheckCode is 0 and no WHEA/disk/GPU reset is nearby, treat this as an unclean power loss or hard freeze clue rather than a proven blue screen. Check power delivery, thermals, BIOS/UEFI, RAM/CPU stability, sleep/standby behavior, and events immediately before the restart." -EventRows $kernelPowerEvents -DetailText ($kernelPowerDetails -join "`r`n`r`n")
    }

    $unexpectedShutdownEvents = @($allEvents | Where-Object { (Test-EventLevelAtMost $_ 3) -and ($_.Id -eq '6008' -or ($_.ProviderName -match 'EventLog' -and $_.Id -eq '6008')) })
    if ($unexpectedShutdownEvents.Count -gt 0) {
        $shutdownCorrelationRows = @(New-ShutdownCorrelationRows -UnexpectedShutdownEvents $unexpectedShutdownEvents -KernelPowerEvents $kernelPowerEvents -AllEvents $allEvents)
        $parsedShutdowns = @($shutdownCorrelationRows | Where-Object { [string]$_.ReportedShutdownTime -ne "Not parsed" })
        $latestReported = @($parsedShutdowns | Sort-Object ReportedShutdownTime -Descending | Select-Object -First 1)
        $shutdownEvidence = "$($unexpectedShutdownEvents.Count) EventLog 6008 event(s)."
        if ($latestReported.Count -gt 0) {
            $shutdownEvidence += " Latest reported previous shutdown: $($latestReported[0].ReportedShutdownTime), logged at next boot: $($latestReported[0].EventLogRecordTime)."
        }
        $shutdownDetails = @()
        $shutdownDetails += (New-ObjectDetailsText -Rows $shutdownCorrelationRows -Title "Unexpected shutdown correlation")
        $shutdownDetails += (New-EventDetailsText -Rows $unexpectedShutdownEvents)
        Add-Finding ([ref]$findings) "High" "Stability" "Windows reports an unexpected shutdown" $shutdownEvidence "Treat EventLog 6008 as a next-boot report. Review the correlation table first: if no direct BugCheck, WHEA, disk, GPU reset, or clean shutdown record exists near the reported shutdown time, investigate power loss, hard freeze, PSU/UPS, BIOS/UEFI, RAM/CPU stability, and thermals." -EventRows $unexpectedShutdownEvents -DetailText ($shutdownDetails -join "`r`n`r`n")
    }

    $wheaEvents = @($allEvents | Where-Object { (Test-EventLevelAtMost $_ 3) -and $_.ProviderName -match 'WHEA-Logger' })
    if ($wheaEvents.Count -gt 0) {
        $wheaSeverity = if ($wheaEvents.Count -eq 1 -and [string]$wheaEvents[0].Id -eq '17') { "Medium" } else { "High" }
        $wheaTitle = if ($wheaSeverity -eq "Medium") { "Single corrected WHEA / PCIe hardware error" } else { "WHEA hardware error events found" }
        Add-Finding ([ref]$findings) $wheaSeverity "Hardware" $wheaTitle "$($wheaEvents.Count) WHEA-Logger event(s)." "Identify the affected device from the Event Viewer details. Update BIOS/UEFI, chipset, storage, GPU, and device drivers; reduce unstable overclocking or XMP/EXPO if the events repeat." -EventRows $wheaEvents
    }

    if ($basicDisplayRows.Count -gt 0) {
        Add-Finding ([ref]$findings) "High" "Drivers" "Microsoft Basic Display Driver appears to be active" "$($basicDisplayRows.Count) display driver row(s) show Microsoft Basic Display Driver or standard display types." "Install the correct NVIDIA, AMD, Intel, or OEM graphics driver for this PC before chasing game crashes or rendering problems. Games such as Counter-Strike 2 should not be tested on the Microsoft Basic Display Driver." -TimeContext $currentObservation -DetailText (New-ObjectDetailsText -Rows $basicDisplayRows -Title "Display driver rows")
    }

    $storageEvents = @($allEvents | Where-Object {
        $provider = [string]$_.ProviderName
        $message = [string]$_.Message
        (Test-EventLevelAtMost $_ 3) -and
        ($provider -notmatch '(?i)nvlddmkm|NVIDIA|Display') -and
        (
            ($provider -match '(?i)^disk$|Ntfs|storahci|stornvme|iaStor|volmgr|partmgr') -or
            (($_.Id -in @('51','55','98','129','153','154','157','161','162')) -and ($message -match '(?i)\\Device\\Harddisk|Disk|Datenträger|Volume|volmgr|NTFS|storage|storport'))
        )
    })
    if ($storageEvents.Count -gt 0) {
        $storageDiskContext = Get-StorageDiskContextFromEvents -EventRows $storageEvents
        $storageEvidence = "$($storageEvents.Count) matching Disk/Ntfs/Storage/volmgr event(s) or typical storage event ID(s)."
        if (-not [string]::IsNullOrWhiteSpace([string]$storageDiskContext.Summary)) {
            $storageEvidence += " Affected disk hint: $($storageDiskContext.Summary)."
        }
        $storageDetails = @((New-EventDetailsText -Rows $storageEvents))
        if (-not [string]::IsNullOrWhiteSpace([string]$storageDiskContext.DetailText)) {
            $storageDetails += [string]$storageDiskContext.DetailText
        }
        Add-Finding ([ref]$findings) "High" "Storage" "Storage or file system events found" $storageEvidence "Review the repeated event summary, StorageReliabilityCounter.csv, and Storage_SMART_FailurePrediction.csv. Then check vendor diagnostics, cables/backplane, controller/NVMe/SATA drivers, and file system health. For NTFS 55/98 or Disk 51/153, verify backups soon." -EventRows $storageEvents -DetailText ($storageDetails -join "`r`n`r`n")
    }

    $usbStorageEvents = @($allEvents | Where-Object {
        $provider = [string]$_.ProviderName
        (Test-EventLevelAtMost $_ 3) -and
        ($provider -notmatch '(?i)nvlddmkm|NVIDIA|Display') -and
        (
            ($provider -match '(?i)UASPStor|USBSTOR|^disk$|storahci|stornvme') -and
            ($_.Id -in @('51','129','153','154','157'))
        )
    })
    if ($usbStorageEvents.Count -gt 0) {
        $usbDiskContext = Get-StorageDiskContextFromEvents -EventRows $usbStorageEvents
        $usbEvidence = "$($usbStorageEvents.Count) storage reset or retried-I/O event(s)."
        if (-not [string]::IsNullOrWhiteSpace([string]$usbDiskContext.Summary)) {
            $usbEvidence += " Affected disk hint: $($usbDiskContext.Summary)."
        }
        $usbDetails = @((New-EventDetailsText -Rows $usbStorageEvents))
        if (-not [string]::IsNullOrWhiteSpace([string]$usbDiskContext.DetailText)) {
            $usbDetails += [string]$usbDiskContext.DetailText
        }
        Add-Finding ([ref]$findings) "High" "Storage" "USB/UASP or disk I/O resets detected" $usbEvidence "If Windows, games, apps, or active data are on USB-attached storage, check the enclosure, cable, port, and power. Prefer an internal NVMe/SATA SSD for the Windows system drive on a desktop PC." -EventRows $usbStorageEvents -DetailText ($usbDetails -join "`r`n`r`n")
    }

    $graphicsDriverEvents = @($allEvents | Where-Object {
        (Test-EventLevelAtMost $_ 3) -and
        (
            ([string]$_.ProviderName -match '(?i)nvlddmkm|amdkmdag|atikmdag|Display|DisplayDriver') -or
            ([string]$_.Message -match '(?i)nvlddmkm|amdkmdag|atikmdag|display driver|video driver|Grafiktreiber')
        )
    })
    if ($graphicsDriverEvents.Count -gt 0) {
        $providerSummary = (@($graphicsDriverEvents | Group-Object ProviderName | Sort-Object Count -Descending | Select-Object -First 5 | ForEach-Object { "$($_.Name)=$($_.Count)" }) -join "; ")
        Add-Finding ([ref]$findings) "High" "Drivers" "Graphics driver reset or crash events found" "$($graphicsDriverEvents.Count) graphics-driver event(s). Providers: $providerSummary." "Correlate these timestamps with game crashes and minidumps. Clean-install the GPU driver, update BIOS/chipset, check GPU temperature/power, and test once without overlays or unstable GPU/RAM tuning." -EventRows $graphicsDriverEvents
    }

    $networkEvents = @($allEvents | Where-Object { (Test-EventLevelAtMost $_ 3) -and $_.ProviderName -match 'Tcpip|Dhcp|DNS Client Events|Microsoft-Windows-DNS-Client|NDIS|NetBT|Netwtw|e1|e2f|e2fnexpress' })
    $tcpPortExhaustionEvents = @($allEvents | Where-Object { $_.ProviderName -match 'Tcpip' -and $_.Id -eq '4231' })
    $udpPortExhaustionEvents = @($allEvents | Where-Object { $_.ProviderName -match 'Tcpip' -and $_.Id -eq '4266' })
    $portExhaustionEvents = @($tcpPortExhaustionEvents + $udpPortExhaustionEvents)
    if ($portExhaustionEvents.Count -gt 0) {
        Add-Finding ([ref]$findings) "High" "Network" "TCP/UDP dynamic port exhaustion detected" "$($tcpPortExhaustionEvents.Count) TCP exhaustion event(s) with ID 4231 and $($udpPortExhaustionEvents.Count) UDP exhaustion event(s) with ID 4266." "Review 04_Network\\TCP_Endpoints_By_Process_Top30.csv and 04_Network\\UDP_Endpoints_By_Process_Top30.csv. Identify the process holding many endpoints and check for connection leaks, stuck updates, sync tools, containers, browsers, or remote-access software." -EventRows $portExhaustionEvents
    }

    $nameConflictEvents = @($allEvents | Where-Object { (Test-EventLevelAtMost $_ 3) -and $_.ProviderName -match 'NetBT' -and $_.Id -eq '4321' })
    if ($nameConflictEvents.Count -gt 0) {
        Add-Finding ([ref]$findings) "High" "Network" "Network computer name conflict detected" "$($nameConflictEvents.Count) NetBT 4321 event(s)." "Make sure this PC has a unique computer name on the network. Check cloned Windows installations, stale DHCP/DNS records, and other PCs using the same NetBIOS name." -EventRows $nameConflictEvents
    }

    $hostsCheckRows = @(Read-CsvSafe (Join-Path $Dirs.Network "Hosts_File_Check.csv"))
    $hostsEntryRows = @(Read-CsvSafe (Join-Path $Dirs.Network "Hosts_File_ActiveEntries.csv"))
    $nrptRows = @(Read-CsvSafe (Join-Path $Dirs.Network "DnsClientNrptRule.csv"))
    $hostsCheck = if ($hostsCheckRows.Count -gt 0) { $hostsCheckRows[0] } else { $null }
    if ($null -ne $hostsCheck) {
        $invalidHostLines = ConvertTo-NumberSafe ([string]$hostsCheck.InvalidLineCount)
        $activeHostEntries = ConvertTo-NumberSafe ([string]$hostsCheck.ActiveEntryCount)
        $hostsReadable = [string]$hostsCheck.Readable
        $hostsError = [string]$hostsCheck.Error
        $hostsDetails = @((New-ObjectDetailsText -Rows $hostsCheckRows -Title "Hosts file check"))
        if ($hostsEntryRows.Count -gt 0) {
            $hostsDetails += (New-ObjectDetailsText -Rows $hostsEntryRows -Title "Active hosts file entries")
        }
        if ($nrptRows.Count -gt 0) {
            $hostsDetails += (New-ObjectDetailsText -Rows $nrptRows -Title "DNS Client NRPT rules")
        }

        if (($hostsReadable -match 'False') -or (-not [string]::IsNullOrWhiteSpace($hostsError)) -or ($null -ne $invalidHostLines -and $invalidHostLines -gt 0)) {
            Add-Finding ([ref]$findings) "High" "Network" "Hosts file content or permissions need review" "Hosts file readable=$hostsReadable, invalid lines=$invalidHostLines, error=$hostsError." "Review 04_Network\\Hosts_File_Check.csv and Hosts_File_ActiveEntries.csv. Fix unreadable permissions or malformed active lines before changing DNS/VPN settings." -TimeContext $currentObservation -DetailText ($hostsDetails -join "`r`n`r`n")
        } elseif ($null -ne $activeHostEntries -and $activeHostEntries -ge 5) {
            Add-Finding ([ref]$findings) "Info" "Network" "Hosts file contains multiple active custom mappings" "$activeHostEntries active hosts file mapping(s) were detected." "Review whether these entries are intentional. Stale hosts overrides can break websites, updates, VPN names, and local services." -TimeContext $currentObservation -DetailText ($hostsDetails -join "`r`n`r`n")
        }
    }

    $dnsClientConfigEvents = @($allEvents | Where-Object {
        (Test-EventLevelAtMost $_ 3) -and
        $_.ProviderName -match 'Microsoft-Windows-DNS-Client|DNS Client Events' -and
        $_.Id -in @('1012','1023')
    })
    if ($dnsClientConfigEvents.Count -gt 0) {
        $dnsConfigDetails = @((New-EventDetailsText -Rows $dnsClientConfigEvents))
        $dnsIdSummary = (@($dnsClientConfigEvents | Group-Object Id | Sort-Object Count -Descending | ForEach-Object { "ID $($_.Name)=$($_.Count)" }) -join "; ")
        $dnsEvidence = "$($dnsClientConfigEvents.Count) DNS client event(s) with ID 1012 or 1023."
        if (-not [string]::IsNullOrWhiteSpace($dnsIdSummary)) {
            $dnsEvidence += " Breakdown: $dnsIdSummary."
        }
        if ($hostsCheckRows.Count -gt 0) {
            $dnsConfigDetails += (New-ObjectDetailsText -Rows $hostsCheckRows -Title "Hosts file check")
            $hc = $hostsCheckRows[0]
            $dnsEvidence += " Hosts now readable=$($hc.Readable), active entries=$($hc.ActiveEntryCount), invalid lines=$($hc.InvalidLineCount)."
        }
        if ($hostsEntryRows.Count -gt 0) {
            $dnsConfigDetails += (New-ObjectDetailsText -Rows $hostsEntryRows -Title "Active hosts file entries")
        }
        if ($nrptRows.Count -gt 0) {
            $dnsConfigDetails += (New-ObjectDetailsText -Rows $nrptRows -Title "DNS Client NRPT rules")
            $nrptServers = (@($nrptRows | ForEach-Object { [string]$_.NameServers } | Where-Object { -not [string]::IsNullOrWhiteSpace($_) } | Sort-Object -Unique) -join ", ")
            if (-not [string]::IsNullOrWhiteSpace($nrptServers)) {
                $dnsEvidence += " NRPT rules=$($nrptRows.Count), name servers=$nrptServers."
            } else {
                $dnsEvidence += " NRPT rules=$($nrptRows.Count)."
            }
        }
        Add-Finding ([ref]$findings) "High" "Network" "DNS client hosts or NRPT configuration errors found" $dnsEvidence "If hosts is readable now, treat older 1012 events as a timestamped clue and focus on what changed around them. For 1023 events, review NRPT rules, VPN DNS settings, and DNS filtering tools before deleting anything." -EventRows $dnsClientConfigEvents -DetailText ($dnsConfigDetails -join "`r`n`r`n")
    }

    $dnsTimeEvents = @($allEvents | Where-Object {
        (Test-EventLevelAtMost $_ 3) -and
        (
            ($_.ProviderName -match 'DNS Client Events|Microsoft-Windows-DNS-Client|Time-Service|Microsoft-Windows-Time-Service|NtpClient') -or
            ($_.Message -match 'NtpClient|time provider|time service|DNS|name resolution|could not resolve|No such host')
        )
    })
    if ($dnsTimeEvents.Count -gt 0) {
        Add-Finding ([ref]$findings) "Medium" "Network" "DNS or time synchronization failures found" "$($dnsTimeEvents.Count) matching DNS/time event(s)." "Review DNS servers, DHCP options, local firewall/VPN behavior, and Windows time settings. Time and DNS problems can break updates, logons, certificates, and remote tools." -EventRows $dnsTimeEvents
    }

    $i225LinkEvents = @($allEvents | Where-Object {
        (Test-EventLevelAtMost $_ 3) -and
        $_.ProviderName -match 'e2fnexpress|e2fexpress|e2f' -and
        $_.Id -eq '27' -and
        $_.Message -match 'I225|I226|Ethernet Controller|Network link is disconnected'
    })
    if ($i225LinkEvents.Count -gt 0) {
        $adapterRowsForFinding = @()
        try {
            $adapterRowsForFinding = @(Read-CsvSafe (Join-Path $Dirs.Network "NetAdapters.csv") | Where-Object {
                "$($_.InterfaceDescription) $($_.DriverFileName)" -match 'I225|I226|e2fn|e2f'
            })
        } catch {}
        $detailParts = @()
        $detailParts += (New-EventDetailsText -Rows $i225LinkEvents)
        if ($adapterRowsForFinding.Count -gt 0) {
            $detailParts += (New-ObjectDetailsText -Rows $adapterRowsForFinding -Title "Matching Intel I225/I226 adapter rows")
        }
        Add-Finding ([ref]$findings) "Medium" "Network" "Intel I225/I226 link disconnect events found" "$($i225LinkEvents.Count) link disconnect event(s), usually around boot/shutdown unless timestamps show otherwise." "Update the Intel LAN driver and motherboard firmware if available. If dropouts occur during normal use, review Energy Efficient Ethernet, speed/duplex, cable, switch port, and NIC power/offload settings." -EventRows $i225LinkEvents -DetailText ($detailParts -join "`r`n`r`n")
    }

    if ($networkEvents.Count -gt 0) {
        Add-Finding ([ref]$findings) "Medium" "Network" "Network or NIC driver events found" "$($networkEvents.Count) matching network event(s)." "Check NIC driver/firmware, power saving settings, link speed, switch port, DHCP, and DNS." -EventRows $networkEvents
    }

    $endpointSummary = Read-CsvSafe (Join-Path $Dirs.Network "Endpoint_Summary.csv")
    $tcpTop = Read-CsvSafe (Join-Path $Dirs.Network "TCP_Endpoints_By_Process_Top30.csv")
    $udpTop = Read-CsvSafe (Join-Path $Dirs.Network "UDP_Endpoints_By_Process_Top30.csv")
    $endpointRows = @($tcpTop + $udpTop)
    $endpointTriggers = @()
    foreach ($row in @($endpointSummary)) {
        $total = ConvertTo-NumberSafe ([string]$row.TotalEndpoints)
        $topCount = ConvertTo-NumberSafe ([string]$row.TopProcessCount)
        if (($null -ne $total -and $total -ge 1000) -or ($null -ne $topCount -and $topCount -ge 300)) {
            $endpointTriggers += $row
        }
    }
    if ($endpointTriggers.Count -gt 0) {
        $summaryText = (($endpointSummary | ForEach-Object { "$($_.Protocol): total=$($_.TotalEndpoints), topPID=$($_.TopProcessPID), topCount=$($_.TopProcessCount)" }) -join "; ")
        Add-Finding ([ref]$findings) "Medium" "Network" "High current TCP/UDP endpoint usage" $summaryText "Open the endpoint top lists and inspect the top process names. A high endpoint count can explain intermittent DNS, update, browser, sync, VPN, launcher, or remote-access problems even when Windows is still running." -TimeContext $currentObservation -DetailText (New-ObjectDetailsText -Rows $endpointRows -Title "Current TCP/UDP endpoint counts by process")
    }

    $powerRows = Read-CsvSafe (Join-Path $Dirs.Network "NetAdapterPowerManagement.csv")
    $advancedRows = Read-CsvSafe (Join-Path $Dirs.Network "NetAdapterAdvancedProperties.csv")
    $riskyPowerRows = @($powerRows | Where-Object {
        $text = ($_.PSObject.Properties | ForEach-Object { "$($_.Name)=$($_.Value)" }) -join "; "
        $text -match '(AllowComputerToTurnOffDevice|ArpOffload|NSOffload|WakeOnPattern).*(Enabled|True|Aktiviert|Ein)'
    })
    $riskyAdvancedRows = @($advancedRows | Where-Object {
        $name = "$($_.DisplayName) $($_.RegistryKeyword)"
        $value = [string]$_.DisplayValue
        ($name -match 'Energy.?Efficient|Energieeffizient|Reduce.*Speed|Geschw.*Abschalten|Wake.*Pattern|Pattern.*Match|ARP.*Offload|NS.*Offload|Abladung') -and
        ($value -match 'Enabled|Aktiviert|On|Ein|active|aktiv')
    })
    if (($riskyPowerRows.Count + $riskyAdvancedRows.Count) -gt 0) {
        $nicDetails = @()
        if ($riskyPowerRows.Count -gt 0) { $nicDetails += (New-ObjectDetailsText -Rows $riskyPowerRows -Title "Power management rows to review") }
        if ($riskyAdvancedRows.Count -gt 0) { $nicDetails += (New-ObjectDetailsText -Rows $riskyAdvancedRows -Title "Advanced NIC properties to review") }
        Add-Finding ([ref]$findings) "Info" "Network" "NIC power or offload settings are enabled" "$($riskyPowerRows.Count) power management row(s) and $($riskyAdvancedRows.Count) advanced NIC setting row(s) should be reviewed only if network dropouts or wake issues are part of the complaint." "For normal desktop PCs these settings can be acceptable. Only change them if dropouts, wake-from-sleep problems, or remote-access issues correlate with the timestamps." -TimeContext $currentObservation -DetailText ($nicDetails -join "`r`n`r`n")
    }

    $driverPnpEvents = @($allEvents | Where-Object {
        (Test-EventLevelAtMost $_ 3) -and
        (
            ($_.ProviderName -match 'Kernel-PnP|UserPnp|DeviceSetupManager|DriverFrameworks-UserMode') -or
            ($_.Id -in @('219','411','400','410','430','442'))
        ) -and
        ([string]$_.Message -match '(?i)PCI\\|ACPI\\|HDAUDIO\\|SCSI\\|STORAGE\\|DISPLAY|VEN_|DEV_|NVME|SATA|NVIDIA|AMD|Intel|Realtek|Media|Audio|Controller') -and
        ([string]$_.Message -notmatch '(?i)USB\\|USBSTOR|HID\\|BTH\\|Bluetooth|SWD\\|ROOT\\')
    })
    if ($driverPnpEvents.Count -gt 0) {
        Add-Finding ([ref]$findings) "Medium" "Hardware Migration" "Fixed-hardware driver or device setup events found" "$($driverPnpEvents.Count) fixed-hardware-looking Kernel-PnP, UserPnp, DeviceSetupManager, or DriverFrameworks event(s)." "On a Windows installation moved between hardware, these events can point to old motherboard, GPU, storage controller, network, or audio devices. USB, HID, Bluetooth, and removable peripheral events are intentionally filtered out of this area." -EventRows $driverPnpEvents
    }

    $serviceEvents = @($allEvents | Where-Object {
        (Test-EventLevelAtMost $_ 3) -and
        $_.ProviderName -match 'Service Control Manager' -and
        $_.Id -in @('7000','7001','7009','7011','7022','7023','7024','7031','7032','7034')
    })
    if ($serviceEvents.Count -gt 0) {
        $serviceRows = @($serviceEvents | ForEach-Object {
            [PSCustomObject]@{
                TimeCreated = $_.TimeCreated
                EventId = $_.Id
                Service = Get-ServiceNameFromEventMessage -Message ([string]$_.Message)
                Signal = if ([string]$_.Id -eq '7011') { "Service timeout" } elseif ([string]$_.Id -in @('7031','7034')) { "Service crash/terminated" } elseif ([string]$_.Id -in @('7000','7001','7009')) { "Service start failure" } else { "Service control event" }
            }
        })
        $serviceSummary = New-TopCountSummary -Rows $serviceRows -PropertyName "Service" -MaxItems 8
        $signalSummary = New-TopCountSummary -Rows $serviceRows -PropertyName "Signal" -MaxItems 5
        $serviceEvidence = "$($serviceEvents.Count) Service Control Manager event(s). Top services: $serviceSummary. Signals: $signalSummary."
        $serviceRecommendation = "Start with the repeated service summary. Repair/update the named application or driver package, then disable or uninstall it only if the timestamps match real symptoms."
        if ($serviceSummary -match '(?i)Armoury|ASUS|AURA|ROG') {
            $serviceRecommendation = "ASUS/Armoury-related services are prominent. Update or repair Armoury Crate/MyASUS/Aura components, then retest. If they still time out or crash, remove unused ASUS utilities deliberately rather than chasing every single service event."
        } elseif ($serviceSummary -match '(?i)Steam') {
            $serviceRecommendation = "Steam service failures are prominent. Repair or reinstall the Steam Client Service, verify Steam starts cleanly, and correlate with gaming/runtime events."
        } elseif ($serviceSummary -match '(?i)WireGuard|Tailscale|OpenVPN|Surfshark') {
            $serviceRecommendation = "VPN service failures are prominent. Update or repair the VPN client and check whether network symptoms match these timestamps."
        }
        $serviceDetails = @()
        $serviceDetails += (New-ObjectDetailsText -Rows $serviceRows -Title "Service event summary rows")
        $serviceDetails += (New-EventDetailsText -Rows $serviceEvents)
        Add-Finding ([ref]$findings) "Medium" "Services" "Service errors or crashes found" $serviceEvidence $serviceRecommendation -EventRows $serviceEvents -DetailText ($serviceDetails -join "`r`n`r`n")
    }

    $lowLevelDriverEvents = @($allEvents | Where-Object {
        ($_.ProviderName -match 'Service Control Manager') -and
        ($_.Message -match 'inpout|WinRing|WinRing0|IOMap|OpenLibSys|inpoutx64')
    })
    if ($lowLevelDriverEvents.Count -gt 0) {
        $lowLevelErrorEvents = @($lowLevelDriverEvents | Where-Object { (Test-EventLevelAtMost $_ 3) -or $_.Id -in @('7000','7001','7009','7011','7022','7023','7024','7026','7031','7032','7034') })
        $driverSeverity = if ($lowLevelErrorEvents.Count -gt 0) { "Medium" } else { "Info" }
        Add-Finding ([ref]$findings) $driverSeverity "Drivers" "Low-level hardware access driver issue detected" "$($lowLevelDriverEvents.Count) event(s) mention inpout, WinRing0, or similar low-level drivers; $($lowLevelErrorEvents.Count) look like start/failure events." "Identify the related monitoring, RGB, fan-control, benchmark, or overclocking tool. Update or remove it if the service repeatedly fails or if instability correlates with these timestamps." -EventRows $lowLevelDriverEvents
    }

    $driverUtilityPattern = '(?i)\bnvcontainer\.exe\b|NvBackend64\.dll|NvUI\.dll|NVIDIA Corporation|NVIDIA App|GeForce Experience|NVIDIA Share|\bAMDADLXServ\.exe\b|amdadlx|RadeonSoftware|AMDRSServ|ArmouryCrate|Armoury Crate|ASUSSystemAnalysis|AURA|AcPowerNotification|ROGLiveService|ROG Live Service|GlideX|MyASUS'
    $driverUtilityEvents = @($allEvents | Where-Object {
        (Test-EventLevelAtMost $_ 3) -and
        (
            ([string]$_.ProviderName -match 'Application Error|Application Hang') -or
            ([string]$_.Id -in @('1000','1002'))
        ) -and
        ([string]$_.Message -match $driverUtilityPattern)
    })
    if ($driverUtilityEvents.Count -gt 0) {
        $driverUtilityRows = @($driverUtilityEvents | ForEach-Object {
            $crashInfo = Get-AppCrashInfoFromMessage -Message ([string]$_.Message)
            $vendor = "Driver utility"
            $signal = "Application crash/hang"
            if ([string]$_.Message -match '(?i)NVIDIA|nvcontainer|NvBackend|NvUI|GeForce') { $vendor = "NVIDIA" }
            elseif ([string]$_.Message -match '(?i)AMD|Radeon|amdadlx|AMDRS') { $vendor = "AMD" }
            elseif ([string]$_.Message -match '(?i)ASUS|Armoury|AURA|ROG|GlideX|MyASUS|AcPowerNotification') { $vendor = "ASUS" }
            if ([string]$_.ProviderName -match 'Application Hang' -or [string]$_.Id -eq '1002') { $signal = "Application hang" }
            [PSCustomObject]@{
                TimeCreated = $_.TimeCreated
                Source = $_.ProviderName
                EventId = $_.Id
                Vendor = $vendor
                Signal = $signal
                FaultingApplication = $crashInfo.FaultingApplication
                FaultingModule = $crashInfo.FaultingModule
                ExceptionCode = $crashInfo.ExceptionCode
                ApplicationPath = $crashInfo.ApplicationPath
            }
        })
        $vendorSummary = New-TopCountSummary -Rows $driverUtilityRows -PropertyName "Vendor" -MaxItems 5
        $appSummary = New-TopCountSummary -Rows $driverUtilityRows -PropertyName "FaultingApplication" -MaxItems 8
        $moduleSummary = New-TopCountSummary -Rows $driverUtilityRows -PropertyName "FaultingModule" -MaxItems 8
        $driverDetails = @()
        $driverDetails += (New-ObjectDetailsText -Rows $driverUtilityRows -Title "Driver utility crash summary rows")
        $driverDetails += (New-EventDetailsText -Rows $driverUtilityEvents)
        Add-Finding ([ref]$findings) "Medium" "Drivers" "GPU or vendor utility crashes found" "$($driverUtilityEvents.Count) driver/vendor utility crash or hang event(s). Vendors: $vendorSummary. Apps: $appSummary. Modules: $moduleSummary." "Update or repair the affected GPU/vendor utility stack. For repeated NVIDIA crashes, clean-install the NVIDIA driver/App and test without overlays. For ASUS/Armoury crashes, update or repair Armoury Crate/MyASUS/Aura components or remove unused utilities." -EventRows $driverUtilityEvents -DetailText ($driverDetails -join "`r`n`r`n")
    }

    $cs2Events = @($allEvents | Where-Object {
        (Test-EventLevelAtMost $_ 3) -and
        (
            ($_.ProviderName -match 'Application Error|Application Hang') -or
            ($_.Id -in @('1000','1002'))
        ) -and
        ($_.Message -match '(?i)\bcs2\.exe\b|Counter-Strike')
    })
    if ($cs2Events.Count -gt 0) {
        $cs2WerRows = @($werReports | Where-Object {
            "$($_.AppName) $($_.ApplicationPath) $($_.ReportPath) $($_.FaultModule)" -match '(?i)\bcs2\.exe\b|Counter-Strike'
        })
        $cs2Rows = @($cs2Events | ForEach-Object {
            $cs2EventRow = $_
            $message = [string]$cs2EventRow.Message
            $crashInfo = Get-AppCrashInfoFromMessage -Message $message
            $matchingWer = $null
            if (-not [string]::IsNullOrWhiteSpace([string]$crashInfo.ReportId)) {
                $matchingWer = $cs2WerRows |
                    Where-Object {
                        [string]$_.EventReportId -eq [string]$crashInfo.ReportId -or
                        [string]$_.ReportIdentifier -eq [string]$crashInfo.ReportId
                    } |
                    Select-Object -First 1
            }
            if ($null -eq $matchingWer) {
                $eventTimeForWer = ConvertTo-DateTimeSafe ([string]$cs2EventRow.TimeCreated)
                if ($null -ne $eventTimeForWer) {
                    $matchingWer = $cs2WerRows |
                        Where-Object {
                            $werTime = ConvertTo-DateTimeSafe ([string]$_.LastWriteTime)
                            $null -ne $werTime -and [math]::Abs(($werTime - $eventTimeForWer).TotalDays) -le 2
                        } |
                        Select-Object -First 1
                }
            }

            $eventException = [string]$crashInfo.ExceptionCode
            $werException = [string]$matchingWer.ExceptionCode
            $isAccessViolation = ($eventException -match '(?i)0x?c0000005') -or ($werException -match '(?i)0x?c0000005')
            $hasWerStackHash = [string]$matchingWer.FaultModule -match '(?i)^StackHash'
            $hasWerNtdllOffset = [string]$matchingWer.ExceptionOffset -match '(?i)ntdll'

            $eventTime = ConvertTo-DateTimeSafe ([string]$cs2EventRow.TimeCreated)
            $directSignalText = "No direct GPU reset, WHEA, disk I/O, BugCheck, or hard-reset event within +/-60 seconds."
            $nearbySignalText = "No GPU reset, WHEA, disk I/O, BugCheck, or hard-reset event within +/-10 minutes."
            if ($null -ne $eventTime) {
                $signalEvents = @($allEvents | Where-Object {
                    $signalTime = ConvertTo-DateTimeSafe ([string]$_.TimeCreated)
                    $null -ne $signalTime -and
                    -not (
                        [string]$_.ProviderName -eq [string]$cs2EventRow.ProviderName -and
                        [string]$_.Id -eq [string]$cs2EventRow.Id -and
                        [string]$_.TimeCreated -eq [string]$cs2EventRow.TimeCreated
                    ) -and
                    (
                        [string]$_.ProviderName -match '(?i)WHEA|Display|nvlddmkm|amdkmdag|amdwddmg|disk|ntfs|stornvme|storahci|BugCheck|Kernel-Power|EventLog' -or
                        [string]$_.Id -in @('41','51','55','98','129','153','4101','6008')
                    )
                })
                $directSignals = @($signalEvents | Where-Object {
                    $signalTime = ConvertTo-DateTimeSafe ([string]$_.TimeCreated)
                    $null -ne $signalTime -and [math]::Abs(($signalTime - $eventTime).TotalSeconds) -le 60
                })
                $nearbySignals = @($signalEvents | Where-Object {
                    $signalTime = ConvertTo-DateTimeSafe ([string]$_.TimeCreated)
                    $null -ne $signalTime -and [math]::Abs(($signalTime - $eventTime).TotalMinutes) -le 10
                })
                if ($directSignals.Count -gt 0) {
                    $directSignalText = (@($directSignals |
                        Group-Object { "$($_.ProviderName) $($_.Id)" } |
                        Sort-Object Count -Descending |
                        Select-Object -First 6 |
                        ForEach-Object { "$($_.Name)=$($_.Count)" }) -join "; ")
                }
                if ($nearbySignals.Count -gt 0) {
                    $nearbySignalText = "Within +/-10 minutes: " + (@($nearbySignals |
                        Group-Object { "$($_.ProviderName) $($_.Id)" } |
                        Sort-Object Count -Descending |
                        Select-Object -First 8 |
                        ForEach-Object { "$($_.Name)=$($_.Count)" }) -join "; ")
                    if ($nearbySignalText -match '(?i)Kernel-Power|EventLog 6008') {
                        $nearbySignalText += ". A later hard reset is a separate stability signal unless it has the same timestamp as the CS2 crash."
                    }
                }
            }

            $meaning = "Windows captured a user-mode CS2 crash."
            if ($isAccessViolation) {
                $meaning = "User-mode access violation: CS2 tried to read or execute invalid memory. This is not a blue screen by itself. Common game causes are overlay/hook conflicts, graphics user-mode driver issues, corrupted game/cache files, unstable RAM/GPU settings, or a game-side bug."
            }
            if ([string]$crashInfo.FaultingModule -match '^(unknown)?$' -or [string]::IsNullOrWhiteSpace([string]$crashInfo.FaultingModule)) {
                $meaning += " Event Viewer could not identify the faulting module, so WER/local dumps are needed for a deeper culprit."
            } elseif ([string]$crashInfo.FaultingModule -match 'scenesystem\.dll') {
                $meaning += " scenesystem.dll is part of the CS2 rendering/scene stack."
            }
            if ($null -ne $matchingWer) {
                $meaning += " WER was matched to this Event Viewer crash by Report ID or timestamp."
                if ([string]$matchingWer.EventType -match '(?i)^BEX' -or $hasWerStackHash -or $hasWerNtdllOffset) {
                    $meaning += " BEX64/StackHash/ntdll is a crash classification or final Windows runtime location, not proof that StackHash or ntdll caused the crash."
                }
                if (-not [string]::IsNullOrWhiteSpace([string]$matchingWer.LoadedModuleHints)) {
                    $meaning += " Loaded context: $($matchingWer.LoadedModuleHints)."
                }
            }

            $werReportFile = ""
            if ($null -ne $matchingWer) {
                $werReportFile = if (-not [string]::IsNullOrWhiteSpace([string]$matchingWer.PackagePath)) { [string]$matchingWer.PackagePath } else { [string]$matchingWer.ReportPath }
            }
            [PSCustomObject]@{
                TimeCreated          = $cs2EventRow.TimeCreated
                Source               = $cs2EventRow.ProviderName
                EventId              = $cs2EventRow.Id
                CrashType            = if ($isAccessViolation) { "User-mode access violation" } else { "User-mode application crash" }
                FaultingApplication  = $crashInfo.FaultingApplication
                FaultingModule       = $crashInfo.FaultingModule
                FaultingModulePath   = $crashInfo.FaultingModulePath
                ExceptionCode        = $crashInfo.ExceptionCode
                FaultOffset          = $crashInfo.FaultOffset
                ReportId             = $crashInfo.ReportId
                MatchedWerReport     = if ($null -ne $matchingWer) { "Yes" } else { "No" }
                WerEventType         = [string]$matchingWer.EventType
                WerFaultModule       = [string]$matchingWer.FaultModule
                WerExceptionCode     = [string]$matchingWer.ExceptionCode
                WerExceptionOffset   = [string]$matchingWer.ExceptionOffset
                WerLoadedHints       = [string]$matchingWer.LoadedModuleHints
                WerReportFile        = $werReportFile
                DirectSystemSignals  = $directSignalText
                NearbySystemSignals  = $nearbySignalText
                ApplicationPath      = $crashInfo.ApplicationPath
                Interpretation       = $meaning
            }
        })
        $moduleSummary = (@($cs2Rows | Where-Object { -not [string]::IsNullOrWhiteSpace([string]$_.FaultingModule) } | Group-Object FaultingModule | Sort-Object Count -Descending | ForEach-Object { "$($_.Name)=$($_.Count)" }) -join "; ")
        $exceptionSummary = (@($cs2Rows | Where-Object { -not [string]::IsNullOrWhiteSpace([string]$_.ExceptionCode) } | Group-Object ExceptionCode | Sort-Object Count -Descending | ForEach-Object { "$($_.Name)=$($_.Count)" }) -join "; ")
        $offsetSummary = (@($cs2Rows | Where-Object { -not [string]::IsNullOrWhiteSpace([string]$_.FaultOffset) } | Group-Object FaultOffset | Sort-Object Count -Descending | ForEach-Object { "$($_.Name)=$($_.Count)" }) -join "; ")
        if ([string]::IsNullOrWhiteSpace($moduleSummary)) { $moduleSummary = "not captured" }
        if ([string]::IsNullOrWhiteSpace($exceptionSummary)) { $exceptionSummary = "not captured" }
        if ([string]::IsNullOrWhiteSpace($offsetSummary)) { $offsetSummary = "not captured" }
        $hasSceneSystem = $cs2Rows | Where-Object { [string]$_.FaultingModule -match 'scenesystem\.dll' } | Select-Object -First 1
        $hasAccessViolation = $cs2Rows | Where-Object { [string]$_.ExceptionCode -match '(?i)0x?c0000005' -or [string]$_.WerExceptionCode -match '(?i)0x?c0000005' } | Select-Object -First 1
        $hasUnknownModule = $cs2Rows | Where-Object { [string]$_.FaultingModule -match '^(unknown)?$' -or [string]::IsNullOrWhiteSpace([string]$_.FaultingModule) } | Select-Object -First 1
        $werEventTypeSummary = New-TopCountSummary -Rows $cs2WerRows -PropertyName "EventType" -MaxItems 5
        $werFaultModuleSummary = New-TopCountSummary -Rows $cs2WerRows -PropertyName "FaultModule" -MaxItems 5
        $werExceptionSummary = New-TopCountSummary -Rows $cs2WerRows -PropertyName "ExceptionCode" -MaxItems 5
        $werOffsetSummary = New-TopCountSummary -Rows $cs2WerRows -PropertyName "ExceptionOffset" -MaxItems 5
        $werLoadedHintsSummary = New-TopCountSummary -Rows $cs2WerRows -PropertyName "LoadedModuleHints" -MaxItems 5
        $hasWerBexStackHash = $cs2WerRows | Where-Object {
            [string]$_.EventType -match '(?i)^BEX' -or [string]$_.FaultModule -match '(?i)^StackHash'
        } | Select-Object -First 1
        $steamCrashEvents = @($allEvents | Where-Object {
            (Test-EventLevelAtMost $_ 3) -and
            ([string]$_.ProviderName -match 'Application Error|Application Hang') -and
            ([string]$_.Message -match '(?i)steamwebhelper\.exe|steam\.exe|Steam')
        })
        $nearbyEvents = @()
        foreach ($cs2Event in $cs2Events) {
            $cs2Time = ConvertTo-DateTimeSafe ([string]$cs2Event.TimeCreated)
            if ($null -eq $cs2Time) { continue }
            $nearbyEvents += @($allEvents | Where-Object {
                $eventTime = ConvertTo-DateTimeSafe ([string]$_.TimeCreated)
                $null -ne $eventTime -and
                [math]::Abs(($eventTime - $cs2Time).TotalMinutes) -le 10 -and
                -not (
                    [string]$_.ProviderName -eq [string]$cs2Event.ProviderName -and
                    [string]$_.Id -eq [string]$cs2Event.Id -and
                    [string]$_.TimeCreated -eq [string]$cs2Event.TimeCreated
                )
            })
        }
        $nearbyEvents = @($nearbyEvents |
            Group-Object { "$($_.TimeCreated)|$($_.ProviderName)|$($_.Id)|$($_.Message)" } |
            ForEach-Object { $_.Group[0] } |
            Sort-Object @{ Expression = { ConvertTo-DateTimeSafe ([string]$_.TimeCreated) }; Descending = $true } |
            Select-Object -First 30)

        $evidenceParts = @("$($cs2Events.Count) CS2 Application Error/Hang event(s)", "Modules: $moduleSummary", "Exception codes: $exceptionSummary", "Fault offsets: $offsetSummary")
        if ($cs2WerRows.Count -gt 0) {
            $evidenceParts += "$($cs2WerRows.Count) matching Windows Error Reporting row(s)"
            if (-not [string]::IsNullOrWhiteSpace($werEventTypeSummary)) { $evidenceParts += "WER event types: $werEventTypeSummary" }
            if (-not [string]::IsNullOrWhiteSpace($werFaultModuleSummary)) { $evidenceParts += "WER fault modules: $werFaultModuleSummary" }
            if (-not [string]::IsNullOrWhiteSpace($werExceptionSummary)) { $evidenceParts += "WER exception codes: $werExceptionSummary" }
            if (-not [string]::IsNullOrWhiteSpace($werOffsetSummary)) { $evidenceParts += "WER exception offsets: $werOffsetSummary" }
            if (-not [string]::IsNullOrWhiteSpace($werLoadedHintsSummary)) { $evidenceParts += "WER loaded module hints: $werLoadedHintsSummary" }
        }
        if ($basicDisplayRows.Count -gt 0) { $evidenceParts += "Microsoft Basic Display Driver is present" }
        if ($steamCrashEvents.Count -gt 0) { $evidenceParts += "$($steamCrashEvents.Count) Steam crash/hang event(s) also captured" }

        $recommendation = "In Steam, verify Counter-Strike 2 game files. Then test once with launch options, autoexec/custom config, overlays, capture tools, and third-party injectors disabled. Update or clean-install the GPU driver and retest with GPU/RAM overclocking or XMP/EXPO disabled if the crashes repeat."
        if ($basicDisplayRows.Count -gt 0) {
            $recommendation = "Install the correct GPU driver first. This report shows Microsoft Basic Display Driver, which is not a usable gaming driver for CS2. After installing the NVIDIA/AMD/Intel/OEM driver, reboot, verify Steam game files, and retest without overlays or launch options."
        } elseif ($hasWerBexStackHash -and $hasAccessViolation) {
            $recommendation = "WER classifies the CS2 crash as BEX/StackHash with access violation. This does not prove one CS2 DLL. First test once with Steam, Xbox Game Bar, Discord, NVIDIA, RTSS/MSI Afterburner, and other overlays/hooks disabled, with no launch options or custom config. Then verify CS2 files, clear shader cache, clean-install the GPU driver if it repeats, and capture a LocalDump for the exact stack."
        } elseif ($hasUnknownModule -and $hasAccessViolation) {
            $recommendation = "CS2 crashed with 0xc0000005, but Event Viewer reports the faulting module as unknown. Verify game files, disable overlays/injectors and launch options for one test, clean-install the GPU driver, and use the WER details or a LocalDumps capture if it repeats because Event Viewer alone cannot name the culprit."
        }
        if ($hasSceneSystem -and $hasAccessViolation) {
            $recommendation = "CS2 is crashing in scenesystem.dll with 0xc0000005, an access violation. Verify game files in Steam, remove launch options/autoexec/custom configs for one test, disable overlays/capture tools, update or clean-install the GPU driver, clear shader cache, and test without GPU/RAM overclocking or XMP/EXPO if it repeats."
        }
        $cs2Interpretation = @"
CS2 interpretation:

- cs2.exe is the Counter-Strike 2 game process.
- scenesystem.dll is part of the game/client rendering and scene stack.
- 0xc0000005 means access violation. For games this is often caused by corrupted game files, overlays/injectors, graphics driver issues, shader/cache problems, unstable RAM/GPU settings, or a game-side bug.
- Faulting module "unknown" means Event Viewer did not receive a precise module name. WER reports or LocalDumps are the next useful source for this kind of user-mode crash.
- WER BEX64/StackHash/ntdll points to a crash classification or final Windows runtime location, not a trustworthy single culprit DLL.
- Loaded module hints such as Steam overlay, NVIDIA user-mode graphics modules, AMD AGS, or CS2 render modules are context for testing; they do not prove that one of those modules caused the crash.
- Direct system-signal rows show whether a GPU reset, WHEA, disk I/O, BugCheck, or hard-reset event was captured at the same time. A later Kernel-Power/EventLog 6008 entry should be treated as a separate stability clue unless it shares the same timestamp.
- If the timestamps line up with driver resets, WHEA, disk errors, or high storage temperature in this report, prioritize those system findings too.
"@
        $detailParts = @()
        $detailParts += (New-EventDetailsText -Rows $cs2Events)
        $detailParts += (New-ObjectDetailsText -Rows $cs2Rows -Title "CS2 crash summary rows")
        if ($cs2WerRows.Count -gt 0) {
            $detailParts += (New-ObjectDetailsText -Rows $cs2WerRows -Title "Windows Error Reporting rows for CS2")
        } else {
            $detailParts += "Windows Error Reporting rows for CS2: 0`r`nNo matching Report.wer file was collected. If the crash repeats, enable Windows Error Reporting LocalDumps for cs2.exe or preserve the WER report before cleanup."
        }
        $detailParts += @"
Optional CS2 LocalDump setup commands (not run by PCDiagLite):

mkdir C:\Dumps
reg add "HKLM\SOFTWARE\Microsoft\Windows\Windows Error Reporting\LocalDumps\cs2.exe" /v DumpFolder /t REG_EXPAND_SZ /d "C:\Dumps" /f
reg add "HKLM\SOFTWARE\Microsoft\Windows\Windows Error Reporting\LocalDumps\cs2.exe" /v DumpCount /t REG_DWORD /d 5 /f
reg add "HKLM\SOFTWARE\Microsoft\Windows\Windows Error Reporting\LocalDumps\cs2.exe" /v DumpType /t REG_DWORD /d 2 /f

After the next crash, collect the new .dmp from C:\Dumps. Full user-mode dumps can be large, so PCDiagLite does not enable this automatically.
"@.Trim()
        if ($basicDisplayRows.Count -gt 0) {
            $detailParts += (New-ObjectDetailsText -Rows $basicDisplayRows -Title "Display driver rows connected to this finding")
        }
        if ($steamCrashEvents.Count -gt 0) {
            $steamCrashRows = @($steamCrashEvents | Select-Object -First 12 | ForEach-Object {
                $steamInfo = Get-AppCrashInfoFromMessage -Message ([string]$_.Message)
                [PSCustomObject]@{
                    TimeCreated = $_.TimeCreated
                    Source = $_.ProviderName
                    EventId = $_.Id
                    FaultingApplication = $steamInfo.FaultingApplication
                    FaultingModule = $steamInfo.FaultingModule
                    ExceptionCode = $steamInfo.ExceptionCode
                    ApplicationPath = $steamInfo.ApplicationPath
                }
            })
            $detailParts += (New-ObjectDetailsText -Rows $steamCrashRows -Title "Steam crash or hang context rows")
        }
        if ($nearbyEvents.Count -gt 0) {
            $detailParts += (New-EventDetailsText -Rows $nearbyEvents)
        }
        $detailParts += $cs2Interpretation.Trim()
        Add-Finding ([ref]$findings) "Medium" "Games" "Counter-Strike 2 crashes detected" (($evidenceParts -join ". ") + ".") $recommendation -EventRows $cs2Events -DetailText ($detailParts -join "`r`n`r`n")
    }

    $gamingPattern = '(?i)GameBar|Gaming\.GameBar|Xbox|XboxGame|XboxGames|GamingServices|GamingServicesNet|GameInput|GameDVR|GameOverlay|\bSteam\b|steam\.exe|steamapps\\common|EpicGamesLauncher|Epic Games|Battle\.net|RiotClient|Riot Games|EasyAntiCheat|EAC|BattlEye|EA app|EADesktop|EA Games|Ubisoft|Ubisoft Game Launcher|GOG Galaxy|DiscordHook|RTSS|RivaTuner|Overwolf|NVIDIA Share|nvcontainer|AMDRSServ|RadeonSoftware|Counter-Strike|cs2\.exe|FortniteClient|League of Legends|VALORANT|RocketLeague|Minecraft|Roblox|EscapeFromTarkov|Cyberpunk2077|GTA5|cod\.exe|ModernWarfare|Warzone'
    $nonGamingAppPattern = '(?i)\bMSTeams\b|MSTeams_|Microsoft Teams|\bTeams\.exe\b|MicrosoftTeams|Teams_'
    $gamingRelatedEvents = @($allEvents | Where-Object {
        (Test-EventLevelAtMost $_ 3) -and
        (
            ([string]$_.ProviderName -match 'DistributedCOM|Application Error|Application Hang|Service Control Manager|AppModel-Runtime|AppXDeployment|Store|GamingServices|GameInput') -or
            ([string]$_.Id -in @('1000','1001','1002','10010','5973','7000','7001','7009','7011','7022','7023','7024','7031','7032','7034'))
        ) -and
        ([string]$_.Message -match $gamingPattern) -and
        ([string]$_.Message -notmatch $nonGamingAppPattern) -and
        ([string]$_.Message -notmatch $driverUtilityPattern) -and
        ([string]$_.Message -notmatch '(?i)\bcs2\.exe\b|Counter-Strike')
    })
    if ($gamingRelatedEvents.Count -gt 0) {
        $gamingRows = @($gamingRelatedEvents | ForEach-Object {
            $message = [string]$_.Message
            $faultingApp = ""
            $faultingModule = ""
            $exceptionCode = ""
            $appPath = ""
            if ($message -match '(?im)(?:Faulting application name|Name der fehlerhaften Anwendung|Fehlerhafter Anwendungsname):\s*([^,\r\n]+)') { $faultingApp = $matches[1].Trim() }
            if ($message -match '(?im)(?:Faulting module name|Name des fehlerhaften Moduls|Fehlerhafter Modulname):\s*([^,\r\n]+)') { $faultingModule = $matches[1].Trim() }
            if ($message -match '(?im)(?:Exception code|Ausnahmecode):\s*(0x[0-9a-f]+)') { $exceptionCode = $matches[1].Trim() }
            if ($message -match '(?im)(?:Faulting application path|Pfad der fehlerhaften Anwendung|Fehlerhafter Anwendungspfad):\s*([^\r\n]+)') { $appPath = $matches[1].Trim() }

            $component = "Gaming component"
            $componentType = "Gaming platform"
            $signal = "Gaming-related event"
            if ($message -match '(?i)Windows\.Gaming\.GameBar|GameBar') { $component = "Xbox Game Bar" }
            elseif ($message -match '(?i)GamingServices') { $component = "Microsoft Gaming Services" }
            elseif ($message -match '(?i)GameInput') { $component = "Microsoft GameInput" }
            elseif ($message -match '(?i)Steam') { $component = "Steam" }
            elseif ($message -match '(?i)EpicGamesLauncher') { $component = "Epic Games Launcher" }
            elseif ($message -match '(?i)Battle\.net') { $component = "Battle.net" }
            elseif ($message -match '(?i)RiotClient|Riot Games') { $component = "Riot Client" }
            elseif ($message -match '(?i)Ubisoft') { $component = "Ubisoft Connect" }
            elseif ($message -match '(?i)GOG Galaxy') { $component = "GOG Galaxy" }
            elseif ($message -match '(?i)EA app|EADesktop|EA Games') { $component = "EA app" }
            elseif ($message -match '(?i)EasyAntiCheat') { $component = "Easy Anti-Cheat" }
            elseif ($message -match '(?i)BattlEye') { $component = "BattlEye" }
            elseif ($message -match '(?i)Discord|RTSS|RivaTuner|Overwolf|NVIDIA Share|AMDRSServ|RadeonSoftware') { $component = "Overlay or capture tool" }
            elseif (-not [string]::IsNullOrWhiteSpace($faultingApp)) { $component = $faultingApp }

            if ($component -match 'Easy Anti-Cheat|BattlEye') { $componentType = "Anti-cheat" }
            elseif ($component -match 'Overlay|Game Bar|Discord|RTSS|RivaTuner|Overwolf|NVIDIA Share|Radeon') { $componentType = "Overlay / capture" }
            elseif ($component -match 'Steam|Epic|Battle\.net|Riot|Ubisoft|GOG|EA app') { $componentType = "Launcher / store" }
            elseif ($component -match 'Gaming Services|GameInput') { $componentType = "Windows gaming runtime" }
            elseif ($message -match '(?i)steamapps\\common|XboxGames|Epic Games|Riot Games|EA Games|Ubisoft Game Launcher|GOG Galaxy' -or $faultingApp -match '\.exe$') { $componentType = "Game process" }

            if ($_.ProviderName -match 'Application Error' -or [string]$_.Id -eq '1000') { $signal = "Application crash" }
            elseif ($_.ProviderName -match 'Application Hang' -or [string]$_.Id -eq '1002') { $signal = "Application hang" }
            elseif ($_.ProviderName -match 'DistributedCOM' -or [string]$_.Id -eq '10010') { $signal = "COM/DCOM timeout" }
            elseif ($_.ProviderName -match 'Service Control Manager' -or [string]$_.Id -match '^70') { $signal = "Service failure or timeout" }
            elseif ($_.ProviderName -match 'AppModel|AppX|Store' -or [string]$_.Id -eq '5973') { $signal = "Store/AppX runtime issue" }

            $detail = ""
            if ($message -match '(?i)PresenceServer|PresenceWriter') { $detail = "Presence writer did not register with DCOM in time." }
            elseif ($message -match '(?i)timeout|Zeitüberschreitung|did not register with DCOM') { $detail = "Startup/COM registration timeout." }
            elseif ($message -match '(?im)(?:Faulting application name|Name der fehlerhaften Anwendung|Fehlerhafter Anwendungsname):\s*([^,\r\n]+)') { $detail = "Faulting application: $($matches[1].Trim())" }
            elseif ($message -match '(?im)(?:Faulting module name|Name des fehlerhaften Moduls|Fehlerhafter Modulname):\s*([^,\r\n]+)') { $detail = "Faulting module: $($matches[1].Trim())" }
            if (-not [string]::IsNullOrWhiteSpace($exceptionCode)) {
                if (-not [string]::IsNullOrWhiteSpace($detail)) { $detail += " " }
                $detail += "Exception: $exceptionCode."
            }

            [PSCustomObject]@{
                TimeCreated = $_.TimeCreated
                Source = $_.ProviderName
                EventId = $_.Id
                Component = $component
                ComponentType = $componentType
                Signal = $signal
                FaultingApplication = $faultingApp
                FaultingModule = $faultingModule
                ExceptionCode = $exceptionCode
                ApplicationPath = $appPath
                Detail = $detail
            }
        })

        $componentSummary = (@($gamingRows | Group-Object Component | Sort-Object Count -Descending | ForEach-Object { "$($_.Name)=$($_.Count)" }) -join "; ")
        $signalSummary = (@($gamingRows | Group-Object Signal | Sort-Object Count -Descending | ForEach-Object { "$($_.Name)=$($_.Count)" }) -join "; ")
        $gameBarEvents = @($gamingRows | Where-Object { [string]$_.Component -eq "Xbox Game Bar" })
        $crashEvents = @($gamingRows | Where-Object { [string]$_.Signal -match 'Application crash|Application hang' })
        $antiCheatEvents = @($gamingRows | Where-Object { [string]$_.ComponentType -eq "Anti-cheat" })
        $serviceEventsForGames = @($gamingRows | Where-Object { [string]$_.Signal -match 'Service failure|Store/AppX runtime' })
        $overlayEvents = @($gamingRows | Where-Object { [string]$_.ComponentType -eq "Overlay / capture" })
        $gamingSeverity = if (($crashEvents.Count + $antiCheatEvents.Count + $serviceEventsForGames.Count) -gt 0) { "Medium" } else { "Info" }
        $recommendation = "Review the affected gaming component. Update or repair the related app, disable overlays/capture tools for one test, and correlate the timestamps with game crashes, GPU driver resets, DCOM timeouts, or Store/AppX issues."
        if ($crashEvents.Count -gt 0) {
            $recommendation = "One or more gaming-related applications crashed or hung. Verify the affected game files, remove launch options/mods for one test, disable overlays/injectors, update or clean-install the GPU driver, clear shader cache, and test RAM/GPU stability if crashes repeat."
        } elseif ($antiCheatEvents.Count -gt 0) {
            $recommendation = "Anti-cheat related events were found. Repair the game launcher, reinstall or repair the anti-cheat component from the game's install folder, remove conflicting overlays/injectors, and check Windows security or virtualization features if the game refuses to start."
        } elseif ($serviceEventsForGames.Count -gt 0) {
            $recommendation = "Gaming runtime or launcher services reported failures/timeouts. Repair Gaming Services, GameInput, Xbox app, or the affected launcher, then reboot and retest the game launch."
        } elseif ($overlayEvents.Count -gt 0) {
            $recommendation = "Overlay or capture related events were found. Test once with Game Bar, Discord overlay, Steam overlay, RTSS/RivaTuner, GeForce/Radeon overlay, and capture tools disabled."
        } elseif ($gameBarEvents.Count -gt 0) {
            $recommendation = "Xbox Game Bar / Game Bar Presence had timeout or registration errors. If gaming, capture, party chat, or overlays are affected, repair or reset Xbox Game Bar and Gaming Services, update Xbox app components from Microsoft Store, and test once with Game Bar overlay/capture disabled."
        }

        $gamingInterpretation = @"
Gaming interpretation:

- Xbox Game Bar PresenceServer/PresenceWriter DCOM 10010 usually means a Game Bar background component did not register in time.
- One isolated entry is often not critical. Repeated entries around game launch, capture, overlay, party chat, or crashes are more relevant.
- Game crashes/hangs point first to game files, mods/configs, overlays/injectors, GPU driver/shader cache, and RAM/GPU stability.
- Anti-cheat errors often involve corrupted anti-cheat installs, blocked drivers, virtualization/security features, or overlay/injector conflicts.
- Common next checks: Xbox Game Bar repair/reset, Gaming Services repair, Microsoft Store updates, overlay/capture tools, GPU driver stability, and game-specific crash events at the same timestamps.
"@
        $detailParts = @()
        $detailParts += (New-EventDetailsText -Rows $gamingRelatedEvents)
        $detailParts += (New-ObjectDetailsText -Rows $gamingRows -Title "Gaming-related event summary rows")
        $detailParts += $gamingInterpretation.Trim()
        Add-Finding ([ref]$findings) $gamingSeverity "Games" "Gaming-related errors, crashes, or runtime events found" "$($gamingRelatedEvents.Count) gaming-related event(s). Components: $componentSummary. Signals: $signalSummary." $recommendation -EventRows $gamingRelatedEvents -DetailText ($detailParts -join "`r`n`r`n")
    }

    $dcomPermissionEvents = @($allEvents | Where-Object {
        (Test-EventLevelAtMost $_ 3) -and
        ([string]$_.ProviderName -match 'DistributedCOM') -and
        ([string]$_.Id -eq '10016') -and
        ([string]$_.Message -match '(?i)Local Activation|Lokal Aktivierung|application-specific|Anwendungsspezifisch|APPID|CLSID')
    })
    if ($dcomPermissionEvents.Count -gt 0) {
        $dcomRows = @($dcomPermissionEvents | ForEach-Object {
            $message = [string]$_.Message
            $appContainer = ""
            $user = ""
            $clsid = ""
            $appid = ""
            if ($message -match '(?im)(?:Benutzer|user)\s+["'']?([^"''\r\n]+?)["'']?\s+\(SID') { $user = $matches[1].Trim() }
            if ($message -match '(?im)CLSID\s*\r?\n?\s*\{([^}]+)\}') { $clsid = "{{{0}}}" -f $matches[1].Trim() }
            if ($message -match '(?im)APPID\s*\r?\n?\s*\{([^}]+)\}') { $appid = "{{{0}}}" -f $matches[1].Trim() }
            if ($message -match '(?im)(?:Anwendungscontainer|application container)\s+["'']([^"''\r\n]+)["'']') { $appContainer = $matches[1].Trim() }
            $appName = if ($appContainer -match '(?i)MSTeams|Teams') { "Microsoft Teams" } elseif (-not [string]::IsNullOrWhiteSpace($appContainer)) { $appContainer } else { "COM app" }
            [PSCustomObject]@{
                TimeCreated = $_.TimeCreated
                Source = $_.ProviderName
                EventId = $_.Id
                App = $appName
                AppContainer = $appContainer
                User = $user
                CLSID = $clsid
                APPID = $appid
                Meaning = "A Windows app tried to locally activate a COM component but Windows logged a DCOM permission warning."
            }
        })
        $appSummary = (@($dcomRows | Group-Object App | Sort-Object Count -Descending | ForEach-Object { "$($_.Name)=$($_.Count)" }) -join "; ")
        $dcomSeverity = if ($dcomPermissionEvents.Count -gt 3) { "Medium" } else { "Info" }
        $dcomInterpretation = @"
DCOM 10016 interpretation:

- DistributedCOM 10016 means Windows blocked or logged a local COM activation permission for an app/container.
- For Microsoft Teams and many Microsoft Store/AppX apps this is often noisy and not automatically a root cause.
- Treat it as relevant mainly if it repeats heavily or the timestamp matches an app crash, login issue, Store/AppX failure, or the exact app not starting.
- Do not change Component Services permissions just because of a single 10016 entry; that can create more problems than it solves.
"@
        $detailParts = @()
        $detailParts += (New-EventDetailsText -Rows $dcomPermissionEvents)
        $detailParts += (New-ObjectDetailsText -Rows $dcomRows -Title "DCOM 10016 summary rows")
        $detailParts += $dcomInterpretation.Trim()
        Add-Finding ([ref]$findings) $dcomSeverity "Windows Stack" "Windows app DCOM permission warnings found" "$($dcomPermissionEvents.Count) DistributedCOM 10016 event(s). Apps: $appSummary." "Usually no action is required for isolated DCOM 10016 entries. If the same app repeats often or symptoms match the timestamp, repair/reset the affected app from Windows Settings or Microsoft Store before changing Component Services permissions." -EventRows $dcomPermissionEvents -DetailText ($detailParts -join "`r`n`r`n")
    }

    $windowsStackEvents = @($allEvents | Where-Object {
        (Test-EventLevelAtMost $_ 3) -and
        (
            ($_.ProviderName -match 'WindowsUpdateClient|Perflib|Application Hang|Application Error|AppModel-Runtime|AppXDeployment|Store|Bits-Client|DistributedCOM') -or
            ($_.Id -in @('20','1002','1008','1023','5973','1000','10010'))
        ) -and
        ($_.Message -notmatch $gamingPattern) -and
        ($_.Message -notmatch $driverUtilityPattern) -and
        -not (($_.ProviderName -match 'DistributedCOM') -and ([string]$_.Id -eq '10016'))
    })
    if ($windowsStackEvents.Count -gt 0) {
        $windowsStackRows = @($windowsStackEvents | ForEach-Object {
            $message = [string]$_.Message
            $crashInfo = Get-AppCrashInfoFromMessage -Message $message
            $subject = ""
            if (-not [string]::IsNullOrWhiteSpace([string]$crashInfo.FaultingApplication)) {
                $subject = $crashInfo.FaultingApplication
            } elseif ($message -match '(?i)(?:0x[0-9a-f]{8})') {
                $subject = $matches[0]
            } else {
                $subject = [string]$_.ProviderName
            }
            [PSCustomObject]@{
                TimeCreated = $_.TimeCreated
                Provider = $_.ProviderName
                EventId = $_.Id
                Subject = $subject
                FaultingApplication = $crashInfo.FaultingApplication
                FaultingModule = $crashInfo.FaultingModule
                ExceptionCode = $crashInfo.ExceptionCode
            }
        })
        $providerSummary = New-TopCountSummary -Rows $windowsStackRows -PropertyName "Provider" -MaxItems 6
        $subjectSummary = New-TopCountSummary -Rows $windowsStackRows -PropertyName "Subject" -MaxItems 8
        $windowsDetails = @()
        $windowsDetails += (New-ObjectDetailsText -Rows $windowsStackRows -Title "Windows stack summary rows")
        $windowsDetails += (New-EventDetailsText -Rows $windowsStackEvents)
        Add-Finding ([ref]$findings) "Medium" "Windows Stack" "Windows update, app, or performance counter issues found" "$($windowsStackEvents.Count) matching WindowsUpdateClient, Perflib, Application Hang/Error, Store/AppX, or BITS event(s). Providers: $providerSummary. Top subjects: $subjectSummary." "Focus on the repeated subjects above. After freeing disk space, run DISM /Online /Cleanup-Image /RestoreHealth and sfc /scannow, then repair the specific app/update component that still repeats." -EventRows $windowsStackEvents -DetailText ($windowsDetails -join "`r`n`r`n")
    }

    $disks = Read-CsvSafe (Join-Path $Dirs.Storage "Disks.csv")
    $driveMappings = Read-CsvSafe (Join-Path $Dirs.Storage "Disk_To_DriveLetter_Mapping.csv")
    $systemDriveRows = @($driveMappings | Where-Object {
        ([string]$_.DriveLetter).TrimEnd(':') -ieq 'C'
    })
    $usbSystemDriveRows = @($systemDriveRows | Where-Object {
        $diskNumber = ConvertTo-NumberSafe ([string]$_.DiskIndex)
        $matchingDisk = @($disks | Where-Object {
            $number = ConvertTo-NumberSafe ([string]$_.Number)
            $null -ne $diskNumber -and $null -ne $number -and [int]$number -eq [int]$diskNumber
        }) | Select-Object -First 1
        $diskText = "$($_.InterfaceType) $($_.DiskModel) $($_.Partition) $($matchingDisk.BusType) $($matchingDisk.FriendlyName)"
        $diskText -match 'USB|UASP|Oracle|External|Portable|Enclosure'
    })
    if ($usbSystemDriveRows.Count -gt 0) {
        $usbDiskDetails = @()
        $usbDiskDetails += (New-ObjectDetailsText -Rows $usbSystemDriveRows -Title "System drive mapping rows")
        $usbDiskNumbers = @($usbSystemDriveRows | ForEach-Object { [string]$_.DiskIndex } | Where-Object { -not [string]::IsNullOrWhiteSpace($_) } | Select-Object -Unique)
        $matchingUsbDisks = @($disks | Where-Object { $usbDiskNumbers -contains [string]$_.Number })
        if ($matchingUsbDisks.Count -gt 0) {
            $usbDiskDetails += (New-ObjectDetailsText -Rows $matchingUsbDisks -Title "Matching disk rows")
        }
        Add-Finding ([ref]$findings) "High" "Storage" "Windows appears to run from USB or enclosure-style storage" "$($usbSystemDriveRows.Count) C: drive mapping row(s) match USB, UASP, portable, external, or enclosure-attached storage." "For a normal desktop PC, prefer an internal NVMe/SATA SSD for the Windows system drive. If this setup is intentional, check enclosure firmware, cable, USB port, and power stability before chasing Windows symptoms." -TimeContext $currentObservation -DetailText ($usbDiskDetails -join "`r`n`r`n")
    }

    $ipconfigPath = Join-Path $Dirs.Network "ipconfig_all.txt"
    if (Test-Path -LiteralPath $ipconfigPath) {
        $ipconfigText = (Get-Content -LiteralPath $ipconfigPath -ErrorAction SilentlyContinue) -join "`r`n"
        $hasInternalSuffix = $ipconfigText -match '(DNS Suffix|DNS Suffix Search List).*(\.local|\.lan|\.corp|\.internal|\.esl\.ooo|\.ooo|\.intra|\.domain|\.ad)\b'
        $hasPublicDns = $ipconfigText -match 'DNS Servers[^\r\n]*:\s*(1\.1\.1\.1|1\.0\.0\.1|8\.8\.8\.8|8\.8\.4\.4|9\.9\.9\.9|208\.67\.222\.222|208\.67\.220\.220)' -or
            $ipconfigText -match '^\s*(1\.1\.1\.1|1\.0\.0\.1|8\.8\.8\.8|8\.8\.4\.4|9\.9\.9\.9|208\.67\.222\.222|208\.67\.220\.220)\s*$'
        if ($hasInternalSuffix -and $hasPublicDns) {
            Add-Finding ([ref]$findings) "Medium" "Network" "Public DNS servers are used with an internal DNS suffix" "ipconfig shows an internal-looking DNS suffix together with public DNS resolvers." "If this PC belongs to a managed network or domain-like deployment, DHCP should usually provide the internal DNS server. Public DNS can break domain discovery, WPAD, time sync, certificates, and deployment services." -TimeContext $currentObservation -DetailText $ipconfigText
        }
    }

    $badDisks = @($disks | Where-Object {
        (($_.HealthStatus) -and ($_.HealthStatus -notmatch 'Healthy|Unknown')) -or
        (($_.OperationalStatus) -and ($_.OperationalStatus -notmatch 'Online|OK|No Media'))
    })
    if ($badDisks.Count -gt 0) {
        Add-Finding ([ref]$findings) "High" "Storage" "Disk status is not healthy" "$($badDisks.Count) disk row(s) have HealthStatus or OperationalStatus other than Healthy/Online." "Review Disks.csv and PhysicalDisks.csv and prioritize the affected disk(s)." -TimeContext $currentObservation -DetailText (New-ObjectDetailsText -Rows $badDisks -Title "Affected disk rows")
    }

    $physicalDisks = Read-CsvSafe (Join-Path $Dirs.Storage "PhysicalDisks.csv")
    $badPhysical = @($physicalDisks | Where-Object {
        (($_.HealthStatus) -and ($_.HealthStatus -notmatch 'Healthy|Unknown')) -or
        (($_.OperationalStatus) -and ($_.OperationalStatus -notmatch 'OK|No Media'))
    })
    if ($badPhysical.Count -gt 0) {
        Add-Finding ([ref]$findings) "High" "Storage" "PhysicalDisk status is suspicious" "$($badPhysical.Count) PhysicalDisk row(s) look suspicious." "Review Storage Reliability Counter output and run the vendor diagnostic tool." -TimeContext $currentObservation -DetailText (New-ObjectDetailsText -Rows $badPhysical -Title "Affected PhysicalDisk rows")
    }

    $lowLevelDrivers = Read-CsvSafe (Join-Path $Dirs.System "LowLevel_Hardware_Access_Drivers.csv")
    $lowLevelServices = Read-CsvSafe (Join-Path $Dirs.System "LowLevel_Hardware_Access_Services.csv")
    $lowLevelRows = @(@($lowLevelDrivers) + @($lowLevelServices))
    if ($lowLevelRows.Count -gt 0) {
        Add-Finding ([ref]$findings) "Info" "Drivers" "Low-level hardware access drivers are installed" "$($lowLevelRows.Count) driver/service row(s) mention inpout, WinRing0, IOMap, OpenLibSys, or similar components." "These components are often installed by monitoring, RGB, fan-control, benchmark, or overclocking tools. They are not automatically bad, but review them if crashes, hangs, or driver service events occur around the same timestamps." -TimeContext $currentObservation -DetailText (New-ObjectDetailsText -Rows $lowLevelRows -Title "Low-level driver and service rows")
    }

    $fixedHardwareClasses = @("Display", "Net", "SCSIAdapter", "HDC", "DiskDrive", "Storage", "System", "MEDIA", "Processor")
    $fixedHardwareDriverPattern = '(?i)\bAMD\b|\bATI\b|NVIDIA|nvlddmkm|Intel|iaStor|e1|e2f|Netwtw|Realtek|RTKVHD|ASUS|MSI|Micro-Star|Gigabyte|Aorus|ASRock|A-Volute|Nahimic|Sonic|Killer|Rivet|storahci|stornvme'

    $migrationPnpRows = @(Read-CsvSafe (Join-Path $Dirs.System "HardwareMigration_PnpProblemDevices.csv") | Where-Object {
        -not [string]::IsNullOrWhiteSpace([string]$_.FriendlyName) -and
        $fixedHardwareClasses -contains [string]$_.Class -and
        [string]$_.Problem -notmatch 'Get-PnpDevice is not available'
    })
    if ($migrationPnpRows.Count -gt 0) {
        $nonPhantomPnpRows = @($migrationPnpRows | Where-Object { [string]$_.Problem -notmatch 'CM_PROB_PHANTOM' })
        if ($nonPhantomPnpRows.Count -gt 0) {
            Add-Finding ([ref]$findings) "Medium" "Hardware Migration" "Fixed hardware devices report driver or hardware problems" "$($nonPhantomPnpRows.Count) non-phantom fixed-hardware device row(s) are not in OK state; $($migrationPnpRows.Count) total relevant PnP problem row(s)." "If this Windows installation was moved between PCs, check whether these devices belong to old motherboard, GPU, storage controller, network, or audio hardware. Prefer vendor chipset, storage, network, audio, and GPU driver packages for the current PC." -TimeContext $currentObservation -DetailText (New-ObjectDetailsText -Rows $migrationPnpRows -Title "Fixed-hardware PnP problem devices")
        } else {
            Add-Finding ([ref]$findings) "Info" "Hardware Migration" "Non-present fixed hardware devices are still registered" "$($migrationPnpRows.Count) fixed-hardware PnP row(s) report CM_PROB_PHANTOM." "This is common when the same Windows installation is moved across motherboard, GPU, storage, network, or audio hardware. Treat it as cleanup context, not a fault by itself. USB, HID, and removable peripherals are intentionally not included here." -TimeContext $currentObservation -DetailText (New-ObjectDetailsText -Rows $migrationPnpRows -Title "Fixed-hardware phantom PnP devices")
        }
    }

    $missingDriverFileRows = @(Read-CsvSafe (Join-Path $Dirs.System "HardwareMigration_DriverServices_MissingFiles.csv") | Where-Object {
        "$($_.Name) $($_.DisplayName) $($_.OriginalPathName) $($_.MissingPath)" -match $fixedHardwareDriverPattern
    })
    if ($missingDriverFileRows.Count -gt 0) {
        Add-Finding ([ref]$findings) "Medium" "Hardware Migration" "Driver services reference missing files" "$($missingDriverFileRows.Count) system driver service row(s) point to missing .sys files." "These are strong stale-driver candidates after hardware swaps or incomplete uninstalls. Review the service names, correlate with Service Control Manager events, and remove or reinstall the related vendor package deliberately." -TimeContext $currentObservation -DetailText (New-ObjectDetailsText -Rows $missingDriverFileRows -Title "Driver services with missing files")
    }

    $oldThirdPartyDriverRows = @(Read-CsvSafe (Join-Path $Dirs.System "HardwareMigration_OldThirdPartyDrivers.csv"))
    if ($oldThirdPartyDriverRows.Count -gt 0) {
        $oldDriverSummary = (($oldThirdPartyDriverRows | Group-Object Manufacturer | Sort-Object Count -Descending | Select-Object -First 5 | ForEach-Object { "$($_.Name)=$($_.Count)" }) -join "; ")
        Add-Finding ([ref]$findings) "Info" "Hardware Migration" "Old third-party hardware drivers are installed" "$($oldThirdPartyDriverRows.Count) non-Microsoft driver row(s) are older than four years. Top manufacturers: $oldDriverSummary." "Old drivers are not automatically wrong, but on installations moved across hardware they are worth reviewing. Prioritize storage, chipset, network, audio, and GPU drivers that no longer match the current PC." -TimeContext $currentObservation -DetailText (New-ObjectDetailsText -Rows $oldThirdPartyDriverRows -Title "Old third-party drivers")
    }

    $vendorDriverServiceRows = @(Read-CsvSafe (Join-Path $Dirs.System "HardwareMigration_VendorDriverServices.csv"))
    $vendorGroups = @($vendorDriverServiceRows | Where-Object { -not [string]::IsNullOrWhiteSpace([string]$_.VendorGroup) } | Group-Object VendorGroup | Sort-Object Count -Descending)
    $vendorGroupNames = @($vendorGroups | ForEach-Object { [string]$_.Name })
    $hasAmdAndNvidia = ($vendorGroupNames -contains "AMD") -and ($vendorGroupNames -contains "NVIDIA")
    if ($hasAmdAndNvidia) {
        Add-Finding ([ref]$findings) "Medium" "Hardware Migration" "AMD and NVIDIA driver stacks are both present" "Driver services from AMD and NVIDIA are both present." "This can be normal on some systems, but after a GPU swap it is a classic stale-driver clue. If graphics crashes, game crashes, driver resets, or WHEA events occur, consider a clean GPU driver reinstall and remove old vendor packages deliberately." -TimeContext $currentObservation -DetailText (New-ObjectDetailsText -Rows $vendorDriverServiceRows -Title "Vendor driver services")
    } elseif ($vendorDriverServiceRows.Count -ge 12 -and $vendorGroups.Count -ge 4) {
        $vendorSummary = (($vendorGroups | Select-Object -First 8 | ForEach-Object { "$($_.Name)=$($_.Count)" }) -join "; ")
        Add-Finding ([ref]$findings) "Info" "Hardware Migration" "Many vendor driver services are installed" "$($vendorDriverServiceRows.Count) vendor driver service row(s) across $($vendorGroups.Count) vendor group(s): $vendorSummary." "This is a review hint for PCs that reuse one Windows installation across hardware. Remove only packages you can identify as old hardware, and prioritize entries that correlate with crashes, failed services, or missing driver files." -TimeContext $currentObservation -DetailText (New-ObjectDetailsText -Rows $vendorDriverServiceRows -Title "Vendor driver services")
    }

    $cleanupCandidates = @()
    foreach ($row in @($migrationPnpRows | Where-Object { [string]$_.Problem -match 'CM_PROB_PHANTOM' })) {
        $instanceId = ([string]$row.InstanceId) -replace '"', '\"'
        $cleanupCandidates += [PSCustomObject]@{
            CandidateType = "Phantom device"
            ReviewPriority = "Review"
            Name = [string]$row.FriendlyName
            Class = [string]$row.Class
            Identifier = [string]$row.InstanceId
            Reason = "Device is registered but currently not present (CM_PROB_PHANTOM)."
            SuggestedCommand = "pnputil.exe /remove-device ""$instanceId"""
            Caution = "Use only after confirming this is old hardware or a stale USB/device entry."
        }
    }
    foreach ($row in @($missingDriverFileRows)) {
        $serviceName = ([string]$row.Name) -replace '"', '\"'
        $cleanupCandidates += [PSCustomObject]@{
            CandidateType = "Driver service with missing file"
            ReviewPriority = "High review"
            Name = [string]$row.DisplayName
            Class = "SystemDriver"
            Identifier = [string]$row.Name
            Reason = "System driver service references a .sys file that was not found."
            SuggestedCommand = "sc.exe query ""$serviceName"" ; sc.exe delete ""$serviceName"""
            Caution = "Deleting a service is destructive. Confirm the missing file path and vendor before using sc.exe delete."
        }
    }
    foreach ($row in @($oldThirdPartyDriverRows | Where-Object { [string]$_.InfName -match '^oem\d+\.inf$' } | Sort-Object InfName -Unique)) {
        $infName = ([string]$row.InfName) -replace '"', '\"'
        $cleanupCandidates += [PSCustomObject]@{
            CandidateType = "Old third-party driver package to review"
            ReviewPriority = "Review"
            Name = [string]$row.DeviceName
            Class = [string]$row.DeviceClass
            Identifier = [string]$row.InfName
            Reason = "Driver package is older than four years. It may still belong to current hardware, so it is review-only."
            SuggestedCommand = "pnputil.exe /enum-drivers | findstr.exe /i ""$infName"""
            Caution = "This is not a delete command. Use it to inspect the package. Only delete after confirming no current hardware uses it."
        }
    }
    if ($cleanupCandidates.Count -gt 0) {
        $cleanupCandidatesPath = Join-Path $Dirs.System "HardwareMigration_CleanupCandidates.csv"
        $cleanupCommandsPath = Join-Path $Dirs.System "HardwareMigration_CleanupCommands_ReviewOnly.ps1"
        $cleanupGuidePath = Join-Path $Dirs.System "HardwareMigration_CleanupGuide.txt"
        $cleanupCandidates | Export-Csv $cleanupCandidatesPath -NoTypeInformation -Encoding UTF8

        $commandLines = New-Object System.Collections.Generic.List[string]
        $commandLines.Add("# Hardware Migration cleanup commands - REVIEW ONLY")
        $commandLines.Add("#")
        $commandLines.Add("# Nothing in this file runs automatically because every command is commented out.")
        $commandLines.Add("# Review HardwareMigration_CleanupCandidates.csv first.")
        $commandLines.Add("# Recommended safety steps before any cleanup:")
        $commandLines.Add("# 1. Create a restore point or backup.")
        $commandLines.Add("# 2. Confirm the device/service/driver belongs to old hardware.")
        $commandLines.Add("# 3. Prefer vendor uninstallers for GPU, chipset, audio, RGB, and security software.")
        $commandLines.Add("# 4. Remove one group at a time and reboot/test.")
        $commandLines.Add("")
        foreach ($candidate in $cleanupCandidates) {
            $commandLines.Add("# [$($candidate.ReviewPriority)] $($candidate.CandidateType): $($candidate.Name)")
            $commandLines.Add("# Class/ID: $($candidate.Class) / $($candidate.Identifier)")
            $commandLines.Add("# Reason: $($candidate.Reason)")
            $commandLines.Add("# Caution: $($candidate.Caution)")
            $commandLines.Add("# $($candidate.SuggestedCommand)")
            $commandLines.Add("")
        }
        $commandLines | Out-File $cleanupCommandsPath -Encoding UTF8

@"
Hardware Migration Cleanup Guide
================================

This package found cleanup candidates for an installation that may have been moved across hardware.

Files:
- HardwareMigration_CleanupCandidates.csv
- HardwareMigration_CleanupCommands_ReviewOnly.ps1

The PowerShell file is intentionally review-only. Every command is commented out.
PCDiagLite does not remove devices, drivers, or services automatically.

Suggested order:
1. Review PnP problem and phantom devices.
2. Handle missing driver-service files first, because they are strong stale-driver clues.
3. Review old third-party driver packages only when they do not match current hardware.
4. Prefer vendor uninstallers for GPU, chipset, audio, RGB, monitoring, and security tools.
5. Remove one hardware family at a time, reboot, and rerun PCDiagLite.

Typical command meanings:
- pnputil /remove-device removes a device node, often useful for stale non-present devices.
- pnputil /delete-driver removes a driver package from the driver store when it is not needed.
- sc.exe delete removes a service entry and should only be used after confirming it is stale.
"@ | Out-File $cleanupGuidePath -Encoding UTF8

        Add-Finding ([ref]$findings) "Info" "Hardware Migration" "Hardware cleanup review commands were generated" "$($cleanupCandidates.Count) cleanup candidate command(s) were written as review-only files." "Open 02_System_Hardware\\HardwareMigration_CleanupCandidates.csv and HardwareMigration_CleanupCommands_ReviewOnly.ps1. Commands are commented out by design; only uncomment and run entries that clearly belong to old hardware." -TimeContext $currentObservation -DetailText (New-ObjectDetailsText -Rows $cleanupCandidates -Title "Hardware cleanup candidates")
    }

    $remoteToolRows = Read-CsvSafe (Join-Path $Dirs.System "Remote_Virtualization_Network_Tools.csv")
    if ($remoteToolRows.Count -ge 5) {
        Add-Finding ([ref]$findings) "Info" "Drivers" "Many remote, VPN, or virtualization components are installed" "$($remoteToolRows.Count) matching driver/service row(s) were collected." "This is not automatically a fault on a desktop PC. If remote control, USB redirection, input devices, VPN, or display capture behave oddly, simplify the stack and test with only the required tools enabled." -TimeContext $currentObservation -DetailText (New-ObjectDetailsText -Rows $remoteToolRows -Title "Remote, VPN, and virtualization related rows")
    }

    $rdpRows = Read-CsvSafe (Join-Path $Dirs.System "RemoteDesktop_Basic_Check.csv")
    $badRdpRows = @($rdpRows | Where-Object {
        ([string]$_.TermddSysExists -notmatch 'True') -or
        ([string]$_.TermDDStatus -match 'Missing') -or
        ([string]$_.TermServiceStatus -match 'Missing') -or
        ([string]$_.RdpTcp3389Listening -notmatch 'True')
    })
    if ($badRdpRows.Count -gt 0) {
        Add-Finding ([ref]$findings) "Info" "Remote Access" "Remote Desktop host baseline is incomplete or not listening" "The basic RDP check found termdd.sys, TermService, TermDD, or TCP 3389 not in the expected host-ready state." "Only treat this as a problem if this PC should accept inbound Remote Desktop connections. Check termdd.sys, TermDD, TermService, firewall rules, Remote Desktop settings, and qwinsta." -TimeContext $currentObservation -DetailText (New-ObjectDetailsText -Rows $badRdpRows -Title "Remote Desktop basic check")
    }

    $reliabilityRows = Read-CsvSafe (Join-Path $Dirs.Storage "StorageReliabilityCounter.csv")
    $smartPredictionRows = Read-CsvSafe (Join-Path $Dirs.Storage "Storage_SMART_FailurePrediction.csv")
    $smartFailureRows = @($smartPredictionRows | Where-Object { [string]$_.PredictFailure -match 'True|1' })
    if ($smartFailureRows.Count -gt 0) {
        Add-Finding ([ref]$findings) "High" "Storage" "SMART failure prediction is active" "$($smartFailureRows.Count) disk row(s) report PredictFailure." "Back up important data immediately, identify the affected disk, and replace or vendor-test the drive before continuing normal use." -TimeContext $currentObservation -DetailText (New-ObjectDetailsText -Rows $smartFailureRows -Title "SMART failure prediction rows")
    }

    $suspiciousReliabilityRows = @($reliabilityRows | Where-Object {
        $readErrors = ConvertTo-NumberSafe ([string]$_.ReadErrorsTotal)
        $writeErrors = ConvertTo-NumberSafe ([string]$_.WriteErrorsTotal)
        $readLatency = ConvertTo-NumberSafe ([string]$_.ReadLatencyMax)
        $writeLatency = ConvertTo-NumberSafe ([string]$_.WriteLatencyMax)
        $wear = ConvertTo-NumberSafe ([string]$_.Wear)
        $loadUnload = ConvertTo-NumberSafe ([string]$_.LoadUnloadCycleCount)
        $errorText = [string]$_.Error
        ($null -ne $readErrors -and $readErrors -gt 0) -or
        ($null -ne $writeErrors -and $writeErrors -gt 0) -or
        ($null -ne $readLatency -and $readLatency -ge 1000) -or
        ($null -ne $writeLatency -and $writeLatency -ge 1000) -or
        ($null -ne $wear -and $wear -ge 80) -or
        ($null -ne $loadUnload -and $loadUnload -ge 300000) -or
        (-not [string]::IsNullOrWhiteSpace($errorText))
    })
    if ($suspiciousReliabilityRows.Count -gt 0) {
        $smartSummary = (($suspiciousReliabilityRows | Select-Object -First 5 | ForEach-Object {
            "$($_.FriendlyName): readErrors=$($_.ReadErrorsTotal), writeErrors=$($_.WriteErrorsTotal), wear=$($_.Wear), temp=$($_.Temperature), maxTemp=$($_.TemperatureMax), error=$($_.Error)"
        }) -join "; ")
        Add-Finding ([ref]$findings) "Medium" "Storage" "SMART or storage reliability counters need review" $smartSummary "Review StorageReliabilityCounter.csv and Storage_SMART_FailurePrediction.csv. If errors, high wear, high latency, or PredictFailure are present, back up data and run the vendor diagnostic tool." -TimeContext $currentObservation -DetailText ((New-ObjectDetailsText -Rows $suspiciousReliabilityRows -Title "Suspicious storage reliability rows") + "`r`n`r`n" + (New-ObjectDetailsText -Rows $smartPredictionRows -Title "SMART failure prediction rows"))
    }

    $hotStorageRows = @($reliabilityRows | Where-Object {
        $currentTemp = ConvertTo-NumberSafe ([string]$_.Temperature)
        $maxTemp = ConvertTo-NumberSafe ([string]$_.TemperatureMax)
        ($null -ne $currentTemp -and $currentTemp -ge 70) -or
        ($null -ne $maxTemp -and $maxTemp -ge 80)
    })
    if ($hotStorageRows.Count -gt 0) {
        $tempSummary = (($hotStorageRows | Select-Object -First 5 | ForEach-Object {
            "$($_.FriendlyName): current=$($_.Temperature) C, max=$($_.TemperatureMax) C"
        }) -join "; ")
        Add-Finding ([ref]$findings) "Medium" "Storage" "High current or historical storage temperature" $tempSummary "Improve airflow or add NVMe cooling if the maximum temperature is repeatedly high. Review StorageReliabilityCounter.csv after a few days of normal operation." -TimeContext $currentObservation -DetailText (New-ObjectDetailsText -Rows $hotStorageRows -Title "Storage reliability temperature rows")
    }

    $volumes = Read-CsvSafe (Join-Path $Dirs.Storage "Volumes.csv")
    $badVolumes = @($volumes | Where-Object {
        (($_.HealthStatus) -and ($_.HealthStatus -notmatch 'Healthy|Unknown')) -or
        (($_.OperationalStatus) -and ($_.OperationalStatus -notmatch 'OK|Online|No Media'))
    })
    $efiLikeVolumes = @($badVolumes | Where-Object {
        $sizeGb = ConvertTo-NumberSafe ([string]$_.SizeGB)
        $_.FileSystem -match 'FAT32' -and $null -ne $sizeGb -and $sizeGb -lt 1
    })
    if ($efiLikeVolumes.Count -gt 0) {
        Add-Finding ([ref]$findings) "Medium" "Storage" "Small FAT32 system/EFI-like volume needs repair" "$($efiLikeVolumes.Count) small FAT32 volume row(s) report Warning or Full Repair Needed." "This is often the EFI system partition. Review Volumes.csv and Partitions.csv. If appropriate, mount the EFI partition deliberately and run a careful file-system check; avoid manual file changes on EFI." -TimeContext $currentObservation -DetailText (New-ObjectDetailsText -Rows $efiLikeVolumes -Title "EFI-like volume rows")
    }
    $badNonEfiVolumes = @($badVolumes | Where-Object {
        $sizeGb = ConvertTo-NumberSafe ([string]$_.SizeGB)
        -not ($_.FileSystem -match 'FAT32' -and $null -ne $sizeGb -and $sizeGb -lt 1)
    })
    if ($badNonEfiVolumes.Count -gt 0) {
        Add-Finding ([ref]$findings) "Medium" "Storage" "Volume status is not healthy" "$($badNonEfiVolumes.Count) volume row(s) have HealthStatus or OperationalStatus other than Healthy/OK." "Review Volumes.csv. For Full Repair Needed, verify file system health and identify the affected partition." -TimeContext $currentObservation -DetailText (New-ObjectDetailsText -Rows $badNonEfiVolumes -Title "Affected volume rows")
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
        Add-Finding ([ref]$findings) "Medium" "Storage" "Low free disk space" "$($lowVolumes.Count) volume(s) of at least 10 GB are below 10% free. $lowVolumeSummary" "Free disk space, review logs/temp data, and identify growth drivers. Because this is a current-state finding, rerun the tool after cleanup to confirm it is gone." -TimeContext $currentObservation -DetailText (New-ObjectDetailsText -Rows $lowVolumes -Title "Low-free-space volume rows")
    }

    $dumpRows = Read-CsvSafe (Join-Path $Dirs.Dumps "DumpFiles.csv")
    $copiedDumps = @($dumpRows | Where-Object { $_.Type -match 'Minidump copied' })
    if ($copiedDumps.Count -gt 0) {
        $dumpEvents = @($copiedDumps | ForEach-Object { [PSCustomObject]@{ TimeCreated = $_.LastWriteTime } })
        $dumpTimeInfo = Get-EventTimeInfo -Rows $dumpEvents
        $dumpAnalysisStatusPath = Join-Path $Dirs.Dumps "DumpAnalysis_Status.txt"
        $dumpAnalysisRows = @(Read-DumpAnalysisRows)
        $completedAnalysisRows = @($dumpAnalysisRows | Where-Object { $_.Status -match 'Success|Warning|Timeout' -and -not [string]::IsNullOrWhiteSpace([string]$_.AnalysisFile) })
        $suspectRows = @($dumpAnalysisRows | Where-Object { -not [string]::IsNullOrWhiteSpace([string]$_.ProbablyCausedBy) -or -not [string]::IsNullOrWhiteSpace([string]$_.BugCheck) })
        $dumpAnalysisStatusText = ""
        if (Test-Path -LiteralPath $dumpAnalysisStatusPath) {
            $dumpAnalysisStatusText = (Get-Content -LiteralPath $dumpAnalysisStatusPath -Raw -ErrorAction SilentlyContinue).Trim()
        }

        $evidence = "$($copiedDumps.Count) minidump(s) copied."
        $recommendation = "Analyze minidumps with WinDbg/DebugDiag. The driver name and BugCheck code are often the fastest next clue."
        $detailParts = @((New-ObjectDetailsText -Rows $copiedDumps -Title "Captured dump files"))

        if (-not [string]::IsNullOrWhiteSpace($dumpAnalysisStatusText)) {
            $detailParts += "Minidump analysis status:`r`n`r`n$dumpAnalysisStatusText"
        }

        if ($dumpAnalysisRows.Count -gt 0) {
            $evidence += " $($completedAnalysisRows.Count) dump analysis file(s) created."
            $detailParts += (New-ObjectDetailsText -Rows $dumpAnalysisRows -Title "Local dump analysis summary")
            if ($suspectRows.Count -gt 0) {
                $dumpTimesByFile = @{}
                foreach ($dump in $copiedDumps) {
                    $dumpTimesByFile[[string](Split-Path -Leaf ([string]$dump.Path))] = [string]$dump.LastWriteTime
                }
                $dumpSummaryRows = @($suspectRows | ForEach-Object {
                    $module = @($_.ImageName, $_.ModuleName, $_.ProbablyCausedBy, $_.FailureBucket) |
                        Where-Object { -not [string]::IsNullOrWhiteSpace([string]$_) } |
                        Select-Object -First 1
                    [PSCustomObject]@{
                        DumpFile = $_.DumpFile
                        LastWriteTime = $dumpTimesByFile[[string]$_.DumpFile]
                        BugCheck = $_.BugCheck
                        SuspectedModule = $module
                        SuspectedArea = $_.SuspectedArea
                    }
                })
                $summaryText = (@($dumpSummaryRows | Select-Object -First 5 | ForEach-Object {
                    "$($_.DumpFile): BugCheck $($_.BugCheck), $($_.SuspectedModule), $($_.SuspectedArea)"
                }) -join "; ")
                if (-not [string]::IsNullOrWhiteSpace($summaryText)) {
                    $evidence += " Dump summary: $summaryText."
                }

                $hasGpuDump = @($suspectRows | Where-Object { ([string]$_.BugCheck -match '^(116|0x116)$') -or (@($_.ImageName,$_.ModuleName,$_.ProbablyCausedBy,$_.FailureBucket) -join ' ') -match '(?i)nvlddmkm|amdkmdag|atikmdag|dxgkrnl' })
                $hasPciePowerDump = @($suspectRows | Where-Object { (@($_.ImageName,$_.ModuleName,$_.SymbolName,$_.FailureBucket,$_.SuspectedArea) -join ' ') -match '(?i)PciD3Cold|CorePowerRail|PCIe / chipset|pci!PciD3' })
                $hasUsbPowerDump = @($suspectRows | Where-Object { ([string]$_.BugCheck -match '^(9f|0x9f)$') -or (@($_.ImageName,$_.ModuleName,$_.ProbablyCausedBy,$_.SuspectedArea) -join ' ') -match '(?i)UsbHub|USB / external' })
                $recommendationParts = @()
                if ($hasGpuDump.Count -gt 0) {
                    $recommendationParts += "At least one dump points to a GPU/video TDR path. Clean-install the GPU driver, check GPU thermals/power, disable overlays for one test, and correlate with game or nvlddmkm events."
                }
                if ($hasPciePowerDump.Count -gt 0) {
                    $recommendationParts += "At least one dump points to PCIe/D3Cold device power management. Update BIOS/UEFI, chipset, GPU/storage/device firmware and compare with sleep/resume or power-state timestamps."
                }
                if ($hasUsbPowerDump.Count -gt 0) {
                    $recommendationParts += "At least one dump points to USB or driver power-transition timeout. Test without docks/hubs/non-essential USB devices and update chipset/USB controller drivers."
                }
                if ($recommendationParts.Count -eq 0) {
                    $recommendationParts += "Review the suspected modules and BugCheck codes together with recent driver, firmware, BIOS, Windows update, and hardware changes."
                }
                $recommendation = "$($recommendationParts -join ' ') Open the listed DumpAnalysis_*.txt file for the full !analyze -v output."
            } else {
                $recommendation = "Open 06_Minidumps\\DumpAnalysis.csv and any DumpAnalysis_*.txt files. If analysis was skipped, install Windows Debugging Tools with cdb.exe and rerun the tool."
            }
        } elseif (Test-Path -LiteralPath $dumpAnalysisStatusPath) {
            $evidence += " Local dump analysis did not produce a summary CSV."
            $recommendation = "Review the Minidump analysis status below. If cdb.exe was installed during this run, rerun PCDiagLite once so the debugger can be discovered cleanly and the dump can be analyzed."
        } else {
            $evidence += " No local dump analysis status was recorded."
            $recommendation = "Rerun the current PCDiagLite version. The report should include Minidump analysis status, even when cdb.exe is missing or installation fails."
        }

        Add-Finding ([ref]$findings) "High" "Crash" "Minidumps are included in the package" $evidence $recommendation -TimeContext $dumpTimeInfo.TimeContext -FirstSeen $dumpTimeInfo.FirstSeen -LastSeen $dumpTimeInfo.LastSeen -DetailText ($detailParts -join "`r`n`r`n")
    }

    $memoryDump = @($dumpRows | Where-Object { $_.Type -match 'MEMORY\.DMP' })
    if ($memoryDump.Count -gt 0) {
        $memoryDumpEvents = @($memoryDump | ForEach-Object { [PSCustomObject]@{ TimeCreated = $_.LastWriteTime } })
        $memoryDumpTimeInfo = Get-EventTimeInfo -Rows $memoryDumpEvents
        Add-Finding ([ref]$findings) "Info" "Crash" "Large MEMORY.DMP exists but was not copied" "MEMORY.DMP was listed only for size and privacy reasons." "Request it only if minidumps are not enough." -TimeContext $memoryDumpTimeInfo.TimeContext -FirstSeen $memoryDumpTimeInfo.FirstSeen -LastSeen $memoryDumpTimeInfo.LastSeen -DetailText (New-ObjectDetailsText -Rows $memoryDump -Title "Listed dump files")
    }

    $timeoutsPath = Join-Path $Dirs.Runtime "timeouts.txt"
    if (Test-Path -LiteralPath $timeoutsPath) {
        $timeoutLines = @(Get-Content -LiteralPath $timeoutsPath -ErrorAction SilentlyContinue)
        if ($timeoutLines.Count -gt 0) {
            Add-Finding ([ref]$findings) "Medium" "Collection" "One or more collection steps timed out" "$($timeoutLines.Count) timeout line(s) in 99_Runtime\timeouts.txt." "Review the timeout file. A hanging provider can itself be a symptom." -TimeContext $currentObservation -DetailText ($timeoutLines -join "`r`n")
        }
    }

    $errorsPath = Join-Path $Dirs.Runtime "errors.txt"
    if (Test-Path -LiteralPath $errorsPath) {
        $errorLines = @(Get-Content -LiteralPath $errorsPath -ErrorAction SilentlyContinue)
        if ($errorLines.Count -gt 0) {
            Add-Finding ([ref]$findings) "Info" "Collection" "Collection errors were logged" "$($errorLines.Count) line(s) in 99_Runtime\errors.txt." "Review errors.txt. Individual missing providers are not automatically critical." -TimeContext $currentObservation -DetailText ($errorLines -join "`r`n")
        }
    }

    if ($findings.Count -eq 0) {
        Add-Finding ([ref]$findings) "Info" "Overview" "No clear high-risk pattern found by the local heuristic" "The heuristic did not find the typical signatures in the collected core data." "Still review top events, targeted events, and exact incident timestamps." -TimeContext $currentObservation
    }

    $findingsPath = Join-Path $Dirs.Runtime "Findings.csv"
    $findings | Export-Csv $findingsPath -NoTypeInformation -Encoding UTF8

    $timelinePath = Join-Path $Dirs.Runtime "TimelineEvents.csv"
    $timelineRows = @(Select-LatestTimestampedRows -Rows $script:TimelineRows -MaxRows 240)
    $timelineRows | Export-Csv $timelinePath -NoTypeInformation -Encoding UTF8

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
Event range:   $EventRangeText
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
- 02_System_Hardware\HardwareMigration_*.csv
- 07_Policies\Changed_Policy_Registry_Values.csv
- 01_Events\System_Targeted_Stability_Storage_Network_${EventRangeLabel}.csv
- 01_Events\System_Targeted_TopEvents_${EventRangeLabel}.csv
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
    $smartPrediction = Read-CsvSafe (Join-Path $Dirs.Storage "Storage_SMART_FailurePrediction.csv")
    $netAdapters = Read-CsvSafe (Join-Path $Dirs.Network "NetAdapters.csv")
    $hostsCheck = Read-CsvSafe (Join-Path $Dirs.Network "Hosts_File_Check.csv")
    $hostsEntries = Read-CsvSafe (Join-Path $Dirs.Network "Hosts_File_ActiveEntries.csv")
    $nrptRules = Read-CsvSafe (Join-Path $Dirs.Network "DnsClientNrptRule.csv")
    $endpointSummary = Read-CsvSafe (Join-Path $Dirs.Network "Endpoint_Summary.csv")
    $tcpTop = Read-CsvSafe (Join-Path $Dirs.Network "TCP_Endpoints_By_Process_Top30.csv")
    $udpTop = Read-CsvSafe (Join-Path $Dirs.Network "UDP_Endpoints_By_Process_Top30.csv")
    $topSystem = Read-CsvSafe (Join-Path $Dirs.Events "System_TopEvents_${EventRangeLabel}.csv")
    $targetedTop = Read-CsvSafe (Join-Path $Dirs.Events "System_Targeted_TopEvents_${EventRangeLabel}.csv")
    $migrationPnpProblems = Read-CsvSafe (Join-Path $Dirs.System "HardwareMigration_PnpProblemDevices.csv")
    $migrationOldDrivers = Read-CsvSafe (Join-Path $Dirs.System "HardwareMigration_OldThirdPartyDrivers.csv")
    $migrationVendorServices = Read-CsvSafe (Join-Path $Dirs.System "HardwareMigration_VendorDriverServices.csv")
    $migrationMissingDriverFiles = Read-CsvSafe (Join-Path $Dirs.System "HardwareMigration_DriverServices_MissingFiles.csv")
    $migrationCleanupCandidates = Read-CsvSafe (Join-Path $Dirs.System "HardwareMigration_CleanupCandidates.csv")
    $dumps = Read-CsvSafe (Join-Path $Dirs.Dumps "DumpFiles.csv")
    $dumpAnalysis = @(Read-DumpAnalysisRows)
    $changedPolicies = Read-CsvSafe (Join-Path $Dirs.Policies "Changed_Policy_Registry_Values.csv")

    $osText = ""
    $overviewPath = Join-Path $Dirs.System "System_Overview.txt"
    if (Test-Path -LiteralPath $overviewPath) {
        $osText = (Get-Content -LiteralPath $overviewPath -ErrorAction SilentlyContinue | Select-Object -First 40) -join "`r`n"
    }

    $findingsHtml = New-HtmlTable $findings @("Severity","Category","Title","TimeContext","Evidence","Recommendation") 50
    $diskHtml = New-HtmlTable $disks @("Number","HarddiskPath","FriendlyName","SerialNumber","HealthStatus","OperationalStatus","BusType","SizeGB") 20
    $volumeHtml = New-HtmlTable $volumes @("DriveLetter","FileSystemLabel","FileSystem","HealthStatus","OperationalStatus","SizeGB","FreeGB","FreePercent") 30
    $smartPredictionHtml = New-HtmlTable $smartPrediction @("InstanceName","Active","PredictFailure","Reason","Error") 30
    $netHtml = New-HtmlTable $netAdapters @("Name","InterfaceDescription","Status","LinkSpeed","DriverVersion","DriverDate") 30
    $hostsCheckHtml = New-HtmlTable $hostsCheck @("Path","Exists","Readable","SizeBytes","LastWriteTime","ActiveEntryCount","InvalidLineCount","LoopbackEntryCount","Error") 5
    $hostsEntriesHtml = New-HtmlTable $hostsEntries @("LineNumber","Target","Hostnames","EntryType","RawLine") 50
    $nrptRulesHtml = New-HtmlTable $nrptRules @("Namespace","NameServers","DirectAccessDnsServers","Comment","DisplayName","NameEncoding","DnsSecValidationRequired") 50
    $endpointSummaryHtml = New-HtmlTable $endpointSummary @("Protocol","TotalEndpoints","UniqueProcesses","TopProcessPID","TopProcessCount") 10
    $tcpTopHtml = New-HtmlTable $tcpTop @("PID","Count","Process","Path","States") 30
    $udpTopHtml = New-HtmlTable $udpTop @("PID","Count","Process","Path") 30
    $topHtml = New-HtmlTable $topSystem @("Count","Name") 25
    $targetedHtml = New-HtmlTable $targetedTop @("Count","Name") 25
    $migrationPnpHtml = New-HtmlTable $migrationPnpProblems @("Status","Class","FriendlyName","InstanceId","Problem") 50
    $migrationOldDriversHtml = New-HtmlTable $migrationOldDrivers @("DeviceName","DeviceClass","Manufacturer","DriverVersion","DriverDate","InfName","DeviceID") 80
    $migrationVendorServicesHtml = New-HtmlTable $migrationVendorServices @("VendorGroup","Name","DisplayName","State","Status","StartMode","PathName") 80
    $migrationMissingDriverFilesHtml = New-HtmlTable $migrationMissingDriverFiles @("Name","DisplayName","State","Status","StartMode","MissingPath","OriginalPathName") 80
    $migrationCleanupCandidatesHtml = New-HtmlTable $migrationCleanupCandidates @("CandidateType","ReviewPriority","Name","Class","Identifier","Reason","SuggestedCommand","Caution") 120
    $dumpHtml = New-HtmlTable $dumps @("Type","Path","PackagePath","SizeMB","LastWriteTime") 10
    $dumpAnalysisHtml = New-HtmlTable $dumpAnalysis @("DumpFile","Status","BugCheck","ProbablyCausedBy","ProcessName","ModuleName","ImageName","SymbolName","FailureBucket","SuspectedArea","RecommendedAction","ExitCode","AnalysisFile","Note") 10
    $changedPolicyHtml = New-HtmlTable $changedPolicies @("Scope","PolicyRoot","KeyPath","ValueName","ValueKind","ValueData") 300

@"
<!doctype html>
<html lang="en">
<head>
  <meta charset="utf-8">
  <title>PCDiagLite Report</title>
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
    <h1>PCDiagLite Report</h1>
    <div class="meta">$ToolVersion | Created: $(Escape-Html (Format-FindingDate (Get-Date))) | Event range: $(Escape-Html $EventRangeText) | PrivacyMode: $([bool]$PrivacyMode)</div>
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
    <h2>Changed Policy Settings</h2>
    <p class="muted">Only explicit policy registry values found under common local Group Policy locations are shown.</p>
    $changedPolicyHtml
    <h2>Hardware Migration / Driver Context</h2>
    <h3>PnP Problem Devices</h3>
    $migrationPnpHtml
    <h3>Old Third-Party Hardware Drivers</h3>
    $migrationOldDriversHtml
    <h3>Vendor Driver Services</h3>
    $migrationVendorServicesHtml
    <h3>Driver Services With Missing Files</h3>
    $migrationMissingDriverFilesHtml
    <h3>Cleanup Candidates</h3>
    $migrationCleanupCandidatesHtml
    <h2>Disks</h2>
    $diskHtml
    <h2>Volumes</h2>
    $volumeHtml
    <h2>SMART Failure Prediction</h2>
    $smartPredictionHtml
    <h2>Network Adapters</h2>
    $netHtml
    <h2>Hosts File Check</h2>
    $hostsCheckHtml
    <h2>Active Hosts File Entries</h2>
    $hostsEntriesHtml
    <h2>DNS Client NRPT Rules</h2>
    $nrptRulesHtml
    <h2>Current TCP/UDP Endpoint Usage</h2>
    $endpointSummaryHtml
    <h2>Top TCP Endpoint Processes</h2>
    $tcpTopHtml
    <h2>Top UDP Endpoint Processes</h2>
    $udpTopHtml
    <h2>Top System Events</h2>
    $topHtml
    <h2>Targeted Stability / Storage / Network Events</h2>
    $targetedHtml
    <h2>Dumps</h2>
    $dumpHtml
    <h2>Minidump Analysis</h2>
    $dumpAnalysisHtml
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
    $areaGroupedFindingsHtml = New-AreaGroupedFindingCardsHtml -Findings $sortedFindings -MaxRowsPerArea 80
    $allFindingsHtml = New-HtmlTable $sortedFindings @("Severity","Category","Title","TimeContext","Evidence","Recommendation") 80
    $disks = Read-CsvSafe (Join-Path $Dirs.Storage "Disks.csv")
    $volumes = Read-CsvSafe (Join-Path $Dirs.Storage "Volumes.csv")
    $storageReliability = Read-CsvSafe (Join-Path $Dirs.Storage "StorageReliabilityCounter.csv")
    $smartPrediction = Read-CsvSafe (Join-Path $Dirs.Storage "Storage_SMART_FailurePrediction.csv")
    $noteworthySmartPrediction = @($smartPrediction | Where-Object {
        ([string]$_.PredictFailure -match 'True|1') -or
        (-not [string]::IsNullOrWhiteSpace([string]$_.Error))
    })
    $noteworthyStorageReliability = @($storageReliability | Where-Object {
        $currentTemp = ConvertTo-NumberSafe ([string]$_.Temperature)
        $maxTemp = ConvertTo-NumberSafe ([string]$_.TemperatureMax)
        $readErrors = ConvertTo-NumberSafe ([string]$_.ReadErrorsTotal)
        $writeErrors = ConvertTo-NumberSafe ([string]$_.WriteErrorsTotal)
        $readLatency = ConvertTo-NumberSafe ([string]$_.ReadLatencyMax)
        $writeLatency = ConvertTo-NumberSafe ([string]$_.WriteLatencyMax)
        $wear = ConvertTo-NumberSafe ([string]$_.Wear)
        $loadUnload = ConvertTo-NumberSafe ([string]$_.LoadUnloadCycleCount)
        $errorText = [string]$_.Error
        ($null -ne $currentTemp -and $currentTemp -ge 70) -or
        ($null -ne $maxTemp -and $maxTemp -ge 80) -or
        ($null -ne $readErrors -and $readErrors -gt 0) -or
        ($null -ne $writeErrors -and $writeErrors -gt 0) -or
        ($null -ne $readLatency -and $readLatency -ge 1000) -or
        ($null -ne $writeLatency -and $writeLatency -ge 1000) -or
        ($null -ne $wear -and $wear -ge 80) -or
        ($null -ne $loadUnload -and $loadUnload -ge 300000) -or
        (-not [string]::IsNullOrWhiteSpace($errorText))
    })
    $noteworthyDisks = @($disks | Where-Object {
        (($_.HealthStatus) -and ($_.HealthStatus -notmatch 'Healthy|Unknown')) -or
        (($_.OperationalStatus) -and ($_.OperationalStatus -notmatch 'OK|Online|No Media'))
    })
    $noteworthyVolumes = @($volumes | Where-Object {
        $freePercent = ConvertTo-NumberSafe $_.FreePercent
        $sizeGb = ConvertTo-NumberSafe $_.SizeGB
        (($_.HealthStatus) -and ($_.HealthStatus -notmatch 'Healthy|Unknown')) -or
        (($_.OperationalStatus) -and ($_.OperationalStatus -notmatch 'OK|Online|No Media')) -or
        ($null -ne $freePercent -and $null -ne $sizeGb -and $sizeGb -ge 10 -and $freePercent -lt 10)
    })
    $noteworthyStorageCount = $noteworthySmartPrediction.Count + $noteworthyStorageReliability.Count + $noteworthyDisks.Count + $noteworthyVolumes.Count
    $diskHtml = New-HtmlTable $noteworthyDisks @("Number","HarddiskPath","FriendlyName","SerialNumber","HealthStatus","OperationalStatus","BusType","SizeGB") 20
    $volumeHtml = New-HtmlTable $noteworthyVolumes @("DriveLetter","FileSystemLabel","FileSystem","HealthStatus","OperationalStatus","SizeGB","FreeGB","FreePercent") 30
    $storageReliabilityHtml = New-HtmlTable $noteworthyStorageReliability @("FriendlyName","Temperature","TemperatureMax","Wear","ReadErrorsTotal","WriteErrorsTotal","ReadLatencyMax","WriteLatencyMax","LoadUnloadCycleCount","Error") 30
    $smartPredictionHtml = New-HtmlTable $noteworthySmartPrediction @("InstanceName","Active","PredictFailure","Reason","Error") 30
    $timelineRows = Read-CsvSafe (Join-Path $Dirs.Runtime "TimelineEvents.csv")
    $timelineHtml = New-TimelineHtml -Rows $timelineRows -MaxRows 140
    $packageDisplay = if ([string]::IsNullOrWhiteSpace($PackagePath)) { "Will be created after completion." } else { $PackagePath }
    $reportPath = "00_Report.html"
    $textReportPath = "00_Findings_Summary.txt"
    $changedPolicies = Read-CsvSafe (Join-Path $Dirs.Policies "Changed_Policy_Registry_Values.csv")
    $changedPolicyHtml = New-HtmlTable $changedPolicies @("Scope","PolicyRoot","KeyPath","ValueName","ValueKind","ValueData") 300
    $changedPolicyCount = @($changedPolicies).Count

@"
<!doctype html>
<html lang="en">
<head>
  <meta charset="utf-8">
  <title>PCDiagLite Result</title>
  <style>
    :root {
      color-scheme: light;
      --ink:#17202a; --muted:#607083; --line:#d7dee8; --soft:#f5f7fa;
      --ok:#0f766e; --warn:#a16207; --high:#b45309; --bad:#b42318; --info:#475569;
      --network:#dbeafe; --network-line:#93c5fd; --network-ink:#1e3a8a;
      --storage:#dcfce7; --storage-line:#86efac; --storage-ink:#166534;
      --hardware:#f3e8ff; --hardware-line:#c4b5fd; --hardware-ink:#5b21b6;
      --migration:#f5f3ff; --migration-line:#c4b5fd; --migration-ink:#6d28d9;
      --stability:#ffedd5; --stability-line:#fdba74; --stability-ink:#9a3412;
      --services:#e0f2fe; --services-line:#7dd3fc; --services-ink:#075985;
      --drivers:#ede9fe; --drivers-line:#a5b4fc; --drivers-ink:#3730a3;
      --games:#f0fdf4; --games-line:#86efac; --games-ink:#15803d;
      --windows:#fef9c3; --windows-line:#fde68a; --windows-ink:#854d0e;
      --remote:#ccfbf1; --remote-line:#5eead4; --remote-ink:#115e59;
      --collection:#f1f5f9; --collection-line:#cbd5e1; --collection-ink:#334155;
      --general:#f8fafc; --general-line:#cbd5e1; --general-ink:#334155;
      --policy:#f8fafc; --policy-line:#cbd5e1; --policy-ink:#334155;
    }
    * { box-sizing:border-box; }
    body { margin:0; font-family: Segoe UI, Arial, sans-serif; color:var(--ink); background:#ffffff; }
    header { padding:30px 34px 22px; border-bottom:1px solid var(--line); background:#f8fafc; }
    main { padding:24px 34px 42px; max-width:1760px; margin:0 auto; }
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
    .result-layout { display:grid; grid-template-columns:minmax(0, 1fr) minmax(440px, 540px); gap:24px; align-items:start; }
    .findings-panel { min-width:0; }
    .area-list { display:grid; gap:14px; }
    .area-group { border:1px solid var(--line); border-radius:8px; background:#fff; border-left-width:6px; overflow:hidden; }
    .area-summary { list-style:none; cursor:pointer; display:flex; justify-content:space-between; align-items:center; gap:16px; padding:14px 16px; background:#fff; }
    .area-summary::-webkit-details-marker { display:none; }
    .area-summary:hover { background:#f8fafc; }
    .area-group[open] > .area-summary { border-bottom:1px solid var(--line); background:#f8fafc; }
    .area-summary h3 { margin:0 0 5px; font-size:18px; }
    .area-summary p { margin:0; color:var(--muted); font-size:13px; }
    .area-count { min-width:34px; height:34px; border-radius:999px; display:inline-flex; align-items:center; justify-content:center; background:#eef2f7; font-weight:700; }
    .area-content { padding:14px; }
    .severity-section + .severity-section { margin-top:16px; }
    .severity-section > h4 { margin:0 0 9px; color:var(--muted); font-size:12px; text-transform:uppercase; letter-spacing:.04em; }
    .finding-list { display:grid; gap:12px; }
    .finding { border:1px solid var(--line); border-radius:8px; padding:0; background:#fff; border-left-width:5px; overflow:hidden; }
    .finding > summary { list-style:none; cursor:pointer; padding:14px 15px; }
    .finding > summary::-webkit-details-marker { display:none; }
    .finding > summary:hover { background:rgba(248,250,252,.78); }
    .finding[open] > summary { border-bottom:1px solid var(--line); background:rgba(248,250,252,.9); }
    .sev-critical { border-left-color:var(--bad); }
    .sev-high { border-left-color:var(--high); }
    .sev-medium { border-left-color:var(--warn); }
    .sev-info { border-left-color:var(--info); }
    .finding-head { display:flex; align-items:center; gap:8px; flex-wrap:wrap; }
    .badge { display:inline-block; min-width:72px; text-align:center; border-radius:999px; padding:3px 9px; background:#eef2f7; font-size:12px; font-weight:650; }
    .category { display:inline-block; border-radius:999px; padding:3px 9px; font-size:12px; font-weight:650; color:var(--muted); background:#f1f5f9; }
    .open-hint { margin-top:9px; color:var(--muted); font-size:12px; }
    .finding-details { padding:14px 15px 16px; background:#fbfcfe; }
    .finding-details h4 { margin:0 0 9px; font-size:14px; }
    .event-details { margin:0; white-space:pre-wrap; overflow-wrap:anywhere; background:#101827; color:#e5e7eb; padding:13px; border-radius:8px; font-size:12px; line-height:1.45; max-height:620px; overflow:auto; }
    .paths { border:1px solid var(--line); border-radius:8px; padding:12px 13px; background:#f8fafc; overflow-wrap:anywhere; }
    .data-section { border:1px solid var(--storage-line); border-left:6px solid var(--storage-ink); border-radius:8px; background:var(--storage); overflow:hidden; }
    .data-section > summary { list-style:none; cursor:pointer; padding:14px 16px; display:flex; justify-content:space-between; align-items:center; gap:16px; }
    .data-section > summary::-webkit-details-marker { display:none; }
    .data-section > summary:hover { filter:saturate(1.05); }
    .data-section h3 { margin:0 0 5px; color:var(--storage-ink); }
    .data-section p { margin:0; color:var(--muted); font-size:13px; }
    .data-content { border-top:1px solid var(--storage-line); padding:14px 16px 16px; background:var(--storage); min-width:0; }
    .data-grid { display:grid; grid-template-columns:minmax(0,1fr); gap:16px; min-width:0; }
    .data-block { min-width:0; max-width:100%; }
    .data-block h4 { margin:0 0 8px; font-size:13px; color:var(--storage-ink); text-transform:uppercase; letter-spacing:.04em; }
    .policy-section { border-color:var(--policy-line); border-left-color:var(--policy-ink); background:var(--policy); }
    .policy-section > summary,
    .policy-section .data-content { background:var(--policy); }
    .policy-section h3,
    .policy-section .data-block h4 { color:var(--policy-ink); }
    .policy-section[open] > summary { border-bottom:1px solid var(--policy-line); }
    .table-scroll { display:block; width:100%; max-width:100%; overflow-x:auto; overflow-y:hidden; border-radius:8px; background:#fff; -webkit-overflow-scrolling:touch; }
    .table-scroll table { width:max-content; min-width:100%; max-width:none; }
    .table-scroll th, .table-scroll td { white-space:nowrap; }
    .timeline-panel { position:sticky; top:18px; max-height:calc(100vh - 36px); overflow:auto; border:1px solid var(--line); border-radius:8px; background:#fff; padding:16px 16px 18px; }
    .timeline-panel h2 { margin:0 0 4px; }
    .timeline-subtitle { color:var(--muted); font-size:12px; margin:0 0 16px; }
    .timeline-limit-note { margin:0 0 10px -18px; color:var(--muted); font-size:12px; }
    .timeline-list { position:relative; padding-left:18px; }
    .timeline-list::before { content:""; position:absolute; left:6px; top:4px; bottom:4px; width:2px; background:#cbd5e1; }
    .timeline-date { position:relative; z-index:1; display:inline-block; margin:10px 0 8px -18px; padding:4px 9px; border-radius:999px; background:#eef2f7; color:#334155; font-size:12px; font-weight:700; }
    .timeline-item { position:relative; margin:0 0 12px; }
    .timeline-summary { list-style:none; cursor:pointer; display:grid; grid-template-columns:16px minmax(0,1fr); gap:10px; }
    .timeline-summary::-webkit-details-marker { display:none; }
    .timeline-marker { position:relative; z-index:2; width:12px; height:12px; margin-top:8px; border:3px solid #fff; border-radius:50%; background:var(--info); box-shadow:0 0 0 2px var(--info); }
    .timeline-card { border:1px solid var(--line); border-radius:8px; padding:10px 11px; background:#fbfcfe; }
    .timeline-summary:hover .timeline-card { filter:saturate(1.04); }
    .timeline-item[open] .timeline-card { border-bottom-left-radius:0; border-bottom-right-radius:0; }
    .timeline-meta-row { display:flex; align-items:flex-start; justify-content:space-between; gap:8px; flex-wrap:wrap; }
    .timeline-time { color:#0f766e; font-size:12px; font-weight:750; }
    .timeline-chip-row { display:flex; gap:6px; flex-wrap:wrap; justify-content:flex-end; }
    .timeline-chip { display:inline-block; border:1px solid var(--line); border-radius:999px; padding:2px 8px; background:#fff; color:#334155; font-size:11px; font-weight:750; line-height:1.2; }
    .timeline-title { margin-top:3px; font-weight:750; font-size:13px; line-height:1.25; }
    .timeline-source { margin-top:4px; color:var(--muted); font-size:11px; line-height:1.25; overflow-wrap:anywhere; }
    .timeline-card p { margin:7px 0 0; color:#334155; font-size:12px; line-height:1.35; }
    .timeline-open-hint { margin-top:7px; color:var(--muted); font-size:11px; }
    .timeline-detail { margin:0 0 0 26px; border:1px solid var(--line); border-top:0; border-radius:0 0 8px 8px; background:#fbfcfe; padding:10px; }
    .timeline-detail .event-details { max-height:420px; font-size:11px; }
    .timeline-empty { color:var(--muted); border:1px dashed var(--line); border-radius:8px; padding:12px; background:#f8fafc; font-size:13px; }
    .timeline-item.sev-critical .timeline-marker { background:var(--bad); box-shadow:0 0 0 2px var(--bad); }
    .timeline-item.sev-high .timeline-marker { background:var(--high); box-shadow:0 0 0 2px var(--high); }
    .timeline-item.sev-medium .timeline-marker { background:var(--warn); box-shadow:0 0 0 2px var(--warn); }
    .timeline-item.sev-info .timeline-marker { background:var(--info); box-shadow:0 0 0 2px var(--info); }
    .cat-network { --cat-bg:var(--network); --cat-line:var(--network-line); --cat-ink:var(--network-ink); }
    .cat-storage { --cat-bg:var(--storage); --cat-line:var(--storage-line); --cat-ink:var(--storage-ink); }
    .cat-hardware { --cat-bg:var(--hardware); --cat-line:var(--hardware-line); --cat-ink:var(--hardware-ink); }
    .cat-migration { --cat-bg:var(--migration); --cat-line:var(--migration-line); --cat-ink:var(--migration-ink); }
    .cat-crash, .cat-stability { --cat-bg:var(--stability); --cat-line:var(--stability-line); --cat-ink:var(--stability-ink); }
    .cat-services { --cat-bg:var(--services); --cat-line:var(--services-line); --cat-ink:var(--services-ink); }
    .cat-drivers { --cat-bg:var(--drivers); --cat-line:var(--drivers-line); --cat-ink:var(--drivers-ink); }
    .cat-games { --cat-bg:var(--games); --cat-line:var(--games-line); --cat-ink:var(--games-ink); }
    .cat-windows { --cat-bg:var(--windows); --cat-line:var(--windows-line); --cat-ink:var(--windows-ink); }
    .cat-remote { --cat-bg:var(--remote); --cat-line:var(--remote-line); --cat-ink:var(--remote-ink); }
    .cat-collection, .cat-general { --cat-bg:var(--general); --cat-line:var(--general-line); --cat-ink:var(--general-ink); }
    .area-group[class*="cat-"], .finding[class*="cat-"] { border-color:var(--cat-line); border-left-color:var(--cat-ink); background:var(--cat-bg); }
    .area-group[class*="cat-"] > .area-summary,
    .area-group[class*="cat-"][open] > .area-summary,
    .area-group[class*="cat-"] .area-content,
    .finding[class*="cat-"] > summary,
    .finding[class*="cat-"][open] > summary,
    .finding[class*="cat-"] .finding-details { background:var(--cat-bg); }
    .area-group[class*="cat-"][open] > .area-summary,
    .finding[class*="cat-"][open] > summary { border-bottom-color:var(--cat-line); }
    .area-group[class*="cat-"] > .area-summary:hover,
    .finding[class*="cat-"] > summary:hover { background:var(--cat-bg); filter:saturate(1.06); }
    .finding[class*="cat-"] .category,
    .timeline-item[class*="cat-"] .timeline-source { color:var(--cat-ink); }
    .category[class*="cat-"] { background:var(--cat-bg); color:var(--cat-ink); }
    .timeline-item[class*="cat-"] .timeline-card,
    .timeline-item[class*="cat-"] .timeline-detail { background:var(--cat-bg); border-color:var(--cat-line); }
    .timeline-item[class*="cat-"] .timeline-time { color:var(--cat-ink); }
    .timeline-chip.sev-critical { color:#7f1d1d; border-color:#fca5a5; background:#fee2e2; }
    .timeline-chip.sev-high { color:#92400e; border-color:#fcd34d; background:#fef3c7; }
    .timeline-chip.sev-medium { color:#854d0e; border-color:#fde68a; background:#fef9c3; }
    .timeline-chip.sev-info { color:#334155; border-color:#cbd5e1; background:#f8fafc; }
    .timeline-chip.category-chip[class*="cat-"] { color:var(--cat-ink); border-color:var(--cat-line); background:#fff; }
    .muted { color:var(--muted); }
    @media (max-width:1100px) {
      main { padding:18px 18px 34px; }
      .result-layout { grid-template-columns:1fr; }
      .timeline-panel { position:static; max-height:none; }
    }
  </style>
</head>
<body>
  <header>
    <h1>PCDiagLite Result</h1>
    <div class="meta">$ToolVersion | Created: $(Escape-Html (Format-FindingDate (Get-Date))) | Computer: $(Escape-Html $env:COMPUTERNAME) | Event range: $(Escape-Html $EventRangeText)</div>
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
    <div class="result-layout">
      <section class="findings-panel">
        <h2>Findings by Primary Area</h2>
        $areaGroupedFindingsHtml

        <h2>Noteworthy Storage Data</h2>
        <details class="data-section" open>
          <summary>
            <div>
              <h3>Storage signals</h3>
              <p>Only unusual SMART, reliability, disk, volume, or free-space rows from this run. Full raw data stays in 03_Storage.</p>
            </div>
            <span class="area-count">$noteworthyStorageCount</span>
          </summary>
          <div class="data-content">
            <div class="data-grid">
              <section class="data-block">
                <h4>SMART Failure Prediction</h4>
                <div class="table-scroll">$smartPredictionHtml</div>
              </section>
              <section class="data-block">
                <h4>Storage Reliability Counters with Signals</h4>
                <div class="table-scroll">$storageReliabilityHtml</div>
              </section>
              <section class="data-block">
                <h4>Disks with Non-OK Status</h4>
                <div class="table-scroll">$diskHtml</div>
              </section>
              <section class="data-block">
                <h4>Volumes with Non-OK Status or Low Free Space</h4>
                <div class="table-scroll">$volumeHtml</div>
              </section>
            </div>
          </div>
        </details>

        <h2>All Findings</h2>
        $allFindingsHtml

        <h2>Changed Policy Settings</h2>
        <details class="data-section policy-section">
          <summary>
            <div>
              <h3>Explicit policy registry values</h3>
              <p>Only set values from common local Group Policy registry locations. Empty/default policy areas are not listed.</p>
            </div>
            <span class="area-count">$changedPolicyCount</span>
          </summary>
          <div class="data-content">
            <div class="data-grid">
              <section class="data-block">
                <h4>Changed Policies</h4>
                <div class="table-scroll">$changedPolicyHtml</div>
              </section>
            </div>
          </div>
        </details>

        <h2>Files</h2>
        <div class="paths">
          <p><strong>ZIP package:</strong> $(Escape-Html $packageDisplay)</p>
          <p><strong>Detailed report inside the package:</strong> $(Escape-Html $reportPath)</p>
          <p><strong>Text findings summary inside the package:</strong> $(Escape-Html $textReportPath)</p>
        </div>
      </section>
      <aside class="timeline-panel">
        <h2>Timeline</h2>
        <p class="timeline-subtitle">Newest captured Event Viewer records connected to findings, shown newest first.</p>
        $timelineHtml
      </aside>
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

$termddFile = "C:\Windows\System32\drivers\termdd.sys"
$termService = Get-Service -Name TermService -ErrorAction SilentlyContinue
$termddService = Get-Service -Name TermDD -ErrorAction SilentlyContinue
$rdpTcpListening = $false
try {
    $rdpTcpListening = [bool](Get-NetTCPConnection -LocalPort 3389 -State Listen -ErrorAction SilentlyContinue | Select-Object -First 1)
} catch {}

[PSCustomObject]@{
    TermddSysExists = Test-Path -LiteralPath $termddFile
    TermddSysPath = $termddFile
    TermServiceStatus = if ($termService) { $termService.Status } else { "Missing" }
    TermServiceStartType = if ($termService) { $termService.StartType } else { "" }
    TermDDStatus = if ($termddService) { $termddService.Status } else { "Missing" }
    TermDDStartType = if ($termddService) { $termddService.StartType } else { "" }
    RdpTcp3389Listening = $rdpTcpListening
} | Export-Csv (Join-Path $Dirs.System "RemoteDesktop_Basic_Check.csv") -NoTypeInformation -Encoding UTF8
'@

Invoke-ChildPowerShellWithTimeout -Name "OS, uptime, and basic hardware inventory" -ScriptContent $SystemInventoryScript -TimeoutSeconds $StepTimeoutSeconds | Out-Null

# ==================================================================================================
# Section 4: Storage / disks
# ==================================================================================================
# Why:
# Storage errors are a common cause of freezes, slowdowns, failed updates, and application hangs.
# The key question is which disk number belongs to which physical drive and drive letter.

$StorageInventoryScript = New-ChildScript @'
Get-Disk |
    Select-Object Number, @{Name="HarddiskPath";Expression={"\\Device\\Harddisk$($_.Number)"}},
                  FriendlyName, SerialNumber, FirmwareVersion, HealthStatus,
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

$diskLookup = @{}
Get-Disk | ForEach-Object { $diskLookup[[string]$_.Number] = $_ }

Get-Partition | ForEach-Object {
    $partition = $_
    $disk = $diskLookup[[string]$partition.DiskNumber]
    $volume = $null
    try { $volume = $partition | Get-Volume -ErrorAction SilentlyContinue } catch {}
    $driveLetter = [string]$partition.DriveLetter
    if ([string]::IsNullOrWhiteSpace($driveLetter) -or ([int][char]$partition.DriveLetter -eq 0)) { $driveLetter = "" }
    [PSCustomObject]@{
        DiskNumber = $partition.DiskNumber
        HarddiskPath = "\\Device\\Harddisk$($partition.DiskNumber)"
        DiskFriendlyName = if ($disk) { $disk.FriendlyName } else { "" }
        DiskSerialNumber = if ($disk) { $disk.SerialNumber } else { "" }
        DiskBusType = if ($disk) { $disk.BusType } else { "" }
        PartitionNumber = $partition.PartitionNumber
        DriveLetter = $driveLetter
        VolumeLabel = if ($volume) { $volume.FileSystemLabel } else { "" }
        FileSystem = if ($volume) { $volume.FileSystem } else { "" }
        Type = $partition.Type
        GptType = $partition.GptType
        SizeGB = [math]::Round($partition.Size / 1GB, 2)
    }
} | Export-Csv (Join-Path $Dirs.Storage "Partitions.csv") -NoTypeInformation -Encoding UTF8

Get-CimInstance Win32_DiskDrive |
    Select-Object Index, @{Name="HarddiskPath";Expression={"\\Device\\Harddisk$($_.Index)"}},
                  Model, SerialNumber, FirmwareRevision, InterfaceType, MediaType,
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
                HarddiskPath  = "\\Device\\Harddisk$($disk.Index)"
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
`$smartFile = '$($Dirs.Storage.Replace("'","''"))\Storage_SMART_FailurePrediction.csv'
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

try {
    Get-CimInstance -Namespace root\wmi -ClassName MSStorageDriver_FailurePredictStatus -ErrorAction Stop |
        Select-Object InstanceName, Active, PredictFailure, Reason |
        Export-Csv `$smartFile -NoTypeInformation -Encoding UTF8
} catch {
    [PSCustomObject]@{
        InstanceName = ""
        Active = ""
        PredictFailure = ""
        Reason = ""
        Error = `$_.Exception.Message
    } | Export-Csv `$smartFile -NoTypeInformation -Encoding UTF8
}
"@

Invoke-ChildPowerShellWithTimeout -Name "Storage Reliability Counter" -ScriptContent $StorageReliabilityScript -TimeoutSeconds 45 | Out-Null

# ==================================================================================================
# Section 5: Network
# ==================================================================================================
# Why:
# Network issues on desktop PCs can look like broken updates, browser failures, VPN issues, or remote-tool drops.
# Therefore we collect driver version, link speed, IPs, offload settings, endpoint counts, and power saving options.

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
    Select-Object InterfaceAlias, InterfaceIndex, AddressFamily,
                  @{Name="ServerAddresses";Expression={($_.ServerAddresses -join "; ")}},
                  @{Name="AddressCount";Expression={@($_.ServerAddresses).Count}} |
    Export-Csv (Join-Path $Dirs.Network "DnsClientServerAddress.csv") -NoTypeInformation -Encoding UTF8

Get-DnsClientNrptRule -ErrorAction SilentlyContinue |
    Select-Object Namespace, NameServers, DirectAccessDnsServers, Comment, DisplayName, NameEncoding, DnsSecValidationRequired |
    Export-Csv (Join-Path $Dirs.Network "DnsClientNrptRule.csv") -NoTypeInformation -Encoding UTF8

$hostsPath = Join-Path $env:WINDIR "System32\drivers\etc\hosts"
$hostsEntries = New-Object System.Collections.Generic.List[object]
$hostsStatus = [ordered]@{
    Path = $hostsPath
    Exists = [System.IO.File]::Exists($hostsPath)
    Readable = $false
    SizeBytes = ""
    LastWriteTime = ""
    ActiveEntryCount = 0
    InvalidLineCount = 0
    LoopbackEntryCount = 0
    Error = ""
}

try {
    if ($hostsStatus.Exists) {
        $hostsFile = Get-Item -LiteralPath $hostsPath -ErrorAction Stop
        $hostsStatus.SizeBytes = $hostsFile.Length
        $hostsStatus.LastWriteTime = $hostsFile.LastWriteTime
        $lines = @(Get-Content -LiteralPath $hostsPath -ErrorAction Stop)
        $hostsStatus.Readable = $true
        for ($lineIndex = 0; $lineIndex -lt $lines.Count; $lineIndex++) {
            $rawLine = [string]$lines[$lineIndex]
            $trimmedLine = $rawLine.Trim()
            if ([string]::IsNullOrWhiteSpace($trimmedLine) -or $trimmedLine.StartsWith("#")) {
                continue
            }

            $contentPart = ($trimmedLine -split '#', 2)[0].Trim()
            if ([string]::IsNullOrWhiteSpace($contentPart)) {
                continue
            }

            $parts = @($contentPart -split '\s+' | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })
            $parsedIp = $null
            $isIpAddress = $parts.Count -ge 2 -and [System.Net.IPAddress]::TryParse([string]$parts[0], [ref]$parsedIp)
            if (-not $isIpAddress) {
                $hostsStatus.InvalidLineCount++
                $hostsEntries.Add([PSCustomObject]@{
                    LineNumber = $lineIndex + 1
                    Target = if ($parts.Count -gt 0) { $parts[0] } else { "" }
                    Hostnames = ""
                    EntryType = "Invalid"
                    RawLine = $rawLine
                })
                continue
            }

            $hostNames = @($parts | Select-Object -Skip 1)
            $isLoopback = [string]$parts[0] -match '^(127\.|::1$|0\.0\.0\.0$)'
            if ($isLoopback) {
                $hostsStatus.LoopbackEntryCount++
            }
            $hostsStatus.ActiveEntryCount++
            $hostsEntries.Add([PSCustomObject]@{
                LineNumber = $lineIndex + 1
                Target = [string]$parts[0]
                Hostnames = ($hostNames -join "; ")
                EntryType = if ($isLoopback) { "Loopback/block" } else { "Custom mapping" }
                RawLine = $rawLine
            })
        }
    }
} catch {
    $hostsStatus.Error = $_.Exception.Message
}

[PSCustomObject]$hostsStatus |
    Export-Csv (Join-Path $Dirs.Network "Hosts_File_Check.csv") -NoTypeInformation -Encoding UTF8

if ($hostsEntries.Count -gt 0) {
    $hostsEntries |
        Export-Csv (Join-Path $Dirs.Network "Hosts_File_ActiveEntries.csv") -NoTypeInformation -Encoding UTF8
} else {
    [PSCustomObject]@{
        LineNumber = ""
        Target = ""
        Hostnames = ""
        EntryType = ""
        RawLine = ""
    } | Export-Csv (Join-Path $Dirs.Network "Hosts_File_ActiveEntries.csv") -NoTypeInformation -Encoding UTF8
}

function Resolve-EndpointProcess {
    param([AllowNull()][int]$ProcessIdValue)

    if ($null -eq $ProcessIdValue -or $ProcessIdValue -le 0) {
        return [PSCustomObject]@{ ProcessName = ""; Path = "" }
    }

    try {
        $process = Get-Process -Id $ProcessIdValue -ErrorAction Stop
        return [PSCustomObject]@{
            ProcessName = $process.ProcessName
            Path = try { $process.Path } catch { "" }
        }
    } catch {
        return [PSCustomObject]@{ ProcessName = ""; Path = "" }
    }
}

$tcpConnections = @(Get-NetTCPConnection -ErrorAction SilentlyContinue)
$tcpConnections |
    Group-Object OwningProcess |
    Sort-Object Count -Descending |
    Select-Object -First 30 |
    ForEach-Object {
        $owningProcessId = [int]$_.Name
        $processInfo = Resolve-EndpointProcess -ProcessIdValue $owningProcessId
        $states = ($_.Group | Group-Object State | Sort-Object Count -Descending | ForEach-Object { "$($_.Name)=$($_.Count)" }) -join "; "
        [PSCustomObject]@{
            PID = $owningProcessId
            Count = $_.Count
            Process = $processInfo.ProcessName
            Path = $processInfo.Path
            States = $states
        }
    } |
    Export-Csv (Join-Path $Dirs.Network "TCP_Endpoints_By_Process_Top30.csv") -NoTypeInformation -Encoding UTF8

$udpEndpoints = @(Get-NetUDPEndpoint -ErrorAction SilentlyContinue)
$udpEndpoints |
    Group-Object OwningProcess |
    Sort-Object Count -Descending |
    Select-Object -First 30 |
    ForEach-Object {
        $owningProcessId = [int]$_.Name
        $processInfo = Resolve-EndpointProcess -ProcessIdValue $owningProcessId
        [PSCustomObject]@{
            PID = $owningProcessId
            Count = $_.Count
            Process = $processInfo.ProcessName
            Path = $processInfo.Path
        }
    } |
    Export-Csv (Join-Path $Dirs.Network "UDP_Endpoints_By_Process_Top30.csv") -NoTypeInformation -Encoding UTF8

$tcpTop = @($tcpConnections | Group-Object OwningProcess | Sort-Object Count -Descending | Select-Object -First 1)
$udpTop = @($udpEndpoints | Group-Object OwningProcess | Sort-Object Count -Descending | Select-Object -First 1)
@(
    [PSCustomObject]@{
        Protocol = "TCP"
        TotalEndpoints = $tcpConnections.Count
        UniqueProcesses = @($tcpConnections | Group-Object OwningProcess).Count
        TopProcessPID = if ($tcpTop.Count -gt 0) { $tcpTop[0].Name } else { "" }
        TopProcessCount = if ($tcpTop.Count -gt 0) { $tcpTop[0].Count } else { 0 }
    }
    [PSCustomObject]@{
        Protocol = "UDP"
        TotalEndpoints = $udpEndpoints.Count
        UniqueProcesses = @($udpEndpoints | Group-Object OwningProcess).Count
        TopProcessPID = if ($udpTop.Count -gt 0) { $udpTop[0].Name } else { "" }
        TopProcessCount = if ($udpTop.Count -gt 0) { $udpTop[0].Count } else { 0 }
    }
) | Export-Csv (Join-Path $Dirs.Network "Endpoint_Summary.csv") -NoTypeInformation -Encoding UTF8

@"
IPv4 TCP dynamic port range
===========================
$(netsh int ipv4 show dynamicport tcp 2>&1)

IPv4 UDP dynamic port range
===========================
$(netsh int ipv4 show dynamicport udp 2>&1)

IPv6 TCP dynamic port range
===========================
$(netsh int ipv6 show dynamicport tcp 2>&1)

IPv6 UDP dynamic port range
===========================
$(netsh int ipv6 show dynamicport udp 2>&1)
"@ | Out-File (Join-Path $Dirs.Network "Dynamic_Port_Ranges.txt") -Encoding UTF8
'@

Invoke-ChildPowerShellWithTimeout -Name "Network adapters, IPs, and NIC settings" -ScriptContent $NetworkInventoryScript -TimeoutSeconds $StepTimeoutSeconds | Out-Null

Invoke-ExternalWithTimeout -Name "ipconfig /all" -Command "ipconfig /all" -OutputFile (Join-Path $Dirs.Network "ipconfig_all.txt") -TimeoutSeconds 20

# ==================================================================================================
# Section 6: Power, sleep, wake
# ==================================================================================================
# Why:
# For desktop PCs, standby, hibernate, wake timers, and device wake state are relevant for sleep/resume issues.
# Each powercfg command gets its own timeout so nothing can block the full run.

Invoke-ExternalWithTimeout -Name "powercfg available sleepstates" -Command "powercfg /a" -OutputFile (Join-Path $Dirs.Power "powercfg_available_sleepstates.txt") -TimeoutSeconds 20
Invoke-ExternalWithTimeout -Name "powercfg active scheme" -Command "powercfg /getactivescheme" -OutputFile (Join-Path $Dirs.Power "powercfg_active_scheme.txt") -TimeoutSeconds 20
Invoke-ExternalWithTimeout -Name "powercfg requests" -Command "powercfg /requests" -OutputFile (Join-Path $Dirs.Power "powercfg_requests.txt") -TimeoutSeconds 20
Invoke-ExternalWithTimeout -Name "powercfg lastwake" -Command "powercfg /lastwake" -OutputFile (Join-Path $Dirs.Power "powercfg_lastwake.txt") -TimeoutSeconds 20
Invoke-ExternalWithTimeout -Name "powercfg waketimers" -Command "powercfg /waketimers" -OutputFile (Join-Path $Dirs.Power "powercfg_waketimers.txt") -TimeoutSeconds 20
Invoke-ExternalWithTimeout -Name "powercfg wake armed devices" -Command "powercfg /devicequery wake_armed" -OutputFile (Join-Path $Dirs.Power "powercfg_wake_armed_devices.txt") -TimeoutSeconds 20

# ==================================================================================================
# Section 7: Changed local policy registry values
# ==================================================================================================
# Why:
# Many desktop tweaks and hardening tools leave explicit Group Policy style registry values behind.
# Only actual value entries under policy locations are exported, so the result stays readable.

$PolicyInventoryScript = New-ChildScript @'
function Convert-PolicyValueToText {
    param([AllowNull()][object]$Value)

    if ($null -eq $Value) { return "" }
    if ($Value -is [byte[]]) {
        return (($Value | ForEach-Object { $_.ToString("X2") }) -join " ")
    }
    if ($Value -is [array]) {
        return (($Value | ForEach-Object { [string]$_ }) -join "; ")
    }
    return [string]$Value
}

$roots = @(
    [PSCustomObject]@{ Scope = "Computer"; RootName = "HKLM\SOFTWARE\Policies"; NativeRootName = "HKEY_LOCAL_MACHINE\SOFTWARE\Policies"; Path = "HKLM:\SOFTWARE\Policies" },
    [PSCustomObject]@{ Scope = "User"; RootName = "HKCU\SOFTWARE\Policies"; NativeRootName = "HKEY_CURRENT_USER\SOFTWARE\Policies"; Path = "HKCU:\SOFTWARE\Policies" },
    [PSCustomObject]@{ Scope = "Computer"; RootName = "HKLM\SOFTWARE\Microsoft\Windows\CurrentVersion\Policies"; NativeRootName = "HKEY_LOCAL_MACHINE\SOFTWARE\Microsoft\Windows\CurrentVersion\Policies"; Path = "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Policies" },
    [PSCustomObject]@{ Scope = "User"; RootName = "HKCU\SOFTWARE\Microsoft\Windows\CurrentVersion\Policies"; NativeRootName = "HKEY_CURRENT_USER\SOFTWARE\Microsoft\Windows\CurrentVersion\Policies"; Path = "HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\Policies" },
    [PSCustomObject]@{ Scope = "Computer"; RootName = "HKLM\SYSTEM\CurrentControlSet\Policies"; NativeRootName = "HKEY_LOCAL_MACHINE\SYSTEM\CurrentControlSet\Policies"; Path = "HKLM:\SYSTEM\CurrentControlSet\Policies" }
)

$rows = New-Object System.Collections.Generic.List[object]
$errors = New-Object System.Collections.Generic.List[string]
$providerColumns = @("PSPath","PSParentPath","PSChildName","PSDrive","PSProvider")

foreach ($root in $roots) {
    if (-not (Test-Path -LiteralPath $root.Path)) { continue }

    $keys = @()
    try {
        $keys += Get-Item -LiteralPath $root.Path -ErrorAction Stop
        $keys += Get-ChildItem -LiteralPath $root.Path -Recurse -ErrorAction Stop
    } catch {
        $errors.Add("$($root.RootName): $($_.Exception.Message)") | Out-Null
        try {
            $keys += Get-ChildItem -LiteralPath $root.Path -Recurse -ErrorAction SilentlyContinue
        } catch {}
    }

    foreach ($key in @($keys | Sort-Object Name -Unique)) {
        try {
            $props = Get-ItemProperty -LiteralPath $key.PSPath -ErrorAction Stop
            $valueNames = @($props.PSObject.Properties |
                Where-Object { $providerColumns -notcontains $_.Name } |
                Select-Object -ExpandProperty Name)

            foreach ($valueName in $valueNames) {
                $valueKind = ""
                try { $valueKind = [string]$key.GetValueKind($valueName) } catch {}
                $relativePath = [string]$key.Name
                if ($relativePath.StartsWith($root.NativeRootName)) {
                    $relativePath = $relativePath.Substring($root.NativeRootName.Length).TrimStart('\')
                } elseif ($relativePath.StartsWith($root.RootName)) {
                    $relativePath = $relativePath.Substring($root.RootName.Length).TrimStart('\')
                }

                $rows.Add([PSCustomObject]@{
                    Scope      = $root.Scope
                    PolicyRoot = $root.RootName
                    KeyPath    = $relativePath
                    ValueName  = $valueName
                    ValueKind  = $valueKind
                    ValueData  = Convert-PolicyValueToText $props.$valueName
                }) | Out-Null
            }
        } catch {
            $errors.Add("$($key.Name): $($_.Exception.Message)") | Out-Null
        }
    }
}

$rows |
    Sort-Object Scope, PolicyRoot, KeyPath, ValueName |
    Export-Csv (Join-Path $Dirs.Policies "Changed_Policy_Registry_Values.csv") -NoTypeInformation -Encoding UTF8

if ($errors.Count -gt 0) {
    $errors | Sort-Object -Unique | Out-File (Join-Path $Dirs.Policies "Policy_Registry_Collection_Errors.txt") -Encoding UTF8
}
'@

Invoke-ChildPowerShellWithTimeout -Name "Changed policy registry values" -ScriptContent $PolicyInventoryScript -TimeoutSeconds 45 | Out-Null

# ==================================================================================================
# Section 8: Relevant drivers instead of a full driver list
# ==================================================================================================
# Why:
# For desktop instability, network, storage, disk, system, and low-level utility drivers are most relevant.
# A full driver list would make the package larger and harder to read.

$DriverInventoryScript = New-ChildScript @'
$wantedClasses = @("Net", "SCSIAdapter", "HDC", "DiskDrive", "Storage", "System")

Get-CimInstance Win32_PnPSignedDriver |
    Where-Object { $wantedClasses -contains $_.DeviceClass } |
    Select-Object DeviceName, DeviceClass, Manufacturer, DriverVersion, DriverDate, InfName, DeviceID |
    Export-Csv (Join-Path $Dirs.System "Relevant_Drivers_Network_Storage_System.csv") -NoTypeInformation -Encoding UTF8

$migrationClasses = @("Display", "Net", "SCSIAdapter", "HDC", "DiskDrive", "Storage", "System", "MEDIA", "Processor")
$oldDriverCutoff = (Get-Date).AddYears(-4)
Get-CimInstance Win32_PnPSignedDriver |
    Where-Object {
        $migrationClasses -contains $_.DeviceClass -and
        "$($_.Manufacturer)" -notmatch 'Microsoft|Windows|Standard|Standardsystem|WireGuard|Tailscale' -and
        $_.DriverDate -and
        ([datetime]$_.DriverDate) -lt $oldDriverCutoff
    } |
    Select-Object DeviceName, DeviceClass, Manufacturer, DriverVersion, DriverDate, InfName, DeviceID |
    Export-Csv (Join-Path $Dirs.System "HardwareMigration_OldThirdPartyDrivers.csv") -NoTypeInformation -Encoding UTF8

if (Get-Command Get-PnpDevice -ErrorAction SilentlyContinue) {
    Get-PnpDevice -ErrorAction SilentlyContinue |
        Where-Object {
            $migrationClasses -contains $_.Class -and
            "$($_.Status)" -notmatch '^OK$' -and
            "$($_.Class)" -notmatch 'LegacyDriver|VolumeSnapshot'
        } |
        Select-Object Status, Class, FriendlyName, InstanceId, Problem |
        Export-Csv (Join-Path $Dirs.System "HardwareMigration_PnpProblemDevices.csv") -NoTypeInformation -Encoding UTF8
} else {
    [PSCustomObject]@{
        Status = ""
        Class = ""
        FriendlyName = ""
        InstanceId = ""
        Problem = "Get-PnpDevice is not available on this system."
    } | Export-Csv (Join-Path $Dirs.System "HardwareMigration_PnpProblemDevices.csv") -NoTypeInformation -Encoding UTF8
}

Get-CimInstance Win32_SystemDriver |
    Where-Object { "$($_.Name) $($_.DisplayName) $($_.PathName)" -match 'inpout|WinRing|WinRing0|IOMap|OpenLibSys' } |
    Select-Object Name, DisplayName, State, Status, StartMode, PathName |
    Export-Csv (Join-Path $Dirs.System "LowLevel_Hardware_Access_Drivers.csv") -NoTypeInformation -Encoding UTF8

$legacyVendorPattern = '(?i)\bAMD\b|\bATI\b|NVIDIA|Intel|Realtek|ASUS|MSI|Micro-Star|Gigabyte|Aorus|ASRock|A-Volute|Nahimic|Sonic|Killer|Rivet'
Get-CimInstance Win32_SystemDriver |
    Where-Object { "$($_.Name) $($_.DisplayName) $($_.PathName)" -match $legacyVendorPattern } |
    ForEach-Object {
        $vendorGroup = "Other"
        $driverText = "$($_.Name) $($_.DisplayName) $($_.PathName)"
        if ($driverText -match 'AMD|ATI') { $vendorGroup = "AMD" }
        elseif ($driverText -match 'NVIDIA|nvlddmkm|nvhda|nvvad') { $vendorGroup = "NVIDIA" }
        elseif ($driverText -match 'Intel|iaStor|e1|e2f|Netwtw') { $vendorGroup = "Intel" }
        elseif ($driverText -match 'Realtek|RTKVHD|Rtk') { $vendorGroup = "Realtek" }
        elseif ($driverText -match 'ASUS|Asus|Armoury|Aura|ASIO') { $vendorGroup = "ASUS" }
        elseif ($driverText -match 'MSI|Micro-Star') { $vendorGroup = "MSI" }
        elseif ($driverText -match 'Gigabyte|Aorus') { $vendorGroup = "Gigabyte" }
        elseif ($driverText -match 'A-Volute|Nahimic|Sonic') { $vendorGroup = "Audio Enhancement" }
        [PSCustomObject]@{
            VendorGroup = $vendorGroup
            Name = $_.Name
            DisplayName = $_.DisplayName
            State = $_.State
            Status = $_.Status
            StartMode = $_.StartMode
            PathName = $_.PathName
        }
    } |
    Export-Csv (Join-Path $Dirs.System "HardwareMigration_VendorDriverServices.csv") -NoTypeInformation -Encoding UTF8

Get-CimInstance Win32_SystemDriver |
    ForEach-Object {
        $pathText = [string]$_.PathName
        if (-not [string]::IsNullOrWhiteSpace($pathText)) {
            $candidate = $pathText.Trim()
            if ($candidate.StartsWith('"')) {
                $candidate = ($candidate -split '"')[1]
            } else {
                $candidate = ($candidate -split '\s+')[0]
            }
            if ($candidate -match '^\\\?\?\\') {
                $candidate = $candidate -replace '^\\\?\?\\', ''
            }
            if ($candidate -match '^\\SystemRoot\\') {
                $candidate = Join-Path $env:WINDIR ($candidate.Substring(12))
            } elseif ($candidate -match '^System32\\') {
                $candidate = Join-Path $env:WINDIR $candidate
            }
            if ($candidate -match '\.sys$' -and -not (Test-Path -LiteralPath $candidate -ErrorAction SilentlyContinue)) {
                [PSCustomObject]@{
                    Name = $_.Name
                    DisplayName = $_.DisplayName
                    State = $_.State
                    Status = $_.Status
                    StartMode = $_.StartMode
                    MissingPath = $candidate
                    OriginalPathName = $_.PathName
                }
            }
        }
    } |
    Export-Csv (Join-Path $Dirs.System "HardwareMigration_DriverServices_MissingFiles.csv") -NoTypeInformation -Encoding UTF8

Get-Service |
    Where-Object { "$($_.Name) $($_.DisplayName)" -match 'inpout|WinRing|WinRing0|IOMap|OpenLibSys' } |
    Select-Object Name, DisplayName, Status, StartType, ServiceType |
    Export-Csv (Join-Path $Dirs.System "LowLevel_Hardware_Access_Services.csv") -NoTypeInformation -Encoding UTF8

$remoteVirtualPattern = 'Tailscale|Surfshark|OpenVPN|WireGuard|Wintun|VMware|Hyper-V|Parsec|RustDesk|Nefarius|ViGEm|Virtual Gamepad|Logitech.*Virtual|hcmon|usbip|Virtual Display|DCO'

$remoteDrivers = Get-CimInstance Win32_PnPSignedDriver |
    Where-Object { "$($_.DeviceName) $($_.Manufacturer) $($_.InfName) $($_.DeviceID)" -match $remoteVirtualPattern } |
    Select-Object DeviceName, DeviceClass, Manufacturer, DriverVersion, DriverDate, InfName, DeviceID

$remoteServices = Get-CimInstance Win32_Service |
    Where-Object { "$($_.Name) $($_.DisplayName) $($_.PathName)" -match $remoteVirtualPattern } |
    Select-Object Name, DisplayName, State, StartMode, PathName

@(
    $remoteDrivers | ForEach-Object {
        [PSCustomObject]@{
            Source = "Driver"
            Name = $_.DeviceName
            Class = $_.DeviceClass
            Status = ""
            Version = $_.DriverVersion
            Date = $_.DriverDate
            Detail = "$($_.Manufacturer) $($_.InfName) $($_.DeviceID)"
        }
    }
    $remoteServices | ForEach-Object {
        [PSCustomObject]@{
            Source = "Service"
            Name = $_.DisplayName
            Class = $_.Name
            Status = $_.State
            Version = ""
            Date = ""
            Detail = "$($_.StartMode) $($_.PathName)"
        }
    }
) | Export-Csv (Join-Path $Dirs.System "Remote_Virtualization_Network_Tools.csv") -NoTypeInformation -Encoding UTF8

Get-HotFix |
    Sort-Object InstalledOn -Descending |
    Select-Object -First 40 |
    Export-Csv (Join-Path $Dirs.System "Recent_Hotfixes_Last40.csv") -NoTypeInformation -Encoding UTF8
'@

Invoke-ChildPowerShellWithTimeout -Name "Relevant driver classes and updates" -ScriptContent $DriverInventoryScript -TimeoutSeconds $StepTimeoutSeconds | Out-Null

# ==================================================================================================
# Section 9: Event logs with timeout and limits
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
`$EventRangeLabel = '$EventRangeLabel'
`$MaxEvents = $MaxEvents
`$EventsDir = '$($Dirs.Events.Replace("'","''"))'
`$UseStartTime = (`$DaysBack -gt 0)
`$StartTime = if (`$UseStartTime) { (Get-Date).AddDays(-`$DaysBack) } else { `$null }

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

function Get-EventDataSummary {
    param([Parameter(Mandatory=`$true)]`$Event)

    try {
        [xml]`$xml = `$Event.ToXml()
        `$index = 0
        `$parts = @()
        foreach (`$data in @(`$xml.Event.EventData.Data)) {
            `$name = [string]`$data.Name
            `$value = [string]`$data.'#text'
            if ([string]::IsNullOrWhiteSpace(`$value)) { `$value = [string]`$data.InnerText }
            if ([string]::IsNullOrWhiteSpace(`$name)) { `$name = "Data`$index" }
            if (`$value.Length -gt 160) { `$value = `$value.Substring(0,160) + "..." }
            if (-not [string]::IsNullOrWhiteSpace(`$value)) {
                `$parts += "`$name=`$value"
            }
            `$index++
            if (`$parts.Count -ge 30) { break }
        }
        return (`$parts -join "; ")
    } catch {
        return ""
    }
}

function Select-EventForCsv {
    param([Parameter(ValueFromPipeline=`$true)]`$Event)
    process {
        [PSCustomObject]@{
            TimeCreated = `$Event.TimeCreated
            LogName = `$Event.LogName
            RecordId = `$Event.RecordId
            Level = `$Event.Level
            LevelDisplayName = Get-EventLevelName `$Event
            ProviderName = `$Event.ProviderName
            Id = `$Event.Id
            EventData = Get-EventDataSummary `$Event
            Message = try { `$Event.Message } catch { "" }
        }
    }
}

foreach (`$log in @('System','Application')) {
    `$safe = `$log -replace '[\\/:*?"<>|]', '_'

    `$filter = @{
        LogName = `$log
        Level = 1,2,3
    }
    if (`$UseStartTime) {
        `$filter.StartTime = `$StartTime
    }

    if (`$UseStartTime) {
        `$events = Get-WinEvent -FilterHashtable `$filter -MaxEvents `$MaxEvents -ErrorAction SilentlyContinue
    } else {
        `$events = Get-WinEvent -FilterHashtable `$filter -ErrorAction SilentlyContinue
    }

    `$events |
        Select-EventForCsv |
        Export-Csv (Join-Path `$EventsDir "`${safe}_WARN_ERR_CRIT_`$EventRangeLabel.csv") -NoTypeInformation -Encoding UTF8

    `$events |
        Group-Object ProviderName, Id, Level |
        Sort-Object Count -Descending |
        Select-Object Count, Name |
        Export-Csv (Join-Path `$EventsDir "`${safe}_TopEvents_`$EventRangeLabel.csv") -NoTypeInformation -Encoding UTF8
}

`$systemFilter = @{
    LogName = 'System'
}
if (`$UseStartTime) {
    `$systemFilter.StartTime = `$StartTime
}

if (`$UseStartTime) {
    `$rawSystem = Get-WinEvent -FilterHashtable `$systemFilter -MaxEvents 7000 -ErrorAction SilentlyContinue
} else {
    `$rawSystem = Get-WinEvent -FilterHashtable `$systemFilter -ErrorAction SilentlyContinue
}

`$targeted = `$rawSystem | Where-Object {
    (
        `$_.ProviderName -match 'Kernel-Power|EventLog|BugCheck|volmgr|WHEA-Logger|disk|Ntfs|storahci|stornvme|iaStor|UASPStor|USBSTOR|e1|e2f|e2fnexpress|NDIS|Tcpip|Dhcp|DNS Client Events|Microsoft-Windows-DNS-Client|NetBT|Netwtw|Time-Service|NtpClient|Service Control Manager|Kernel-PnP|UserPnp|DeviceSetupManager|DriverFrameworks-UserMode|Power-Troubleshooter|Kernel-General|Kernel-Boot|WindowsUpdateClient|Bits-Client|Perflib|Application Hang|Application Error|AppModel-Runtime|AppXDeployment|DistributedCOM|GamingServices|GameInput'
    ) -or
    (
        `$_.Id -in 1,12,13,17,20,27,41,42,51,55,98,129,153,154,157,161,162,1000,1001,1002,1008,1023,4231,4266,4321,5007,5973,6005,6006,6008,7000,7001,7009,7011,7022,7023,7024,7031,7032,7034,10010
    )
}
if (`$UseStartTime) {
    `$targeted = `$targeted | Select-Object -First `$MaxEvents
}

`$targeted |
    Select-EventForCsv |
    Export-Csv (Join-Path `$EventsDir "System_Targeted_Stability_Storage_Network_`$EventRangeLabel.csv") -NoTypeInformation -Encoding UTF8

`$targeted |
    Group-Object ProviderName, Id, Level |
    Sort-Object Count -Descending |
    Select-Object Count, Name |
    Export-Csv (Join-Path `$EventsDir "System_Targeted_TopEvents_`$EventRangeLabel.csv") -NoTypeInformation -Encoding UTF8

`$targeted |
    Select-Object -First 200 TimeCreated, Level, ProviderName, Id |
    Format-Table -AutoSize |
    Out-String -Width 300 |
    Out-File (Join-Path `$EventsDir "System_Targeted_Last200.txt") -Encoding UTF8
"@

Invoke-ChildPowerShellWithTimeout -Name "Event log analysis System Application Targeted" -ScriptContent $EventScript -TimeoutSeconds $EventTimeoutSeconds | Out-Null

# ==================================================================================================
# Section 10: Windows Error Reporting app crash reports
# ==================================================================================================
# Why:
# User-mode crashes such as games usually do not create C:\Windows\Minidump files.
# WER Report.wer files often contain the app, module, exception, and report ID that tie back to Event Viewer.

Invoke-Step "Collect Windows Error Reporting app crash reports" {
    $werRoots = @()
    if (-not [string]::IsNullOrWhiteSpace($env:ProgramData)) {
        $werRoots += (Join-Path $env:ProgramData "Microsoft\Windows\WER\ReportArchive")
        $werRoots += (Join-Path $env:ProgramData "Microsoft\Windows\WER\ReportQueue")
    }
    if (-not [string]::IsNullOrWhiteSpace($env:LOCALAPPDATA)) {
        $werRoots += (Join-Path $env:LOCALAPPDATA "Microsoft\Windows\WER\ReportArchive")
        $werRoots += (Join-Path $env:LOCALAPPDATA "Microsoft\Windows\WER\ReportQueue")
    }
    $werRoots = @($werRoots | Where-Object { -not [string]::IsNullOrWhiteSpace($_) } | Select-Object -Unique)

    $startTime = if ($DaysBack -gt 0) { (Get-Date).AddDays(-$DaysBack) } else { $null }
    $werFiles = @()
    foreach ($root in $werRoots) {
        if (Test-Path -LiteralPath $root) {
            $werFiles += @(Get-ChildItem -LiteralPath $root -Recurse -Filter "Report.wer" -File -ErrorAction SilentlyContinue)
        }
    }

    if ($null -ne $startTime) {
        $werFiles = @($werFiles | Where-Object { $_.LastWriteTime -ge $startTime })
    }

    $werFiles = @($werFiles | Sort-Object LastWriteTime -Descending | Select-Object -First 120)
    $werRows = @()
    $copyIndex = 1

    foreach ($file in $werFiles) {
        try {
            $lines = @(Get-Content -LiteralPath $file.FullName -ErrorAction Stop)
            $fields = @{}
            foreach ($line in $lines) {
                if ($line -match '^([^=]+)=(.*)$') {
                    $fields[$matches[1]] = $matches[2]
                }
            }

            $appName = Get-WerFieldValue $fields @("AppName","AppPath","TargetAppId")
            $eventType = Get-WerFieldValue $fields @("EventType")
            $friendlyName = Get-WerFieldValue $fields @("FriendlyEventName","ConsentKey")
            $reportIdentifier = Get-WerFieldValue $fields @("ReportIdentifier")
            $integratorReportIdentifier = Get-WerFieldValue $fields @("IntegratorReportIdentifier")
            $faultModule = Get-WerSignatureValue $fields '(?i)^Fault Module Name$|^Problem Module Name$'
            $exceptionCode = Get-WerSignatureValue $fields '(?i)^Exception Code$'
            $exceptionOffset = Get-WerSignatureValue $fields '(?i)^Exception Offset$'
            $appPath = Get-WerSignatureValue $fields '(?i)application path|app path'
            if ([string]::IsNullOrWhiteSpace($appPath)) {
                $appPath = Get-WerFieldValue $fields @("AppPath","UI[2]")
            }
            if ([string]::IsNullOrWhiteSpace($appName) -and -not [string]::IsNullOrWhiteSpace($appPath)) {
                $appName = Split-Path -Leaf $appPath
            }
            $loadedModuleHints = Get-WerLoadedModuleHints $fields

            $combined = "$($file.DirectoryName) $appName $eventType $friendlyName $faultModule $exceptionCode $exceptionOffset $appPath"
            $isCrashReport = $combined -match '(?i)APPCRASH|BEX|Stopped working|Nicht mehr funktionsfähig|crash|hang|cs2|steam|game|counter-strike|xbox|gaming'
            $copiedReport = ""
            if ($isCrashReport -and $copyIndex -le 30) {
                $safeApp = if ([string]::IsNullOrWhiteSpace($appName)) { "app" } else { $appName }
                $safeApp = ($safeApp -replace '[\\/:*?"<>|\s]+', '_').Trim('_')
                if ([string]::IsNullOrWhiteSpace($safeApp)) { $safeApp = "app" }
                $copiedName = "WER_Report_{0:000}_{1}.wer.txt" -f $copyIndex, $safeApp
                $copiedPath = Join-Path $Dirs.WER $copiedName
                Copy-Item -LiteralPath $file.FullName -Destination $copiedPath -Force -ErrorAction SilentlyContinue
                $copiedReport = "08_WER\$copiedName"
                $copyIndex++
            }

            $werRows += [PSCustomObject]@{
                LastWriteTime     = $file.LastWriteTime
                AppName           = $appName
                EventType         = $eventType
                FriendlyEventName = $friendlyName
                FaultModule       = $faultModule
                ExceptionCode     = $exceptionCode
                ExceptionOffset   = $exceptionOffset
                ReportIdentifier  = $reportIdentifier
                EventReportId     = $integratorReportIdentifier
                LoadedModuleHints = $loadedModuleHints
                ApplicationPath   = $appPath
                ReportPath        = $file.FullName
                PackagePath       = $copiedReport
            }
        } catch {
            $werRows += [PSCustomObject]@{
                LastWriteTime     = $file.LastWriteTime
                AppName           = ""
                EventType         = "ReadError"
                FriendlyEventName = $_.Exception.Message
                FaultModule       = ""
                ExceptionCode     = ""
                ExceptionOffset   = ""
                ReportIdentifier  = ""
                EventReportId     = ""
                LoadedModuleHints = ""
                ApplicationPath   = ""
                ReportPath        = $file.FullName
                PackagePath       = ""
            }
        }
    }

    $werRows | Export-Csv (Join-Path $Dirs.WER "WindowsErrorReporting_RecentReports.csv") -NoTypeInformation -Encoding UTF8
}

# ==================================================================================================
# Section 11: Minidumps, but no huge MEMORY.DMP
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
            $copiedPath = Join-Path $Dirs.Dumps $d.Name
            Copy-Item $d.FullName $copiedPath -ErrorAction SilentlyContinue
            $dumpList += [PSCustomObject]@{
                Type = "Minidump copied"
                Path = $d.FullName
                PackagePath = "06_Minidumps\$($d.Name)"
                CopiedPath = $copiedPath
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

Invoke-Step "Analyze minidumps when debugger is available" {
    $analysisRows = @()
    $statusPath = Join-Path $Dirs.Dumps "DumpAnalysis_Status.txt"
    $debugger = Get-DumpDebuggerPath
    $copiedDumps = @(Get-ChildItem -LiteralPath $Dirs.Dumps -Filter "*.dmp" -ErrorAction SilentlyContinue |
        Sort-Object LastWriteTime -Descending |
        Select-Object -First 5)

    if ($copiedDumps.Count -eq 0) {
        "No copied minidumps were available for local analysis." | Out-File $statusPath -Encoding UTF8
        $analysisRows | Export-Csv (Join-Path $Dirs.Dumps "DumpAnalysis.csv") -NoTypeInformation -Encoding UTF8
        return
    }

    if ([string]::IsNullOrWhiteSpace($debugger) -or -not (Test-Path -LiteralPath $debugger)) {
        @"
No local dump debugger was found.

PCDiagLite can install Windows Debugging Tools automatically and then analyze the copied minidumps.
Expected debugger: cdb.exe
"@ | Out-File $statusPath -Encoding UTF8

        $shouldInstallDebugTools = [bool]$AutoInstallDebugTools
        if (-not $shouldInstallDebugTools -and (Test-InteractivePromptAvailable)) {
            Write-Host ""
            Write-Host "Minidumps were found, but cdb.exe is missing." -ForegroundColor Yellow
            Write-Host "Install Windows Debugging Tools now so the dumps can be analyzed? [Y/N]" -ForegroundColor Yellow
            $answer = Read-Host "Install Debugging Tools"
            $shouldInstallDebugTools = ($answer -match '^(y|yes|j|ja)$')
        }

        if ($shouldInstallDebugTools) {
            $debugger = Install-WindowsDebuggingTools -StatusPath $statusPath
        }
    }

    if ([string]::IsNullOrWhiteSpace($debugger) -or -not (Test-Path -LiteralPath $debugger)) {
        @"
Minidump analysis was skipped because cdb.exe is still unavailable.

Install Windows Debugging Tools and rerun PCDiagLite, or start PCDiagLite with -AutoInstallDebugTools.
"@ | Out-File $statusPath -Encoding UTF8 -Append

        foreach ($dump in $copiedDumps) {
            $analysisRows += [PSCustomObject]@{
                DumpFile         = $dump.Name
                Status           = "Skipped"
                BugCheck         = ""
                ProbablyCausedBy = ""
                ProcessName      = ""
                ModuleName       = ""
                ImageName        = ""
                SymbolName       = ""
                FailureBucket    = ""
                FailureHash      = ""
                SuspectedArea    = "Not analyzed"
                RecommendedAction = "Install Windows Debugging Tools and rerun PCDiagLite, or start PCDiagLite with -AutoInstallDebugTools."
                ExitCode         = ""
                AnalysisFile     = ""
                Note             = "cdb.exe was not found or installation was declined/failed"
            }
        }

        $analysisRows | Export-Csv (Join-Path $Dirs.Dumps "DumpAnalysis.csv") -NoTypeInformation -Encoding UTF8
        return
    }

    $analysisCsvPath = Join-Path $Dirs.Dumps "DumpAnalysis.csv"
    "Debugger: $debugger" | Out-File $statusPath -Encoding UTF8

    foreach ($dump in $copiedDumps) {
        $analysisFile = Join-Path $Dirs.Dumps ("DumpAnalysis_{0}.txt" -f [IO.Path]::GetFileNameWithoutExtension($dump.Name))
        $command = ".symfix; .reload; !analyze -v; q"
        $status = "Success"
        $note = ""
        $exitCode = ""

        try {
            "Analyzing dump: $($dump.Name)" | Out-File $statusPath -Encoding UTF8 -Append
            Remove-Item -LiteralPath $analysisFile -Force -ErrorAction SilentlyContinue

            $psi = New-Object System.Diagnostics.ProcessStartInfo
            $psi.FileName = $debugger
            $psi.UseShellExecute = $false
            $psi.CreateNoWindow = $true
            $escapedAnalysisFile = $analysisFile.Replace('"', '\"')
            $escapedDumpFile = $dump.FullName.Replace('"', '\"')
            $escapedCommand = $command.Replace('"', '\"')
            $psi.Arguments = "-logo `"$escapedAnalysisFile`" -y `"srv*C:\Symbols*https://msdl.microsoft.com/download/symbols`" -z `"$escapedDumpFile`" -c `"$escapedCommand`""

            $proc = New-Object System.Diagnostics.Process
            $proc.StartInfo = $psi
            [void]$proc.Start()

            $timeoutSeconds = 120
            if (-not $proc.WaitForExit($timeoutSeconds * 1000)) {
                Stop-ProcessTreeSafe -ProcessId ([int]$proc.Id) -Reason "Minidump analysis timeout"
                $status = "Timeout"
                $note = "Timed out after $timeoutSeconds seconds"
            } else {
                $exitCode = [string]$proc.ExitCode
                if ($proc.ExitCode -ne 0) {
                    $status = "Warning"
                    $note = "Debugger exit code $($proc.ExitCode)"
                }
            }
        } catch {
            $status = "Error"
            $note = $_.Exception.Message
        }

        if (-not (Test-Path -LiteralPath $analysisFile)) {
            [System.IO.File]::WriteAllText($analysisFile, "No cdb.exe analysis output file was created.`r`nStatus: $status`r`nNote: $note", [System.Text.UTF8Encoding]::new($true))
            if ([string]::IsNullOrWhiteSpace($note)) {
                $note = "No analysis output file was created"
            }
        }

        $analysisRows += Convert-DumpAnalysisTextToRow -DumpFile $dump.Name -AnalysisPath $analysisFile -Status $status -ExitCode $exitCode -Note $note

        $analysisRows | Export-Csv $analysisCsvPath -NoTypeInformation -Encoding UTF8
        "Analysis row written for $($dump.Name): $status $note" | Out-File $statusPath -Encoding UTF8 -Append
    }

    $analysisRows | Export-Csv $analysisCsvPath -NoTypeInformation -Encoding UTF8
}

# ==================================================================================================
# Section 11: Quick summary
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
Event range:    $EventRangeText
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

$endpointSummary = Join-Path $Dirs.Network "Endpoint_Summary.csv"
if (Test-Path $endpointSummary) {
    "`r`nCurrent TCP/UDP endpoint summary:`r`n" | Out-File $summaryPath -Encoding UTF8 -Append
    Import-Csv $endpointSummary |
        Format-Table -AutoSize |
        Out-String -Width 240 |
        Out-File $summaryPath -Encoding UTF8 -Append
}

$tcpTop = Join-Path $Dirs.Network "TCP_Endpoints_By_Process_Top30.csv"
if (Test-Path $tcpTop) {
    "`r`nTop TCP endpoint processes:`r`n" | Out-File $summaryPath -Encoding UTF8 -Append
    Import-Csv $tcpTop |
        Select-Object -First 10 |
        Format-Table -AutoSize |
        Out-String -Width 300 |
        Out-File $summaryPath -Encoding UTF8 -Append
}

$udpTop = Join-Path $Dirs.Network "UDP_Endpoints_By_Process_Top30.csv"
if (Test-Path $udpTop) {
    "`r`nTop UDP endpoint processes:`r`n" | Out-File $summaryPath -Encoding UTF8 -Append
    Import-Csv $udpTop |
        Select-Object -First 10 |
        Format-Table -AutoSize |
        Out-String -Width 300 |
        Out-File $summaryPath -Encoding UTF8 -Append
}

$topSystem = Join-Path $Dirs.Events "System_TopEvents_${EventRangeLabel}.csv"
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
# Section 12: Findings, HTML report, manifest, and optional privacy mode
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
# Section 13: Create ZIP
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
