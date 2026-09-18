Set-StrictMode -Version 2.0

$moduleDir = $PSScriptRoot
Import-Module (Join-Path $moduleDir "Common.psm1") -Force

function Get-HsOverallStatus {
    <#
        Rolls up all stage statuses into one headline verdict for the top of
        the report (spec section 42): PASS, ATTENTION, FAILED, INTERRUPTED.
    #>
    param([Parameter(Mandatory=$true)][object[]]$Stages)

    if (@($Stages | Where-Object { $_.Status -eq "INTERRUPTED" }).Count -gt 0) { return "INTERRUPTED" }
    if (@($Stages | Where-Object { $_.Status -in @("FAIL","SYSTEM_RESET","THERMAL_ABORT") }).Count -gt 0) { return "FAILED" }
    if (@($Stages | Where-Object { $_.Status -in @("WARNING","BLOCKED") }).Count -gt 0) { return "ATTENTION" }
    return "PASS"
}

function Get-HsStatusColor {
    param([string]$Status)
    switch ($Status) {
        "PASS" { return "#2e7d32" }
        "FAIL" { return "#c62828" }
        "SYSTEM_RESET" { return "#b71c1c" }
        "THERMAL_ABORT" { return "#b71c1c" }
        "WARNING" { return "#ef6c00" }
        "BLOCKED" { return "#ef6c00" }
        "INTERRUPTED" { return "#6a1b9a" }
        "SKIPPED" { return "#757575" }
        "UNSUPPORTED" { return "#757575" }
        default { return "#455a64" }
    }
}

function New-HsStageHtmlRow {
    param([Parameter(Mandatory=$true)]$Stage)
    $color = Get-HsStatusColor -Status $Stage.Status
    $notes = ($Stage.Notes -join "<br/>")
    $events = if ($Stage.EventsFound) { "$(@($Stage.EventsFound).Count) event(s)" } else { "0" }
    $peak = if ($null -ne $Stage.PeakTemperature) { "$($Stage.PeakTemperature) C" } else { "n/a" }
    return @"
<tr>
<td>$(ConvertTo-HsHtml $Stage.Component)</td>
<td><span style="color:$color;font-weight:bold;">$(ConvertTo-HsHtml $Stage.Status)</span></td>
<td>$(ConvertTo-HsHtml $Stage.Tool) $(ConvertTo-HsHtml $Stage.ToolVersion)</td>
<td>$(ConvertTo-HsHtml $Stage.Duration)</td>
<td>$(ConvertTo-HsHtml $Stage.Coverage)</td>
<td>$(ConvertTo-HsHtml $Stage.ErrorCount)</td>
<td>$peak</td>
<td>$events</td>
<td>$(ConvertTo-HsHtml $Stage.Assessment)$(if($notes){"<br/><span style='color:#777;font-size:0.9em;'>$notes</span>"})</td>
</tr>
"@
}

function New-HsHtmlReport {
    <#
    .SYNOPSIS
        Builds the Hardware-Stabilitätstest HTML report (spec section 42).
    #>
    param(
        [Parameter(Mandatory=$true)][object[]]$Stages,
        [Parameter(Mandatory=$true)]$Inventory,
        [Parameter(Mandatory=$true)][string]$Profile,
        [string]$RunId = "",
        [pscustomobject]$SystemResetInfo = $null
    )

    $overall = Get-HsOverallStatus -Stages $Stages
    $overallColor = Get-HsStatusColor -Status $overall

    $resetBanner = ""
    if ($SystemResetInfo -and $SystemResetInfo.Classification -eq "SYSTEM_RESET") {
        $resetBanner = @"
<div style="background:#b71c1c;color:#fff;padding:14px;border-radius:6px;margin-bottom:16px;">
<strong>SYSTEM_RESET detected:</strong> Windows did not complete a normal shutdown while a stage was marked as running.
$(ConvertTo-HsHtml $SystemResetInfo.Notes)
<br/>This makes power delivery, PSU, VRM, mainboard, and combined CPU/GPU stability more suspect. A single component is not proven defective by this alone.
</div>
"@
    }

    $rows = ($Stages | ForEach-Object { New-HsStageHtmlRow -Stage $_ }) -join "`n"

    $cpuInv = ($Inventory.Cpus | ForEach-Object { "$($_.Name) ($($_.LogicalProcessors) logical / $($_.Cores) cores)" }) -join ", "
    $gpuInv = ($Inventory.Gpus | ForEach-Object { $_.Name }) -join ", "
    $diskInv = ($Inventory.PhysicalDisks | ForEach-Object { "$($_.DeviceId): $($_.Model) ($([math]::Round($_.CapacityBytes/1GB,1)) GB, $($_.BusType), $($_.HealthStatus))" }) -join "<br/>"

    $html = @"
<!DOCTYPE html>
<html lang="en">
<head>
<meta charset="utf-8"/>
<title>Hardware-Stabilitaetstest - $(ConvertTo-HsHtml $Inventory.ComputerName)</title>
<style>
body { font-family: Segoe UI, Arial, sans-serif; background:#f4f5f7; color:#1a1a1a; margin:0; padding:24px; }
h1 { margin-top:0; }
table { border-collapse: collapse; width:100%; background:#fff; margin-bottom:24px; }
th, td { border:1px solid #ddd; padding:8px 10px; text-align:left; vertical-align:top; font-size:0.92em; }
th { background:#eceff1; }
.card { background:#fff; padding:16px; border-radius:8px; margin-bottom:20px; box-shadow:0 1px 3px rgba(0,0,0,0.1); }
.badge { display:inline-block; padding:6px 16px; border-radius:20px; color:#fff; font-weight:bold; font-size:1.1em; }
</style>
</head>
<body>
<h1>Hardware-Stabilitaetstest</h1>
<div class="card">
<span class="badge" style="background:$overallColor;">$overall</span>
<p><strong>Computer:</strong> $(ConvertTo-HsHtml $Inventory.ComputerName) &nbsp; <strong>Profile:</strong> $(ConvertTo-HsHtml $Profile) &nbsp; <strong>Run:</strong> $(ConvertTo-HsHtml $RunId)</p>
<p><strong>Windows:</strong> $(ConvertTo-HsHtml $Inventory.WindowsVersion) (Build $(ConvertTo-HsHtml $Inventory.WindowsBuild)) &nbsp; <strong>Mainboard:</strong> $(ConvertTo-HsHtml $Inventory.Mainboard) &nbsp; <strong>BIOS:</strong> $(ConvertTo-HsHtml $Inventory.Bios)</p>
<p><strong>CPU:</strong> $(ConvertTo-HsHtml $cpuInv)</p>
<p><strong>RAM:</strong> $([math]::Round($Inventory.PhysicalRamBytes/1GB,1)) GB physical</p>
<p><strong>GPU:</strong> $(ConvertTo-HsHtml $gpuInv)</p>
<p><strong>Storage:</strong><br/>$diskInv</p>
</div>
$resetBanner
<div class="card">
<h2>Stage Results</h2>
<table>
<tr><th>Component</th><th>Status</th><th>Tool</th><th>Duration</th><th>Coverage</th><th>Errors</th><th>Peak Temp</th><th>Events</th><th>Assessment</th></tr>
$rows
</table>
</div>
<div class="card">
<p style="color:#777;font-size:0.9em;">
PASS means: within the range actually tested, no errors were detected. It is not a guarantee that the hardware is completely free of defects.
A Windows user-space RAM test cannot cover 100% of installed memory; for full offline RAM coverage, MemTest86 is recommended.
Storage Surface Read is a strictly read-only scan; Storage Write/Read Verification only ever uses a normal temporary file, never raw disk writes.
WHEA events indicate that a hardware error was reported by the platform; they do not by themselves prove which specific component is defective.
</p>
</div>
</body>
</html>
"@

    return $html
}

function New-HsSummaryText {
    param([Parameter(Mandatory=$true)][object[]]$Stages)
    $overall = Get-HsOverallStatus -Stages $Stages
    $lines = @("Hardware-Stabilitaetstest Summary", "==================================", "Overall: $overall", "")
    foreach ($stage in $Stages) {
        $lines += ("{0,-22} {1,-14} {2}" -f $stage.Component, $stage.Status, $stage.Assessment)
    }
    return ($lines -join "`r`n")
}

function Export-HsStagesCsv {
    param([Parameter(Mandatory=$true)][object[]]$Stages, [Parameter(Mandatory=$true)][string]$Path)
    $rows = $Stages | Select-Object StageName, Component, Started, Ended, Duration, Tool, ToolVersion, ExitCode, Status, ErrorCount, WarningCount, Coverage, PeakTemperature, SystemReset, Assessment
    $rows | Export-Csv -Path $Path -NoTypeInformation -Encoding UTF8
}

function New-HsResultZip {
    param([Parameter(Mandatory=$true)][string]$SourceDirectory, [Parameter(Mandatory=$true)][string]$ZipPath)
    if (Test-Path -LiteralPath $ZipPath) { Remove-Item -LiteralPath $ZipPath -Force }
    Compress-Archive -Path (Join-Path $SourceDirectory "*") -DestinationPath $ZipPath -Force
}

Export-ModuleMember -Function * -Variable *
