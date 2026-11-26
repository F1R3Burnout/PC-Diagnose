Set-StrictMode -Version 2.0

Import-Module (Join-Path $PSScriptRoot "Common.psm1") -Force
Import-Module (Join-Path $PSScriptRoot "ToolManager.psm1") -Force

<#
    Helpers for the classic stress test (scripts/diagnostics/StressTest.ps1):
    Prime95 + FurMark at full load, temperatures in the console. Unlike the
    Hardware-Stabilitaetstest this is a load/heat test: FurMark renders but
    does not verify results, so a GPU "pass" here means "ran the full time
    without crash, driver reset or overheating" - not "computed correctly".
#>

function Get-HsStressModeChoice {
    <# The test variants offered in the menu, in display order. #>
    return @(
        [pscustomobject]@{ Key = "1"; Mode = "Both"; Label = "CPU + RAM + GPU gleichzeitig (Prime95 Blend + FurMark)" }
        [pscustomobject]@{ Key = "2"; Mode = "CPU";  Label = "CPU + RAM (Prime95 Blend, alle Threads, fast der ganze freie RAM)" }
        [pscustomobject]@{ Key = "3"; Mode = "GPU";  Label = "nur GPU (FurMark)" }
    )
}

function Test-HsVcRuntimeInstalled {
    <#
        True if the Visual C++ 2015+ x64 runtime DLLs FurMark needs are in
        System32 (64-bit view; from a 32-bit host Sysnative is used).
    #>
    param([string]$SystemDirectory = "")
    if (-not $SystemDirectory) {
        $SystemDirectory = Join-Path $env:SystemRoot "System32"
        if (-not [Environment]::Is64BitProcess -and [Environment]::Is64BitOperatingSystem) {
            $SystemDirectory = Join-Path $env:SystemRoot "Sysnative"
        }
    }
    foreach ($dll in @("vcruntime140.dll", "vcruntime140_1.dll", "msvcp140.dll")) {
        if (-not (Test-Path -LiteralPath (Join-Path $SystemDirectory $dll))) { return $false }
    }
    return $true
}

function Install-HsVcRedist {
    <#
    .SYNOPSIS
        Installs the Microsoft Visual C++ 2015-2022 x64 runtime if it is
        missing. The installer is hash-verified by ToolManager (winget hash)
        and must carry a valid Microsoft Authenticode signature before it is
        run. Returns a status object; never throws.
    #>
    param(
        [Parameter(Mandatory=$true)][string]$ConfigPath,
        [Parameter(Mandatory=$true)][string]$ToolCacheRoot,
        [switch]$NoDownload
    )
    $result = [pscustomobject]@{ Installed = $false; AlreadyPresent = $false; RebootRequired = $false; ExitCode = $null; Message = "" }
    if (Test-HsVcRuntimeInstalled) {
        $result.Installed = $true
        $result.AlreadyPresent = $true
        $result.Message = "Visual C++ runtime is already installed."
        return $result
    }
    try {
        $tool = Resolve-HsTool -ToolId "vcredist_x64" -ToolConfig (Get-HsToolConfig -ConfigPath $ConfigPath) -ToolCacheRoot $ToolCacheRoot -NoDownload:$NoDownload
        if (-not $tool.Available) {
            $result.Message = "Visual C++ runtime installer not available: $($tool.Reason)"
            return $result
        }
        $signature = Test-HsAuthenticodeSigner -Path $tool.ExecutablePath -SubjectPattern "O=Microsoft Corporation"
        if (-not $signature.Valid) {
            $result.Message = "Visual C++ runtime installer is not validly signed by Microsoft ($($signature.Status)) - not executed."
            return $result
        }
        $process = Start-Process -FilePath $tool.ExecutablePath -ArgumentList @("/install", "/quiet", "/norestart") -Wait -PassThru -WindowStyle Hidden
        $result.ExitCode = $process.ExitCode
        # 0 = installed, 3010 = installed (restart pending), 1638 = a newer
        # version is already installed.
        if ($process.ExitCode -eq 3010) { $result.RebootRequired = $true }
        $result.Installed = (Test-HsVcRuntimeInstalled) -or ($process.ExitCode -in @(0, 1638, 3010))
        $result.Message = if ($result.Installed) { "Visual C++ runtime $($tool.Version) installed (exit code $($process.ExitCode))." } else { "Visual C++ runtime installer exited with code $($process.ExitCode)." }
    } catch {
        $result.Message = "Visual C++ runtime installation failed: $($_.Exception.Message)"
    }
    return $result
}

function Get-HsFurMarkArguments {
    <#
        Command line of the FurMark 2 OpenGL stress test (furmark.exe is the
        command line tool of FurMark 2): no benchmark, no score box, ends by
        itself after the given time; the script stops it as well.
    #>
    param([Parameter(Mandatory=$true)][int]$Seconds, [int]$Width = 1280, [int]$Height = 720)
    return @("--demo", "furmark-gl", "--width", [string]$Width, "--height", [string]$Height, "--max-time", [string][math]::Max(1, $Seconds))
}

function Get-HsWorseStatus {
    <# The more severe of two result states. #>
    param([string]$Current, [string]$New)
    $order = @{ PASS = 0; WARNING = 1; INTERRUPTED = 2; BLOCKED = 2; SKIPPED = 2; UNSUPPORTED = 2; THERMAL_ABORT = 3; FAIL = 4 }
    $currentRank = if ($order.ContainsKey($Current)) { $order[$Current] } else { 2 }
    $newRank = if ($order.ContainsKey($New)) { $order[$New] } else { 2 }
    if ($newRank -gt $currentRank) { return $New }
    return $Current
}

function Get-HsStressVerdict {
    <#
    .SYNOPSIS
        Overall result of the classic stress test from its parts. PASS only
        if every selected part ran its full time without an error, an early
        end, a driver reset, a new WHEA hardware error or a thermal abort.
    #>
    param(
        [string]$Mode = "Both",
        $CpuResult = $null,
        $GpuResult = $null,
        [int]$DriverResets = 0,
        [int]$WheaEvents = 0,
        [string]$ThermalAbortReason = "",
        [bool]$Cancelled = $false
    )
    $findings = New-Object System.Collections.ArrayList
    $status = "PASS"

    if ($Mode -in @("Both","CPU")) {
        if ($null -eq $CpuResult) {
            $status = Get-HsWorseStatus $status "BLOCKED"
            [void]$findings.Add("Prime95 lief nicht.")
        } elseif ($CpuResult.Status -eq "FAIL") {
            $status = Get-HsWorseStatus $status "FAIL"
            [void]$findings.Add("Prime95 hat einen Rechenfehler gemeldet: $($CpuResult.Reason)")
        } elseif ($CpuResult.Status -ne "PASS") {
            $status = Get-HsWorseStatus $status $(if ($CpuResult.Status -eq "INTERRUPTED") { "INTERRUPTED" } else { "BLOCKED" })
            [void]$findings.Add("Prime95: $($CpuResult.Status) - $($CpuResult.Reason)")
        }
    }
    if ($Mode -in @("Both","GPU")) {
        if ($null -eq $GpuResult) {
            $status = Get-HsWorseStatus $status "BLOCKED"
            [void]$findings.Add("FurMark lief nicht.")
        } elseif ($GpuResult.Status -ne "PASS") {
            $status = Get-HsWorseStatus $status ([string]$GpuResult.Status)
            [void]$findings.Add("FurMark: $($GpuResult.Reason)")
        }
    }
    if ($DriverResets -gt 0) {
        $status = Get-HsWorseStatus $status "WARNING"
        [void]$findings.Add("Windows hat $DriverResets Grafiktreiber-Reset(s) (Display 4101) waehrend des Tests protokolliert.")
    }
    if ($WheaEvents -gt 0) {
        $status = Get-HsWorseStatus $status "WARNING"
        [void]$findings.Add("Windows hat $WheaEvents WHEA-Hardwarefehler waehrend des Tests protokolliert (Ereignisanzeige: System, WHEA-Logger).")
    }
    if ($ThermalAbortReason) {
        $status = Get-HsWorseStatus $status "THERMAL_ABORT"
        [void]$findings.Add("Abbruch durch Temperaturschutz: $ThermalAbortReason")
    } elseif ($Cancelled) {
        $status = Get-HsWorseStatus $status "INTERRUPTED"
        [void]$findings.Add("Der Test wurde vorzeitig abgebrochen.")
    }
    return [pscustomobject]@{ Status = $status; Findings = @($findings) }
}

Export-ModuleMember -Function *
