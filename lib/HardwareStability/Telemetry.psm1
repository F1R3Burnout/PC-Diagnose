Set-StrictMode -Version 2.0

$moduleDir = $PSScriptRoot
Import-Module (Join-Path $moduleDir "ToolManager.psm1") -Force

$script:HsComputer = $null
$script:HsTelemetryAvailable = $false
$script:HsTelemetryStatus = $null

# Windows PowerShell 5.1 (.NET Framework) has no binding redirects for the
# NuGet dependencies of LibreHardwareMonitorLib's net472 build, and it does not
# probe the library's own folder the way .NET (PowerShell 7) does. This small
# AssemblyResolve handler fills that gap: it answers a failed bind by simple
# name - first with an already loaded assembly of that name (covers version
# mismatches such as System.Memory asking for an older System.Buffers), then
# with <name>.dll from the hash-verified dependency folders registered below.
# Everything it could not resolve is recorded so the report can say exactly
# which assembly was missing instead of only "telemetry unavailable".
# The handler is written in C# on purpose: a PowerShell scriptblock handler
# can be invoked on a thread without a runspace and crash the process.
$script:HsResolverSource = @'
using System;
using System.Collections.Generic;
using System.IO;
using System.Reflection;

public static class PcDiagHsAssemblyResolver
{
    private static readonly object Sync = new object();
    private static readonly List<string> Directories = new List<string>();
    private static readonly List<string> Unresolved = new List<string>();
    private static bool registered;

    public static void AddDirectory(string directory)
    {
        if (string.IsNullOrEmpty(directory)) { return; }
        string full = Path.GetFullPath(directory);
        lock (Sync)
        {
            if (!Directories.Contains(full)) { Directories.Add(full); }
            if (!registered)
            {
                AppDomain.CurrentDomain.AssemblyResolve += OnAssemblyResolve;
                registered = true;
            }
        }
    }

    public static string[] GetUnresolved()
    {
        lock (Sync) { return Unresolved.ToArray(); }
    }

    private static Assembly OnAssemblyResolve(object sender, ResolveEventArgs args)
    {
        try
        {
            string simpleName = new AssemblyName(args.Name).Name;
            if (string.IsNullOrEmpty(simpleName) || simpleName.EndsWith(".resources", StringComparison.OrdinalIgnoreCase))
            {
                return null;
            }

            foreach (Assembly loaded in AppDomain.CurrentDomain.GetAssemblies())
            {
                if (string.Equals(loaded.GetName().Name, simpleName, StringComparison.OrdinalIgnoreCase))
                {
                    return loaded;
                }
            }

            string[] dirs;
            lock (Sync) { dirs = Directories.ToArray(); }
            foreach (string dir in dirs)
            {
                string candidate = Path.Combine(dir, simpleName + ".dll");
                if (File.Exists(candidate)) { return Assembly.LoadFrom(candidate); }
            }

            lock (Sync)
            {
                if (!Unresolved.Contains(simpleName)) { Unresolved.Add(simpleName); }
            }
        }
        catch
        {
        }
        return null;
    }
}
'@

function Get-HsPawnIoStatus {
    <#
        LibreHardwareMonitorLib 0.9.5+ reads CPU temperature, CPU power and all
        Super I/O (motherboard/VRM) sensors through the PawnIO kernel driver,
        which is NOT part of the NuGet package and must be installed
        separately. The library itself detects it through this exact uninstall
        registry key (see PawnIo.cs in LibreHardwareMonitor 0.9.6), so the same
        check is used here. This project never installs a driver.
    #>
    $version = ""
    foreach ($view in @([Microsoft.Win32.RegistryView]::Registry64, [Microsoft.Win32.RegistryView]::Registry32)) {
        $base = $null
        $key = $null
        try {
            $base = [Microsoft.Win32.RegistryKey]::OpenBaseKey([Microsoft.Win32.RegistryHive]::LocalMachine, $view)
            $key = $base.OpenSubKey("SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\PawnIO")
            if ($null -ne $key) { $version = [string]$key.GetValue("DisplayVersion") }
        } catch {
        } finally {
            if ($null -ne $key) { $key.Close() }
            if ($null -ne $base) { $base.Close() }
        }
        if (-not [string]::IsNullOrWhiteSpace($version)) { break }
    }
    return [pscustomobject]@{
        Installed = (-not [string]::IsNullOrWhiteSpace($version))
        Version   = $version
    }
}

function New-HsTelemetryStatus {
    $isDesktop = ([string]$PSVersionTable.PSEdition -ne "Core")
    return [pscustomobject]@{
        Initialized             = $false
        HostEdition             = if ($isDesktop) { "Windows PowerShell $($PSVersionTable.PSVersion) (.NET Framework)" } else { "PowerShell $($PSVersionTable.PSVersion) (.NET)" }
        LibraryBuild            = if ($isDesktop) { "net472" } else { "netstandard2.0" }
        LibraryPath             = ""
        PawnIoInstalled         = $false
        PawnIoVersion           = ""
        HardwareCount           = 0
        SensorValueCount        = 0
        CpuTemperatureAvailable = $false
        GpuTemperatureAvailable = $false
        MissingDependencies     = @()
        UnresolvedAssemblies    = @()
        Notes                   = @()
    }
}

function Get-HsTelemetryStatus {
    <#
        Returns what telemetry could actually observe in this run, so the
        report can state plainly whether the thermal guard had CPU/GPU
        temperatures to work with. $null until Initialize-HsTelemetry ran.
    #>
    return $script:HsTelemetryStatus
}

function Add-HsTelemetryNote {
    param([Parameter(Mandatory=$true)][string]$Text)
    if ($null -eq $script:HsTelemetryStatus) { $script:HsTelemetryStatus = New-HsTelemetryStatus }
    $script:HsTelemetryStatus.Notes = @($script:HsTelemetryStatus.Notes) + $Text
}

function Import-HsLibreHardwareMonitor {
    <#
        Loads LibreHardwareMonitorLib for the current host and returns the
        loaded DLL path. Under Windows PowerShell 5.1 this deliberately uses
        the net472 build plus [Reflection.Assembly]::LoadFrom instead of
        Add-Type -Path: Add-Type enumerates every type of the assembly up
        front (Assembly.GetTypes()), which on .NET Framework throws a
        ReflectionTypeLoadException as soon as ANY optional dependency
        (DiskInfoToolkit, RAMSPDToolkit-NDD, HidSharp, System.IO.Ports) is
        absent - that was the exact failure seen on the real elevated runs.
        LoadFrom only resolves dependencies when code that needs them runs.
    #>
    param(
        [Parameter(Mandatory=$true)]$ToolConfig,
        [Parameter(Mandatory=$true)]$Resolved,
        [Parameter(Mandatory=$true)][string]$ToolCacheRoot,
        [switch]$NoDownload
    )

    if ("LibreHardwareMonitor.Hardware.Computer" -as [type]) {
        return ([type]"LibreHardwareMonitor.Hardware.Computer").Assembly.Location
    }

    if ([string]$PSVersionTable.PSEdition -eq "Core") {
        Add-Type -Path $Resolved.ExecutablePath -ErrorAction Stop
        return $Resolved.ExecutablePath
    }

    $entry = $ToolConfig.tools.librehardwaremonitor
    $desktopRelative = [string](Get-HsPropertyOrDefault -InputObject $entry -Name "executableDesktop")
    if ([string]::IsNullOrWhiteSpace($desktopRelative)) {
        throw "No executableDesktop (net472 build) configured for LibreHardwareMonitorLib"
    }
    $libraryPath = Join-Path $Resolved.ToolDirectory $desktopRelative
    if (-not (Test-Path -LiteralPath $libraryPath)) {
        throw "net472 build of LibreHardwareMonitorLib not found in the verified package: $libraryPath"
    }

    if (-not ("PcDiagHsAssemblyResolver" -as [type])) {
        Add-Type -TypeDefinition $script:HsResolverSource -Language CSharp -ErrorAction Stop
    }

    $missing = @()
    foreach ($dependencyId in @(Get-HsPropertyOrDefault -InputObject $entry -Name "desktopDependencies" -Default @())) {
        if ([string]::IsNullOrWhiteSpace([string]$dependencyId)) { continue }
        $dependency = Resolve-HsTool -ToolId ([string]$dependencyId) -ToolConfig $ToolConfig -ToolCacheRoot $ToolCacheRoot -NoDownload:$NoDownload
        if ($dependency.Available) {
            [PcDiagHsAssemblyResolver]::AddDirectory((Split-Path -Path $dependency.ExecutablePath -Parent))
        } else {
            $missing += "$dependencyId ($($dependency.Reason))"
        }
    }
    $script:HsTelemetryStatus.MissingDependencies = @($missing)

    [PcDiagHsAssemblyResolver]::AddDirectory((Split-Path -Path $libraryPath -Parent))
    [void][System.Reflection.Assembly]::LoadFrom($libraryPath)
    return $libraryPath
}

function Initialize-HsTelemetry {
    <#
    .SYNOPSIS
        Loads LibreHardwareMonitorLib and opens CPU/GPU/Motherboard sensors.

    .DESCRIPTION
        Storage and RAM-SPD hardware groups are intentionally left disabled:
        LibreHardwareMonitor's optional NuGet dependencies for those groups
        (DiskInfoToolkit, RAMSPDToolkit-NDD) are not vendored by this project,
        and calling Computer.Open() with those groups enabled throws before
        any hardware is enumerated at all (verified during implementation -
        see docs/HARDWARE_STABILITY_STATE.md). Storage temperature is instead
        read directly from smartctl in StorageTests.psm1, which is the more
        authoritative source for drive temperature anyway. Returns $false
        (not a terminating error) if the library cannot be loaded so callers
        degrade to "no telemetry available" rather than aborting the run.
    #>
    param(
        [Parameter(Mandatory=$true)][string]$ConfigPath,
        [Parameter(Mandatory=$true)][string]$ToolCacheRoot,
        [switch]$NoDownload
    )

    if ($script:HsTelemetryAvailable) { return $true }

    $script:HsTelemetryStatus = New-HsTelemetryStatus
    $pawnIo = Get-HsPawnIoStatus
    $script:HsTelemetryStatus.PawnIoInstalled = $pawnIo.Installed
    $script:HsTelemetryStatus.PawnIoVersion = $pawnIo.Version

    try {
        $cfg = Get-HsToolConfig -ConfigPath $ConfigPath
        $resolved = Resolve-HsTool -ToolId "librehardwaremonitor" -ToolConfig $cfg -ToolCacheRoot $ToolCacheRoot -NoDownload:$NoDownload
        if (-not $resolved.Available) {
            Add-HsTelemetryNote "LibreHardwareMonitorLib unavailable: $($resolved.Reason)"
            Write-Warning "Telemetry unavailable: $($resolved.Reason)"
            return $false
        }

        $script:HsTelemetryStatus.LibraryPath = Import-HsLibreHardwareMonitor -ToolConfig $cfg -Resolved $resolved -ToolCacheRoot $ToolCacheRoot -NoDownload:$NoDownload

        $computer = New-Object LibreHardwareMonitor.Hardware.Computer
        $computer.IsCpuEnabled = $true
        $computer.IsGpuEnabled = $true
        $computer.IsMotherboardEnabled = $true
        $computer.IsMemoryEnabled = $false
        $computer.IsStorageEnabled = $false
        $computer.IsNetworkEnabled = $false
        $computer.IsControllerEnabled = $false

        try {
            $computer.Open()
        } catch {
            # Best-effort: some hardware groups may already be populated even
            # if Open() threw for an unrelated optional dependency.
            Add-HsTelemetryNote "Open() reported an error: $($_.Exception.Message)"
            Write-Warning "LibreHardwareMonitor Open() reported an error (continuing with whatever hardware was already detected): $($_.Exception.Message)"
        }

        if ($computer.Hardware.Count -eq 0) {
            Add-HsTelemetryNote "LibreHardwareMonitor loaded but detected no CPU/GPU/motherboard hardware."
            return $false
        }

        $script:HsComputer = $computer
        $script:HsTelemetryAvailable = $true
        $script:HsTelemetryStatus.Initialized = $true
        $script:HsTelemetryStatus.HardwareCount = $computer.Hardware.Count

        # Probe once so the report states what the thermal guard can really
        # see, instead of implying protection that has no sensor behind it.
        $probe = Get-HsTelemetrySample -Stage "TELEMETRY_PROBE"
        $script:HsTelemetryStatus.SensorValueCount = @($probe).Count
        $script:HsTelemetryStatus.CpuTemperatureAvailable = (@($probe | Where-Object { $null -ne $_ -and $_.HardwareType -eq "Cpu" -and $_.SensorType -eq "Temperature" }).Count -gt 0)
        $script:HsTelemetryStatus.GpuTemperatureAvailable = (@($probe | Where-Object { $null -ne $_ -and $_.HardwareType -like "Gpu*" -and $_.SensorType -eq "Temperature" }).Count -gt 0)
        return $true
    } catch {
        Add-HsTelemetryNote "Initialization failed: $($_.Exception.GetType().Name): $($_.Exception.Message)"
        Write-Warning "Telemetry initialization failed: $($_.Exception.Message)"
        return $false
    } finally {
        if ("PcDiagHsAssemblyResolver" -as [type]) {
            $script:HsTelemetryStatus.UnresolvedAssemblies = @([PcDiagHsAssemblyResolver]::GetUnresolved())
        }
        if (-not $script:HsTelemetryStatus.CpuTemperatureAvailable) {
            if (-not $script:HsTelemetryStatus.PawnIoInstalled) {
                Add-HsTelemetryNote "No CPU temperature: the PawnIO driver that LibreHardwareMonitor needs for CPU and motherboard sensors is not installed (https://pawnio.eu). The thermal guard cannot stop CPU stages on temperature."
            } else {
                Add-HsTelemetryNote "No CPU temperature was reported although PawnIO $($script:HsTelemetryStatus.PawnIoVersion) is installed (CPU possibly not supported by LibreHardwareMonitor 0.9.6). The thermal guard cannot stop CPU stages on temperature."
            }
        }
    }
}

function Get-HsTelemetrySample {
    <#
    .SYNOPSIS
        Returns one telemetry row per currently available sensor value.
        Only sensors that actually report a value are included - nothing is
        synthesized (spec section 24/25).
    #>
    param([Parameter(Mandatory=$true)][string]$Stage)

    $rows = @()
    # The leading comma forces PowerShell to return this AS an array, even
    # when it is empty: "return $rows" on an empty array is otherwise
    # unwrapped to $null by the pipeline, which then fails to bind to a
    # downstream [object[]] Mandatory parameter (observed for real: this
    # collapsed to $null whenever telemetry was unavailable, breaking every
    # stage that checked the thermal guard - see
    # docs/HARDWARE_STABILITY_STATE.md).
    if (-not $script:HsTelemetryAvailable -or $null -eq $script:HsComputer) { return ,$rows }

    $timestamp = Get-Date
    foreach ($hw in $script:HsComputer.Hardware) {
        try { $hw.Update() } catch { continue }
        # Deliberately NOT wrapped in @(...): Get-HsHardwareSensorRows already
        # returns a clean array via its own leading comma. Wrapping an
        # already-comma-protected function call in @() here double-nests it
        # (the call's single pipeline object - the array itself - becomes
        # the lone element of a new outer array), which silently produced a
        # bad entry lacking any of the expected properties and crashed
        # Test-HsThermalState. Verified with both forms during the fix - see
        # docs/HARDWARE_STABILITY_STATE.md.
        $rows += Get-HsHardwareSensorRows -Hardware $hw -Stage $Stage -Timestamp $timestamp
        foreach ($sub in $hw.SubHardware) {
            try { $sub.Update() } catch { continue }
            $rows += Get-HsHardwareSensorRows -Hardware $sub -Stage $Stage -Timestamp $timestamp
        }
    }
    return ,$rows
}

function Get-HsHardwareSensorRows {
    param($Hardware, [string]$Stage, [datetime]$Timestamp)
    $rows = @()
    foreach ($sensor in $Hardware.Sensors) {
        if ($null -eq $sensor.Value) { continue }
        $rows += [pscustomobject]@{
            Timestamp    = $Timestamp.ToString("yyyy-MM-dd HH:mm:ss.fff")
            Stage        = $Stage
            HardwareType = [string]$Hardware.HardwareType
            HardwareName = [string]$Hardware.Name
            SensorType   = [string]$sensor.SensorType
            SensorName   = [string]$sensor.Name
            Value        = [math]::Round([double]$sensor.Value, 2)
        }
    }
    # Same leading-comma fix as Get-HsTelemetrySample: without it, a piece of
    # hardware with zero populated sensors (common - e.g. a Motherboard
    # object with no exposed sensors) makes this return $null instead of an
    # empty array. The caller's "$rows += Get-HsHardwareSensorRows ..." then
    # appends that $null as a literal element of the outer array (PowerShell
    # treats a $null RHS of += as one item to add, not as "nothing"), which
    # later crashed Test-HsThermalState's property access under
    # Set-StrictMode when it iterated that null entry.
    return ,$rows
}

function Get-HsPeakTemperature {
    <#
        Returns the highest Temperature-type sensor value seen across the
        given telemetry rows, or $null if none were captured.
    #>
    param([object[]]$Rows)
    $temps = @($Rows | Where-Object { $_.SensorType -eq "Temperature" } | Select-Object -ExpandProperty Value)
    if ($temps.Count -eq 0) { return $null }
    return ($temps | Measure-Object -Maximum).Maximum
}

function Close-HsTelemetry {
    if ($script:HsComputer) {
        try { $script:HsComputer.Close() } catch {}
    }
    $script:HsComputer = $null
    $script:HsTelemetryAvailable = $false
}

Export-ModuleMember -Function * -Variable *
