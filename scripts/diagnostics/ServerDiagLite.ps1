<#
.SYNOPSIS
    Erstellt ein kleines, robustes Diagnosepaket für einen instabilen Windows-PC / Headless-Server.

.DESCRIPTION
    Diese Version ist bewusst "ChatGPT-/Analyse-freundlich":
    - keine vollständigen EVTX-Exporte
    - keine optionalen Operational-Logs
    - kein Security-Log
    - keine große MEMORY.DMP
    - begrenzte Event-Anzahl
    - Timeout für potenziell hängende Teilschritte
    - deutlich mehr Fortschrittsanzeige mit Laufzeit
    - erster automatischer Befundbericht mit lokaler Ergebnisanzeige
    - optionaler Privacy-Modus zum Maskieren typischer personenbezogener/gerätebezogener Werte
    - HTML-Report und Manifest für Support-Übergaben

    Wenn ein Schritt hängt, wird er nach einer festen Zeit abgebrochen und das Script macht weiter.

.PARAMETER DaysBack
    Zeitraum für Event-Auswertungen. Standard: 30 Tage.

.PARAMETER OutputRoot
    Zielordner. Standard: C:\Temp

.PARAMETER MaxEvents
    Maximale Anzahl detaillierter Events pro Event-Auswertung. Standard: 2000.

.PARAMETER EventTimeoutSeconds
    Timeout für die Eventlog-Auswertung. Standard: 180 Sekunden.

.PARAMETER StepTimeoutSeconds
    Timeout für größere lokale Sammelschritte. Standard: 90 Sekunden.

.PARAMETER PrivacyMode
    Maskiert typische IP-Adressen, Benutzernamen, Computernamen, MACs, Seriennummern und Geräte-IDs vor dem ZIP.
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
# Abschnitt 1: Start, Admin-Prüfung und Ordnerstruktur
# ==================================================================================================
# Warum:
# Für Eventlogs, Treiberinfos, powercfg und Minidumps sind Adminrechte hilfreich bzw. nötig.

$ErrorActionPreference = "Continue"
$ToolName = "ServerDiagLite"
$ToolVersion = "Lite v6 Lokale Analyse"
$RunStarted = Get-Date

function Test-IsAdmin {
    $currentIdentity = [Security.Principal.WindowsIdentity]::GetCurrent()
    $principal = New-Object Security.Principal.WindowsPrincipal($currentIdentity)
    return $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

if (-not (Test-IsAdmin)) {
    Write-Host "FEHLER: Bitte als Administrator ausführen." -ForegroundColor Red
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
    # Warum:
    # Wenn z. B. ein PowerShell-Kindprozess oder cmd.exe hängt, bleibt manchmal ein Unterprozess übrig.
    # Danach können weitere Scriptläufe blockieren. Deshalb wird hier rekursiv der ganze Prozessbaum beendet.
    try {
        $children = Get-CimInstance Win32_Process -Filter "ParentProcessId=$ProcessId" -ErrorAction SilentlyContinue
        foreach ($child in $children) {
            Stop-ProcessTreeSafe -ProcessId ([int]$child.ProcessId) -Reason $Reason
        }

        if ($ProcessId -ne $PID) {
            Stop-Process -Id $ProcessId -Force -ErrorAction SilentlyContinue
            Write-ProgressLine "Prozess beendet: PID $ProcessId ($Reason)" "Yellow"
        }
    } catch {
        Write-ProgressLine "Konnte Prozessbaum PID $ProcessId nicht beenden: $($_.Exception.Message)" "DarkYellow"
    }
}

function Stop-OldDiagnosticProcesses {
    # Räumt hängende Diagnoseprozesse aus früheren Läufen auf.
    # Wichtig:
    # Es werden NICHT pauschal alle PowerShell-Prozesse beendet.
    # Beendet werden nur Prozesse, deren CommandLine eindeutig zu diesem Diagnose-Script passt.
    # Das verhindert, dass ein alter hängen gebliebener Lauf einen neuen Lauf blockiert.

    Write-ProgressLine "Prüfe auf hängende alte Diagnoseprozesse..." "Cyan"

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
        Write-ProgressLine "Keine alten Diagnoseprozesse gefunden." "Green"
        return
    }

    foreach ($p in $old) {
        Write-ProgressLine "Alter Diagnoseprozess gefunden: PID $($p.ProcessId), $($p.Name)" "Yellow"
        Write-ProgressLine "CommandLine: $($p.CommandLine)" "DarkGray"
        Stop-ProcessTreeSafe -ProcessId ([int]$p.ProcessId) -Reason "alter Diagnoseprozess"
    }
}

Write-Host ""
Write-ProgressLine "Erstelle schlankes Diagnosepaket..." "Cyan"
Write-ProgressLine "Zielordner: $Out" "Gray"
Write-ProgressLine "Event-Zeitraum: letzte $DaysBack Tage" "Gray"
Write-ProgressLine "Max. Detail-Events pro Auswertung: $MaxEvents" "Gray"
Write-ProgressLine "Event-Timeout: $EventTimeoutSeconds Sekunden" "Gray"
Write-ProgressLine "Schritt-Timeout: $StepTimeoutSeconds Sekunden" "Gray"
Write-ProgressLine "Privacy-Modus: $([bool]$PrivacyMode)" "Gray"
Write-Host ""

Stop-OldDiagnosticProcesses


@"
ServerDiagLite v6 Lokale Analyse
=========================

Computer:      $env:COMPUTERNAME
User:          $env:USERNAME
Export time:   $(Get-Date)
DaysBack:      $DaysBack
MaxEvents:     $MaxEvents
Output folder: $Out
Privacy mode:  $([bool]$PrivacyMode)

Hinweis:
Dieses Paket enthält nur die wichtigsten Diagnoseinformationen für eine erste Analyse.
Es kann trotzdem IP-Adressen, Gerätenamen, Benutzernamen, Seriennummern und Pfade enthalten.
Nicht öffentlich hochladen.

Privacy-Modus:
Wenn dieses Script mit -PrivacyMode gestartet wurde, werden typische sensible Werte vor dem ZIP maskiert.
Das ist ein Hilfsfilter, ersetzt aber keine manuelle Prüfung vor öffentlicher Weitergabe.

Wichtig:
Diese Version speichert keine vollständigen EVTX-Logs und keine riesige MEMORY.DMP. Alte hängende Diagnoseprozesse werden beim Start bereinigt.
Falls später wirklich nötig, kann man danach gezielt nachfordern.
"@ | Out-File (Join-Path $Dirs.Root "README.txt") -Encoding UTF8

# ==================================================================================================
# Abschnitt 2: Hilfsfunktionen mit Feedback und Timeout
# ==================================================================================================
# Warum:
# Einige Windows-Abfragen können auf beschädigten Logs, defektem Storage oder problematischen Providern
# hängen. Normale Schritte bekommen genaue Start/OK/Fehler-Ausgaben. Riskante Schritte laufen in einem
# Kindprozess mit Timeout.

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
        $msg = "FEHLER: $Name nach $([math]::Round($sw.Elapsed.TotalSeconds,1))s - $($_.Exception.Message)"
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
                $msg = "ÜBERSPRUNGEN/TIMEOUT: $Name nach $TimeoutSeconds Sekunden"
                Write-ProgressLine $msg "Yellow"
                $msg | Out-File $OutputFile -Encoding UTF8 -Append
                return
            }
        }

        $sw.Stop()
        Write-ProgressLine ("OK: {0} ({1:n1}s)" -f $Name, $sw.Elapsed.TotalSeconds) "Green"
    } catch {
        $sw.Stop()
        $msg = "FEHLER: $Name - $($_.Exception.Message)"
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
                Write-ProgressLine "LÄUFT NOCH: $Name seit ${elapsed}s..." "DarkGray"
            }

            if ($elapsed -ge $TimeoutSeconds) {
                Stop-ProcessTreeSafe -ProcessId ([int]$p.Id) -Reason "Timeout"
                $sw.Stop()
                $msg = "ÜBERSPRUNGEN/TIMEOUT: $Name nach $TimeoutSeconds Sekunden"
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

            Write-ProgressLine "WARNUNG: $Name beendet, ExitCode nicht verfügbar" "Yellow"
            "ExitCode nicht verfügbar" | Out-File (Join-Path $Dirs.Runtime "errors.txt") -Encoding UTF8 -Append
            $stderrText | Out-File (Join-Path $Dirs.Runtime "errors.txt") -Encoding UTF8 -Append
            return $false
        }

        if ([int]$exitCode -eq 0) {
            Write-ProgressLine ("OK: {0} ({1:n1}s)" -f $Name, $sw.Elapsed.TotalSeconds) "Green"
            return $true
        } else {
            Write-ProgressLine "WARNUNG: $Name beendet mit ExitCode $exitCode" "Yellow"
            "ExitCode $exitCode" | Out-File (Join-Path $Dirs.Runtime "errors.txt") -Encoding UTF8 -Append
            if (Test-Path $stderr) {
                Get-Content $stderr -ErrorAction SilentlyContinue | Out-File (Join-Path $Dirs.Runtime "errors.txt") -Encoding UTF8 -Append
            }
            return $false
        }
    } catch {
        $sw.Stop()
        $msg = "FEHLER: $Name - $($_.Exception.Message)"
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
        [Parameter(Mandatory=$true)][string]$Recommendation
    )

    $Findings.Value += [PSCustomObject]@{
        Severity       = $Severity
        Category       = $Category
        Title          = $Title
        Evidence       = $Evidence
        Recommendation = $Recommendation
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
        "Kritisch" { return 4 }
        "Hoch"     { return 3 }
        "Mittel"   { return 2 }
        "Info"     { return 1 }
        default    { return 0 }
    }
}

function Get-FindingSeverityColor {
    param([AllowNull()][string]$Severity)

    switch ([string]$Severity) {
        "Kritisch" { return "Red" }
        "Hoch"     { return "Yellow" }
        "Mittel"   { return "DarkYellow" }
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
    foreach ($severity in @("Kritisch", "Hoch", "Mittel", "Info")) {
        $count = @($Findings | Where-Object { $_.Severity -eq $severity }).Count
        if ($count -gt 0) {
            $parts += ("{0}: {1}" -f $severity, $count)
        }
    }

    if ($parts.Count -eq 0) { return "keine" }
    return ($parts -join ", ")
}

function Get-PrimaryCategoriesText {
    param([object[]]$Findings)

    $important = @($Findings | Where-Object { (Get-FindingSeverityRank $_.Severity) -ge 2 })
    if ($important.Count -eq 0) {
        return "Keine stark auffälligen Kategorien."
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
            Label = "Kritisch"
            Color = "Red"
            Text  = "Es gibt mindestens einen kritischen Hinweis. Absturz-/Hardware-/Storage-Spuren zuerst prüfen."
        }
    }

    if ($maxRank -eq 3) {
        return [PSCustomObject]@{
            Label = "Auffällig"
            Color = "Yellow"
            Text  = "Es gibt deutliche Auffälligkeiten. Die wichtigsten Treffer sollten zeitnah eingeordnet werden."
        }
    }

    if ($maxRank -eq 2) {
        return [PSCustomObject]@{
            Label = "Warnung"
            Color = "DarkYellow"
            Text  = "Es gibt mittlere Auffälligkeiten, aber keine klare Hochrisiko-Signatur in der Heuristik."
        }
    }

    return [PSCustomObject]@{
        Label = "Unauffällig"
        Color = "Green"
        Text  = "Die lokale Heuristik hat keine klaren kritischen Muster in den Kerndaten gefunden."
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
    Write-AnalysisResultLine "Lokales Analyse-Ergebnis" "Cyan"
    Write-AnalysisResultLine "========================" "Cyan"
    Write-AnalysisResultLine ("Gesamtstatus: {0}" -f $status.Label) $status.Color
    Write-AnalysisResultLine ("Kurzfazit: {0}" -f $status.Text) "Gray"
    Write-AnalysisResultLine ("Findings: {0}" -f (Get-FindingCountsText $items)) "Gray"
    Write-AnalysisResultLine ("Hauptbereiche: {0}" -f (Get-PrimaryCategoriesText $items)) "Gray"

    if ($topFindings.Count -gt 0) {
        Write-AnalysisResultLine "" "Gray"
        Write-AnalysisResultLine "Wichtigste Treffer:" "Cyan"
        foreach ($finding in $topFindings) {
            $color = Get-FindingSeverityColor $finding.Severity
            Write-AnalysisResultLine ("- [{0}] {1}: {2}" -f $finding.Severity, $finding.Category, $finding.Title) $color
            Write-AnalysisResultLine ("  Hinweis: {0}" -f $finding.Evidence) "Gray"
            Write-AnalysisResultLine ("  Naechster Schritt: {0}" -f $finding.Recommendation) "Gray"
        }
    }

    Write-AnalysisResultLine "" "Gray"
    Write-AnalysisResultLine "Details im ZIP: 00_Befund_Ersteinschaetzung.txt und 00_Report.html" "Cyan"
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
        return "<p class=""muted"">Keine Daten gefunden.</p>"
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
        "Kritisch"    { return "status-critical" }
        "Auffällig"   { return "status-high" }
        "Warnung"     { return "status-medium" }
        "Unauffällig" { return "status-ok" }
        default       { return "status-neutral" }
    }
}

function Get-SeverityCssClass {
    param([AllowNull()][string]$Severity)

    switch ([string]$Severity) {
        "Kritisch" { return "sev-critical" }
        "Hoch"     { return "sev-high" }
        "Mittel"   { return "sev-medium" }
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
        return '<p class="muted">Keine Findings vorhanden.</p>'
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
        [void]$sb.AppendLine("  <p><strong>Hinweis:</strong> $(Escape-Html $finding.Evidence)</p>")
        [void]$sb.AppendLine("  <p><strong>Nächster Schritt:</strong> $(Escape-Html $finding.Recommendation)</p>")
        [void]$sb.AppendLine('</section>')
    }

    [void]$sb.AppendLine('</div>')
    return $sb.ToString()
}

function Write-InitialFindingsReport {
    $findings = @()

    $targetedPath = Join-Path $Dirs.Events "System_Targeted_Stability_Storage_Network_${DaysBack}d.csv"
    $systemPath = Join-Path $Dirs.Events "System_WARN_ERR_CRIT_${DaysBack}d.csv"
    $applicationPath = Join-Path $Dirs.Events "Application_WARN_ERR_CRIT_${DaysBack}d.csv"

    $targeted = Read-CsvSafe $targetedPath
    $systemEvents = Read-CsvSafe $systemPath
    $applicationEvents = Read-CsvSafe $applicationPath
    $allEvents = @($targeted + $systemEvents + $applicationEvents) |
        Group-Object { "$($_.TimeCreated)|$($_.LogName)|$($_.ProviderName)|$($_.Id)" } |
        ForEach-Object { $_.Group[0] }

    $bugChecks = Get-MatchCount $allEvents { (Test-EventLevelAtMost $_ 3) -and ($_.ProviderName -match 'BugCheck' -or $_.Id -eq '1001') }
    if ($bugChecks -gt 0) {
        Add-Finding ([ref]$findings) "Kritisch" "Absturz" "BugCheck/Bluescreen-Hinweise gefunden" "$bugChecks passende Event(s), z. B. Provider BugCheck oder Event-ID 1001." "Minidumps in 06_Minidumps mit Treiber-/Hardwarefokus auswerten. Danach Storage-, RAM- und Treiberstände prüfen."
    }

    $kernelPower41 = Get-MatchCount $allEvents { (Test-EventLevelAtMost $_ 3) -and $_.ProviderName -match 'Kernel-Power' -and $_.Id -eq '41' }
    if ($kernelPower41 -gt 0) {
        Add-Finding ([ref]$findings) "Hoch" "Stabilität" "Unerwartete Neustarts/Power-Verluste" "$kernelPower41 Event(s) Kernel-Power 41." "Auf Stromversorgung, Netzteil/USV, thermische Abschaltung, BIOS/UEFI, RAM/CPU und vorausgehende Fehler direkt vor dem Neustart achten."
    }

    $unexpectedShutdown = Get-MatchCount $allEvents { (Test-EventLevelAtMost $_ 3) -and ($_.Id -eq '6008' -or ($_.ProviderName -match 'EventLog' -and $_.Id -eq '6008')) }
    if ($unexpectedShutdown -gt 0) {
        Add-Finding ([ref]$findings) "Hoch" "Stabilität" "Windows meldet unerwartetes Herunterfahren" "$unexpectedShutdown Event(s) 6008." "Zeitpunkte mit Kernel-Power, BugCheck, WHEA, Disk/Ntfs und Service-Fehlern abgleichen."
    }

    $whea = Get-MatchCount $allEvents { (Test-EventLevelAtMost $_ 3) -and $_.ProviderName -match 'WHEA-Logger' }
    if ($whea -gt 0) {
        Add-Finding ([ref]$findings) "Hoch" "Hardware" "WHEA-Hardwarefehler gefunden" "$whea WHEA-Logger Event(s)." "CPU/RAM/PCIe/NVMe/GPU und BIOS/UEFI prüfen. Bei wiederholten WHEA-Events sind Hardware, Firmware oder Übertaktung/XMP typische Kandidaten."
    }

    $storage = Get-MatchCount $allEvents {
        (Test-EventLevelAtMost $_ 3) -and
        (
            ($_.ProviderName -match 'disk|Ntfs|storahci|stornvme|iaStor|volmgr') -or
            ($_.Id -in @('51','55','98','129','153','154','157','161','162'))
        )
    }
    if ($storage -gt 0) {
        Add-Finding ([ref]$findings) "Hoch" "Storage" "Storage-/Dateisystem-Ereignisse gefunden" "$storage passende Event(s) aus Disk/Ntfs/Storage/volmgr oder typischen Storage-IDs." "SMART/Herstellerdiagnose, Kabel/Backplane, Controller-/NVMe-/SATA-Treiber und Dateisystem prüfen. Bei NTFS 55/98 oder Disk 51/153 zeitnah Backupstatus prüfen."
    }

    $network = Get-MatchCount $allEvents { (Test-EventLevelAtMost $_ 3) -and $_.ProviderName -match 'Tcpip|Dhcp|DNS Client Events|NDIS|Netwtw|e1|e2f|e2fnexpress' }
    if ($network -gt 0) {
        Add-Finding ([ref]$findings) "Mittel" "Netzwerk" "Netzwerk-/Treiberereignisse gefunden" "$network passende Netzwerk-Event(s)." "NIC-Treiber/Firmware, Energiesparoptionen, Link-Speed, Switch-Port und DHCP/DNS prüfen."
    }

    $service = Get-MatchCount $allEvents {
        (Test-EventLevelAtMost $_ 3) -and
        $_.ProviderName -match 'Service Control Manager' -and
        $_.Id -in @('7000','7001','7009','7011','7022','7023','7024','7031','7032','7034')
    }
    if ($service -gt 0) {
        Add-Finding ([ref]$findings) "Mittel" "Dienste" "Dienstfehler oder Dienstabstürze gefunden" "$service Service-Control-Manager Event(s)." "TopEvents öffnen und prüfen, ob ein bestimmter Dienst wiederholt hängt, abstürzt oder beim Start blockiert."
    }

    $disks = Read-CsvSafe (Join-Path $Dirs.Storage "Disks.csv")
    $badDisks = @($disks | Where-Object {
        (($_.HealthStatus) -and ($_.HealthStatus -notmatch 'Healthy|Unknown')) -or
        (($_.OperationalStatus) -and ($_.OperationalStatus -notmatch 'Online|OK|No Media'))
    })
    if ($badDisks.Count -gt 0) {
        Add-Finding ([ref]$findings) "Hoch" "Storage" "Datenträger melden auffälligen Status" "$($badDisks.Count) Disk-Eintrag/E mit HealthStatus oder OperationalStatus ungleich Healthy/Online." "Disks.csv und PhysicalDisks.csv prüfen und betroffene Datenträger priorisieren."
    }

    $physicalDisks = Read-CsvSafe (Join-Path $Dirs.Storage "PhysicalDisks.csv")
    $badPhysical = @($physicalDisks | Where-Object {
        (($_.HealthStatus) -and ($_.HealthStatus -notmatch 'Healthy|Unknown')) -or
        (($_.OperationalStatus) -and ($_.OperationalStatus -notmatch 'OK|No Media'))
    })
    if ($badPhysical.Count -gt 0) {
        Add-Finding ([ref]$findings) "Hoch" "Storage" "PhysicalDisk meldet auffälligen Status" "$($badPhysical.Count) PhysicalDisk-Eintrag/E auffällig." "Storage Reliability Counter und Herstellerdiagnose prüfen."
    }

    $volumes = Read-CsvSafe (Join-Path $Dirs.Storage "Volumes.csv")
    $badVolumes = @($volumes | Where-Object {
        (($_.HealthStatus) -and ($_.HealthStatus -notmatch 'Healthy|Unknown')) -or
        (($_.OperationalStatus) -and ($_.OperationalStatus -notmatch 'OK|Online|No Media'))
    })
    if ($badVolumes.Count -gt 0) {
        Add-Finding ([ref]$findings) "Mittel" "Storage" "Volume meldet auffälligen Status" "$($badVolumes.Count) Volume-Eintrag/E mit HealthStatus oder OperationalStatus ungleich Healthy/OK." "Volumes.csv prüfen. Bei Full Repair Needed chkdsk/Dateisystemstatus und betroffene Partition einordnen."
    }

    $lowVolumes = @($volumes | Where-Object {
        $freePercent = ConvertTo-NumberSafe $_.FreePercent
        $sizeGb = ConvertTo-NumberSafe $_.SizeGB
        $null -ne $freePercent -and $null -ne $sizeGb -and $sizeGb -ge 10 -and $freePercent -lt 10
    })
    if ($lowVolumes.Count -gt 0) {
        Add-Finding ([ref]$findings) "Mittel" "Storage" "Wenig freier Speicherplatz" "$($lowVolumes.Count) Volume(s) ab 10 GB Größe unter 10 Prozent frei." "Freien Speicher schaffen, Logs/Temp prüfen und Wachstumstreiber identifizieren."
    }

    $dumpRows = Read-CsvSafe (Join-Path $Dirs.Dumps "DumpFiles.csv")
    $copiedDumps = @($dumpRows | Where-Object { $_.Type -match 'Minidump copied' })
    if ($copiedDumps.Count -gt 0) {
        Add-Finding ([ref]$findings) "Hoch" "Absturz" "Minidumps im Paket enthalten" "$($copiedDumps.Count) Minidump(s) kopiert." "Minidumps mit WinDbg/DebugDiag auswerten; Treibername und BugCheck-Code sind oft der schnellste nächste Hinweis."
    }

    $memoryDump = @($dumpRows | Where-Object { $_.Type -match 'MEMORY\.DMP' })
    if ($memoryDump.Count -gt 0) {
        Add-Finding ([ref]$findings) "Info" "Absturz" "Großer MEMORY.DMP vorhanden, nicht kopiert" "MEMORY.DMP wurde aus Größen-/Datenschutzgründen nur aufgelistet." "Nur gezielt nachfordern, wenn Minidumps nicht ausreichen."
    }

    $timeoutsPath = Join-Path $Dirs.Runtime "timeouts.txt"
    if (Test-Path -LiteralPath $timeoutsPath) {
        $timeoutLines = @(Get-Content -LiteralPath $timeoutsPath -ErrorAction SilentlyContinue)
        if ($timeoutLines.Count -gt 0) {
            Add-Finding ([ref]$findings) "Mittel" "Datensammlung" "Ein oder mehrere Sammelschritte liefen in einen Timeout" "$($timeoutLines.Count) Timeout-Zeile(n) in 99_Runtime\timeouts.txt." "Timeout-Datei prüfen; ein hängender Provider kann selbst ein Symptom sein."
        }
    }

    $errorsPath = Join-Path $Dirs.Runtime "errors.txt"
    if (Test-Path -LiteralPath $errorsPath) {
        $errorLines = @(Get-Content -LiteralPath $errorsPath -ErrorAction SilentlyContinue)
        if ($errorLines.Count -gt 0) {
            Add-Finding ([ref]$findings) "Info" "Datensammlung" "Sammelfehler protokolliert" "$($errorLines.Count) Zeile(n) in 99_Runtime\errors.txt." "errors.txt prüfen. Einzelne fehlende Provider sind nicht automatisch kritisch."
        }
    }

    if ($findings.Count -eq 0) {
        Add-Finding ([ref]$findings) "Info" "Überblick" "Keine klaren Hochrisiko-Muster in der automatischen Ersteinschätzung" "Die Heuristik fand keine der typischen Signaturen in den gesammelten Kerndaten." "Trotzdem TopEvents, gezielte Events und konkrete Fehlerzeitpunkte prüfen."
    }

    $findingsPath = Join-Path $Dirs.Runtime "Befund_Findings.csv"
    $findings | Export-Csv $findingsPath -NoTypeInformation -Encoding UTF8

    $analysisStatus = Get-AnalysisStatus $findings
    $sortedFindings = @(Get-SortedFindings $findings)
    $topFindings = @($sortedFindings | Select-Object -First 5)

    $reportPath = Join-Path $Dirs.Root "00_Befund_Ersteinschaetzung.txt"
@"
Automatische Ersteinschaetzung
=============================

Tool:          $ToolName $ToolVersion
Erstellt:      $(Get-Date)
Computer:      $env:COMPUTERNAME
Zeitraum:      letzte $DaysBack Tage
PrivacyMode:   $([bool]$PrivacyMode)

Wichtig:
Diese Datei ist eine heuristische Ersteinschaetzung auf Basis der gesammelten Daten.
Sie ersetzt keine manuelle Analyse, priorisiert aber die wahrscheinlich relevanten Spuren.

Gesamtstatus:  $($analysisStatus.Label)
Kurzfazit:     $($analysisStatus.Text)
Findings:      $(Get-FindingCountsText $findings)
Hauptbereiche: $(Get-PrimaryCategoriesText $findings)

"@ | Out-File $reportPath -Encoding UTF8

    if ($topFindings.Count -gt 0) {
        "Wichtigste Treffer:`r`n" | Out-File $reportPath -Encoding UTF8 -Append
        foreach ($finding in $topFindings) {
@"
[$($finding.Severity)] $($finding.Category): $($finding.Title)
Hinweis:        $($finding.Evidence)
Naechster Schritt: $($finding.Recommendation)

"@ | Out-File $reportPath -Encoding UTF8 -Append
        }
    }

    "Alle Treffer:`r`n" | Out-File $reportPath -Encoding UTF8 -Append

    foreach ($finding in $sortedFindings) {
@"
[$($finding.Severity)] $($finding.Category): $($finding.Title)
Hinweis:        $($finding.Evidence)
Naechster Schritt: $($finding.Recommendation)

"@ | Out-File $reportPath -Encoding UTF8 -Append
    }

@"
Dateien fuer die manuelle Pruefung:
- 00_Kurzuebersicht.txt
- 00_Report.html
- 01_Events\System_Targeted_Stability_Storage_Network_${DaysBack}d.csv
- 01_Events\System_Targeted_TopEvents_${DaysBack}d.csv
- 99_Runtime\runtime.log
- 99_Runtime\errors.txt und timeouts.txt, falls vorhanden
"@ | Out-File $reportPath -Encoding UTF8 -Append

    return $findings
}

function Write-HtmlReport {
    $htmlPath = Join-Path $Dirs.Root "00_Report.html"
    $findings = Read-CsvSafe (Join-Path $Dirs.Runtime "Befund_Findings.csv")
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

    $findingsHtml = New-HtmlTable $findings @("Severity","Category","Title","Evidence","Recommendation") 50
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
    <div class="meta">$ToolVersion | Erstellt: $(Escape-Html (Get-Date)) | Zeitraum: letzte $DaysBack Tage | PrivacyMode: $([bool]$PrivacyMode)</div>
    <div class="grid">
      <div class="stat"><div class="label">Computer</div><div class="value">$(Escape-Html $env:COMPUTERNAME)</div></div>
      <div class="stat"><div class="label">Gesamtstatus</div><div class="value">$(Escape-Html $analysisStatus.Label)</div></div>
      <div class="stat"><div class="label">Findings</div><div class="value">$($findings.Count)</div></div>
      <div class="stat"><div class="label">Disks</div><div class="value">$($disks.Count)</div></div>
      <div class="stat"><div class="label">Netzwerkadapter</div><div class="value">$($netAdapters.Count)</div></div>
    </div>
  </header>
  <main>
    <h2>Automatische Ersteinschaetzung</h2>
    <div class="summary">
      <p><strong>Gesamtstatus:</strong> $(Escape-Html $analysisStatus.Label)</p>
      <p><strong>Kurzfazit:</strong> $(Escape-Html $analysisStatus.Text)</p>
      <p><strong>Findings:</strong> $(Escape-Html (Get-FindingCountsText $findings))</p>
      <p><strong>Hauptbereiche:</strong> $(Escape-Html (Get-PrimaryCategoriesText $findings))</p>
    </div>
    $findingsHtml
    <h2>System</h2>
    <pre>$(Escape-Html $osText)</pre>
    <h2>Datentraeger</h2>
    $diskHtml
    <h2>Volumes</h2>
    $volumeHtml
    <h2>Netzwerkadapter</h2>
    $netHtml
    <h2>Top System Events</h2>
    $topHtml
    <h2>Gezielte Stabilitaets-/Storage-/Netzwerk-Events</h2>
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
        [string]$OutputPath = (Join-Path $Dirs.Root "00_Ergebnis.html"),
        [string]$PackagePath = ""
    )

    $findings = Read-CsvSafe (Join-Path $Dirs.Runtime "Befund_Findings.csv")
    $sortedFindings = @(Get-SortedFindings $findings)
    $analysisStatus = Get-AnalysisStatus $sortedFindings
    $statusClass = Get-StatusCssClass $analysisStatus.Label
    $findingCardsHtml = New-FindingCardsHtml -Findings $sortedFindings -MaxRows 6
    $allFindingsHtml = New-HtmlTable $sortedFindings @("Severity","Category","Title","Evidence","Recommendation") 80
    $packageDisplay = if ([string]::IsNullOrWhiteSpace($PackagePath)) { "Wird nach Abschluss erstellt." } else { $PackagePath }
    $reportPath = "00_Report.html"
    $textReportPath = "00_Befund_Ersteinschaetzung.txt"

@"
<!doctype html>
<html lang="de">
<head>
  <meta charset="utf-8">
  <title>ServerDiagLite Ergebnis</title>
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
    <h1>ServerDiagLite Ergebnis</h1>
    <div class="meta">$ToolVersion | Erstellt: $(Escape-Html (Get-Date)) | Computer: $(Escape-Html $env:COMPUTERNAME) | Zeitraum: letzte $DaysBack Tage</div>
    <section class="status $statusClass">
      <div class="status-label">Gesamtstatus</div>
      <div class="status-value">$(Escape-Html $analysisStatus.Label)</div>
      <p>$(Escape-Html $analysisStatus.Text)</p>
    </section>
    <div class="summary-grid">
      <div class="summary-item"><div class="label">Findings</div><div class="value">$(Escape-Html (Get-FindingCountsText $sortedFindings))</div></div>
      <div class="summary-item"><div class="label">Hauptbereiche</div><div class="value">$(Escape-Html (Get-PrimaryCategoriesText $sortedFindings))</div></div>
      <div class="summary-item"><div class="label">Privacy-Modus</div><div class="value">$([bool]$PrivacyMode)</div></div>
    </div>
  </header>
  <main>
    <h2>Wichtigste Treffer und nächste Schritte</h2>
    $findingCardsHtml

    <h2>Alle Findings</h2>
    $allFindingsHtml

    <h2>Dateien</h2>
    <div class="paths">
      <p><strong>ZIP-Paket:</strong> $(Escape-Html $packageDisplay)</p>
      <p><strong>Detailreport im Paket:</strong> $(Escape-Html $reportPath)</p>
      <p><strong>Textbefund im Paket:</strong> $(Escape-Html $textReportPath)</p>
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

    Write-ProgressLine "Privacy-Modus aktiv: maskiere typische sensible Werte vor dem ZIP..." "Cyan"

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
PrivacyMode war aktiv.
Typische IP-Adressen, MAC-Adressen, Computernamen, Benutzernamen, Pfade, Seriennummern und Geräte-IDs wurden maskiert.
Bitte vor öffentlicher Weitergabe trotzdem manuell prüfen.
"@ | Out-File (Join-Path $Dirs.Runtime "privacy_mode.txt") -Encoding UTF8
}

# ==================================================================================================
# Abschnitt 3: Betriebssystem, Uptime und Hardware-Grunddaten
# ==================================================================================================
# Warum:
# Für Freezes/Abstürze sind Windows-Build, letzter Boot, BIOS-Version, Board, CPU und RAM wichtig.

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

Invoke-ChildPowerShellWithTimeout -Name "OS, Uptime und Hardware-Grunddaten" -ScriptContent $SystemInventoryScript -TimeoutSeconds $StepTimeoutSeconds | Out-Null

# ==================================================================================================
# Abschnitt 4: Storage / Datenträger
# ==================================================================================================
# Warum:
# Bei Headless-Hängern sind Datenträgerfehler eine häufige Ursache.
# Wichtig ist vor allem: Welche Disk-Nummer gehört zu welchem echten Laufwerk und Laufwerksbuchstaben?

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

Invoke-ChildPowerShellWithTimeout -Name "Storage- und Laufwerkszuordnung" -ScriptContent $StorageInventoryScript -TimeoutSeconds $StepTimeoutSeconds | Out-Null

# StorageReliabilityCounter läuft in einem Kindprozess mit Timeout, weil Storage-Provider manchmal hängen.
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
# Abschnitt 5: Netzwerk
# ==================================================================================================
# Warum:
# Wenn ein Headless-Server nicht erreichbar ist, kann Windows laufen, aber die NIC hängen.
# Deshalb sammeln wir Treiberstand, Link-Speed, IPs, Offload-/Energiesparoptionen.

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

Invoke-ChildPowerShellWithTimeout -Name "Netzwerkadapter, IPs und NIC-Einstellungen" -ScriptContent $NetworkInventoryScript -TimeoutSeconds $StepTimeoutSeconds | Out-Null

Invoke-ExternalWithTimeout -Name "ipconfig /all" -Command "ipconfig /all" -OutputFile (Join-Path $Dirs.Network "ipconfig_all.txt") -TimeoutSeconds 20

# ==================================================================================================
# Abschnitt 6: Energie, Sleep, Wake
# ==================================================================================================
# Warum:
# Für einen Headless-Server sind Standby, Hibernate, Wake-Timer und Geräte-Wake-Status relevant.
# Jeder powercfg-Befehl bekommt einzeln einen Timeout, damit nichts hängen bleibt.

Invoke-ExternalWithTimeout -Name "powercfg available sleepstates" -Command "powercfg /a" -OutputFile (Join-Path $Dirs.Power "powercfg_available_sleepstates.txt") -TimeoutSeconds 20
Invoke-ExternalWithTimeout -Name "powercfg active scheme" -Command "powercfg /getactivescheme" -OutputFile (Join-Path $Dirs.Power "powercfg_active_scheme.txt") -TimeoutSeconds 20
Invoke-ExternalWithTimeout -Name "powercfg requests" -Command "powercfg /requests" -OutputFile (Join-Path $Dirs.Power "powercfg_requests.txt") -TimeoutSeconds 20
Invoke-ExternalWithTimeout -Name "powercfg lastwake" -Command "powercfg /lastwake" -OutputFile (Join-Path $Dirs.Power "powercfg_lastwake.txt") -TimeoutSeconds 20
Invoke-ExternalWithTimeout -Name "powercfg waketimers" -Command "powercfg /waketimers" -OutputFile (Join-Path $Dirs.Power "powercfg_waketimers.txt") -TimeoutSeconds 20
Invoke-ExternalWithTimeout -Name "powercfg wake armed devices" -Command "powercfg /devicequery wake_armed" -OutputFile (Join-Path $Dirs.Power "powercfg_wake_armed_devices.txt") -TimeoutSeconds 20

# ==================================================================================================
# Abschnitt 7: Relevante Treiber statt komplette Treiberliste
# ==================================================================================================
# Warum:
# Für diesen Fehlerfall sind vor allem Netzwerk-, Storage-, Disk- und Systemtreiber interessant.
# Eine komplette Treiberliste macht das Paket größer und unübersichtlicher.

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

Invoke-ChildPowerShellWithTimeout -Name "Relevante Treiberklassen und Updates" -ScriptContent $DriverInventoryScript -TimeoutSeconds $StepTimeoutSeconds | Out-Null

# ==================================================================================================
# Abschnitt 8: Eventlogs mit Timeout und Begrenzung
# ==================================================================================================
# Warum:
# Eventlogs sind der Teil, der auf manchen Systemen lange dauern oder hängen kann.
# Deshalb läuft dieser Teil separat mit Timeout.
#
# Diese Version exportiert KEINE vollständigen EVTX-Dateien.
# Stattdessen gibt es CSV/TXT:
# - System/Application Kritisch/Fehler/Warnung
# - Top-Events
# - gezielte Stabilitäts-/Storage-/Netzwerkevents
# Das ist für die erste ChatGPT-Analyse meistens besser und deutlich kleiner.

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

Invoke-ChildPowerShellWithTimeout -Name "Eventlog-Auswertung System Application Targeted" -ScriptContent $EventScript -TimeoutSeconds $EventTimeoutSeconds | Out-Null

# ==================================================================================================
# Abschnitt 9: Minidumps, aber keine riesige MEMORY.DMP
# ==================================================================================================
# Warum:
# Kleine Minidumps sind bei Bluescreens sehr hilfreich.
# MEMORY.DMP kann mehrere GB groß sein und wird nur aufgelistet, nicht kopiert.

Invoke-Step "Minidumps sammeln und große Dumps nur auflisten" {
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
# Abschnitt 10: Kurzüberblick
# ==================================================================================================
# Warum:
# Diese Datei zeigt direkt die wichtigsten Eckdaten und Top-Events, ohne erst CSVs zu öffnen.

$SummaryScript = New-ChildScript @'
$summaryPath = Join-Path $Dirs.Root "00_Kurzuebersicht.txt"

$os = Get-CimInstance Win32_OperatingSystem
$cs = Get-CimInstance Win32_ComputerSystem
$bios = Get-CimInstance Win32_BIOS
$bb = Get-CimInstance Win32_BaseBoard
$cpu = Get-CimInstance Win32_Processor | Select-Object -First 1
$uptime = (Get-Date) - $os.LastBootUpTime

@"
Kurzuebersicht
==============

Computer:       $env:COMPUTERNAME
Windows:        $($os.Caption) $($os.Version) Build $($os.BuildNumber)
Letzter Boot:   $($os.LastBootUpTime)
Uptime:         $([math]::Round($uptime.TotalDays,2)) Tage
Hersteller:     $($cs.Manufacturer)
Modell:         $($cs.Model)
Mainboard:      $($bb.Manufacturer) $($bb.Product)
BIOS:           $($bios.SMBIOSBIOSVersion) vom $($bios.ReleaseDate)
CPU:            $($cpu.Name)
RAM gesamt:     $([math]::Round($cs.TotalPhysicalMemory / 1GB,2)) GB

Pakettyp:       $ToolVersion
Zeitraum:       letzte $DaysBack Tage
MaxEvents:      $MaxEvents

Dieses Paket enthält nur die wichtigsten Daten:
- automatische Ersteinschaetzung
- HTML-Report und Manifest
- System/Application Fehler/Warnungen als CSV
- gezielte Stabilitäts-/Storage-/Netzwerkevents
- Hardware, Storage, Netzwerk, Power
- Minidumps, falls vorhanden

"@ | Out-File $summaryPath -Encoding UTF8

"`r`nDatentraeger:`r`n" | Out-File $summaryPath -Encoding UTF8 -Append
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

"`r`nNetzwerkadapter:`r`n" | Out-File $summaryPath -Encoding UTF8 -Append
Get-NetAdapter |
    Select-Object Name, InterfaceDescription, Status, LinkSpeed, DriverVersion, DriverDate |
    Format-Table -AutoSize |
    Out-String -Width 240 |
    Out-File $summaryPath -Encoding UTF8 -Append

$topSystem = Join-Path $Dirs.Events "System_TopEvents_${DaysBack}d.csv"
if (Test-Path $topSystem) {
    "`r`nTop System Events Kritisch/Fehler/Warnung:`r`n" | Out-File $summaryPath -Encoding UTF8 -Append
    Import-Csv $topSystem |
        Select-Object -First 25 |
        Format-Table -AutoSize |
        Out-String -Width 300 |
        Out-File $summaryPath -Encoding UTF8 -Append
}

$targetedTxt = Join-Path $Dirs.Events "System_Targeted_Last200.txt"
if (Test-Path $targetedTxt) {
    "`r`nLetzte gezielte Stabilitaetsereignisse:`r`n" | Out-File $summaryPath -Encoding UTF8 -Append
    Get-Content $targetedTxt -ErrorAction SilentlyContinue |
        Select-Object -First 80 |
        Out-File $summaryPath -Encoding UTF8 -Append
}
'@

Invoke-ChildPowerShellWithTimeout -Name "Kurzüberblick erstellen" -ScriptContent $SummaryScript -TimeoutSeconds $StepTimeoutSeconds | Out-Null

# ==================================================================================================
# Abschnitt 11: Befund, HTML-Report, Manifest und optionaler Privacy-Modus
# ==================================================================================================
# Warum:
# Ab hier werden die gesammelten Rohdaten in eine erste Priorisierung und menschenlesbare Übersicht
# überführt. Der Privacy-Modus läuft ganz am Ende vor dem ZIP, damit auch Report und Manifest maskiert werden.

$script:LatestFindings = @()
Invoke-Step "Automatische Ersteinschaetzung erstellen" {
    $script:LatestFindings = @(Write-InitialFindingsReport)
}

Invoke-Step "HTML-Report erstellen" {
    Write-HtmlReport
}

Invoke-Step "Ergebnisfenster vorbereiten" {
    Write-ResultWindowReport | Out-Null
}

Invoke-Step "Lokales Analyse-Ergebnis anzeigen" {
    Show-LocalAnalysisResult -Findings $script:LatestFindings
}

Write-ProgressLine "Finalisiere Transcript vor Manifest/ZIP..." "Gray"
try {
    Stop-Transcript | Out-Null
} catch {}

Invoke-Step "Manifest erstellen" {
    Write-Manifest -RunEnded (Get-Date)
}

if ($PrivacyMode) {
    Invoke-Step "Privacy-Modus anwenden" {
        Invoke-PrivacyScrub
    }
}

# ==================================================================================================
# Abschnitt 12: ZIP erstellen
# ==================================================================================================
# Warum:
# Am Ende soll nur eine Datei weitergegeben werden.

Write-Host ""
Write-ProgressLine "Erstelle ZIP-Datei..." "Cyan"

$Zip = "$Out.zip"
$ResultWindowSource = Join-Path $Out "00_Ergebnis.html"
$ResultWindow = "${Out}_Ergebnis.html"

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
        Write-Warning "Ergebnisfenster-Datei konnte nicht erstellt werden: $($_.Exception.Message)"
    }

    # Nach erfolgreichem ZIP wird der Arbeitsordner gelöscht.
    # Dadurch bleiben keine alten Rohdatenordner liegen und spätere Läufe starten sauberer.
    try {
        Remove-Item -Path $Out -Recurse -Force -ErrorAction Stop
        Write-Host "Arbeitsordner wurde nach erfolgreichem ZIP gelöscht." -ForegroundColor DarkGray
    } catch {
        Write-Warning "ZIP wurde erstellt, aber der Arbeitsordner konnte nicht gelöscht werden: $($_.Exception.Message)"
    }

    Write-Host ""
    Write-Host "Fertig." -ForegroundColor Green
    Write-Host "Schlankes Diagnosepaket:"
    Write-Host $Zip -ForegroundColor Yellow
    Write-Host ""
    Write-Host "Diese ZIP-Datei reicht für die erste Analyse meistens aus." -ForegroundColor Cyan
    if (Test-Path -LiteralPath $ResultWindow) {
        Write-Host ""
        Write-Host "Ergebnisfenster:"
        Write-Host $ResultWindow -ForegroundColor Yellow
        try {
            Start-Process -FilePath $ResultWindow
        } catch {
            Write-Warning "Ergebnisfenster konnte nicht automatisch geöffnet werden: $($_.Exception.Message)"
        }
    }
} catch {
    Write-Warning "ZIP konnte nicht erstellt werden: $($_.Exception.Message)"
    Write-Host "Der unkomprimierte Ordner liegt hier:"
    Write-Host $Out -ForegroundColor Yellow
    $fallbackResultWindow = Join-Path $Out "00_Ergebnis.html"
    if (Test-Path -LiteralPath $fallbackResultWindow) {
        Write-Host "Ergebnisfenster:"
        Write-Host $fallbackResultWindow -ForegroundColor Yellow
        try {
            Start-Process -FilePath $fallbackResultWindow
        } catch {
            Write-Warning "Ergebnisfenster konnte nicht automatisch geöffnet werden: $($_.Exception.Message)"
        }
    }
}
