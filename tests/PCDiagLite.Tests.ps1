[CmdletBinding()]
param([string]$ReplayPackageRoot = "")

$ErrorActionPreference = "Stop"
$repoRoot = Split-Path $PSScriptRoot -Parent
$tokens = $null
$parseErrors = $null
$ast = [Management.Automation.Language.Parser]::ParseFile((Join-Path $repoRoot "scripts\diagnostics\PCDiagLite.ps1"), [ref]$tokens, [ref]$parseErrors)
if ($parseErrors.Count) { throw "PCDiagLite parse failed: $parseErrors" }
foreach ($definition in $ast.FindAll({ param($node) $node -is [Management.Automation.Language.FunctionDefinitionAst] }, $false)) {
    . ([scriptblock]::Create($definition.Extent.Text))
}

function Assert-True {
    param([bool]$Condition, [string]$Message)
    if (-not $Condition) { throw "Assertion failed: $Message" }
}

function Set-TestDirectories {
    param([string]$Root)
    $script:Out = $Root
    $script:Dirs = @{ Root=$Root; Events=(Join-Path $Root "01_Events"); System=(Join-Path $Root "02_System_Hardware"); Storage=(Join-Path $Root "03_Storage"); Network=(Join-Path $Root "04_Network"); Power=(Join-Path $Root "05_Power"); Dumps=(Join-Path $Root "06_Minidumps"); WER=(Join-Path $Root "07_WER"); GPU=(Join-Path $Root "08_GPU_Driver"); Runtime=(Join-Path $Root "99_Runtime") }
    foreach ($directory in $script:Dirs.Values) { New-Item -ItemType Directory -Path $directory -Force | Out-Null }
    $script:RuntimeLog = Join-Path $script:Dirs.Runtime "runtime.log"
}

$testRoot = Join-Path ([IO.Path]::GetTempPath()) ("PCDiagLite-Tests-" + [guid]::NewGuid().ToString("N"))
$EventRangeLabel = "all"
$EventRangeText = "all available entries"
$ToolName = "PCDiagLite"
$ToolVersion = "2.6 test"
$PrivacyMode = $false
$RunStarted = Get-Date
$RestartCorrelationWindowMinutes = 10
$BootCorrelationWindowMinutes = 3

try {
    Set-TestDirectories -Root $testRoot
    $cpuEvent = [PSCustomObject]@{
        TimeCreated="2026-11-21 22:02:08"; LogName="System"; ProviderName="Microsoft-Windows-WHEA-Logger"; Id=18; Level=2; RecordId=100; LevelDisplayName="Error"
        Message="Schwerwiegender Hardwarefehler.`nGemeldet von Komponente: Prozessorkern`nFehlerquelle: Machine Check Exception`nFehlertyp: Cache Hierarchy Error`nProzessor-APIC-ID: 13"
        EventData="ErrorSource=3; ApicId=13; MCABank=5; MciStat=0xbea0000000000108"
        SourceFile="01_Events\System.csv"; SourceEntry="CSV row 2"
    }
    $cpu = Get-WheaEventAssessment -Event $cpuEvent
    Assert-True ($cpu.Component -eq "CPU / Cache-Hierarchie" -and $cpu.ReportedBy -eq "Prozessorkern") "German processor/cache error identifies the reported component"
    Assert-True ($cpu.ApicId -eq "13" -and $cpu.MCABank -eq "5") "APIC ID and MCA bank are preserved"
    Assert-True ($cpu.Severity -eq "Critical") "Fatal processor errors take priority over generic driver warnings"
    Assert-True ($cpu.Recommendation -match "Curve Optimizer" -and $cpu.Recommendation -match "keinen CPU-Defekt") "CPU recommendation is specific without declaring a defective processor"
    Assert-True ($cpu.SourceEntry -eq "CSV row 2" -and $cpu.RecordId -eq "100") "Assessment retains file, entry and event identity"

    $english = $cpuEvent | Select-Object *
    $english.Message = "Reported by component: Processor Core`nError Source: Machine Check Exception`nError Type: Cache Hierarchy Error"
    $english.EventData = '{"ApicId":0,"MCABank":5,"MciStat":"0xbea0000000000108"}'
    Assert-True ((Get-WheaEventAssessment -Event $english).ApicId -eq "0") "JSON and APIC zero are supported"
    $pcie = $cpuEvent | Select-Object *
    $pcie.Id = 17
    $pcie.Message = "A corrected hardware error has occurred.`nReported by component: PCI Express Root Port`nError Source: Advanced Error Reporting (PCI Express)"
    $pcie.EventData = '{"PrimaryDeviceName":"PCI\\VEN_1234&DEV_5678"}'
    $pcieAssessment = Get-WheaEventAssessment -Event $pcie
    Assert-True ($pcieAssessment.Component -like "PCIe*" -and $pcieAssessment.Severity -eq "Medium") "Corrected PCIe errors remain distinct from fatal CPU errors"
    Assert-True ($pcieAssessment.Device -match 'VEN_1234') "PCIe device identity is retained without guessing its component type"
    $memory = $cpuEvent | Select-Object *
    $memory.Message = "Reported by component: Memory`nError Type: Memory Error"
    $memory.EventData = ""
    Assert-True ((Get-WheaEventAssessment -Event $memory).Component -like "Arbeitsspeicher*") "Memory errors get a memory-specific assessment"
    $unknown = $cpuEvent | Select-Object *
    $unknown.Message = "Hardware error"
    $unknown.EventData = ""
    Assert-True ((Get-WheaEventAssessment -Event $unknown).Component -match "nicht eindeutig") "Unknown source does not invent a component"

    foreach ($case in @(
        @{Code="124"; Classification="WHEA hardware error report"},
        @{Code="0x00000124"; Classification="WHEA hardware error report"},
        @{Code="141"; Classification="GPU kernel timeout / TDR report"},
        @{Code="193"; Classification="Graphics kernel live report"},
        @{Code="a1000005"; Classification="AMD graphics diagnostic report"},
        @{Code="999"; Classification="Other live kernel report"}
    )) {
        $info = Get-WerKernelInfo -Fields @{'Sig[0].Name'='Code'; 'Sig[0].Value'=$case.Code}
        Assert-True ($info.Classification -eq $case.Classification) "Kernel code $($case.Code) is classified by evidence rather than by LiveKernelEvent alone"
    }

    $source = Join-Path $testRoot "locked.log"
    $destination = Join-Path $testRoot "copy.log"
    $lockedFile = [IO.File]::Open($source, [IO.FileMode]::Create, [IO.FileAccess]::ReadWrite, [IO.FileShare]::None)
    try {
        $copy = Copy-DiagnosticEvidenceFile -SourcePath $source -DestinationPath $destination
        Assert-True (-not $copy.Success -and $copy.Note -match 'Copy failed') "Locked log is recorded as a copy failure instead of aborting collection"
    } finally { $lockedFile.Dispose() }
    Assert-True (Copy-DiagnosticEvidenceFile -SourcePath $source -DestinationPath $destination).Success "Collection can continue with a readable file"

    $werFolder = Join-Path $Dirs.WER "Reports\fixture"
    New-Item -ItemType Directory -Path $werFolder -Force | Out-Null
    [IO.File]::WriteAllText((Join-Path $Dirs.Dumps "same.dmp"), "same dump")
    [IO.File]::WriteAllText((Join-Path $werFolder "same.dmp"), "same dump")
    foreach ($index in 1..13) { [IO.File]::WriteAllText((Join-Path $werFolder "WHEA-$index.dmp"), "unique dump $index") }
    $dumps = @(Get-CopiedCrashDumps -SearchRoots @($Dirs.Dumps, (Join-Path $Dirs.WER "Reports")))
    Assert-True ($dumps.Count -eq 14) "WER attachments are included beyond the old twelve-file limit; identical copies are analyzed once"

    $secondCpuEvent = $cpuEvent | Select-Object *
    $secondCpuEvent.TimeCreated = "2026-11-21 22:03:08"
    $secondCpuEvent.RecordId = 101
    $secondCpuEvent.EventData = "ApicId=0; MCABank=5"
    $pcie.RecordId = 102
    @($cpuEvent, $secondCpuEvent, $pcie) | Export-Csv -LiteralPath (Join-Path $Dirs.Events "System_WARN_ERR_CRIT_all.csv") -NoTypeInformation
    "Status: Success" | Out-File -LiteralPath (Join-Path $Dirs.Runtime "EventCollection_Status.txt")
    [PSCustomObject]@{DeviceName="Microsoft Basic Display Driver"; DeviceClass="SYSTEM"; DeviceID='ROOT\BASICDISPLAY\0000'} | Export-Csv -LiteralPath (Join-Path $Dirs.System "Relevant_Drivers_Network_Storage_System.csv") -NoTypeInformation
    $kernelRows = @(foreach ($code in @('124', '141')) {
        $folder = Join-Path $Dirs.WER "Reports\kernel-$code"
        New-Item -ItemType Directory -Path $folder | Out-Null
        $eventUtc = [datetime]::SpecifyKind([datetime]'2026-11-21T21:05:55', [DateTimeKind]::Utc)
        [IO.File]::WriteAllText((Join-Path $folder 'Report.wer'), "EventType=LiveKernelEvent`r`nEventTime=$($eventUtc.ToFileTimeUtc())`r`nSig[0].Name=Code`r`nSig[0].Value=$code", [Text.Encoding]::UTF8)
        [PSCustomObject]@{Classification='GPU kernel timeout / TDR report'; EventType='LiveKernelEvent'; LastWriteTime='2026-11-26 07:55:38'; SourceReport="C:\WER\Kernel_${code}_fixture\Report.wer"; PackagePath="07_WER\Reports\kernel-$code\Report.wer"}
    })
    $kernelRows | Export-Csv -LiteralPath (Join-Path $Dirs.GPU 'GPU_WER_Reports.csv') -NoTypeInformation
    $findings = @(Write-InitialFindingsReport)
    $cpuFindings = @($findings | Where-Object Title -like 'CPU / Cache*')
    Assert-True ($cpuFindings.Count -eq 1 -and $cpuFindings[0].Evidence -match '2 WHEA') "Repeated processor errors are grouped with a component-specific recommendation"
    Assert-True (@($findings | Where-Object Title -like 'PCIe-Verbindung*').Count -eq 1) "Mixed WHEA components produce separate findings and recommendations"
    Assert-True ($cpuFindings[0].Details -match 'CSV row 2' -and $cpuFindings[0].Details -match 'Record ID') "Readable findings retain original event provenance"
    Assert-True (@($findings | Where-Object Title -eq 'Microsoft Basic Display Driver appears to be active').Count -eq 0) "Generic ROOT BasicDisplay entry does not claim a missing active GPU driver"
    $gpuFinding = $findings | Where-Object Title -eq 'Graphics kernel / GPU timeout evidence was captured'
    Assert-True ($gpuFinding.Evidence -match '1 graphics-related WER' -and $gpuFinding.TimeContext -match '2026-11-21') "WHEA is excluded from GPU counts and event time replaces report-file modification time"
    [PSCustomObject]@{Name='Microsoft Basic Display Adapter'; PNPDeviceID='PCI\VEN_1234&DEV_1111'; ConfigManagerErrorCode=0} | Export-Csv -LiteralPath (Join-Path $Dirs.GPU 'DisplayAdapters.csv') -NoTypeInformation
    $activeBasicFindings = @(Write-InitialFindingsReport)
    Assert-True (@($activeBasicFindings | Where-Object Title -eq 'Microsoft Basic Display Driver appears to be active').Count -eq 1) "A current Basic Display Adapter still produces a driver warning"

    if ($ReplayPackageRoot) {
        $replayRoot = Join-Path $testRoot "replay"
        New-Item -ItemType Directory -Path $replayRoot | Out-Null
        Get-ChildItem -LiteralPath $ReplayPackageRoot -Force | ForEach-Object { Copy-Item -LiteralPath $_.FullName -Destination $replayRoot -Recurse }
        Set-TestDirectories -Root $replayRoot
        $replayFindings = @(Write-InitialFindingsReport)
        Write-HtmlReport
        Write-ResultWindowReport | Out-Null
        $wheaRows = @(Import-Csv -LiteralPath (Join-Path $Dirs.Events 'WHEA_Assessment.csv'))
        $expected = @(Import-Csv -LiteralPath (Join-Path $Dirs.Events 'System_WARN_ERR_CRIT_all.csv') | Where-Object ProviderName -match 'WHEA-Logger')
        Assert-True ($wheaRows.Count -eq $expected.Count) "Replay accounts for every captured WHEA event"
        Assert-True (@($wheaRows | Where-Object Component -like 'CPU / Cache*').Count -eq 10) "Real scan identifies all ten processor-cache errors"
        Assert-True ([IO.File]::ReadAllText((Join-Path $Dirs.Root '00_Result.html')) -match 'CPU / Cache-Hierarchie') "Result HTML displays the component-specific finding"
        Assert-True (@($replayFindings | Where-Object Title -eq 'Microsoft Basic Display Driver appears to be active').Count -eq 0) "Real scan's incomplete display inventory is not mistaken for active Basic Display"
        $replayDumps = @(Get-CopiedCrashDumps -SearchRoots @($Dirs.Dumps, (Join-Path $Dirs.WER 'Reports')))
        Assert-True ($replayDumps.Count -gt 0) "Real scan's WER dumps are found without installing or running a debugger"
        $replayFindings | Where-Object { $_.Title -like 'CPU / Cache*' -or $_.Title -like 'Graphics kernel*' } | Select-Object Title,Evidence,Recommendation | Format-List | Out-Host
        Write-Host "Replay: $($wheaRows.Count) WHEA events, $($replayDumps.Count) unique dumps discovered."
    }
    Write-Host "PCDiagLite evidence tests passed. No live collection, debugger installation, or hardware load was performed." -ForegroundColor Green
} finally {
    $resolvedRoot = [IO.Path]::GetFullPath($testRoot)
    $tempParent = [IO.Path]::GetFullPath([IO.Path]::GetTempPath()).TrimEnd('\') + '\'
    if ($resolvedRoot.StartsWith($tempParent, [StringComparison]::OrdinalIgnoreCase) -and (Split-Path -Leaf $resolvedRoot) -like 'PCDiagLite-Tests-*') {
        Remove-Item -LiteralPath $resolvedRoot -Recurse -Force
    }
}
