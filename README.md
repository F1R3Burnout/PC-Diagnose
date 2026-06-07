# PC-Diagnose

PowerShell-based diagnostics tools for normal Windows desktop PCs.

The current tool is focused on desktop PC troubleshooting, local first-pass analysis, and clean handoff of a ZIP package for deeper review.

## Quick Start

Start the menu:

```powershell
irm https://kiwus-it.de/r|iex
```

The starter reads `manifest.json`, shows all registered tools, elevates through UAC when a tool requires Administrator rights, downloads the selected tool, and runs it from the loaded script text. This avoids common Execution Policy blocks on the temporary `.ps1` cache file.

When PCDiagLite is started from the menu, the starter asks how many days back should be analyzed. Press Enter to use the default of 30 days.

## Current Tools

| Tool ID | Name | Purpose | Admin |
| --- | --- | --- | --- |
| `pcdiag` | PCDiagLite | Collects a lightweight desktop PC diagnostics package and opens a local result view | Yes |

## PCDiagLite

PCDiagLite creates a ZIP package under `C:\Temp` and opens a local HTML result window after collection.

It collects and summarizes:

- local findings with timestamps, severity, evidence, and next steps
- grouped result view by primary area, collapsed by default
- directly visible storage SMART and reliability tables in the result view
- newest-first timeline for finding-related Event Viewer records
- clickable captured Event Viewer details for relevant findings
- system, uptime, BIOS, CPU, RAM, and basic hardware data
- storage, disks, volumes, partitions, and free-space status
- SMART failure prediction and storage reliability counters
- network adapters, IP configuration, DNS, NIC power/offload settings
- hosts file content check and DNS Client NRPT rules
- current TCP/UDP endpoint usage by process
- dynamic TCP/UDP port exhaustion signals
- power and wake information
- targeted System/Application event analysis
- minidumps, if present
- optional local minidump analysis through Windows Debugging Tools (`cdb.exe`)

PCDiagLite does not repair or modify the system. It collects data, evaluates common patterns locally, and packages the result.

## Local Analysis

The result view highlights likely problem areas such as:

- crashes, hard resets, and BugCheck indicators
- storage and file-system problems
- SMART warning signals, read/write reliability counters, high wear, and high latency
- low free disk space
- DNS, network, NIC driver, and TCP/UDP exhaustion issues
- hosts file permission/content problems and stale custom name mappings
- Windows Update, AppX, Perflib, and application hangs
- service start failures and driver-related errors
- repeated event summaries, such as which service failed several times or which Windows Stack update/app error repeated
- suspicious current system state, such as high endpoint usage

The analysis is heuristic. It is meant to point to the most likely next checks, not to replace manual diagnosis.

## Minidump Analysis

If minidumps are found, PCDiagLite copies the latest small dumps into the package.

If `cdb.exe` from Windows Debugging Tools is installed, PCDiagLite runs:

```text
!analyze -v
```

The result is shown in:

- the local result window under `Crash`
- `00_Report.html` under `Minidump Analysis`
- `06_Minidumps\DumpAnalysis.csv`
- `06_Minidumps\DumpAnalysis_*.txt`

If `cdb.exe` is missing and minidumps are present, the normal menu run asks whether Windows Debugging Tools should be installed. It installs only the debugger feature from Microsoft's Windows SDK installer:

```text
OptionId.WindowsDesktopDebuggers
```

For unattended runs:

```powershell
& ([scriptblock]::Create((irm https://kiwus-it.de/r))) -AutoInstallDebugTools
```

## Privacy

Diagnostics packages can contain IP addresses, user names, computer names, serial numbers, MAC addresses, file paths, device IDs, installed drivers, and event messages.

Optional privacy mode masks common sensitive values before ZIP creation:

```powershell
& ([scriptblock]::Create((irm https://kiwus-it.de/r))) -PrivacyMode
```

Privacy mode is a helper, not a guarantee. Review packages before public sharing.

## Parameters

Common bootstrap parameters:

| Parameter | Purpose |
| --- | --- |
| `-Tool pcdiag` | Starts PCDiagLite directly instead of showing the menu |
| `-DaysBack 30` | Event analysis range; skips the menu prompt when passed explicitly |
| `-OutputRoot C:\Temp` | Output location |
| `-PrivacyMode` | Masks common sensitive values |
| `-AutoInstallDebugTools` | Installs Windows Debugging Tools automatically when minidumps need analysis |

Example direct run:

```powershell
& ([scriptblock]::Create((irm https://kiwus-it.de/r))) -Tool pcdiag -DaysBack 14
```

## Development

Repository structure:

```text
r
bootstrap.ps1
manifest.json
scripts/
  diagnostics/
    PCDiagLite.ps1
.github/
  workflows/
    test-powershell.yml
```

Add new tools as PowerShell scripts under `scripts/`, then register them in `manifest.json`. The menu updates from the manifest, so the Wix redirect only needs to point to the short starter once.

## Trust Note

Running remote code through `irm ... | iex` is convenient, but it requires trust in this repository. For broader production use, tagged releases, signed scripts, or an internal private repository are recommended.
