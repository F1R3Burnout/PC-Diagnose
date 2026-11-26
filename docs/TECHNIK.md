# PC-Diagnose für Windows · Technische Details

Ergänzung zur [README](../README.md). Hier stehen Parameter, Abläufe und technische Einzelheiten für Einrichtung, Betrieb und Fehlersuche.

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
06_Minidumps\LiveKernelReports\...
07_WER\Reports\...
08_GPU_Driver\GPUDriverAssessment.csv
08_GPU_Driver\AMDInstallerLogs.csv
99_Runtime\EventCollection_Status.txt
PCDiagLite_<Computer>_<Timestamp>.zip
```

The result view shows the most important findings first. The ZIP contains the full collected data.

`NetzwerkDiagnose` writes an HTML report to:

```text
C:\Temp\NetzwerkDiagnose
```

`HDMI- und Display-Diagnose` writes reports, EDID raw data, snapshots, and
live-monitor logs to:

```text
C:\Temp\HDMIDiagnose
```

`Hardware-Stabilitätstest` writes its result package to:

```text
C:\Temp\PCStability_<Computer>_<Timestamp>\
```

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

The legacy switch below remains accepted for compatibility, but is no longer required:

```powershell
& ([scriptblock]::Create((irm https://kiwus-it.de/r))) -AutoInstallDebugTools
```

Start NetzwerkDiagnose directly:

```powershell
& ([scriptblock]::Create((irm https://kiwus-it.de/r))) -Tool netdiag
```

Start the HDMI/display tool directly and select its mode:

```powershell
& ([scriptblock]::Create((irm https://kiwus-it.de/r))) -Tool displaydiag
```

The display tool offers a full report, live monitoring, EDID export, event-log
analysis, before/after snapshots, snapshot comparison, and a guided bandwidth
test. The downloaded tool runs read-only. It does not change display modes,
drivers, devices, EDID, or registry settings.

Direct commands from a repository checkout:

```powershell
.\scripts\diagnostics\HDMIDiagnose.ps1 -Full
.\scripts\diagnostics\HDMIDiagnose.ps1 -Monitor
.\scripts\diagnostics\HDMIDiagnose.ps1 -EDID
.\scripts\diagnostics\HDMIDiagnose.ps1 -Events
.\scripts\diagnostics\HDMIDiagnose.ps1 -Snapshot BeforeTest
.\scripts\diagnostics\HDMIDiagnose.ps1 -Snapshot AfterTest
.\scripts\diagnostics\HDMIDiagnose.ps1 -Compare BeforeTest,AfterTest
```

Windows can report display paths, modes, EDID, advanced-color state, audio
endpoints, and related system events. It cannot measure HDMI bit-error rates,
eye patterns, electrical cable quality, or remaining physical signal margin.
The report labels calculated bandwidth and heuristic conclusions accordingly.

Run NetzwerkDiagnose with extra path tests:

```powershell
& ([scriptblock]::Create((irm https://kiwus-it.de/r))) -Tool netdiag -IncludeTraceroute -IncludeMtuTest
```

Network event logs, cautious subnet discovery, and internet speed test run by default. Useful parameters include `-NoInternetTest`, `-SmbTestPath`, `-LanSpeedTarget`, `-LocalTargets`, and `-TcpTargets`.

Start the Hardware-Stabilitätstest directly:

```powershell
& ([scriptblock]::Create((irm https://kiwus-it.de/r))) -Tool hardwarestability -Profile Quick
```

Show what a run would do without starting any active hardware load:

```powershell
& ([scriptblock]::Create((irm https://kiwus-it.de/r))) -Tool hardwarestability -HsDryRun
```

Direct commands from a repository checkout:

```powershell
.\scripts\diagnostics\HardwareStability.ps1 -DryRun -Profile Quick
.\scripts\diagnostics\HardwareStability.ps1 -Profile Standard -Components CPU,RAM,Storage
.\scripts\diagnostics\HardwareStability.ps1 -Profile Extended -NoDownload
```

## Hardware-Stabilitätstest

Unlike a classic stress test, this tool checks hardware stability mainly
through **verification**, not just maximum load:

```text
known data / known computation
        -> hardware processes it
        -> result read back
        -> compared against the expected result
        -> mismatches recorded
```

High load and temperature are a permitted side effect of individual tests
(especially CPU torture testing and GPU load validation), not the test
result itself. A stage only fails when a mismatch, a verified calculation
error, or a real read/write error was actually detected.

**Components:**

- **CPU Compute / CPU Cache-IMC** - Prime95 (GIMPS) torture test. CPU Compute
  uses one worker per physical core; CPU Cache/IMC uses one worker per
  logical processor (including SMT/Hyperthreading siblings) to put more
  pressure on the cache hierarchy, interconnect, and memory controller. Both
  read Prime95's own `results.txt` for `FATAL ERROR` / `ROUND OFF` / `SUMOUT`
  evidence.
- **RAM** - [MemoryChecker](https://github.com/lordmulder/MemoryChecker)
  writes a pattern to a configurable share of physical RAM, reads it back,
  and compares. A Windows user-space test cannot cover 100% of installed
  RAM (some is reserved by Windows itself); for full offline coverage, use
  [MemTest86](https://www.memtest86.com/) instead.
- **GPU Compute** - a small Direct3D 11 compute-shader verifier built into
  this project: known 32-bit integer input is processed on the GPU (rotate/
  XOR/multiply-add), read back, and compared bit-exact against a CPU
  reference. Integer/bit operations are used deliberately so normal
  floating-point rounding differences can never be mistaken for a hardware
  error. Falls back to the WARP software renderer, or reports `UNSUPPORTED`,
  if no Direct3D 11 hardware device is available.
- **VRAM** - [memtest_vulkan](https://github.com/GpuZelenograd/memtest_vulkan)
  writes and reads back GPU memory. Reports `UNSUPPORTED` (not a failure) on
  systems without a usable Vulkan runtime/driver.
- **GPU Load / Thermal Validation** - reuses the same verified GPU compute
  kernel in a sustained loop to produce real load while temperature and
  device-loss (TDR) are monitored.
- **Storage SMART** - [smartmontools](https://www.smartmontools.org/)
  (`smartctl -x`) on every physical disk, the Windows disk first; the SMART
  self-test and the surface scan use the Windows disk. Drives/controllers
  that do not support SMART (e.g. many USB bridges) are reported as
  `UNSUPPORTED`, never as a failure.
- **Storage Surface Read** - a strictly **read-only** sequential scan of a
  physical drive (`\\.\PhysicalDriveN`, opened with `GENERIC_READ` only -
  never `GENERIC_WRITE` or `WriteFile`). `-SurfaceScanMaxBytes` bounds the
  scan for a quick check without limiting a normal full scan by default.
- **Storage Write/Read Verification** - writes pseudo-random data to a single
  normal temporary file, flushes, reads it back, and verifies a CRC32
  checksum per block. Never touches a raw disk; the test file is always
  removed afterward, even on failure or cancellation.
- **PCIe / WHEA** - correlates `Microsoft-Windows-WHEA-Logger` events (IDs
  17/18/19/20) recorded during other stages. A single corrected PCIe error
  is reported as a possible cause among several (GPU, slot, mainboard, power
  delivery, signal integrity) - never as a definitive mainboard diagnosis.
- **System Stability** - runs CPU (Prime95), GPU (D3D11 load) and RAM
  (MemoryChecker, continuous, 40/50/60% of physical RAM) concurrently to
  check whether components that pass individually remain stable together.
  PASS requires all three workloads to have run without a verified error. If
  an unexpected reset happens here, the report explicitly says PSU/VRM/
  memory controller/mainboard become more suspect without naming a single
  proven cause.

**Duration and intensity (Kurz / Mittel / Lang = Quick / Standard /
Extended)**: without `-Profile`, the test asks at start and shows the
planned minutes of the load stages for each choice. The profiles differ in
duration and intensity - RAM share and passes, GPU workload size, file size
of the write/verify check, surface scan, SMART self-test type - see
`lib/HardwareStability/Profiles.psm1`. `-Profile` still selects one directly;
`-NoPrompt` never asks (Quick when no profile is given).

**Live progress**: one progress bar at the top of the console, labelled
with the run position ("Hardware-Stabilitaetstest (Extended (Lang)),
Komponente 1 von 8: CPU Compute"); the bar itself fills with the running
stage's progress, and every 10% a plain line is also written. The status
line shows the remaining time of the stage ("Phase noch") and of the whole
run ("Gesamt noch"), the latter from the planned durations of the stages
still ahead - shown as "mind. ... + RAM/Surface-Scan/SMART-Test" while some
of them cannot be known up front. Below the bar the current temperatures are
shown, refreshed every 3 s: CPU (needs PawnIO, otherwise "CPU - (PawnIO
fehlt)"), GPU core and hotspot, VRM if the board reports it, and the Windows
disk via smartctl (every 30 s). Real percentages where the work is countable
(surface scan in bytes with MB/s and remaining time, write/verify in MB, RAM
passes and write/read phases parsed from MemoryChecker, SMART self-test as
reported by the drive, GPU compute iterations); elapsed against planned time
for the time-bound stages (Prime95, VRAM, GPU load, combined test).

**Targeted retest**: after the run, every noticeable stage (FAIL, WARNING,
BLOCKED, INTERRUPTED, THERMAL_ABORT) is listed and the tool asks whether to
test it again and for how long (10/30/60 minutes or a custom value).
CPU/Cache/VRAM/GPU load/combined test run for that time, RAM runs
MemoryChecker continuously for that time, storage reads the Windows disk for
that time and repeats the write/verify check. Retest stages are added to the
same report as "(Retest n, x min)"; they add evidence and never replace the
original result. PCIe/WHEA is not offered because it only reads past event
log entries. Unattended: `-RetestComponents "Cache,RAM" -RetestMinutes 30`.

**Thermal Guard**: conservative default abort/warning temperatures for CPU,
GPU core, GPU hotspot, NVMe, and VRM stop an active stage and produce a
partial report instead of continuing past a safety threshold. Telemetry (via
[LibreHardwareMonitorLib](https://github.com/LibreHardwareMonitor/LibreHardwareMonitor))
only ever reports sensor values that are actually present; nothing is
invented (a 0 C placeholder temperature is not a reading). `-SkipTelemetry`
disables sensor sampling and the live thermal guard checks. Under Windows
PowerShell 5.1 (the elevated default) the library's .NET Framework build is
loaded together with its hash-verified NuGet dependencies. CPU temperature
and motherboard/VRM sensors additionally require the separately installed
[PawnIO](https://pawnio.eu) driver; the tool never installs a driver. The
report's "Temperature monitoring" section and
`02_Telemetry\TelemetryStatus.json` state which temperatures the thermal
guard could actually see.

**Crash / reset recovery**: before an active stage starts, a small
`PendingRun.json` (`C:\ProgramData\PC-Diagnose\HardwareStability\`) records
that it is running. If a later start of the tool finds that file still
marked "Running" after a reboot, it analyzes Kernel-Power 41, EventLog
6005/6006/6008, User32 1074, and BugCheck 1001 around that time to
distinguish an unexpected `SYSTEM_RESET` from a normal planned
restart/shutdown (e.g. Windows Update). No scheduled task or autostart is
created, and the test is never resumed automatically after a reboot - the
user chooses whether to analyze the incident, continue, or exit.

**PASS** always means only: *within the range actually tested, no errors
were detected* - it is not a guarantee of complete hardware health, and a
failing stage names *possible* causes rather than declaring a specific
component defective without further evidence (for example, a memory
verification error can point to RAM, the memory controller, the CPU memory
path, or board-level signal integrity - not automatically "RAM is broken").

Third-party tools are downloaded only from their official sources and
SHA256/MD5-verified against the values recorded in
`config/HardwareStabilityTools.json` before use; `-NoDownload` prevents any
download and degrades the affected stage to `SKIPPED`/`UNSUPPORTED` instead
of failing the whole run.

## Important Notes

The diagnostics do not repair drivers, devices, registry settings, or Windows configuration. One deliberate exception applies: when PCDiagLite finds a copied crash dump and `cdb.exe` is missing, it automatically installs Microsoft's Windows Debugging Tools so every captured minidump and live-kernel dump can be analyzed locally.

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
- Local HTML result view
- Compact hardware summary at the top of PCDiagLite with CPU, GPU, RAM, mainboard, and system storage
- Dedicated read-only HDMI/display diagnostics with active Windows display paths, GPU mapping, raw and decoded EDID, HDR/advanced color, HDMI audio, bandwidth estimates, event correlation, live monitoring, and snapshot comparison
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
- Network event correlation uses a seven-day default lookback so intermittent adapter failures remain visible after a reboot or a later follow-up scan
- Dedicated VPN overview for common providers such as Tailscale, OpenVPN, Surfshark, WireGuard, NordVPN, Proton VPN, Mullvad, Cloudflare WARP, ZeroTier, Cisco AnyConnect, Fortinet, GlobalProtect, and similar tools
- Collapsible network event logs directly above the VPN section
- Sortable network report tables with colored result markers for reachability, DNS resolution, latency, packet loss, Wi-Fi signal, and speed values
- Internet speed test includes download, upload, ping, and the selected or detected test server/edge
- WLAN details from Windows built-in diagnostics: active connection, signal, BSSID, band, channel, rates, security mode, driver data, nearby BSSIDs, saved profiles, and Windows WLAN report path when available
- Network event logs, cautious subnet discovery, and internet speed test run by default
- Gaming-related error interpretation for Xbox Game Bar, Gaming Services, launchers, overlays, anti-cheat, game paths, and Counter-Strike 2 (`cs2.exe`)
- Windows Error Reporting appcrash collection for deeper game and application crash context
- Dedicated GPU/display-driver evidence section with LiveKernelReports/WATCHDOG dumps, matching WER report attachments, current display-adapter status, AMD CIM installer logs, and a filtered SetupAPI display-driver history
- Automatic `!analyze -v` coverage for copied live-kernel dumps as well as normal blue-screen minidumps; missing Windows Debugging Tools are installed automatically only when a dump needs analysis
- Counter-Strike 2 crash correlation with WER BEX/StackHash, overlay/GPU module hints, and nearby system signals
- More precise NVIDIA/AMD/ASUS vendor utility, graphics driver, service, Windows Update, AppX, and application hang checks
- Minidump copies in the ZIP and optional local `!analyze -v` interpretation
- Detailed network report for adapters, routes, gateway, DNS, TCP reachability, Wi-Fi, firewall profile, services, optional events, traceroute, MTU, SMB, iperf3, and speed tests
- ZIP package for handoff
- Verification-first Hardware-Stabilitätstest: CPU (Prime95), RAM (MemoryChecker), GPU compute (built-in D3D11 verifier), VRAM (memtest_vulkan), storage SMART/surface/write-verify, PCIe/WHEA correlation, thermal guard, and crash/reset recovery - see "Hardware-Stabilitätstest" below

## Development

Add tools under `scripts/` and register them in `manifest.json`.

The menu is generated from `manifest.json`, so the Wix redirect only needs to point to the short starter once.

Tests (no hardware load unless noted):

```powershell
.\tests\Bootstrap.Tests.ps1                      # launcher, Windows PowerShell 5.1
.\tests\PCDiagLite.Tests.ps1                     # component-aware diagnostic evidence (offline)
.\tests\PCDiagLite.RestartShutdown.Tests.ps1     # restart/shutdown classification (offline)
.\tests\HDMIDiagnose.Tests.ps1                   # display diagnostics core
.\tests\HardwareStability\HardwareStability.Fixtures.Tests.ps1   # fixtures, short real GPU/disk checks
.\tests\HardwareStability\Telemetry.Smoke.ps1   # downloads and loads LibreHardwareMonitorLib, one sample
.\tests\HardwareStability\EndToEnd.Smoke.ps1    # Administrator: real run with 30 s stages + automatic retest
.\tests\HardwareStability\Validate-HardwareStability.ps1   # all gates, fixtures under pwsh and powershell.exe
```
