Set-StrictMode -Version 2.0

<#
    Restart/shutdown/BugCheck event parsing logic. The field-extraction
    functions in this module (Get-HsEventDataValue, Get-HsFirstEventDataValue,
    Get-HsEvent1074Info, Get-HsBugcheckCodeFromEvent) are adapted verbatim
    from PCDiagLite.ps1's proven restart/shutdown correlation code so the
    Hardware-Stabilitätstest's SYSTEM_RESET detection (spec sections 27-30)
    does not re-implement the same Event 1074 / BugCheck 1001 parsing
    independently. PCDiagLite.ps1 has since been updated to import this same
    module instead of keeping its own private copies - see
    docs/HARDWARE_STABILITY_STATE.md for the refactor note.
#>

function Get-HsEventsSafe {
    param(
        [Parameter(Mandatory=$true)][hashtable]$Filter,
        [int]$Maximum = 0
    )
    try {
        if ($Maximum -gt 0) {
            return @(Get-WinEvent -FilterHashtable $Filter -MaxEvents $Maximum -ErrorAction Stop)
        }
        return @(Get-WinEvent -FilterHashtable $Filter -ErrorAction Stop)
    } catch {
        if ([string]$_.FullyQualifiedErrorId -match 'NoMatchingEventsFound') { return @() }
        throw
    }
}

function Get-HsEventDataSummary {
    <#
        Flattens an event's <EventData> into a "Name=Value; Name2=Value2"
        string, the normalized form the field-extraction helpers below parse.
    #>
    param([Parameter(Mandatory=$true)]$Event)
    try {
        [xml]$xml = $Event.ToXml()
        $index = 0
        $parts = @()
        foreach ($data in @($xml.Event.EventData.Data)) {
            $name = [string]$data.Name
            $value = [string]$data.'#text'
            if ([string]::IsNullOrWhiteSpace($value)) { $value = [string]$data.InnerText }
            if ([string]::IsNullOrWhiteSpace($value)) { $value = [string]$data }
            if ([string]::IsNullOrWhiteSpace($name)) { $name = "Data$index" }
            if ($value.Length -gt 160) { $value = $value.Substring(0,160) + "..." }
            if (-not [string]::IsNullOrWhiteSpace($value)) { $parts += "$name=$value" }
            $index++
            if ($parts.Count -ge 30) { break }
        }
        return ($parts -join "; ")
    } catch {
        return ""
    }
}

function ConvertTo-HsEventRow {
    <#
        Normalizes a raw Get-WinEvent result into the plain row shape that
        every classification helper in this module consumes.
    #>
    param([Parameter(Mandatory=$true)]$Event)
    return [pscustomobject]@{
        ProviderName = [string]$Event.ProviderName
        Id           = [int]$Event.Id
        RecordId     = $Event.RecordId
        TimeCreated  = $Event.TimeCreated
        Message      = [string]$Event.Message
        EventData    = Get-HsEventDataSummary -Event $Event
        LevelDisplayName = [string]$Event.LevelDisplayName
    }
}

function Get-HsEventDataValue {
    param(
        [AllowNull()][string]$EventData,
        [Parameter(Mandatory=$true)][string]$Name
    )
    if ([string]::IsNullOrWhiteSpace($EventData)) { return "" }
    $text = ([string]$EventData).Trim()
    if ($text.StartsWith("{")) {
        try {
            $dataObject = $text | ConvertFrom-Json -ErrorAction Stop
            $property = @($dataObject.PSObject.Properties | Where-Object { $_.Name -ieq $Name } | Select-Object -First 1)
            if ($property.Count -gt 0) { return ([string]$property[0].Value).Trim() }
        } catch {}
    }
    $match = [regex]::Match($text, "(?i)(^|;\s*)$([regex]::Escape($Name))=([^;]*)")
    if ($match.Success) { return $match.Groups[2].Value.Trim() }
    return ""
}

function Get-HsFirstEventDataValue {
    param(
        [AllowNull()][string]$EventData,
        [string[]]$Names
    )
    foreach ($name in @($Names)) {
        $value = Get-HsEventDataValue -EventData $EventData -Name $name
        if (-not [string]::IsNullOrWhiteSpace($value)) { return $value }
    }
    return ""
}

function Get-HsEvent1074Info {
    <#
        Extracts the initiating process/user/reason/shutdown-type from a
        User32 1074 event (planned shutdown/restart request), and classifies
        Windows Update as the initiator only on matching process/service/
        reason evidence (spec section 30).
    #>
    param([Parameter(Mandatory=$true)]$Event)

    $eventData = [string]$Event.EventData
    $message = [string]$Event.Message
    $process = Get-HsFirstEventDataValue -EventData $eventData -Names @("ProcessName","InitiatorProcess","param1","Data0")
    $user = Get-HsFirstEventDataValue -EventData $eventData -Names @("User","UserName","InitiatingUser","param7","Data6")
    $reason = Get-HsFirstEventDataValue -EventData $eventData -Names @("Reason","param3","Data2")
    $reasonCode = Get-HsFirstEventDataValue -EventData $eventData -Names @("ReasonCode","param4","Data3")
    $shutdownType = Get-HsFirstEventDataValue -EventData $eventData -Names @("ShutdownType","param5","Data4")
    $comment = Get-HsFirstEventDataValue -EventData $eventData -Names @("Comment","param6","Data5")

    if ([string]::IsNullOrWhiteSpace($process) -and $message -match '(?im)(?:The process|Der Prozess)\s+(.+?\.exe)(?:\s+\([^)]+\))?\s+(?:has initiated|hat den)') {
        $process = $matches[1].Trim()
    }
    if ($process -match '^(?<path>.+?\.exe)(?:\s+\([^)]+\))?$') { $process = $matches.path.Trim() }
    if ([string]::IsNullOrWhiteSpace($user) -and $message -match '(?im)(?:on behalf of user|im Auftrag des Benutzers)\s+([^\r\n]+?)(?:\s+for the following reason|\s+aus folgendem Grund)') {
        $user = $matches[1].Trim()
    }
    if ([string]::IsNullOrWhiteSpace($reason) -and $message -match '(?im)(?:for the following reason|aus folgendem Grund):\s*([^\r\n]+)') {
        $reason = $matches[1].Trim()
    }
    if ([string]::IsNullOrWhiteSpace($reasonCode) -and $message -match '(?im)(?:Reason Code|Ursachencode):\s*([^\r\n]+)') {
        $reasonCode = $matches[1].Trim()
    }
    if ([string]::IsNullOrWhiteSpace($shutdownType) -and $message -match '(?im)(?:Shutdown Type|Herunterfahrtyp):\s*([^\r\n]+)') {
        $shutdownType = $matches[1].Trim()
    }
    if ([string]::IsNullOrWhiteSpace($comment) -and $message -match '(?im)(?:Comment|Kommentar):\s*([^\r\n]*)') {
        $comment = $matches[1].Trim()
    }

    $normalizedType = [string]$shutdownType
    if ($normalizedType -match '(?i)restart|reboot|neu\s*start|Neustart') {
        $normalizedType = "restart"
    } elseif ($normalizedType -match '(?i)power\s*off|shutdown|herunter|ausschalten') {
        $normalizedType = "shutdown"
    }

    $context = "$process $reason $reasonCode $shutdownType $comment $message"
    $category = if ([string]::IsNullOrWhiteSpace($process)) { "Unknown" } else { "Application or service" }
    if ($process -match '(?i)(?:^|\\)(MoNotificationUx|MusNotification|MusNotificationUx|UsoClient)\.exe$') {
        $category = "Windows Update"
    } elseif ($context -match '(?i)UpdateOrchestrator|Update Orchestrator|UsoSvc' -and ($process -notmatch '(?i)svchost\.exe$' -or $context -match '(?i)UsoSvc|UpdateOrchestrator')) {
        $category = "Windows Update"
    } elseif ($reason -match '(?i)Operating System:\s*Service pack\s*\(Planned\)|Betriebssystem:\s*Service Pack\s*\(geplant\)') {
        $category = "Windows Update"
    }

    return [PSCustomObject]@{
        InitiatorProcess  = $process
        InitiatingUser    = $user
        ShutdownType      = $normalizedType
        Reason            = $reason
        ReasonCode        = $reasonCode
        Comment           = $comment
        InitiatorCategory = $category
    }
}

function Get-HsBugcheckCodeFromEvent {
    param([AllowNull()]$Event)
    if ($null -eq $Event) { return "" }
    $eventData = [string]$Event.EventData
    $code = Get-HsFirstEventDataValue -EventData $eventData -Names @("BugcheckCode","BugCheckCode","param1","Data0")
    if (-not [string]::IsNullOrWhiteSpace($code)) { return $code }
    $message = [string]$Event.Message
    if ($message -match '(?i)(?:bugcheck was|Fehlerüberprüfung[^\r\n]*)(?:\s|:)+(0x[0-9a-f]+)') { return $matches[1] }
    return ""
}

function Get-HsEventRecordKey {
    param([AllowNull()]$Event)
    if ($null -eq $Event) { return "" }
    return "$([string]$Event.ProviderName)|$([string]$Event.Id)|$([string]$Event.RecordId)|$([string]$Event.TimeCreated)"
}

# ---------------------------------------------------------------------------
# WHEA classification (spec section 22/27/32/33)
# ---------------------------------------------------------------------------

function Get-HsWheaCategory {
    <#
        Categorizes a WHEA-Logger event without over-interpreting a single
        corrected error as definitive proof of a specific defective
        component (spec section 22: WHEA 17 must not be read as "mainboard
        defective").
    #>
    param([Parameter(Mandatory=$true)]$Event)

    if ($Event.ProviderName -notmatch '(?i)WHEA') { return "" }
    $text = "$($Event.Message) $($Event.EventData)"

    switch ($Event.Id) {
        17 {
            if ($text -match '(?i)PCI Express|PCIe') { return "PCIe" }
            return "Corrected Machine Check"
        }
        18 { return "Machine Check Exception" }
        19 { return "Corrected Machine Check" }
        20 { return "Machine Check" }
        default {
            if ($text -match '(?i)cache') { return "Cache Hierarchy" }
            if ($text -match '(?i)memory controller|DRAM') { return "Memory Controller" }
            if ($text -match '(?i)PCI Express|PCIe') { return "PCIe" }
            if ($text -match '(?i)bus|interconnect') { return "Bus / Interconnect" }
            return "WHEA"
        }
    }
}

function Get-HsWheaAssessment {
    param([Parameter(Mandatory=$true)][string]$Category)
    switch ($Category) {
        "PCIe" { return "Corrected PCIe hardware errors occurred. Possible causes include the GPU, the PCIe link/slot, the mainboard, power delivery, or signal integrity - not necessarily a defective card or board." }
        "Cache Hierarchy" { return "Errors were reported in the CPU cache hierarchy. CPU, voltage/BIOS settings, or platform stability may be involved." }
        "Memory Controller" { return "Errors were reported in the memory controller / DRAM path. RAM, the integrated memory controller, or platform configuration may be involved." }
        default { return "One or more WHEA hardware error events were recorded. This does not by itself prove a specific defective component." }
    }
}

Export-ModuleMember -Function * -Variable *
