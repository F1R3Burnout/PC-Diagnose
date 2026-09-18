Set-StrictMode -Version 2.0

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
        [scriptblock]$CancelCheck = { $false }
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

    $progressCallback = [Action[long,long]] {
        param($read, $total)
        $result.BytesRead = $read
        if ($OnProgress) { & $OnProgress $read $total }
    }
    $cancelCallback = [Func[bool]] { & $CancelCheck }

    $sw = [Diagnostics.Stopwatch]::StartNew()
    $errorInfo = [PCDiagnose.HardwareStability.RawDiskReader]::ScanSequentialRead($path, $bytesToRead, $BlockSizeBytes, $progressCallback, $cancelCallback)
    $sw.Stop()
    $result.DurationSeconds = $sw.Elapsed.TotalSeconds

    if ($null -eq $errorInfo) {
        if ($result.BytesRead -ge $bytesToRead) {
            $result.Status = "PASS"
            $result.Reason = "Read $($result.BytesRead) of $bytesToRead requested bytes with 0 read errors."
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
