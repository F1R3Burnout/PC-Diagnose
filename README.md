# PC-Diagnose

Small PowerShell diagnostics toolkit for normal Windows desktop PCs.

The current tool, `PCDiagLite`, collects diagnostics, creates a local HTML result view, and saves a ZIP package for later review.

The menu also contains `HardwareCleanupAssist` for interactive cleanup of stale hardware traces.

## How to Run

1. Open PowerShell.

2. Run:

```powershell
irm https://kiwus-it.de/r|iex
```

3. Select the tool from the menu.

4. Accept the UAC prompt when Windows asks for Administrator rights.

5. Enter how many days back should be analyzed.

   Press Enter to use the default:

```text
30
```

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

Use privacy mode:

```powershell
& ([scriptblock]::Create((irm https://kiwus-it.de/r))) -PrivacyMode
```

Auto-install Windows Debugging Tools when minidumps need analysis:

```powershell
& ([scriptblock]::Create((irm https://kiwus-it.de/r))) -AutoInstallDebugTools
```

Start the hardware cleanup assistant directly:

```powershell
& ([scriptblock]::Create((irm https://kiwus-it.de/r))) -Tool hwcleanup
```

## Important Notes

PCDiagLite is collect-only. It does not repair or modify the PC.

HardwareCleanupAssist can remove selected non-present device nodes and stale driver services, but only after explicit selection and confirmation.

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
- Interactive cleanup assistant for selected stale hardware traces
- Network, DNS, hosts file, NRPT, and endpoint checks
- TCP/UDP port exhaustion detection
- Game crash context for Counter-Strike 2 (`cs2.exe`)
- Windows Update, AppX, service, driver, and application hang checks
- Minidump copies in the ZIP and optional local `!analyze -v` interpretation
- ZIP package for handoff

## Development

Add tools under `scripts/` and register them in `manifest.json`.

The menu is generated from `manifest.json`, so the Wix redirect only needs to point to the short starter once.
