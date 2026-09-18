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

    $downloadUrl = [string]$entry.downloadUrl
    $archiveType = [string]$entry.archiveType
    $fileName = [IO.Path]::GetFileName(([Uri]$downloadUrl).AbsolutePath)
    $extensionByType = @{ zip = ".zip"; exe = ".exe"; "nsis-installer" = ".exe"; nupkg = ".zip" }
    if ([string]::IsNullOrWhiteSpace($fileName) -or -not [IO.Path]::HasExtension($fileName)) {
        # Redirector URLs (e.g. SourceForge's "/download" auto-mirror link) don't end in a real
        # file name. Force a correct extension so Start-Process / Expand-Archive can rely on it
        # (Windows resolves how to launch a file by extension, not by content).
        $forcedExtension = if ($extensionByType.ContainsKey($archiveType)) { $extensionByType[$archiveType] } else { ".bin" }
        $fileName = "$ToolId$forcedExtension"
    }
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

    $expectedSha256 = [string](Get-HsPropertyOrDefault -InputObject $entry -Name "sha256")
    if (-not [string]::IsNullOrWhiteSpace($expectedSha256)) {
        $actualSha256 = Get-HsFileHash256 -Path $downloadPath
        if ($actualSha256 -ne $expectedSha256.ToLowerInvariant()) {
            Remove-Item -LiteralPath $downloadPath -Force -ErrorAction SilentlyContinue
            $result.Reason = "SHA256 mismatch (expected $expectedSha256, got $actualSha256) - download rejected"
            return $result
        }
    }

    $expectedMd5 = [string](Get-HsPropertyOrDefault -InputObject $entry -Name "md5")
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
