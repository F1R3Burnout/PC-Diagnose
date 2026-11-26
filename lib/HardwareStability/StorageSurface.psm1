Set-StrictMode -Version 2.0

Import-Module (Join-Path $PSScriptRoot "Common.psm1") -Force

$script:HsRawDiskReaderLoaded = $false

function Initialize-HsRawDiskReader {
    if ($script:HsRawDiskReaderLoaded -and ("PCDiagnose.HardwareStability.RawDiskReader" -as [type])) { return }
    if ("PCDiagnose.HardwareStability.RawDiskReader" -as [type]) {
        $script:HsRawDiskReaderLoaded = $true
        return
    }
    $sourcePath = Join-Path $PSScriptRoot "Native\RawDiskReader.cs"
    if (-not (Test-Path -LiteralPath $sourcePath)) {
        throw "RawDiskReader source is missing: $sourcePath"
    }
    Add-Type -TypeDefinition ([IO.File]::ReadAllText($sourcePath)) -Language CSharp -ErrorAction Stop
    $script:HsRawDiskReaderLoaded = $true
}

function Invoke-HsStorageSurfaceScan {
    <#
    .SYNOPSIS
        Read-only sequential surface scan of a PhysicalDrive (spec section 20).
        Opens the drive with GENERIC_READ only; never writes to it.

    .PARAMETER MaxBytes
        0 = scan the full reported drive size. A positive value bounds the
        scan (used for automated tests and for -SurfaceScanMaxBytes so a
        small, real, non-production-impacting scan can be exercised).
    #>
    param(
        [Parameter(Mandatory=$true)][int]$DriveIndex,
        [long]$MaxBytes = 0,
        [int]$BlockSizeBytes = 4MB,
        [scriptblock]$OnProgress = $null,
        [scriptblock]$CancelCheck = { $false },
        [int]$MaxSeconds = 0,
        [string]$ProgressLabel = "Surface-Scan (nur lesen)"
    )

    Initialize-HsRawDiskReader

    $result = [pscustomobject]@{
        DriveIndex   = $DriveIndex
        Status       = "SKIPPED"
        TotalBytes   = 0
        BytesRead    = 0
        Errors       = @()
        Reason       = ""
        DurationSeconds = 0
    }

    $path = "\\.\PhysicalDrive$DriveIndex"
    $open = [PCDiagnose.HardwareStability.RawDiskReader]::TryOpenReadOnly($path)
    if (-not $open.Success) {
        $result.Reason = "Could not open $path read-only: $($open.ErrorMessage)"
        return $result
    }

    $bytesToRead = if ($MaxBytes -gt 0) { [math]::Min($MaxBytes, $open.TotalBytes) } else { $open.TotalBytes }
    $result.TotalBytes = $bytesToRead

    $sw = [Diagnostics.Stopwatch]::StartNew()
    # The native reader asks for cancellation before EVERY block (4 MB). The
    # caller's check takes a full sensor sample, so it is only evaluated every
    # 2 s here - per block it would have cost far more time than the reads
    # themselves on a fast NVMe.
    $scan = @{ LastCheck = -10.0; Cancelled = $false; TimeLimitReached = $false }
    $progressCallback = [Action[long,long]] {
        param($read, $total)
        $result.BytesRead = $read
        if ($OnProgress) { & $OnProgress $read $total }
        $elapsed = $sw.Elapsed.TotalSeconds
        $speed = if ($elapsed -gt 0) { $read / $elapsed } else { 0 }
        if ($MaxSeconds -gt 0) {
            $percent = [math]::Min(100.0, 100.0 * $elapsed / $MaxSeconds)
            $remaining = [math]::Max(0, $MaxSeconds - $elapsed)
        } else {
            $percent = if ($total -gt 0) { 100.0 * $read / $total } else { -1 }
            $remaining = if ($speed -gt 0) { ($total - $read) / $speed } else { -1 }
        }
        Write-HsStageProgress -Activity $ProgressLabel -Status ("{0:N1} / {1:N1} GB gelesen, {2:N0} MB/s, 0 Lesefehler" -f ($read / 1GB), ($total / 1GB), ($speed / 1MB)) `
            -Percent $percent -SecondsRemaining $remaining
    }
    $cancelCallback = [Func[bool]] {
        $elapsed = $sw.Elapsed.TotalSeconds
        if ($MaxSeconds -gt 0 -and $elapsed -ge $MaxSeconds) {
            $scan.TimeLimitReached = $true
            return $true
        }
        if (($elapsed - $scan.LastCheck) -lt 2.0) { return $false }
        $scan.LastCheck = $elapsed
        if (& $CancelCheck) {
            $scan.Cancelled = $true
            return $true
        }
        return $false
    }

    try {
        $errorInfo = [PCDiagnose.HardwareStability.RawDiskReader]::ScanSequentialRead($path, $bytesToRead, $BlockSizeBytes, $progressCallback, $cancelCallback)
    } finally {
        $sw.Stop()
        Write-HsStageProgress -Activity $ProgressLabel -Completed
    }
    $result.DurationSeconds = $sw.Elapsed.TotalSeconds

    if ($null -eq $errorInfo) {
        if ($result.BytesRead -ge $bytesToRead) {
            $result.Status = "PASS"
            $result.Reason = "Read $($result.BytesRead) of $bytesToRead requested bytes with 0 read errors."
        } elseif ($scan.TimeLimitReached) {
            # A time-limited scan (targeted retest) that ran its full time
            # without a read error is a PASS for the range actually read.
            $result.Status = "PASS"
            $result.Reason = "Time-limited scan: read $([math]::Round($result.BytesRead/1GB,2)) of $([math]::Round($bytesToRead/1GB,2)) GB in $([math]::Round($MaxSeconds/60,1)) minute(s) with 0 read errors. Only this range was checked."
        } else {
            $result.Status = "INTERRUPTED"
            $result.Reason = "Scan was cancelled after $($result.BytesRead) of $bytesToRead bytes."
        }
    } else {
        $result.Status = "FAIL"
        $result.Errors = @([pscustomobject]@{
            Offset = $errorInfo.Offset
            Win32ErrorCode = $errorInfo.Win32ErrorCode
            Message = $errorInfo.Message
        })
        $result.Reason = "Read error at offset $($errorInfo.Offset): $($errorInfo.Message) (Win32 $($errorInfo.Win32ErrorCode))"
    }

    return $result
}

Export-ModuleMember -Function * -Variable *
