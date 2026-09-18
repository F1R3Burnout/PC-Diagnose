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
    param([Parameter(Mandatory=$true)][string]$Path, [Parameter(Mandatory=$true)][int]$ExitCode)
    $src = @"
using System;
class FakeMemoryChecker {
    static int Main(string[] args) {
        Console.WriteLine("Fake MemoryChecker fixture, args=" + string.Join(" ", args));
        return $ExitCode;
    }
}
"@
    New-HsFixtureExe -CSharpSource $src -OutputPath $Path
}

function New-HsFakePrime95 {
    <#
        Simulates prime95.exe -t: runs briefly, optionally writes a
        results.txt containing the given failure text into its own working
        directory (matching where the real tool logs), then exits.
    #>
    param([Parameter(Mandatory=$true)][string]$Path, [string]$FailureText = "")
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
        Thread.Sleep(2000);
        return 0;
    }
}
'@
    $src = $src.Replace("__FAILURE_TEXT__", $literal)
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

Export-ModuleMember -Function *
