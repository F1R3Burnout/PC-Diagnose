# PC-Diagnose

PowerShell-based diagnostics and maintenance tools for Windows PCs and small servers.

## Quick Start

Start the menu:

```powershell
irm https://raw.githubusercontent.com/F1R3Burnout/PC-Diagnose/main/r|iex
```

The menu reads `manifest.json` and shows all registered tools.

## Current Tools

| Tool ID | Name | Purpose | Admin |
| --- | --- | --- | --- |
| `serverdiag` | ServerDiagLite | Collect a diagnostics package and open a local result view | Yes |

## ServerDiagLite

ServerDiagLite creates a ZIP package under `C:\Temp` with:

- local findings summary with timestamps
- automatically opened result window with status and next steps
- HTML report
- manifest
- system and hardware data
- storage and volume status
- network adapters, IP configuration, and DNS
- power and wake information
- limited System/Application event analysis
- minidumps, if present

The current version is intentionally `collect-only`: it collects diagnostics data, evaluates typical patterns locally, opens a result view, and does not repair or modify the system.

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
    ServerDiagLite.ps1
.github/
  workflows/
    test-powershell.yml
```

New tools are added as PowerShell scripts under `scripts/` and registered in `manifest.json`.

## Notes

Running remote code through `irm ... | iex` is convenient, but it requires trust in this repository. For production use, tagged releases or signed scripts are recommended.
