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
01_Events\Restart_Shutdown_History_<range>.csv
01_Events\Restart_Shutdown_Incidents_<range>.csv
99_Runtime\EventCollection_Status.txt
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

Restart and shutdown results distinguish the actual incident time from the later time at which Windows logged the event. `User32` event 1074 is treated as a planned request and identifies its initiating process, user, reason, and shutdown type when Windows recorded those fields. Windows Update is named as the initiator only when the event contains matching process, service, or reason evidence.

`EventLog` 6008 and `Kernel-Power` 41 confirm that a previous Windows session did not end cleanly, but do not by themselves prove a blue screen, power-supply fault, or hardware defect. A blue screen is classified only when matching BugCheck evidence is present. The runtime status file makes missing or failed core event collection visible instead of allowing an incomplete scan to appear healthy.

- `User32 1074`: planned shutdown/restart request and initiator
- `EventLog 6006`: Event Log service stopped cleanly
- `EventLog 6005`: Event Log service started and serves as a boot marker
- `EventLog 6008`: previous shutdown was unexpected; normally written at the following boot
- `Kernel-Power 41`: previous Windows session was not shut down cleanly
- `BugCheck 1001`: blue-screen/bugcheck evidence when the provider also identifies a BugCheck or system error report

Privacy mode masks common sensitive values, but it is not a guarantee. Review ZIP files before public sharing.

Running remote PowerShell code requires trust in this repository.

## Features

- Menu-based tool selection from one short command
- Portable, read-only NTLite and policy verification in menu item `3` against presets, unattended XML, NTLite logs, safe static registry assertions, current Windows state, and retained Panther setup evidence
- Local HTML result view
- Compact hardware summary at the top of PCDiagLite with CPU, GPU, RAM, mainboard, and system storage
- Timeout-protected collection steps with hardened child process handling
- Findings grouped by primary area
- Newest-first event timeline
- Clickable Event Viewer details
- Source tracing for captured files, CSV rows, and Event Viewer record IDs
- Correlated restart/shutdown history for User32 1074, EventLog 6005/6006/6008, Kernel-Power 41, and BugCheck 1001, with incident time, log time, initiator, clean-shutdown confirmation, and source record IDs
- SMART and storage reliability checks
- Disk, volume, free-space, and file-system checks
- Disk event mapping to physical disk names and drive letters when Windows reports `\Device\Harddisk...`
- Hardware migration and stale fixed-hardware driver context
- Network, DNS, hosts file, NRPT, and endpoint checks
- TCP/UDP port exhaustion detection
- Main network report separates VPN-related adapters, routes, tests, and findings into a dedicated VPN section at the bottom
- Network report prioritizes system info, active adapters, ping, DNS, speed, findings, and logs; skipped optional tests are listed at the bottom
- Network report correlates NDIS resets, physical link losses, negotiated link speed, adapter driver/settings, and packet-counter changes during the scan
- Ping rows are deduplicated per destination and show loss, minimum, median, average, 95th percentile, maximum, and true successive-sample jitter
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
