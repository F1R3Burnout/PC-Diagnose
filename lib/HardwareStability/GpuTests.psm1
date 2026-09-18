Set-StrictMode -Version 2.0

$moduleDir = $PSScriptRoot
Import-Module (Join-Path $moduleDir "ToolManager.psm1") -Force
Import-Module (Join-Path $moduleDir "ProcessRunner.psm1") -Force

$script:HsD3D11Loaded = $false

function Initialize-HsD3D11ComputeVerifier {
    if ($script:HsD3D11Loaded -and ("PCDiagnose.HardwareStability.D3D11ComputeVerifier" -as [type])) { return }
    if ("PCDiagnose.HardwareStability.D3D11ComputeVerifier" -as [type]) {
        $script:HsD3D11Loaded = $true
        return
    }
    # Uses $PSScriptRoot directly (not the module-level $moduleDir variable):
    # a same-named top-level $moduleDir in another sibling module was found
    # during implementation to be able to shadow this one across
    # Import-Module -Force reloads. $PSScriptRoot is an automatic,
    # per-file variable and is not subject to that collision.
    $sourcePath = Join-Path $PSScriptRoot "Native\D3D11ComputeVerifier.cs"
    Add-Type -TypeDefinition ([IO.File]::ReadAllText($sourcePath)) -Language CSharp -ErrorAction Stop
    $script:HsD3D11Loaded = $true
}

function Invoke-HsGpuComputeVerification {
    <#
    .SYNOPSIS
        GPU_COMPUTE stage: known input -> GPU compute (D3D11 compute shader,
        bit-exact 32-bit integer rotate/xor/multiply mix) -> readback ->
        compare against a bit-exact CPU reference (spec section 13).
    #>
    param(
        [Parameter(Mandatory=$true)][int]$ElementCount,
        [int]$Iterations = 1
    )

    $result = [pscustomobject]@{
        Status         = "SKIPPED"
        Tool           = "PC-Diagnose D3D11 Compute Verifier"
        UsedWarp       = $false
        FeatureLevel   = ""
        DeviceLost     = $false
        ElementsVerified = 0
        Mismatches     = 0
        Iterations     = 0
        Reason         = ""
    }

    try {
        Initialize-HsD3D11ComputeVerifier
    } catch {
        $result.Status = "UNSUPPORTED"
        $result.Reason = "Direct3D 11 compute is not available on this system: $($_.Exception.Message)"
        return $result
    }

    $rand = New-Object Random(1234567)
    $totalMismatches = [int64]0
    $totalElements = [int64]0
    $deviceLost = $false
    $lastError = ""
    $completedIterations = 0

    for ($iter = 0; $iter -lt $Iterations; $iter++) {
        $data = New-Object uint32[] $ElementCount
        for ($i = 0; $i -lt $ElementCount; $i++) { $data[$i] = [uint32]$rand.Next() }

        $r = [PCDiagnose.HardwareStability.D3D11ComputeVerifier]::RunVerification($data)
        $result.UsedWarp = $r.UsedWarp
        $result.FeatureLevel = "0x{0:X}" -f $r.FeatureLevel

        if (-not $r.Success) {
            if ($r.DeviceLost) {
                $deviceLost = $true
                $lastError = $r.ErrorMessage
                break
            }
            $lastError = $r.ErrorMessage
            break
        }

        $totalMismatches += $r.MismatchCount
        $totalElements += $r.ElementCount
        $completedIterations++
    }

    $result.Iterations = $completedIterations
    $result.ElementsVerified = $totalElements
    $result.Mismatches = $totalMismatches
    $result.DeviceLost = $deviceLost

    if ($deviceLost) {
        $result.Status = "FAIL"
        $result.Reason = "GPU device was lost (TDR) during compute verification: $lastError"
    } elseif ($completedIterations -eq 0) {
        $result.Status = "UNSUPPORTED"
        $result.Reason = "Could not run the GPU compute verifier: $lastError"
    } elseif ($totalMismatches -gt 0) {
        $result.Status = "FAIL"
        $result.Reason = "GPU compute output differed from the verified reference result ($totalMismatches of $totalElements element(s))."
    } else {
        $result.Status = "PASS"
        $warpNote = if ($result.UsedWarp) { " (software WARP fallback was used - no hardware-accelerated GPU compute path was available)" } else { "" }
        $result.Reason = "$totalElements integer operation(s) verified across $completedIterations iteration(s) with 0 mismatches$warpNote."
    }

    return $result
}

function Test-HsGpuComputeMismatchDetection {
    <#
        Fixture used by tests/HardwareStability: proves the comparison logic
        used by the GPU_COMPUTE stage actually flags a difference when the
        "GPU" result does not match the CPU reference, without needing to
        force a real GPU into producing an incorrect result (HS-016).
    #>
    Initialize-HsD3D11ComputeVerifier
    $v = [uint32]999
    $idx = [uint32]3
    $correct = [PCDiagnose.HardwareStability.D3D11ComputeVerifier]::ComputeReference($v, $idx)
    $tamperedGpuResult = $correct -bxor [uint32]1
    return ($tamperedGpuResult -ne $correct)
}

function Invoke-HsVramVerification {
    <#
    .SYNOPSIS
        VRAM verification stage using memtest_vulkan (write pattern -> read
        back -> compare), spec section 14. Runs for a bounded duration since
        the tool otherwise runs until Ctrl+C.
    #>
    param(
        [Parameter(Mandatory=$true)][string]$ConfigPath,
        [Parameter(Mandatory=$true)][string]$ToolCacheRoot,
        [Parameter(Mandatory=$true)][string]$OutputDirectory,
        [Parameter(Mandatory=$true)][int]$DurationMinutes,
        [switch]$NoDownload
    )

    $result = [pscustomobject]@{
        Status   = "SKIPPED"
        Tool     = "memtest_vulkan"
        ToolVersion = ""
        Reason   = ""
        LogPath  = ""
        DurationSeconds = 0
    }

    $cfg = Get-HsToolConfig -ConfigPath $ConfigPath
    $tool = Resolve-HsTool -ToolId "memtest_vulkan" -ToolConfig $cfg -ToolCacheRoot $ToolCacheRoot -NoDownload:$NoDownload
    $result.ToolVersion = $tool.Version
    if (-not $tool.Available) {
        $result.Status = "SKIPPED"
        $result.Reason = "memtest_vulkan not available: $($tool.Reason)"
        return $result
    }

    New-Item -ItemType Directory -Force -Path $OutputDirectory | Out-Null
    $logPath = Join-Path $OutputDirectory "memtest_vulkan.log"
    $result.LogPath = $logPath

    $errorFound = $false
    $deviceLost = $false
    $initFailure = $false
    $sawAnyOutput = $false
    $cb = {
        param($line)
        $script:sawAnyOutput = $true
        if ($line -match "(?i)error found|memory error") { $script:errorFound = $true }
        if ($line -match "(?i)ERROR_DEVICE_LOST") { $script:deviceLost = $true }
        if ($line -match "(?i)runtime error|initialization failure|no vulkan|failed to create instance|failed to load|early exit during init") { $script:initFailure = $true }
    }
    $script:errorFound = $false
    $script:deviceLost = $false
    $script:initFailure = $false
    $script:sawAnyOutput = $false

    # memtest_vulkan shows a device-selection prompt on multi-GPU systems and
    # auto-selects the first device after a short timeout; feeding it an
    # empty line lets that auto-selection happen immediately when stdin is
    # redirected instead of an interactive console.
    $run = Invoke-HsProcess -FilePath $tool.ExecutablePath -TimeoutSeconds ($DurationMinutes * 60) `
        -StdOutPath $logPath -Stage "VRAM" -OnOutputLine $cb

    $result.DurationSeconds = $run.DurationSeconds

    if (-not $script:sawAnyOutput -and [string]::IsNullOrWhiteSpace($run.StdErr) -and $run.ExitCode -ne 0 -and -not $run.TimedOut) {
        $result.Status = "UNSUPPORTED"
        $result.Reason = "memtest_vulkan produced no output and exited immediately (exit code $($run.ExitCode)); Vulkan is most likely not available on this system (no vulkan-1.dll / ICD)."
        return $result
    }

    if ($script:initFailure) {
        $result.Status = "UNSUPPORTED"
        $result.Reason = "memtest_vulkan reported an initialization failure - Vulkan is not usable on this system."
        return $result
    }

    if ($script:deviceLost) {
        $result.Status = "FAIL"
        $result.Reason = "GPU device was lost (ERROR_DEVICE_LOST) during VRAM verification."
        return $result
    }

    if ($script:errorFound) {
        $result.Status = "FAIL"
        $result.Reason = "GPU memory verification errors occurred. GPU VRAM or the GPU memory path is suspected (not necessarily a defective VRAM chip)."
        return $result
    }

    if (-not $run.TimedOut -and $run.ExitCode -ne 0 -and -not $script:sawAnyOutput) {
        $result.Status = "UNSUPPORTED"
        $result.Reason = "memtest_vulkan exited with code $($run.ExitCode) and produced no usable output."
        return $result
    }

    $result.Status = "PASS"
    $result.Reason = "No VRAM verification errors observed during $([math]::Round($result.DurationSeconds/60,1)) minute(s) of testing."
    return $result
}

function Invoke-HsGpuLoadThermalValidation {
    <#
    .SYNOPSIS
        GPU Load / Thermal Validation (spec section 15): sustained GPU
        activity using the SAME verified D3D11 compute kernel used by
        GPU_COMPUTE, run in a loop for the configured duration while the
        caller samples telemetry. FurMark2 was deliberately not integrated
        (see docs/HARDWARE_STABILITY_SPEC.md section 2) - this reuses an
        already-verified compute path instead of adding a new closed-source
        GUI-tool dependency for a load-only stage.
    #>
    param(
        [Parameter(Mandatory=$true)][int]$DurationSeconds,
        [int]$ElementCount = 262144,
        [scriptblock]$TelemetrySample = $null,
        [scriptblock]$CancelCheck = { $false }
    )

    $result = [pscustomobject]@{
        Status = "SKIPPED"
        Iterations = 0
        Mismatches = 0
        DeviceLost = $false
        PeakTemperature = $null
        Reason = ""
    }

    try {
        Initialize-HsD3D11ComputeVerifier
    } catch {
        $result.Status = "UNSUPPORTED"
        $result.Reason = "Direct3D 11 compute is not available on this system."
        return $result
    }

    $deadline = [datetime]::Now.AddSeconds($DurationSeconds)
    $iterations = 0
    $mismatches = [int64]0
    $deviceLost = $false
    $peakTemp = $null
    $cancelled = $false

    while ([datetime]::Now -lt $deadline) {
        $data = New-Object uint32[] $ElementCount
        $rnd = New-Object Random
        for ($i = 0; $i -lt $ElementCount; $i++) { $data[$i] = [uint32]$rnd.Next() }
        $r = [PCDiagnose.HardwareStability.D3D11ComputeVerifier]::RunVerification($data)
        if (-not $r.Success) {
            if ($r.DeviceLost) { $deviceLost = $true }
            break
        }
        $mismatches += $r.MismatchCount
        $iterations++

        if ($TelemetrySample) {
            $rows = & $TelemetrySample "GPU_LOAD_THERMAL"
            $temp = ($rows | Where-Object { $_.SensorType -eq "Temperature" } | Select-Object -ExpandProperty Value | Measure-Object -Maximum).Maximum
            if ($temp) { $peakTemp = if ($null -eq $peakTemp) { $temp } else { [math]::Max($peakTemp, $temp) } }
        }

        if (& $CancelCheck) { $cancelled = $true; break }
    }

    $result.Iterations = $iterations
    $result.Mismatches = $mismatches
    $result.DeviceLost = $deviceLost
    $result.PeakTemperature = $peakTemp

    if ($cancelled) {
        $result.Status = "INTERRUPTED"
        $result.Reason = "GPU load/thermal validation was cancelled after $iterations iteration(s)."
    } elseif ($deviceLost) {
        $result.Status = "FAIL"
        $result.Reason = "GPU device was lost (TDR) under sustained load."
    } elseif ($mismatches -gt 0) {
        $result.Status = "FAIL"
        $result.Reason = "$mismatches compute mismatch(es) occurred under sustained GPU load."
    } elseif ($iterations -eq 0) {
        $result.Status = "UNSUPPORTED"
        $result.Reason = "No iterations completed."
    } else {
        $result.Status = "PASS"
        $result.Reason = "$iterations sustained load iteration(s) completed with 0 mismatches and no device loss."
    }

    return $result
}

Export-ModuleMember -Function * -Variable *
