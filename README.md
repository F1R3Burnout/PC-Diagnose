# PC-Diagnose

Small PowerShell diagnostics toolkit for normal Windows desktop PCs.

The current tool, `PCDiagLite`, collects diagnostics, creates a local HTML result view, and saves a ZIP package for later review.

## How to Run

1. Open PowerShell.

2. Run:

```powershell
irm https://kiwus-it.de/r|iex
```

3. Select the tool from the menu.

4. Accept the UAC prompt when Windows asks for Administrator rights.

5. Choose the event range.

   Press Enter to analyze all available Event Viewer entries:

```text
all
```

   Enter a number only when you want to limit the range, for example `14`.

6. Wait until the collection finishes.

7. Review the HTML result window that opens automatically.

8. Keep the created ZIP file if the result should be shared or analyzed later.

## Output

PCDiagLite writes the result package to:

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

## Important Notes

PCDiagLite is collect-only. It does not repair or modify the PC.

Privacy mode masks common sensitive values, but it is not a guarantee. Review ZIP files before public sharing.

Running remote PowerShell code requires trust in this repository.

## Features

- Local HTML result view
- Findings grouped by primary area
- Newest-first event timeline
- Clickable Event Viewer details
- SMART and storage reliability checks
- Disk, volume, free-space, and file-system checks
- Disk event mapping to physical disk names and drive letters when Windows reports `\Device\Harddisk...`
- Collapsed overview of explicitly changed local policy settings
- Hardware migration and stale fixed-hardware driver context
- Review-only cleanup commands for stale hardware traces
- Network, DNS, hosts file, NRPT, and endpoint checks
- TCP/UDP port exhaustion detection
- Gaming-related context for Xbox Game Bar, Gaming Services, launchers, overlays, anti-cheat, and Counter-Strike 2 (`cs2.exe`)
- Windows Update, AppX, service, driver, and application hang checks
- Minidump copies in the ZIP and optional local `!analyze -v` interpretation
- ZIP package for handoff

## Development

Add tools under `scripts/` and register them in `manifest.json`.

The menu is generated from `manifest.json`, so the Wix redirect only needs to point to the short starter once.
