# PC-Diagnose

Small PowerShell diagnostics toolkit for normal Windows desktop PCs.

## How to Run

1. Open PowerShell.

2. Run:

```powershell
irm https://kiwus-it.de/r|iex
```

3. Select the tool from the menu:

```text
1 = PCDiagLite
2 = NetzwerkDiagnose
3 = NTLiteChecker
```

4. Accept the UAC prompt only when the selected tool asks for it.

5. For `PCDiagLite`, choose the event range.

   Press Enter to analyze all available Event Viewer entries:

```text
all
```

   Enter a number only when you want to limit the range, for example `14`.

6. Wait until the tool finishes.

7. Review the HTML result window that opens automatically.

8. Keep the created output files if the result should be shared or analyzed later.

## Output

`PCDiagLite` writes the result package to:

```text
C:\Temp
```

Typical files:

```text
00_Result.html
00_Report.html
00_Findings_Summary.txt
PCDiagLite_<Computer>_<Timestamp>.zip
```

The result view shows the most important findings first. The ZIP contains the full collected data.

`NetzwerkDiagnose` writes an HTML report to:

```text
C:\Temp\NetzwerkDiagnose
```

`NTLiteChecker` asks for a ZIP and writes its HTML, CSV, and result ZIP files to:

```text
C:\Temp\NTLiteChecker
```

## NTLite Verification

The checker is portable and read-only. Nothing from PC-Diagnose must be installed or added to the Windows image.

For a new NTLite installation:

1. Build the image from one fixed Windows version and edition.
2. Save the final NTLite preset immediately before Apply and keep the auto-saved session preset created by Apply.
3. Keep the exact unattended XML and NTLite build logs.
4. Put the files below into one ZIP. Subfolders are supported.
5. Install Windows normally.
6. Run menu item `3 = NTLiteChecker` on the installed PC and select the ZIP.

Include:

1. The final auto-saved NTLite session preset created after the last Apply operation. This is the most important file.
2. The exact `autounattend.xml` or `unattend.xml` used for Windows Setup.
3. Every manually loaded NTLite `[Preset].xml` file, for history and conflict detection.
4. The matching `NTLite.log` and `NTLite_dism.log` from the image build.
5. Post-setup `.ps1`, `.cmd`, `.bat`, and `.reg` source files referenced by the presets.

NTLite logs are normally stored in `%LOCALAPPDATA%\Temp`; the configured temporary directory is shown in NTLite under `Menu > Settings`.

The checker safely compares literal REG entries and simple literal registry commands with the current PC. It never imports or executes supplied files. It also reads the Windows Setup evidence already retained under `C:\Windows\Panther`. Historical script exit codes remain `Not verifiable` when Windows did not retain them, but durable effects can still be verified from the current state.

The original input ZIP is not copied into the result ZIP. Product keys and common secret parameters are redacted from generated output, but review archives before sharing them publicly.

## Optional Commands

Start PCDiagLite directly:

```powershell
& ([scriptblock]::Create((irm https://kiwus-it.de/r))) -Tool pcdiag
```

Set the event range directly:

```powershell
& ([scriptblock]::Create((irm https://kiwus-it.de/r))) -Tool pcdiag -DaysBack 14
```

Analyze all available Event Viewer entries directly:

```powershell
& ([scriptblock]::Create((irm https://kiwus-it.de/r))) -Tool pcdiag -DaysBack 0
```

Use privacy mode:

```powershell
& ([scriptblock]::Create((irm https://kiwus-it.de/r))) -PrivacyMode
```

Auto-install Windows Debugging Tools when minidumps need analysis:

```powershell
& ([scriptblock]::Create((irm https://kiwus-it.de/r))) -AutoInstallDebugTools
```

Start NetzwerkDiagnose directly:

```powershell
& ([scriptblock]::Create((irm https://kiwus-it.de/r))) -Tool netdiag
```

Start NTLiteChecker directly and select the ZIP in the file dialog:

```powershell
& ([scriptblock]::Create((irm https://kiwus-it.de/r))) -Tool ntlitecheck
```

Provide the ZIP directly:

```powershell
& ([scriptblock]::Create((irm https://kiwus-it.de/r))) -Tool ntlitecheck -NTLiteInputZip 'C:\Temp\NTLite-Verification.zip'
```

Run NetzwerkDiagnose with extra path tests:

```powershell
& ([scriptblock]::Create((irm https://kiwus-it.de/r))) -Tool netdiag -IncludeTraceroute -IncludeMtuTest
```

Network event logs, cautious subnet discovery, and internet speed test run by default. Useful parameters include `-NoInternetTest`, `-SmbTestPath`, `-LanSpeedTarget`, `-LocalTargets`, and `-TcpTargets`.

## Important Notes

The tools are collect-only. They do not repair or modify the PC.

Privacy mode masks common sensitive values, but it is not a guarantee. Deployment logs can contain setup command lines, although script source contents are not copied. Review ZIP files before public sharing.

Running remote PowerShell code requires trust in this repository.

## Features

- Menu-based tool selection from one short command
- Portable, read-only NTLite verification against presets, unattended XML, NTLite logs, safe static registry assertions, current Windows state, and retained Panther setup evidence
- Local HTML result view
- Timeout-protected collection steps with hardened child process handling
- Findings grouped by primary area
- Newest-first event timeline
- Clickable Event Viewer details
- Source tracing for captured files, CSV rows, and Event Viewer record IDs
- Unexpected shutdown correlation for EventLog 6008, Kernel-Power 41, planned restarts, and nearby hardware signals
- SMART and storage reliability checks
- Disk, volume, free-space, and file-system checks
- Disk event mapping to physical disk names and drive letters when Windows reports `\Device\Harddisk...`
- Collapsed overview of explicitly changed local policy settings
- Plain-English Deployment / Image Audit for NTLite, SetupComplete, unattend, first-logon evidence, effective Widgets/Sticky Keys state, and repeated setup errors grouped by cause; complete technical evidence stays collapsed below
- Hardware migration and stale fixed-hardware driver context
- Network, DNS, hosts file, NRPT, and endpoint checks
- TCP/UDP port exhaustion detection
- Main network report separates VPN-related adapters, routes, tests, and findings into a dedicated VPN section at the bottom
- Network report prioritizes system info, active adapters, ping, DNS, speed, findings, and logs; skipped optional tests are listed at the bottom
- Dedicated VPN overview for common providers such as Tailscale, OpenVPN, Surfshark, WireGuard, NordVPN, Proton VPN, Mullvad, Cloudflare WARP, ZeroTier, Cisco AnyConnect, Fortinet, GlobalProtect, and similar tools
- Collapsible network event logs directly above the VPN section
- Sortable network report tables with colored result markers for reachability, DNS resolution, latency, packet loss, Wi-Fi signal, and speed values
- Internet speed test includes download, upload, ping, and the selected or detected test server/edge
- WLAN details from Windows built-in diagnostics: active connection, signal, BSSID, band, channel, rates, security mode, driver data, nearby BSSIDs, saved profiles, and Windows WLAN report path when available
- Network event logs, cautious subnet discovery, and internet speed test run by default
- Gaming-related error interpretation for Xbox Game Bar, Gaming Services, launchers, overlays, anti-cheat, game paths, and Counter-Strike 2 (`cs2.exe`)
- Windows Error Reporting appcrash collection for deeper game and application crash context
- Counter-Strike 2 crash correlation with WER BEX/StackHash, overlay/GPU module hints, and nearby system signals
- More precise NVIDIA/AMD/ASUS vendor utility, graphics driver, service, Windows Update, AppX, and application hang checks
- Minidump copies in the ZIP and optional local `!analyze -v` interpretation
- Detailed network report for adapters, routes, gateway, DNS, TCP reachability, Wi-Fi, firewall profile, services, optional events, traceroute, MTU, SMB, iperf3, and speed tests
- ZIP package for handoff

## Development

Add tools under `scripts/` and register them in `manifest.json`.

The menu is generated from `manifest.json`, so the Wix redirect only needs to point to the short starter once.
