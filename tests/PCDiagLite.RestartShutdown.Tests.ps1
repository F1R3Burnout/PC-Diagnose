[CmdletBinding()]
param([string]$RepositoryRoot = "")

# Fixture-based regression tests for PCDiagLite's restart/shutdown
# classification (User32 1074, EventLog 6005/6006/6008, Kernel-Power 41,
# BugCheck 1001). PCDiagLite.ps1 is a single script that starts collecting as
# soon as it runs, so this test never executes it: it parses the file and loads
# only the pure helper functions listed below, then feeds them event rows that
# look exactly like the CSV rows PCDiagLite reads back (all values are strings).
# No event log is read and nothing on the machine is changed.

$ErrorActionPreference = "Stop"
$repoRoot = if ($RepositoryRoot) { $RepositoryRoot } else { Split-Path $PSScriptRoot -Parent }
$scriptPath = Join-Path $repoRoot "scripts\diagnostics\PCDiagLite.ps1"

$tokens = $null
$parseErrors = $null
$ast = [Management.Automation.Language.Parser]::ParseFile($scriptPath, [ref]$tokens, [ref]$parseErrors)
if ($parseErrors.Count -gt 0) { throw "PCDiagLite.ps1 parse failed: $($parseErrors | Out-String)" }

$requiredFunctions = @(
    "ConvertTo-DateTimeSafe",
    "Format-FindingDate",
    "Get-EventDataValue",
    "Get-FirstEventDataValue",
    "Get-UnexpectedShutdownReportedTime",
    "Get-Event1074Info",
    "Get-BugcheckCodeFromEvent",
    "Get-EventRecordKey",
    "Get-RelatedRecordIdsText",
    "New-RestartShutdownIncidentRows",
    "New-KernelPowerSummaryRows"
)

# Only top-level definitions: PCDiagLite also embeds child scripts in
# here-strings, and those are not part of the AST as functions anyway.
$definitions = @($ast.FindAll({ param($node) $node -is [Management.Automation.Language.FunctionDefinitionAst] }, $false))
foreach ($name in $requiredFunctions) {
    $matching = @($definitions | Where-Object { $_.Name -eq $name })
    if ($matching.Count -ne 1) { throw "Expected exactly one top-level definition of $name in PCDiagLite.ps1, found $($matching.Count)" }
    . ([scriptblock]::Create($matching[0].Extent.Text))
}

$script:PassCount = 0
$script:FailCount = 0

function Assert-True {
    param([bool]$Condition, [string]$Message)
    if ($Condition) {
        $script:PassCount++
        Write-Host "  PASS  $Message" -ForegroundColor Green
    } else {
        $script:FailCount++
        Write-Host "  FAIL  $Message" -ForegroundColor Red
    }
}

$script:NextRecordId = 1000
function New-EventRow {
    param(
        [Parameter(Mandatory=$true)][string]$Id,
        [Parameter(Mandatory=$true)][string]$ProviderName,
        [Parameter(Mandatory=$true)][datetime]$Time,
        [string]$EventData = "",
        [string]$Message = "",
        [string]$Level = "4"
    )
    $script:NextRecordId++
    return [pscustomobject]@{
        TimeCreated  = $Time.ToString("yyyy-MM-dd HH:mm:ss")
        LogName      = "System"
        RecordId     = [string]$script:NextRecordId
        Level        = $Level
        ProviderName = $ProviderName
        Id           = $Id
        EventData    = $EventData
        Message      = $Message
    }
}

function New-Clean6006 { param([datetime]$Time) New-EventRow -Id "6006" -ProviderName "EventLog" -Time $Time -Message "The Event log service was stopped." }
function New-Boot6005 { param([datetime]$Time) New-EventRow -Id "6005" -ProviderName "EventLog" -Time $Time -Message "The Event log service was started." }
function New-Unexpected6008 {
    param([datetime]$LoggedAt, [datetime]$ReportedIncident)
    # Same field layout Windows uses: param1 = time, param2 = date (system locale).
    $data = "param1=$($ReportedIncident.ToString('HH:mm:ss', [Globalization.CultureInfo]::InvariantCulture)); param2=$($ReportedIncident.ToString('dd.MM.yyyy', [Globalization.CultureInfo]::InvariantCulture))"
    New-EventRow -Id "6008" -ProviderName "EventLog" -Time $LoggedAt -Level "2" -EventData $data -Message "The previous system shutdown was unexpected."
}
function New-KernelPower41 {
    param([datetime]$Time, [string]$BugcheckCode = "0")
    New-EventRow -Id "41" -ProviderName "Microsoft-Windows-Kernel-Power" -Time $Time -Level "1" `
        -EventData "BugcheckCode=$BugcheckCode; BugcheckParameter1=0x0; SleepInProgress=0; PowerButtonTimestamp=0; ConnectedStandbyInProgress=false" `
        -Message "The system has rebooted without cleanly shutting down first."
}
function New-Planned1074 {
    param([datetime]$Time, [string]$Process, [string]$Reason, [string]$ShutdownType, [string]$User = "PC\Max")
    New-EventRow -Id "1074" -ProviderName "User32" -Time $Time `
        -EventData "param1=$Process (PC); param2=PC; param3=$Reason; param4=0x80020010; param5=$ShutdownType; param6=; param7=$User"
}

function Format-T { param([datetime]$Time) return $Time.ToString("yyyy-MM-dd HH:mm:ss") }

$base = [datetime]::new(2026, 11, 20, 10, 0, 0)

Write-Host "`n=== Helper parsing ===" -ForegroundColor Cyan

Assert-True ((Get-EventDataValue -EventData "param1=a; param2=b c; param3=" -Name "param2") -eq "b c") "EventData summary value is read by name"
Assert-True ((Get-EventDataValue -EventData '{"BugcheckCode":"209","Other":"x"}' -Name "bugcheckcode") -eq "209") "EventData JSON value is read case-insensitively"
Assert-True ((Get-EventDataValue -EventData "" -Name "param1") -eq "") "Empty EventData yields an empty value"

$t = ConvertTo-DateTimeSafe "26.11.2026 07:12:30"
Assert-True ($null -ne $t -and $t.Day -eq 26 -and $t.Month -eq 11 -and $t.Hour -eq 7) "German CSV timestamp (dd.MM.yyyy) is parsed"
Assert-True ($null -eq (ConvertTo-DateTimeSafe "not a date")) "Unparsable timestamp yields null instead of throwing"

$reported = Get-UnexpectedShutdownReportedTime -Message "" -EventData "param1=07:12:30; param2=26.11.2026"
Assert-True ($null -ne $reported -and (Format-T $reported) -eq "2026-11-26 07:12:30") "6008 incident time is taken from EventData param1/param2"

$lrm = [string][char]0x200E
$reported = Get-UnexpectedShutdownReportedTime -Message "Das System wurde zuvor am $($lrm)26.$($lrm)11.$($lrm)2026 um 07:12:30 unerwartet heruntergefahren." -EventData ""
Assert-True ($null -ne $reported -and (Format-T $reported) -eq "2026-11-26 07:12:30") "6008 incident time is parsed from the German message including left-to-right marks"

$reported = Get-UnexpectedShutdownReportedTime -Message "The previous system shutdown at 7:12:30 AM on 11/26/2026 was unexpected." -EventData ""
Assert-True ($null -ne $reported -and (Format-T $reported) -eq "2026-11-26 07:12:30") "6008 incident time is parsed from the English message"

Assert-True ($null -eq (Get-UnexpectedShutdownReportedTime -Message "something else" -EventData "")) "6008 without a recognizable time yields null"

Write-Host "`n=== Event 1074 initiator classification ===" -ForegroundColor Cyan

$wu = Get-Event1074Info -Event (New-Planned1074 -Time $base -Process "C:\Windows\System32\MoNotificationUx.exe" -Reason "Operating System: Service pack (Planned)" -ShutdownType "restart" -User "NT AUTHORITY\SYSTEM")
Assert-True ($wu.InitiatorCategory -eq "Windows Update") "MoNotificationUx.exe restart is attributed to Windows Update"
Assert-True ($wu.InitiatorProcess -eq "C:\Windows\System32\MoNotificationUx.exe") "Initiator process is stripped of the '(PC)' suffix"
Assert-True ($wu.ShutdownType -eq "restart") "Shutdown type 'restart' is normalized"

$de = Get-Event1074Info -Event (New-Planned1074 -Time $base -Process "C:\Windows\explorer.exe" -Reason "Anderer Grund (Geplant)" -ShutdownType "Neu starten")
Assert-True ($de.ShutdownType -eq "restart") "German shutdown type 'Neu starten' is normalized to restart"
Assert-True ($de.InitiatorCategory -eq "Application or service") "explorer.exe is an application initiator, not Windows Update"

$off = Get-Event1074Info -Event (New-Planned1074 -Time $base -Process "C:\Windows\explorer.exe" -Reason "Other (Unplanned)" -ShutdownType "power off")
Assert-True ($off.ShutdownType -eq "shutdown") "Shutdown type 'power off' is normalized to shutdown"

$svchostPlain = Get-Event1074Info -Event (New-Planned1074 -Time $base -Process "C:\Windows\System32\svchost.exe" -Reason "Other (Planned)" -ShutdownType "restart")
Assert-True ($svchostPlain.InitiatorCategory -ne "Windows Update") "svchost.exe alone is not claimed as Windows Update without Update evidence"

$svchostUpdate = Get-Event1074Info -Event (New-Planned1074 -Time $base -Process "C:\Windows\System32\svchost.exe" -Reason "Operating System: Service pack (Planned)" -ShutdownType "restart")
Assert-True ($svchostUpdate.InitiatorCategory -eq "Windows Update") "svchost.exe with the planned service-pack reason is attributed to Windows Update"

$msgOnly = New-EventRow -Id "1074" -ProviderName "User32" -Time $base -Message ("The process C:\Windows\system32\winlogon.exe (PC) has initiated the restart of computer PC on behalf of user PC\Max for the following reason: No title for this reason could be found`r`n Reason Code: 0x500ff`r`n Shutdown Type: restart`r`n Comment: ")
$fromMessage = Get-Event1074Info -Event $msgOnly
Assert-True ($fromMessage.InitiatorProcess -eq "C:\Windows\system32\winlogon.exe") "Without EventData the initiator is parsed from the English message"
Assert-True ($fromMessage.InitiatingUser -eq "PC\Max") "Without EventData the user is parsed from the English message"
Assert-True ($fromMessage.ReasonCode -eq "0x500ff" -and $fromMessage.ShutdownType -eq "restart") "Without EventData reason code and type are parsed from the English message"

Write-Host "`n=== Incident correlation ===" -ForegroundColor Cyan

# 1) Windows Update restart that completed cleanly.
$history = @(
    (New-Planned1074 -Time $base -Process "C:\Windows\System32\MoNotificationUx.exe" -Reason "Operating System: Service pack (Planned)" -ShutdownType "restart" -User "NT AUTHORITY\SYSTEM"),
    (New-Clean6006 -Time $base.AddSeconds(40)),
    (New-Boot6005 -Time $base.AddSeconds(90))
)
$rows = @(New-RestartShutdownIncidentRows -HistoryRows $history -RestartWindowMinutes 10 -BootWindowMinutes 3)
Assert-True ($rows.Count -eq 1) "Clean Windows Update restart produces exactly one incident row (got $($rows.Count))"
Assert-True ($rows[0].Classification -eq "Planned restart" -and $rows[0].Planned -eq "Yes") "Clean restart is classified as planned restart"
Assert-True ($rows[0].InitiatorCategory -eq "Windows Update") "Clean restart names Windows Update as initiator"
Assert-True ($rows[0].CleanShutdownConfirmed -eq "Yes" -and $rows[0].BootConfirmed -eq "Yes") "6006 and 6005 confirm clean stop and boot"
Assert-True ($rows[0].UnexpectedShutdown6008Present -eq "No" -and $rows[0].KernelPower41Present -eq "No") "No unexpected-shutdown evidence is attached to a clean restart"
Assert-True ($rows[0].RelatedRecordIds -match "User32 1074" -and $rows[0].RelatedRecordIds -match "EventLog 6006") "Related record IDs reference the source events"

# 2) Planned shutdown without a 6006 record.
$history = @(New-Planned1074 -Time $base -Process "C:\Windows\explorer.exe" -Reason "Other (Unplanned)" -ShutdownType "power off")
$rows = @(New-RestartShutdownIncidentRows -HistoryRows $history -RestartWindowMinutes 10 -BootWindowMinutes 3)
Assert-True ($rows.Count -eq 1 -and $rows[0].Classification -eq "Planned shutdown requested; clean shutdown not confirmed") "Planned shutdown without 6006 is not reported as clean"
Assert-True ($rows[0].Assessment -match "not confirmed") "Assessment says the clean shutdown is not confirmed"

# 3) Hard reset / power loss: 6008 + Kernel-Power 41 (BugcheckCode 0), no BugCheck.
$incident = $base.AddMinutes(30)
$boot = $incident.AddMinutes(2)
$history = @(
    (New-Boot6005 -Time $boot.AddSeconds(-10)),
    (New-Unexpected6008 -LoggedAt $boot -ReportedIncident $incident),
    (New-KernelPower41 -Time $boot.AddSeconds(30) -BugcheckCode "0")
)
$rows = @(New-RestartShutdownIncidentRows -HistoryRows $history -RestartWindowMinutes 10 -BootWindowMinutes 3)
Assert-True ($rows.Count -eq 1) "6008 and its Kernel-Power 41 form a single incident (got $($rows.Count))"
Assert-True ($rows[0].Classification -eq "Unexpected shutdown / hard reset" -and $rows[0].Planned -eq "No") "Hard reset is classified as unexpected shutdown"
Assert-True ($rows[0].IncidentTime -eq (Format-T $incident) -and $rows[0].LoggedTime -eq (Format-T $boot)) "Incident time (reported) and log time (boot) are kept apart"
Assert-True ($rows[0].KernelPower41Present -eq "Yes" -and $rows[0].BugCheckPresent -eq "No") "Kernel-Power 41 is attached, no BugCheck is invented"
Assert-True ($rows[0].Assessment -match "cannot distinguish") "Assessment does not claim a specific cause for a hard reset"
Assert-True ($rows[0].Assessment -notmatch "(?i)defekt|defective|power supply fault") "Assessment makes no hardware-defect claim"

# 4) Blue screen: 6008 + Kernel-Power 41 with bugcheck + BugCheck 1001.
$history = @(
    (New-Unexpected6008 -LoggedAt $boot -ReportedIncident $incident),
    (New-KernelPower41 -Time $boot.AddSeconds(20) -BugcheckCode "209"),
    (New-EventRow -Id "1001" -ProviderName "Microsoft-Windows-WER-SystemErrorReporting" -Time $boot.AddSeconds(60) -Level "2" `
        -EventData "param1=0x000000d1 (0x0000000000000000, 0x0000000000000002, 0x0000000000000000, 0xfffff80000000000); param2=C:\Windows\Minidump\112026-1234-01.dmp" `
        -Message "The computer has rebooted from a bugcheck. The bugcheck was: 0x000000d1 (0x0000000000000000, 0x0000000000000002, 0x0000000000000000, 0xfffff80000000000).")
)
$rows = @(New-RestartShutdownIncidentRows -HistoryRows $history -RestartWindowMinutes 10 -BootWindowMinutes 3)
Assert-True ($rows.Count -eq 1) "Blue screen evidence forms a single incident (got $($rows.Count))"
Assert-True ($rows[0].Classification -eq "Unexpected restart after bugcheck") "Blue screen is classified as restart after bugcheck"
Assert-True ($rows[0].BugCheckPresent -eq "Yes" -and $rows[0].BugcheckCode -match "^0x000000d1") "Bugcheck code is taken from BugCheck 1001"

# 5) Kernel-Power 41 alone with BugcheckCode 0.
$history = @(New-KernelPower41 -Time $boot -BugcheckCode "0")
$rows = @(New-RestartShutdownIncidentRows -HistoryRows $history -RestartWindowMinutes 10 -BootWindowMinutes 3)
Assert-True ($rows.Count -eq 1 -and $rows[0].Classification -eq "Previous session ended unexpectedly") "Kernel-Power 41 alone is not reported as a blue screen"
Assert-True ($rows[0].Assessment -match "does not prove a blue screen") "Kernel-Power 41 assessment says it proves no blue screen"

# 6) Kernel-Power 41 alone with a non-zero bugcheck code.
$history = @(New-KernelPower41 -Time $boot -BugcheckCode "209")
$rows = @(New-RestartShutdownIncidentRows -HistoryRows $history -RestartWindowMinutes 10 -BootWindowMinutes 3)
Assert-True ($rows.Count -eq 1 -and $rows[0].Classification -eq "Unexpected restart after bugcheck" -and $rows[0].BugcheckCode -eq "209") "Kernel-Power 41 with a bugcheck code is a restart after bugcheck"

# 7) Planned restart that hung and was then hard reset: one incident, not two.
$history = @(
    (New-Planned1074 -Time $base -Process "C:\Windows\explorer.exe" -Reason "Other (Planned)" -ShutdownType "restart"),
    (New-Unexpected6008 -LoggedAt $base.AddMinutes(20) -ReportedIncident $base.AddMinutes(1)),
    (New-KernelPower41 -Time $base.AddMinutes(20).AddSeconds(10) -BugcheckCode "0")
)
$rows = @(New-RestartShutdownIncidentRows -HistoryRows $history -RestartWindowMinutes 10 -BootWindowMinutes 3)
Assert-True ($rows.Count -eq 1) "Hung planned restart is reported once, not additionally as a separate hard reset (got $($rows.Count))"
Assert-True ($rows[0].Planned -eq "Yes" -and $rows[0].CleanShutdownConfirmed -eq "No") "Hung planned restart stays planned but is not confirmed clean"
Assert-True ($rows[0].UnexpectedShutdown6008Present -eq "Yes" -and $rows[0].KernelPower41Present -eq "Yes") "Hung planned restart keeps the 6008 and Kernel-Power 41 evidence"
Assert-True ($rows[0].Assessment -match "ended unexpectedly") "Hung planned restart assessment mentions the unexpected end"
Assert-True ($rows[0].IncidentTime -eq (Format-T $base.AddMinutes(1))) "Hung planned restart uses the time Windows reported for the unexpected end"

# 8) An unrelated 6008 far away from a planned restart stays separate.
$history = @(
    (New-Planned1074 -Time $base -Process "C:\Windows\explorer.exe" -Reason "Other (Planned)" -ShutdownType "restart"),
    (New-Clean6006 -Time $base.AddSeconds(30)),
    (New-Unexpected6008 -LoggedAt $base.AddHours(5) -ReportedIncident $base.AddHours(4))
)
$rows = @(New-RestartShutdownIncidentRows -HistoryRows $history -RestartWindowMinutes 10 -BootWindowMinutes 3)
Assert-True ($rows.Count -eq 2) "Planned restart and a later unrelated hard reset are two incidents (got $($rows.Count))"
Assert-True ($rows[0].Planned -eq "No" -and $rows[1].Planned -eq "Yes") "Incidents are sorted newest first"

# 9) No relevant events.
$rows = @(New-RestartShutdownIncidentRows -HistoryRows @() -RestartWindowMinutes 10 -BootWindowMinutes 3)
Assert-True ($rows.Count -eq 0) "Empty history produces no incident rows"
$rows = @(New-RestartShutdownIncidentRows -HistoryRows @((New-Boot6005 -Time $base), (New-Clean6006 -Time $base.AddHours(1))) -RestartWindowMinutes 10 -BootWindowMinutes 3)
Assert-True ($rows.Count -eq 0) "Boot and clean-stop markers alone produce no incident rows"

Write-Host "`n=== Kernel-Power 41 summary ===" -ForegroundColor Cyan
$summary = @(New-KernelPowerSummaryRows -Rows @((New-KernelPower41 -Time $boot -BugcheckCode "0")))
Assert-True ($summary.Count -eq 1 -and $summary[0].Interpretation -match "does not prove a blue screen") "Kernel-Power summary with BugcheckCode 0 does not claim a blue screen"
$summary = @(New-KernelPowerSummaryRows -Rows @((New-KernelPower41 -Time $boot -BugcheckCode "209")))
Assert-True ($summary[0].Interpretation -match "BugcheckCode 209") "Kernel-Power summary names a reported bugcheck code"

Write-Host ""
Write-Host "PCDiagLite restart/shutdown tests: $script:PassCount passed, $script:FailCount failed." -ForegroundColor $(if ($script:FailCount -eq 0) { "Green" } else { "Red" })
if ($script:FailCount -gt 0) { exit 1 }
exit 0
