Set-StrictMode -Version 2.0

$moduleDir = $PSScriptRoot
Import-Module (Join-Path $moduleDir "Common.psm1") -Force

# Registry of every externally started process so Ctrl+C, timeouts, and thermal
# aborts can reliably clean up Prime95 / MemoryChecker / memtest_vulkan / smartctl
# / the telemetry helper without leaving orphaned processes behind (spec section 32/33).
#
# Stored in a global (not $script:) variable deliberately: several sibling
# modules (CpuTests, MemoryTests, GpuTests, StorageTests, ...) each
# "Import-Module ProcessRunner.psm1 -Force" on their own load. Every -Force
# reimport creates a NEW module instance with its own fresh $script: scope,
# but calls from an OLDER instance's Invoke-HsProcess to "Register-HsProcess"/
# "Unregister-HsProcess" by bare name were observed during implementation to
# resolve against whichever instance is CURRENTLY bound in global scope
# (i.e. the newest one) rather than that older instance's own siblings -
# causing Register and Unregister to operate on two different registry
# objects and Unregister-HsProcess's Where-Object to fail under
# Set-StrictMode. A single global-scope registry sidesteps the ambiguity
# entirely, since it is the same object no matter which module instance's
# functions are executing.
if (-not (Get-Variable -Name HsProcessRegistryStore -Scope Global -ErrorAction SilentlyContinue)) {
    $global:HsProcessRegistryStore = New-Object System.Collections.ArrayList
}

function Register-HsProcess {
    param(
        [Parameter(Mandatory=$true)][int]$ProcessId,
        [Parameter(Mandatory=$true)][string]$Stage,
        [string]$LogFile = ""
    )
    $entry = [pscustomobject]@{
        ProcessId = $ProcessId
        Stage     = $Stage
        LogFile   = $LogFile
        Started   = Get-Date
    }
    [void]$global:HsProcessRegistryStore.Add($entry)
    return $entry
}

function Unregister-HsProcess {
    param([Parameter(Mandatory=$true)][int]$ProcessId)
    $toRemove = @($global:HsProcessRegistryStore | Where-Object { $_.ProcessId -eq $ProcessId })
    foreach ($item in $toRemove) {
        [void]$global:HsProcessRegistryStore.Remove($item)
    }
}

function Get-HsTrackedProcesses {
    return @($global:HsProcessRegistryStore)
}

function Stop-HsAllTrackedProcesses {
    param([string]$Reason = "cleanup", [string]$LogPath = "")
    foreach ($entry in @($global:HsProcessRegistryStore)) {
        Stop-HsProcessTree -ProcessId $entry.ProcessId -Reason $Reason -LogPath $LogPath
    }
    $global:HsProcessRegistryStore.Clear()
}

function ConvertTo-HsWin32ArgumentString {
    <#
    .SYNOPSIS
        Builds a single Win32 command-line string from an argument array,
        using the same quoting/escaping rules CommandLineToArgvW expects
        (an argument is quoted only if it contains a space/tab/quote;
        backslashes are doubled only when they immediately precede a quote
        or the end of a quoted argument).

    .DESCRIPTION
        ProcessStartInfo.ArgumentList (which handles this automatically) is
        a .NET Core-only member; it does not exist on .NET Framework's
        ProcessStartInfo, which is what Windows PowerShell 5.1 uses. Since
        this project's own elevation path launches "powershell.exe" (5.1),
        not "pwsh.exe", Invoke-HsProcess must build .Arguments itself to
        work under both hosts. Verified against a real Windows PowerShell
        5.1 process during implementation - see
        docs/HARDWARE_STABILITY_STATE.md.
    #>
    param([string[]]$Arguments)

    $parts = @()
    foreach ($arg in $Arguments) {
        if ($null -eq $arg) { $arg = "" }
        if ($arg.Length -gt 0 -and $arg -notmatch '[\s"]') {
            $parts += $arg
            continue
        }

        $sb = New-Object Text.StringBuilder
        [void]$sb.Append('"')
        $backslashCount = 0
        foreach ($ch in $arg.ToCharArray()) {
            if ($ch -eq '\') {
                $backslashCount++
                continue
            }
            if ($backslashCount -gt 0) {
                $multiplier = if ($ch -eq '"') { 2 } else { 1 }
                [void]$sb.Append('\' * ($backslashCount * $multiplier))
                $backslashCount = 0
            }
            if ($ch -eq '"') {
                [void]$sb.Append('\"')
            } else {
                [void]$sb.Append($ch)
            }
        }
        if ($backslashCount -gt 0) {
            [void]$sb.Append('\' * ($backslashCount * 2))
        }
        [void]$sb.Append('"')
        $parts += $sb.ToString()
    }

    return ($parts -join " ")
}

function Invoke-HsProcess {
    <#
    .SYNOPSIS
        Unicode-safe external process runner with timeout and optional live
        output line callback. Does NOT go through cmd.exe, so paths and
        computer names containing non-ASCII characters (e.g. "Marcus-Büro")
        are never mangled.

    .PARAMETER OnOutputLine
        Optional scriptblock invoked for every stdout line as it is produced,
        receiving the line as its single argument. Used to detect verification
        errors (e.g. "FATAL ERROR", "Error found") as they happen instead of
        only after the process exits.

    .PARAMETER CancelCheck
        Optional scriptblock evaluated periodically; if it returns $true the
        process is stopped early (used for thermal aborts and Ctrl+C).
    #>
    param(
        [Parameter(Mandatory=$true)][string]$FilePath,
        [string[]]$ArgumentList = @(),
        [string]$WorkingDirectory = "",
        [int]$TimeoutSeconds = 0,
        [string]$StdOutPath = "",
        [string]$StdErrPath = "",
        [string]$Stage = "",
        [scriptblock]$OnOutputLine = $null,
        [scriptblock]$CancelCheck = $null,
        [hashtable]$EnvironmentVariables = $null
    )

    $psi = New-Object Diagnostics.ProcessStartInfo
    $psi.FileName = $FilePath
    $psi.Arguments = ConvertTo-HsWin32ArgumentString -Arguments $ArgumentList
    if ($WorkingDirectory) { $psi.WorkingDirectory = $WorkingDirectory }
    $psi.UseShellExecute = $false
    $psi.RedirectStandardOutput = $true
    $psi.RedirectStandardError = $true
    $psi.StandardOutputEncoding = [Text.Encoding]::UTF8
    $psi.StandardErrorEncoding = [Text.Encoding]::UTF8
    $psi.CreateNoWindow = $true

    if ($EnvironmentVariables) {
        foreach ($key in $EnvironmentVariables.Keys) {
            $psi.EnvironmentVariables[$key] = [string]$EnvironmentVariables[$key]
        }
    }

    $process = New-Object Diagnostics.Process
    $process.StartInfo = $psi
    $process.EnableRaisingEvents = $true

    $stdoutBuilder = New-Object Text.StringBuilder
    $stderrBuilder = New-Object Text.StringBuilder
    $outputLock = New-Object object

    $stdoutHandler = {
        param($sender, $e)
        if ($null -eq $e.Data) { return }
        [void]$Event.MessageData.Builder.AppendLine($e.Data)
        if ($Event.MessageData.OutFile) {
            try { $e.Data | Out-File -FilePath $Event.MessageData.OutFile -Encoding UTF8 -Append } catch {}
        }
        if ($Event.MessageData.Callback) {
            try { & $Event.MessageData.Callback $e.Data } catch {}
        }
    }

    $stdoutState = [pscustomobject]@{ Builder = $stdoutBuilder; OutFile = $StdOutPath; Callback = $OnOutputLine }
    $stderrState = [pscustomobject]@{ Builder = $stderrBuilder; OutFile = $StdErrPath; Callback = $null }

    $outSub = Register-ObjectEvent -InputObject $process -EventName OutputDataReceived -Action $stdoutHandler -MessageData $stdoutState
    $errSub = Register-ObjectEvent -InputObject $process -EventName ErrorDataReceived -Action $stdoutHandler -MessageData $stderrState

    $result = [pscustomobject]@{
        ExitCode = $null
        TimedOut = $false
        Cancelled = $false
        StdOut = ""
        StdErr = ""
        DurationSeconds = 0
        ProcessId = $null
    }

    $sw = [Diagnostics.Stopwatch]::StartNew()
    try {
        [void]$process.Start()
        $result.ProcessId = $process.Id
        if ($Stage) { Register-HsProcess -ProcessId $process.Id -Stage $Stage -LogFile $StdOutPath | Out-Null }
        $process.BeginOutputReadLine()
        $process.BeginErrorReadLine()

        while (-not $process.HasExited) {
            Start-Sleep -Milliseconds 500

            if ($TimeoutSeconds -gt 0 -and $sw.Elapsed.TotalSeconds -ge $TimeoutSeconds) {
                $result.TimedOut = $true
                Stop-HsProcessTree -ProcessId $process.Id -Reason "Timeout ($TimeoutSeconds s)" -LogPath $StdErrPath
                break
            }

            if ($CancelCheck -and (& $CancelCheck)) {
                $result.Cancelled = $true
                Stop-HsProcessTree -ProcessId $process.Id -Reason "Cancelled" -LogPath $StdErrPath
                break
            }
        }

        if (-not $result.TimedOut -and -not $result.Cancelled) {
            $process.WaitForExit()
        } else {
            $process.WaitForExit(5000) | Out-Null
        }

        if (-not $result.TimedOut -and -not $result.Cancelled) {
            $result.ExitCode = $process.ExitCode
        }
    } finally {
        $sw.Stop()
        $result.DurationSeconds = $sw.Elapsed.TotalSeconds
        try { Unregister-Event -SourceIdentifier $outSub.Name -ErrorAction SilentlyContinue } catch {}
        try { Unregister-Event -SourceIdentifier $errSub.Name -ErrorAction SilentlyContinue } catch {}
        Remove-Job -Name $outSub.Name -Force -ErrorAction SilentlyContinue
        Remove-Job -Name $errSub.Name -Force -ErrorAction SilentlyContinue
        if ($result.ProcessId) { Unregister-HsProcess -ProcessId $result.ProcessId }
        $result.StdOut = $stdoutBuilder.ToString()
        $result.StdErr = $stderrBuilder.ToString()
    }

    return $result
}

Export-ModuleMember -Function * -Variable *
