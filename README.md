# PC-Diagnose

PowerShell-based diagnostics and maintenance tools for normal Windows desktop PCs.

## Quick Start

Start the menu:

```powershell
irm https://raw.githubusercontent.com/F1R3Burnout/PC-Diagnose/main/r|iex
```

The menu reads `manifest.json` and shows all registered tools.

## Current Tools

| Tool ID | Name | Purpose | Admin |
| --- | --- | --- | --- |
| `pcdiag` | PCDiagLite | Collect a diagnostics package and open a local result view | Yes |

## PCDiagLite

PCDiagLite creates a ZIP package under `C:\Temp` with:

- local findings summary with timestamps
- automatically opened result window grouped by primary area, with status, next steps, and clickable Event Viewer details
- HTML report
- manifest
- system and hardware data
- storage and volume status
- network adapters, IP configuration, and DNS
- current TCP/UDP endpoint usage by process
- dynamic port exhaustion detection
- power and wake information
- limited System/Application event analysis
- minidumps, if present
- optional minidump analysis when Windows Debugging Tools (`cdb.exe`) are installed

The current version collects diagnostics data, evaluates typical patterns locally, opens a result view, and does not repair or modify the system.

### Optional Minidump Analysis

PCDiagLite can run a local `!analyze -v` pass for copied minidumps when `cdb.exe` from Windows Debugging Tools is available.

If `cdb.exe` is not installed and minidumps are present, the tool can install Windows Debugging Tools through Microsoft's Windows SDK installer and then analyze the dumps. In normal menu runs it asks before installing anything.

For unattended runs, pass `-AutoInstallDebugTools` to the bootstrap command so missing Debugging Tools are installed automatically.

```powershell
& ([scriptblock]::Create((irm https://kiwus-it.de/r))) -AutoInstallDebugTools
```

## Privacy

Diagnostics packages can contain IP addresses, user names, computer names, serial numbers, MAC addresses, paths, and device IDs.

Privacy mode is a helper filter. Still review packages manually before public sharing.

## Development

Structure:

```text
bootstrap.ps1
manifest.json
scripts/
  diagnostics/
    PCDiagLite.ps1
.github/
  workflows/
    test-powershell.yml
```

New tools are added as PowerShell scripts under `scripts/` and registered in `manifest.json`.

## Notes

Running remote code through `irm ... | iex` is convenient, but it requires trust in this repository. For production use, tagged releases or signed scripts are recommended.
