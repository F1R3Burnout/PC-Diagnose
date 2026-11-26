Set-StrictMode -Version 2.0

Import-Module (Join-Path $PSScriptRoot "Common.psm1") -Force

# CRC32 in compiled code: the previous byte-by-byte PowerShell loop needed
# several seconds per 4 MB block, which made the 1 GB (Standard) and 4 GB
# (Extended) write/verify sizes take far longer than the I/O itself. Same
# polynomial and result as before (verified by fixture HS-034).
if (-not ("PCDiagnose.HardwareStability.Crc32" -as [type])) {
    Add-Type -Language CSharp -TypeDefinition @'
namespace PCDiagnose.HardwareStability
{
    public static class Crc32
    {
        private static readonly uint[] Table = CreateTable();

        private static uint[] CreateTable()
        {
            uint[] table = new uint[256];
            for (uint i = 0; i < 256; i++)
            {
                uint c = i;
                for (int k = 0; k < 8; k++)
                {
                    c = ((c & 1) != 0) ? (0xEDB88320u ^ (c >> 1)) : (c >> 1);
                }
                table[i] = c;
            }
            return table;
        }

        public static uint Compute(byte[] bytes, int count)
        {
            uint crc = 0xFFFFFFFFu;
            for (int i = 0; i < count; i++)
            {
                crc = Table[(crc ^ bytes[i]) & 0xFF] ^ (crc >> 8);
            }
            return crc ^ 0xFFFFFFFFu;
        }
    }
}
'@
}

function Invoke-HsStorageWriteReadVerify {
    <#
    .SYNOPSIS
        Data-integrity test using ONLY a normal temporary file on an existing
        file system (spec section 21). Never touches a raw disk. Writes
        pseudo-random data, flushes, reads it back, and compares a CRC32
        checksum per block; the test file is always removed afterward, even
        on failure or cancellation.
    #>
    param(
        [Parameter(Mandatory=$true)][string]$Directory,
        [int]$SizeMB = 256,
        [int]$BlockSizeBytes = 4MB,
        [int]$Seed = 12345,
        [string]$ProgressLabel = "Schreib-/Lesepruefung (Testdatei)"
    )

    $result = [pscustomobject]@{
        Status       = "SKIPPED"
        BytesWritten = 0
        BytesVerified = 0
        Mismatches   = 0
        Reason       = ""
        TestFilePath = ""
        DurationSeconds = 0
    }

    New-Item -ItemType Directory -Force -Path $Directory | Out-Null
    $testFile = Join-Path $Directory ("hwstability_writeverify_{0}.tmp" -f ([guid]::NewGuid().ToString("N")))
    $result.TestFilePath = $testFile

    $sw = [Diagnostics.Stopwatch]::StartNew()
    try {
        $totalBytes = [int64]$SizeMB * 1MB
        $random = New-Object Random($Seed)
        $blockChecksums = New-Object System.Collections.Generic.List[uint32]

        $stream = [IO.File]::Open($testFile, [IO.FileMode]::Create, [IO.FileAccess]::Write, [IO.FileShare]::None)
        try {
            $written = [int64]0
            while ($written -lt $totalBytes) {
                $thisBlockSize = [int][math]::Min($BlockSizeBytes, $totalBytes - $written)
                $buffer = New-Object byte[] $thisBlockSize
                $random.NextBytes($buffer)
                $stream.Write($buffer, 0, $thisBlockSize)
                $blockChecksums.Add((Get-HsCrc32 -Bytes $buffer))
                $written += $thisBlockSize
                Write-HsStageProgress -Activity $ProgressLabel -Status ("Schreiben {0:N0} / {1:N0} MB" -f ($written / 1MB), ($totalBytes / 1MB)) -Percent (50.0 * $written / $totalBytes)
            }
            $stream.Flush($true)
        } finally {
            $stream.Dispose()
        }
        $result.BytesWritten = $written

        $readStream = [IO.File]::Open($testFile, [IO.FileMode]::Open, [IO.FileAccess]::Read, [IO.FileShare]::Read)
        try {
            $verified = [int64]0
            $mismatches = 0
            $blockIndex = 0
            while ($verified -lt $totalBytes) {
                $thisBlockSize = [int][math]::Min($BlockSizeBytes, $totalBytes - $verified)
                $buffer = New-Object byte[] $thisBlockSize
                $readCount = 0
                while ($readCount -lt $thisBlockSize) {
                    $n = $readStream.Read($buffer, $readCount, $thisBlockSize - $readCount)
                    if ($n -eq 0) { break }
                    $readCount += $n
                }
                $actualChecksum = Get-HsCrc32 -Bytes $buffer
                if ($actualChecksum -ne $blockChecksums[$blockIndex]) {
                    $mismatches++
                }
                $verified += $thisBlockSize
                $blockIndex++
                Write-HsStageProgress -Activity $ProgressLabel -Status ("Lesen und vergleichen {0:N0} / {1:N0} MB, {2} Abweichung(en)" -f ($verified / 1MB), ($totalBytes / 1MB), $mismatches) -Percent (50.0 + 50.0 * $verified / $totalBytes)
            }
        } finally {
            $readStream.Dispose()
        }

        $result.BytesVerified = $verified
        $result.Mismatches = $mismatches

        if ($mismatches -gt 0) {
            $result.Status = "FAIL"
            $result.Reason = "$mismatches of $($blockChecksums.Count) block(s) failed checksum verification after write+read-back."
        } else {
            $result.Status = "PASS"
            $result.Reason = "$($blockChecksums.Count) block(s) ($([math]::Round($totalBytes/1MB,1)) MB) written, read back, and checksum-verified with 0 mismatches."
        }
    } catch {
        $result.Status = "FAIL"
        $result.Reason = "Write/read verification failed: $($_.Exception.Message)"
    } finally {
        Write-HsStageProgress -Activity $ProgressLabel -Completed
        $sw.Stop()
        $result.DurationSeconds = $sw.Elapsed.TotalSeconds
        if (Test-Path -LiteralPath $testFile) {
            Remove-Item -LiteralPath $testFile -Force -ErrorAction SilentlyContinue
        }
    }

    return $result
}

function Get-HsCrc32 {
    param([Parameter(Mandatory=$true)][byte[]]$Bytes)
    return [PCDiagnose.HardwareStability.Crc32]::Compute($Bytes, $Bytes.Length)
}

Export-ModuleMember -Function * -Variable *
