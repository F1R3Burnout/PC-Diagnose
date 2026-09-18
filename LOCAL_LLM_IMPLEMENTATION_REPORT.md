# Hardware-Stabilitätstest — Implementation Report

Date: 2026-09-18
Branch: `feature/hardware-stability-test`

## 1. Ausgangszustand

- Repository geklont, `git log`/Dateisystem geprüft: kein bestehender Stresstest- oder
  Stabilitätstest-Code vorhanden. Basis waren `PCDiagLite.ps1` (6123 Zeilen, Monolith),
  `NetzwerkDiagnose.ps1`, `lib/HDMIDiagnostics.Core.psm1` + `.Native.cs`, `bootstrap.ps1`/`r`,
  `manifest.json`, `tests/HDMIDiagnose.Tests.ps1`.
- Umgebung: PowerShell 7.6.6 auf Windows 11 Pro (Build 26200), reale physische Hardware
  (Gigabyte B760M DS3H, Intel Core i5-14400, 32GB RAM, Samsung SSD 970 EVO Plus 500GB,
  Intel UHD 730), erreicht über eine nicht-interaktive Remote-Session ohne Möglichkeit,
  UAC-Elevation interaktiv zu bestätigen. Kein .NET SDK, kein C/C++-Compiler, kein
  Vulkan-Runtime installiert; `csc.exe` (.NET Framework Compiler) und Windows PowerShell
  5.1 waren vorhanden und wurden ausschließlich für Test-Fixture-Executables genutzt.

## 2. Architektur

Siehe `docs/HARDWARE_STABILITY_SPEC.md` Abschnitt 2 für alle Architekturentscheidungen
mit Begründung (D3D11 statt Vulkan für GPU_COMPUTE, kein FurMark2, eigener
Storage-Write-Verifier statt fio, kein OCCT).

### Neue Dateien

```
config/HardwareStabilityTools.json
lib/HardwareStability/Common.psm1
lib/HardwareStability/ProcessRunner.psm1
lib/HardwareStability/ToolManager.psm1
lib/HardwareStability/Profiles.psm1
lib/HardwareStability/Inventory.psm1
lib/HardwareStability/Telemetry.psm1
lib/HardwareStability/ThermalGuard.psm1
lib/HardwareStability/EventCorrelation.psm1
lib/HardwareStability/CrashRecovery.psm1
lib/HardwareStability/CpuTests.psm1
lib/HardwareStability/MemoryTests.psm1
lib/HardwareStability/GpuTests.psm1
lib/HardwareStability/StorageTests.psm1
lib/HardwareStability/StorageSurface.psm1
lib/HardwareStability/StorageWriteVerify.psm1
lib/HardwareStability/Reporting.psm1
lib/HardwareStability/Native/RawDiskReader.cs
lib/HardwareStability/Native/D3D11ComputeVerifier.cs
scripts/diagnostics/HardwareStability.ps1
tests/HardwareStability/FixtureTools.psm1
tests/HardwareStability/HardwareStability.Fixtures.Tests.ps1
tests/HardwareStability/Validate-HardwareStability.ps1
docs/HARDWARE_STABILITY_SPEC.md
docs/HARDWARE_STABILITY_STATE.md
docs/HARDWARE_STABILITY_ACCEPTANCE.md
LOCAL_LLM_IMPLEMENTATION_REPORT.md (this file)
LOCAL_LLM_TEST_RESULTS.txt
```

### Geänderte Dateien

```
manifest.json          - neuer Tool-Eintrag "hardwarestability"
bootstrap.ps1, r        - neue Parameter + Arg-Mapping für hardwarestability;
                          Dependency-Caching auf strukturerhaltende Ablage umgestellt
README.md               - neuer Abschnitt "Hardware-Stabilitätstest" + Menüpunkt 4
```

`PCDiagLite.ps1`, `NetzwerkDiagnose.ps1`, `HDMIDiagnose.ps1`, `HDMIDiagnostics.Core.psm1`,
`HDMIDiagnostics.Native.cs` wurden **nicht** verändert (siehe Abschnitt 6, Entscheidung
gegen den PCDiagLite-Refactor).

## 3. Testverfahren pro Komponente (verifikationsbasiert, nicht nur Lastgenerierung)

| Komponente | Prinzip | Tool |
|---|---|---|
| RAM | Muster schreiben -> lesen -> vergleichen | MemoryChecker 1.2.3 |
| CPU Compute / Cache-IMC | deterministische Berechnung -> Ergebnisvergleich (Prime95-intern) | Prime95 30.19b20 |
| GPU Compute | bekannte Ints -> D3D11-Compute (Rotate/XOR/Mul) -> Readback -> CPU-Referenzvergleich, bitgenau | eigener D3D11-Verifier |
| VRAM | Muster schreiben -> lesen -> vergleichen | memtest_vulkan 0.5.0 |
| Storage SMART | Herstellerdiagnose auslesen | smartctl 7.5 |
| Storage Surface | sequenzieller Read-Only-Scan, Fehlererfassung | eigener Win32-P/Invoke-Reader |
| Storage Write/Read | Testdatei schreiben -> lesen -> CRC32 vergleichen | eigener Verifier |

## 4. Drittanbieter-Tools: Versionen, Quellen, Lizenzen, Hashstrategie

Siehe `config/HardwareStabilityTools.json` für die maschinenlesbare Quelle der Wahrheit.
Zusammenfassung:

| Tool | Version | Lizenz | Hash-Strategie |
|---|---|---|---|
| MemoryChecker | 1.2.3 | CC0-1.0 | lokal berechneter SHA256 (kein Publisher-Hash verfügbar) |
| Prime95 | 30.19 build 20 | Freeware (GIMPS EULA) | lokal berechneter SHA256 |
| memtest_vulkan | 0.5.0 | Zlib | lokal berechneter SHA256 |
| smartmontools | 7.5 | GPL-2.0-or-later | offizieller MD5 (smartmontools.org/SourceForge) |
| LibreHardwareMonitorLib | 0.9.6 | MPL-2.0 | lokal berechneter SHA256 (NuGet-Paket) |

Alle Downloads erfolgen ausschließlich über HTTPS von der offiziellen Quelle; bei
Hash-Mismatch wird die Datei verworfen und das Tool nicht ausgeführt. `-NoDownload`
verhindert jeden Download; fehlende Tools degradieren die jeweilige Stage zu
`SKIPPED`/`UNSUPPORTED`.

Entdeckte Besonderheit: SourceForges Auto-Mirror-Redirector (`/download`-URLs) liefert
PowerShells `Invoke-WebRequest` mit Standard-User-Agent eine HTML-Zwischenseite statt der
Datei; ein curl-artiger User-Agent behebt das zuverlässig (siehe Kommentar in
`ToolManager.psm1`).

## 5. GPU-Compute-Architektur

Da im Build-Environment weder Vulkan-Runtime noch NuGet/dotnet-SDK verfügbar waren, wurde
ein Direct3D-11-Compute-Pfad direkt per P/Invoke implementiert (`D3D11ComputeVerifier.cs`):

- `D3D11CreateDevice` (d3d11.dll) mit Fallback auf WARP.
- `D3DCompile` (d3dcompiler_47.dll) kompiliert einen eingebetteten HLSL-Compute-Shader
  zur Laufzeit.
- COM-Interfaces (`ID3D11Device`, `ID3D11DeviceContext`, `ID3D10Blob`) werden über direkten
  Vtable-Zugriff (`Marshal.GetDelegateForFunctionPointer` auf berechnete Slot-Indizes)
  angesprochen, statt vollständige COM-Interop-Interfaces zu deklarieren. Die
  Slot-Indizes wurden gegen den WIDL-generierten, Microsoft-SDK-treuen
  `mingw-w64`-Header (`d3d11.h`, `d3dcompiler.h`) verifiziert, nicht geraten.
- Verifikations-Workload: 32-Bit-Integer Rotate/XOR/Multiply-Add, bitgenau mit einer
  identischen C#-CPU-Referenzfunktion vergleichbar (keine Fließkomma-Toleranzprobleme).
- Real getestet gegen Intel UHD 730 (Feature Level 11_0), bis 65536 Elemente, 0 Mismatches,
  inklusive Sustained-Load-Schleife für GPU Load/Thermal Validation.

## 6. Storage-Safety

`RawDiskReader.cs` öffnet `\\.\PhysicalDriveN` ausschließlich mit `GENERIC_READ`
(`CreateFile` P/Invoke). Automatisiert geprüft (Gate HS-027/028/029): weder
`GENERIC_WRITE` noch `WriteFile(` noch `FileAccess.Write` kommen im Code vor.
`StorageWriteVerify.psm1` arbeitet ausschließlich mit einer normalen temporären Datei.

## 7. Eventlog-/Recovery-Architektur

`EventCorrelation.psm1` enthält aus `PCDiagLite.ps1` adaptierte (nicht wortwörtlich
kopierte, aber nach demselben geprüften Algorithmus arbeitende) Funktionen für
Event-1074-Parsing und BugCheck-Extraktion. `CrashRecovery.psm1` implementiert
`PendingRun.json` (`C:\ProgramData\PC-Diagnose\HardwareStability\`) und die
SYSTEM_RESET/PLANNED-Klassifikation über Kernel-Power 41, EventLog 6005/6006/6008,
User32 1074, BugCheck 1001.

## 8. Fixture-Ergebnisse

`tests/HardwareStability/HardwareStability.Fixtures.Tests.ps1`: **40/40 Assertions PASS**
(letzter Lauf siehe `LOCAL_LLM_TEST_RESULTS.txt`).

`tests/HardwareStability/Validate-HardwareStability.ps1`: **10/10 Gates PASS, Exitcode 0**.

## 9. Tatsächlich ausgeführte reale Smoke-Tests

Siehe `docs/HARDWARE_STABILITY_STATE.md` Abschnitt "Reale Validierung auf dieser
Maschine" für die vollständige Liste. Kurzfassung: echte RAM-Verifikation, echter
Prime95-Torture-Start mit gemessener CPU-Last, echte D3D11-GPU-Compute-Dispatches, echte
SMART-Abfrage der produktiven NVMe und eines USB-Laufwerks, echter Storage-Write/Read/
CRC32-Zyklus, echter (nicht-elevierter, korrekt SKIPPED) PhysicalDrive-Zugriffsversuch,
alle 5 Drittanbieter-Downloads real verifiziert.

## 10. Coverage-Beispiele (real gemessen)

- GPU Compute: bis zu 65.536 Integer-Operationen pro Lauf verifiziert, 0 Mismatches.
- Storage Write/Read: 32 MB geschrieben/gelesen/CRC32-verifiziert, 0 Mismatches.
- RAM: 1 Pass gegen 1% des physischen RAM (Smoke-Test-Parameter), 0 Fehler.

## 11. Regressionstests

`tests/HDMIDiagnose.Tests.ps1` läuft weiterhin fehlerfrei durch (automatisiert als
HS-048 im Validate-Runner). `PCDiagLite.ps1`, `NetzwerkDiagnose.ps1` wurden nicht
verändert; ihre Syntaxgültigkeit ist über HS-001 (Parse-Check aller .ps1/.psm1-Dateien)
mitabgedeckt.

## 12. Bekannte Einschränkungen / BLOCKED

Siehe `docs/HARDWARE_STABILITY_ACCEPTANCE.md`: 5 von 50 Gates sind BLOCKED
(HS-017, HS-018, HS-019, HS-026, HS-038) - jeweils mit Begründung, vorhandenem
Code-Pfad und warum eine reale Erzwingung in dieser Umgebung nicht sicher/sinnvoll war
(kein echter GPU-Treiberabsturz auf Produktivhardware erzwungen, keine interaktive
UAC-Bestätigung für vollständig elevierten End-to-End-Lauf möglich).

PCDiagLite.ps1 wurde bewusst **nicht** refaktoriert, um die gemeinsame Eventlog-Logik zu
teilen (siehe `docs/HARDWARE_STABILITY_STATE.md` für die Begründung) - eine
Parallelarchitektur mit an PCDiagLite angelehnter, aber unabhängiger Logik in
`EventCorrelation.psm1` wurde als das geringere Risiko bewertet.

## 13. git status / git diff --check

Siehe `LOCAL_LLM_TEST_RESULTS.txt` für den finalen `git status` und
`git diff --check`-Output vor dem Commit.
