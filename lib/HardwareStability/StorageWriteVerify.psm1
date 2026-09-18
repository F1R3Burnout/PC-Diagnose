Set-StrictMode -Version 2.0

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
        [int]$Seed = 12345
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
        $sw.Stop()
        $result.DurationSeconds = $sw.Elapsed.TotalSeconds
        if (Test-Path -LiteralPath $testFile) {
            Remove-Item -LiteralPath $testFile -Force -ErrorAction SilentlyContinue
        }
    }

    return $result
}

$script:HsCrc32Table = $null

function Get-HsCrc32 {
    param([Parameter(Mandatory=$true)][byte[]]$Bytes)

    $polynomial = [uint32]3988292384 # 0xEDB88320, written decimal to avoid PowerShell hex-literal widening

    if ($null -eq $script:HsCrc32Table) {
        $table = New-Object uint32[] 256
        for ($i = 0; $i -lt 256; $i++) {
            [uint32]$c = [uint32]$i
            for ($k = 0; $k -lt 8; $k++) {
                if (($c -band [uint32]1) -ne 0) {
                    [uint32]$c = [uint32]($polynomial -bxor ($c -shr 1))
                } else {
                    [uint32]$c = [uint32]($c -shr 1)
                }
            }
            $table[$i] = $c
        }
        $script:HsCrc32Table = $table
    }

    [uint32]$crc = [uint32]4294967295 # 0xFFFFFFFF
    foreach ($b in $Bytes) {
        $index = [int](($crc -bxor [uint32]$b) -band [uint32]0xFF)
        [uint32]$crc = [uint32]($script:HsCrc32Table[$index] -bxor ($crc -shr 8))
    }
    return [uint32]($crc -bxor [uint32]4294967295)
}

Export-ModuleMember -Function * -Variable *
