Set-StrictMode -Version 2.0

function Get-HsToolConfig {
    param([Parameter(Mandatory=$true)][string]$ConfigPath)
    $json = Get-Content -LiteralPath $ConfigPath -Raw -Encoding UTF8
    return $json | ConvertFrom-Json
}

function Get-HsFileHash256 {
    param([Parameter(Mandatory=$true)][string]$Path)
    return (Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash.ToLowerInvariant()
}

function Get-HsFileHash512 {
    param([Parameter(Mandatory=$true)][string]$Path)
    return (Get-FileHash -LiteralPath $Path -Algorithm SHA512).Hash.ToLowerInvariant()
}

function ConvertTo-HsHexHash {
    <#
        Normalizes a configured hash to lowercase hex. NuGet publishes its
        package hashes as base64 (88 characters for SHA512); everything else in
        HardwareStabilityTools.json is already hex. Returns "" for input that is
        neither, so a malformed value can never accidentally "match".
    #>
    param([AllowNull()][string]$Value, [Parameter(Mandatory=$true)][int]$ByteLength)
    if ([string]::IsNullOrWhiteSpace($Value)) { return "" }
    $text = $Value.Trim()
    if ($text -match '^[0-9a-fA-F]+$' -and $text.Length -eq ($ByteLength * 2)) { return $text.ToLowerInvariant() }
    try {
        $bytes = [Convert]::FromBase64String($text)
        if ($bytes.Length -ne $ByteLength) { return "" }
        return (($bytes | ForEach-Object { $_.ToString("x2") }) -join "")
    } catch {
        return ""
    }
}

function Get-HsFileHashMd5 {
    param([Parameter(Mandatory=$true)][string]$Path)
    return (Get-FileHash -LiteralPath $Path -Algorithm MD5).Hash.ToLowerInvariant()
}

function Get-HsPropertyOrDefault {
    param([Parameter(Mandatory=$true)]$InputObject, [Parameter(Mandatory=$true)][string]$Name, $Default = "")
    if ($null -eq $InputObject) { return $Default }
    if ($InputObject.PSObject.Properties.Name -contains $Name) {
        return $InputObject.$Name
    }
    return $Default
}

function Resolve-HsTool {
    <#
    .SYNOPSIS
        Resolves the local path to a third-party diagnostic tool executable,
        downloading and hash-verifying it from its official source if it is
        not already cached locally.

    .DESCRIPTION
        Returns a status object rather than throwing, so a missing/blocked
        tool degrades a single stage to SKIPPED/UNSUPPORTED instead of
        aborting the whole Hardware-Stabilitätstest run (spec section 36).
    #>
    param(
        [Parameter(Mandatory=$true)][string]$ToolId,
        [Parameter(Mandatory=$true)]$ToolConfig,
        [Parameter(Mandatory=$true)][string]$ToolCacheRoot,
        [switch]$NoDownload
    )

    $result = [pscustomobject]@{
        ToolId       = $ToolId
        Available    = $false
        ExecutablePath = ""
        ToolDirectory = ""
        Reason       = ""
        Version      = ""
        License      = ""
    }

    if (-not ($ToolConfig.tools.PSObject.Properties.Name -contains $ToolId)) {
        $result.Reason = "Tool '$ToolId' is not defined in HardwareStabilityTools.json"
        return $result
    }

    $entry = $ToolConfig.tools.$ToolId
    $result.Version = [string]$entry.version
    $result.License = [string]$entry.license

    $toolDir = Join-Path $ToolCacheRoot $ToolId
    New-Item -ItemType Directory -Force -Path $toolDir | Out-Null
    $result.ToolDirectory = $toolDir

    $execRelative = [string]$entry.executable
    $execPath = Join-Path $toolDir $execRelative

    if (Test-Path -LiteralPath $execPath) {
        $result.Available = $true
        $result.ExecutablePath = $execPath
        $result.Reason = "Already cached"
        return $result
    }

    if ($NoDownload) {
        $result.Reason = "Not cached locally and -NoDownload was specified"
        return $result
    }

    # Fail closed: a tool without any configured integrity hash is never
    # downloaded and executed. Previously such an entry was silently accepted
    # unverified, which would have turned a config mistake into running an
    # unchecked binary with administrator rights.
    $expectedSha256 = [string](Get-HsPropertyOrDefault -InputObject $entry -Name "sha256")
    $expectedSha512 = [string](Get-HsPropertyOrDefault -InputObject $entry -Name "sha512")
    $expectedMd5 = [string](Get-HsPropertyOrDefault -InputObject $entry -Name "md5")
    if ([string]::IsNullOrWhiteSpace($expectedSha256) -and [string]::IsNullOrWhiteSpace($expectedSha512) -and [string]::IsNullOrWhiteSpace($expectedMd5)) {
        $result.Reason = "No integrity hash (sha256/sha512/md5) configured for '$ToolId' - download refused"
        return $result
    }

    $downloadUrl = [string]$entry.downloadUrl
    $archiveType = [string]$entry.archiveType
    $extensionByType = @{ zip = ".zip"; exe = ".exe"; "nsis-installer" = ".exe"; nupkg = ".zip" }
    # Always name the downloaded file from the known archiveType rather than
    # trying to infer/preserve an extension from the URL. Redirector URLs
    # (e.g. SourceForge's "/download" auto-mirror link) don't end in a real
    # file name at all, and a URL ending in a bare version number such as
    # ".../LibreHardwareMonitorLib/0.9.6" is mis-detected by
    # [IO.Path]::HasExtension() as "having" the extension ".6" - which then
    # made Expand-Archive on Windows PowerShell 5.1 refuse the file outright
    # ("'.6' ist kein unterstuetztes Archivdateiformat"), while PowerShell 7
    # happened not to care. Always forcing the extension from archiveType
    # sidesteps that entirely. See docs/HARDWARE_STABILITY_STATE.md.
    $forcedExtension = if ($extensionByType.ContainsKey($archiveType)) { $extensionByType[$archiveType] } else { ".bin" }
    $fileName = "$ToolId$forcedExtension"
    $downloadPath = Join-Path $toolDir $fileName

    try {
        [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
        # Some official mirrors (e.g. SourceForge's auto-mirror "/download" redirector) serve a
        # JS mirror-selection interstitial instead of the file to PowerShell's default User-Agent.
        # A curl-like User-Agent reliably reaches the real binary; verified against smartmontools
        # 7.5 during implementation (see docs/HARDWARE_STABILITY_STATE.md).
        Invoke-WebRequest -Uri $downloadUrl -OutFile $downloadPath -UseBasicParsing -UserAgent "curl/8.7.1" -MaximumRedirection 10 -ErrorAction Stop
    } catch {
        $result.Reason = "Download failed: $($_.Exception.Message)"
        return $result
    }

    if (-not [string]::IsNullOrWhiteSpace($expectedSha256)) {
        $actualSha256 = Get-HsFileHash256 -Path $downloadPath
        if ($actualSha256 -ne $expectedSha256.ToLowerInvariant()) {
            Remove-Item -LiteralPath $downloadPath -Force -ErrorAction SilentlyContinue
            $result.Reason = "SHA256 mismatch (expected $expectedSha256, got $actualSha256) - download rejected"
            return $result
        }
    }

    if (-not [string]::IsNullOrWhiteSpace($expectedSha512)) {
        $expectedSha512Hex = ConvertTo-HsHexHash -Value $expectedSha512 -ByteLength 64
        $actualSha512 = Get-HsFileHash512 -Path $downloadPath
        if ([string]::IsNullOrEmpty($expectedSha512Hex) -or $actualSha512 -ne $expectedSha512Hex) {
            Remove-Item -LiteralPath $downloadPath -Force -ErrorAction SilentlyContinue
            $result.Reason = "SHA512 mismatch (expected $expectedSha512, got $actualSha512) - download rejected"
            return $result
        }
    }

    if (-not [string]::IsNullOrWhiteSpace($expectedMd5)) {
        $actualMd5 = Get-HsFileHashMd5 -Path $downloadPath
        if ($actualMd5 -ne $expectedMd5.ToLowerInvariant()) {
            Remove-Item -LiteralPath $downloadPath -Force -ErrorAction SilentlyContinue
            $result.Reason = "MD5 mismatch (expected $expectedMd5, got $actualMd5) - download rejected"
            return $result
        }
    }

    switch ($archiveType) {
        { $_ -in @("zip", "nupkg") } {
            try {
                Expand-Archive -LiteralPath $downloadPath -DestinationPath $toolDir -Force
            } catch {
                $result.Reason = "Archive extraction failed: $($_.Exception.Message)"
                return $result
            }
        }
        "exe" {
            $execPath = Join-Path $toolDir $execRelative
            if ($downloadPath -ne $execPath) {
                Copy-Item -LiteralPath $downloadPath -Destination $execPath -Force
            }
        }
        "nsis-installer" {
            try {
                $installArgs = @("/S", "/D=$toolDir")
                $proc = Start-Process -FilePath $downloadPath -ArgumentList $installArgs -Wait -PassThru -WindowStyle Hidden
                if ($proc.ExitCode -ne 0) {
                    $result.Reason = "Silent installer exited with code $($proc.ExitCode)"
                    return $result
                }
            } catch {
                $result.Reason = "Silent install failed: $($_.Exception.Message)"
                return $result
            }
        }
        default {
            $result.Reason = "Unknown archiveType '$archiveType'"
            return $result
        }
    }

    if (-not (Test-Path -LiteralPath $execPath)) {
        $result.Reason = "Executable not found after install/extract: $execPath"
        return $result
    }

    $result.Available = $true
    $result.ExecutablePath = $execPath
    $result.Reason = "Downloaded and verified"
    return $result
}

Export-ModuleMember -Function * -Variable *
