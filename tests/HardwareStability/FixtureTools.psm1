Set-StrictMode -Version 2.0

<#
    Compiles tiny throwaway console executables used to drive the REAL
    production Invoke-Hs* functions (Invoke-HsRamVerification,
    Invoke-HsCpuTortureTest, Invoke-HsVramVerification, ...) through their
    PASS/FAIL/UNSUPPORTED classification logic without needing to force an
    actual hardware failure. Pre-placing a fixture exe at the exact path
    ToolManager.Resolve-HsTool expects makes it skip the download step
    ("already cached") and hand the fixture straight to the real stage
    function - so these tests exercise the same code path a real run would.

    Uses Add-Type -OutputType ConsoleApplication, which (like the rest of
    this project's native interop) compiles via the Roslyn compiler service
    hosted inside PowerShell 7 itself - no separate C/C++ toolchain or
    .NET SDK is required or was available in this project's environment.
#>

function New-HsFixtureExe {
    <#
        PowerShell 7's Add-Type only supports producing a library (DLL);
        it does not support -OutputType ConsoleApplication (verified during
        implementation: "Die Assemblytypen ... werden derzeit nicht
        unterstuetzt."). csc.exe - the .NET Framework compiler that ships
        with every Windows install at
        %WINDIR%\Microsoft.NET\Framework64\v4.0.30319\csc.exe - is used
        instead, purely for compiling these throwaway TEST fixture
        executables. This is not a production dependency: HardwareStability
        itself never shells out to csc.exe.
    #>
    param(
        [Parameter(Mandatory=$true)][string]$CSharpSource,
        [Parameter(Mandatory=$true)][string]$OutputPath
    )

    $csc = Join-Path $env:WINDIR "Microsoft.NET\Framework64\v4.0.30319\csc.exe"
    if (-not (Test-Path -LiteralPath $csc)) {
        $csc = Join-Path $env:WINDIR "Microsoft.NET\Framework\v4.0.30319\csc.exe"
    }
    if (-not (Test-Path -LiteralPath $csc)) {
        throw "csc.exe not found - cannot compile fixture executables on this machine."
    }

    New-Item -ItemType Directory -Force -Path (Split-Path $OutputPath -Parent) | Out-Null
    if (Test-Path -LiteralPath $OutputPath) { Remove-Item -LiteralPath $OutputPath -Force }
    $sourcePath = [IO.Path]::ChangeExtension($OutputPath, ".cs")
    [IO.File]::WriteAllText($sourcePath, $CSharpSource, [Text.UTF8Encoding]::new($false))

    $output = & $csc "/nologo" "/target:exe" "/out:$OutputPath" $sourcePath 2>&1
    if (-not (Test-Path -LiteralPath $OutputPath)) {
        throw "csc.exe failed to produce $OutputPath`: $($output -join "`n")"
    }
}

function New-HsFakeMemoryChecker {
    <#
        Simulates MemoryChecker.exe with its real output format
        ("--- [ Pass N of M ] ---", "Writing memory...", "\r12.3%",
        "Error: N hash check(s) have failed. Memory corrupted :-(").
        Modes: pass, corrupt, allocfail, continuous (runs until stopped),
        continuous-corrupt (reports corruption after about 1 s).
        -ExitCode 0/1 is kept for older calls (0 = pass, 1 = corrupt).
    #>
    param([Parameter(Mandatory=$true)][string]$Path, [int]$ExitCode = 0, [string]$Mode = "")
    if (-not $Mode) { $Mode = if ($ExitCode -eq 0) { "pass" } else { "corrupt" } }
    if ($Mode -notin @("pass","corrupt","allocfail","continuous","continuous-corrupt")) { throw "Unknown fake MemoryChecker mode: $Mode" }
    $src = @'
using System;
using System.Threading;
class FakeMemoryChecker {
    static void Phase(string text) {
        Console.Write(text + "\n");
        Console.Write("0.0%");
        Console.Write("\r50.0%");
        Console.Write("\r100.0% [OK]\n\n");
    }
    static int Main(string[] args) {
        string mode = "__MODE__";
        Console.Write("Fake MemoryChecker fixture, args=" + string.Join(" ", args) + "\n");
        if (mode == "allocfail") {
            Console.Write("\nError: Failed to allocate the requested amount of physical memory!\n\n");
            return 1;
        }
        bool continuous = mode.StartsWith("continuous");
        DateTime start = DateTime.UtcNow;
        int pass = 0;
        while (true) {
            pass++;
            if (continuous) { Console.Write("--- [ Testing pass " + pass + " ] ---\n\n"); }
            else { Console.Write("--- [ Pass " + pass + " of 1 ] ---\n\n"); }
            Phase("Writing memory, please be patient, this will take a while...");
            Thread.Sleep(150);
            Phase("Reading memory, please be patient, this will take a while...");
            bool corruptNow = (mode == "corrupt") || (mode == "continuous-corrupt" && (DateTime.UtcNow - start).TotalSeconds > 1.0);
            if (corruptNow) {
                Console.Write("\rFailed!\n\nError: 3 hash check(s) have failed. Memory corrupted :-(\n\n");
                return 1;
            }
            Console.Write("Pass completed after 0.15 seconds.\n\n");
            if (!continuous) { break; }
            Thread.Sleep(250);
        }
        Console.Write("--- [ Completed ] ---\n\nNo errors have been detected during the test :-)\n\n");
        return 0;
    }
}
'@
    $src = $src.Replace("__MODE__", $Mode)
    New-HsFixtureExe -CSharpSource $src -OutputPath $Path
}

function New-HsFakePrime95 {
    <#
        Simulates prime95.exe -t: runs briefly, optionally writes a
        results.txt containing the given failure text into its own working
        directory (matching where the real tool logs), then exits.
    #>
    param([Parameter(Mandatory=$true)][string]$Path, [string]$FailureText = "", [int]$RunMilliseconds = 2500)
    if ($FailureText -match '["\r\n]') { throw "FailureText must not contain quotes or newlines (fixture generator keeps this simple)." }
    $literal = if ($FailureText) { '"' + $FailureText + '"' } else { "null" }
    $src = @'
using System;
using System.IO;
using System.Threading;
class FakePrime95 {
    static int Main(string[] args) {
        Thread.Sleep(500);
        string failureText = __FAILURE_TEXT__;
        if (!string.IsNullOrEmpty(failureText)) {
            File.WriteAllText("results.txt", failureText + Environment.NewLine);
        }
        Thread.Sleep(Math.Max(0, __RUN_MS__ - 500));
        return 0;
    }
}
'@
    $src = $src.Replace("__FAILURE_TEXT__", $literal).Replace("__RUN_MS__", [string]$RunMilliseconds)
    New-HsFixtureExe -CSharpSource $src -OutputPath $Path
}

function New-HsFakeMemtestVulkan {
    param([Parameter(Mandatory=$true)][string]$Path, [string]$Behavior = "pass")
    $body = switch ($Behavior) {
        "error" { 'Console.WriteLine("Error found. Mode NEXT_RE_READ, total errors 0x1");' }
        "devicelost" { 'Console.WriteLine("Runtime error: ERROR_DEVICE_LOST while getting () in context wait_for_fences");' }
        "initfail" { 'Console.WriteLine("memtest_vulkan: early exit during init: The library failed to load");' }
        default { 'Console.WriteLine("1 iteration. Since last report passed 100ms written 1GB read 2GB 10GB/sec");' }
    }
    $src = @"
using System;
using System.Threading;
class FakeMemtestVulkan {
    static int Main(string[] args) {
        Console.WriteLine("https://github.com/GpuZelenograd/memtest_vulkan v0.5.0 (fixture)");
        $body
        Thread.Sleep(300);
        return 0;
    }
}
"@
    New-HsFixtureExe -CSharpSource $src -OutputPath $Path
}

function New-HsFakeFurMark {
    <#
        Simulates FurMark 2's furmark.exe: writes its arguments and working
        directory to furmark_fixture_args.txt (in its working directory),
        then runs for --max-time seconds (RunMilliseconds -1) or for the given
        time, and exits with ExitCode - an early exit simulates a crash.
    #>
    param([Parameter(Mandatory=$true)][string]$Path, [int]$RunMilliseconds = -1, [int]$ExitCode = 0)
    $src = @'
using System;
using System.IO;
using System.Threading;
class FakeFurMark {
    static int Main(string[] args) {
        File.WriteAllText("furmark_fixture_args.txt", string.Join(" ", args) + Environment.NewLine + Environment.CurrentDirectory);
        int seconds = 0;
        for (int i = 0; i < args.Length - 1; i++) { if (args[i] == "--max-time") { int.TryParse(args[i + 1], out seconds); } }
        int runMs = __RUN_MS__;
        Thread.Sleep(runMs >= 0 ? runMs : seconds * 1000);
        return __EXIT__;
    }
}
'@
    $src = $src.Replace("__RUN_MS__", [string]$RunMilliseconds).Replace("__EXIT__", [string]$ExitCode)
    New-HsFixtureExe -CSharpSource $src -OutputPath $Path
}

Export-ModuleMember -Function *
