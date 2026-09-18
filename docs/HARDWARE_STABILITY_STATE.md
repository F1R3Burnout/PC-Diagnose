# Hardware-Stabilitätstest — Projektstatus

Letztes Update: 2026-09-18 (Nachtrag: reale Elevated-Läufe auf X470-SERVER)

## Aktuelle Phase

NACHBESSERUNG NACH REALEM ELEVATED-LAUF. Der erste echte, voll elevierte Lauf durch den
Nutzer selbst (über `irm https://kiwus-it.de/r|iex`) deckte drei reale Bugs auf, die in
der Entwicklungssession unentdeckt blieben, weil dort ausschließlich unter PowerShell 7
(`pwsh`) getestet wurde. Die Elevation in `bootstrap.ps1` startet aber bewusst
`powershell.exe` (Windows PowerShell 5.1, .NET Framework), da das auf jeder
Windows-Installation vorhanden ist. Alle drei Bugs sind behoben und sowohl unter `pwsh`
als auch real unter `powershell.exe` 5.1 verifiziert (40/40 Fixtures bestehen unter
beiden Hosts).

### Gefundene und behobene Bugs (realer Lauf 1: PCStability_X470-SERVER_20260918_092824)

1. **`ProcessStartInfo.ArgumentList` existiert nicht unter .NET Framework** (nur unter
   .NET Core/.NET 5+). `Invoke-HsProcess` nutzte diese Property blind, was RAM
   (MemoryChecker) und Storage SMART (smartctl) unter der echten Elevation mit
   "Die Eigenschaft 'ArgumentList' wurde für dieses Objekt nicht gefunden" abstürzen
   ließ. Fix: eigene Win32-konforme Argument-Quoting-Funktion
   (`ConvertTo-HsWin32ArgumentString`) baut jetzt `.Arguments` (String) — funktioniert
   unter beiden Hosts. Real unter PS5.1 gegen echtes RAM und die echte NVMe verifiziert.
2. **Leeres Array wird beim Return zu `$null`**: `Get-HsTelemetrySample` gab bei
   nicht verfügbarer Telemetrie ein leeres Array zurück, das PowerShell beim Zuweisen
   am Aufrufer zu `$null` kollabierte (bekanntes PowerShell-Verhalten). `$null` ließ
   sich nicht an `Test-HsThermalState`s `[Parameter(Mandatory=$true)][object[]]$Rows`
   binden, wodurch CPU Compute, CPU Cache/IMC, GPU Load/Thermal und System Stability
   mit "BLOCKED" abbrachen, sobald Telemetrie fehlte. Fix: `return ,$rows` (Komma
   erzwingt Array-Rückgabe) an der Quelle plus defensive `[AllowNull()]` +
   Null-zu-leer-Array-Behandlung in `Test-HsThermalState` selbst.
3. **Downloaddatei-Namensgebung**: Für URLs, die auf eine reine Versionsnummer enden
   (z. B. `.../LibreHardwareMonitorLib/0.9.6`), erkannte `[IO.Path]::HasExtension()`
   fälschlich ".6" als Dateiendung, wodurch keine erzwungene ".zip"-Endung gesetzt
   wurde. `Expand-Archive` unter Windows PowerShell 5.1 verweigerte die Datei daraufhin
   strikt ("'.6' ist kein unterstütztes Archivdateiformat") — PowerShell 7s
   `Expand-Archive` war hier nachsichtiger. Fix: Dateiname wird jetzt immer strikt aus
   dem konfigurierten `archiveType` abgeleitet, nie aus der URL geraten.

### Bekannte verbleibende Einschränkung: Telemetrie unter PowerShell 5.1

Nach Fix 3 lädt sich die ZIP-Datei korrekt, aber `Add-Type -Path LibreHardwareMonitorLib.dll`
schlägt unter .NET Framework (PS5.1) weiterhin fehl: `ReflectionTypeLoadException` wegen
fehlender optionaler Abhängigkeiten (`RAMSPDToolkit-NDD`, `DiskInfoToolkit`,
`System.IO.Ports`). Unter .NET Core (PS7) lädt dieselbe DLL erfolgreich, da dort Typen
lazy (erst bei tatsächlicher Nutzung) aufgelöst werden; .NET Framework validiert beim
Laden dagegen alle referenzierten Assemblies sofort. `Initialize-HsTelemetry` fängt
diesen Fehler bereits sauber ab (`Initialized: False`, kein Crash) — der Thermal Guard
läuft dadurch aber unter dem produktiven Elevation-Pfad (PS5.1) derzeit ohne echte
Live-Sensordaten, was den Sicherheitsspielraum bei längeren CPU/GPU-Lasttests
(Standard/Extended-Profil) reduziert. Nicht in dieser Nachbesserung behoben (Aufwand:
alle fehlenden optionalen NuGet-Abhängigkeiten zusätzlich vendoren, oder plattform-
spezifisch `net472`- statt `netstandard2.0`-Build laden) - als offener Folgepunkt
dokumentiert.

## Erledigt

Vollständige Implementierung, siehe `docs/HARDWARE_STABILITY_ACCEPTANCE.md` für den
gateweisen Status (45/50 PASS, 5 BLOCKED mit Begründung).

- Architektur: `lib/HardwareStability/*.psm1` (Common, ProcessRunner, ToolManager,
  Profiles, Inventory, Telemetry, ThermalGuard, EventCorrelation, CrashRecovery,
  CpuTests, MemoryTests, GpuTests, StorageTests, StorageSurface, StorageWriteVerify,
  Reporting) + `lib/HardwareStability/Native/*.cs` (RawDiskReader, D3D11ComputeVerifier).
- Hauptskript `scripts/diagnostics/HardwareStability.ps1` mit internem Menü-Fluss über
  `-Components`, CLI-Parametern (`-Profile`, `-Components`, `-OutputRoot`, `-NoDownload`,
  `-SkipTelemetry`, `-Resume`, `-DryRun`, `-SurfaceScanMaxBytes`), DryRun ohne
  Verzeichnis-/Prozess-Nebenwirkungen.
- `manifest.json` und `bootstrap.ps1`/`r` (identisch gehalten) um `hardwarestability`
  erweitert; Bootstrap-Dependency-Caching wurde von flacher Ablage (nur Dateiname) auf
  strukturerhaltende Ablage umgestellt (nötig, weil dieses Tool - anders als HDMIDiagnose -
  Unterordner wie `Native/` und `config/` referenziert). Real gegen eine simulierte
  Bootstrap-Cache-Struktur getestet.
- `config/HardwareStabilityTools.json`: MemoryChecker 1.2.3 (CC0-1.0), Prime95 30.19
  Build 20 (Freeware), memtest_vulkan 0.5.0 (Zlib), smartmontools 7.5 (GPL-2.0),
  LibreHardwareMonitorLib 0.9.6 (MPL-2.0) - alle mit Version, offizieller Quelle, Hash
  und Lizenz. Alle fünf Downloads real gegen ihre offiziellen Quellen getestet.
- Fixture-Suite `tests/HardwareStability/HardwareStability.Fixtures.Tests.ps1`
  (40 Assertions, aktuell 40/40 PASS) + Runner
  `tests/HardwareStability/Validate-HardwareStability.ps1` (10 Gates, aktuell alle PASS,
  Exitcode 0).
- README, SPEC/STATE/ACCEPTANCE-Dokumente, `LOCAL_LLM_IMPLEMENTATION_REPORT.md`,
  `LOCAL_LLM_TEST_RESULTS.txt`.

## Reale Validierung auf dieser Maschine (X470-SERVER)

Diese Session lief nachweislich auf echter physischer Hardware (Gigabyte B760M DS3H,
Intel Core i5-14400, 32GB RAM gemischter Hersteller, Samsung SSD 970 EVO Plus 500GB,
Intel UHD 730 iGPU + virtuelle RDP-Displayadapter), erreichbar über eine
nicht-interaktive Remote-Session ohne UAC-Möglichkeit (siehe "Bekannte Einschränkungen").
Real (nicht nur simuliert) getestet:

- RAM-Verifikation: echter MemoryChecker-Lauf gegen echtes RAM, PASS, 0 Fehler.
- CPU: echter Prime95-Torture-Test-Start (`-t`), echte Prozessorlast über alle 16
  logischen Prozessoren gemessen (TotalProcessorTime), sauber gestoppt.
- GPU Compute: echte D3D11-Compute-Dispatches gegen Intel UHD 730 (Feature Level
  0xB000/11_0), bis 65536 Elemente, 0 Mismatches über mehrere Läufe, inkl. Sustained-Load-
  Schleife (45 Iterationen in 5s).
- VRAM (memtest_vulkan): korrekt UNSUPPORTED, da auf dieser Maschine keine
  `vulkan-1.dll`/Vulkan-Runtime installiert ist - genau der spezifizierte
  Nichtabsturz-Pfad.
- Storage SMART: echte Abfrage der realen NVMe (PASSED, 52°C, 8% used) und des USB-
  Laufwerks (korrekt UNSUPPORTED statt FAIL).
- Storage Surface Read: echter Lese-Loop (P/Invoke CreateFile/ReadFile) gegen eine reale
  10MB-Testdatei über denselben nativen Code, 0 Fehler; echter Zugriff auf
  `\\.\PhysicalDrive0` scheiterte korrekt mit SKIPPED ("Zugriffs verweigert"), da diese
  Session nicht eleviert ist (erwartetes, spezifiziertes Verhalten ohne Admin-Rechte).
- Storage Write/Read Verification: 32MB realer Schreib-/Lese-/CRC32-Zyklus, PASS,
  Testdatei danach entfernt.
- Tool-Download/Hash-Verifikation: alle 5 Tools real heruntergeladen und verifiziert.

## Zwei während der Implementierung gefundene und behobene Bugs

1. **Process-Registry-Inkonsistenz über Modul-Instanzen hinweg**: Da mehrere
   Geschwister-Module (`CpuTests`, `MemoryTests`, `GpuTests`, `StorageTests`, ...) jeweils
   selbst `Import-Module ProcessRunner.psm1 -Force` ausführen, entstand pro Reimport eine
   neue Modul-Instanz mit eigenem `$script:`-Scope. Aufrufe von `Register-HsProcess`/
   `Unregister-HsProcess` aus einer älteren Instanz heraus lösten sich gegen die zuletzt
   geladene (globale) Instanz auf, wodurch zwei unterschiedliche Registries entstanden und
   `Unregister-HsProcess` unter `Set-StrictMode` mit "Eigenschaft ProcessId nicht gefunden"
   fehlschlug. Fix: Registry liegt jetzt in einer einzigen `$global:`-Variable statt
   `$script:`, siehe Kommentar in `lib/HardwareStability/ProcessRunner.psm1`.
2. **Gleicher Effekt bei `$moduleDir` in `GpuTests.psm1`**: `Initialize-HsD3D11ComputeVerifier`
   nutzte die gemeinsame Top-Level-Variable `$moduleDir`, die durch denselben
   Reimport-Mechanismus null werden konnte. Fix: direkter Gebrauch von `$PSScriptRoot`
   (automatische, dateibezogene Variable) statt der gemeinsam benannten Variable.
3. Prime95-Fixture-Monitoring prüfte `results.txt` erst NACH dem `HasExited`-Check, wodurch
   ein schneller Testlauf sein Ergebnis nie auswertete. Fix: Reihenfolge vertauscht.

Alle drei Fixes wurden durch erneuten Lauf der Fixture-Suite verifiziert (0 Fehler danach).

## Architekturentscheidung: PCDiagLite NICHT refaktoriert

`lib/HardwareStability/EventCorrelation.psm1` enthält aus PCDiagLite.ps1 adaptierte
(nicht identische, aber nach demselben bewährten Algorithmus arbeitende) Funktionen für
Event-1074-Parsing, BugCheck-Code-Extraktion und Event-Normalisierung. PCDiagLite.ps1
selbst wurde bewusst NICHT umgestellt, dieses gemeinsame Modul zu importieren:

- PCDiagLite besitzt keine automatisierte Verhaltens-Testsuite (nur Parse-Check in CI),
  die eine Verhaltensänderung durch einen Refactor zuverlässig aufgedeckt hätte.
- Ein 6000+ Zeilen Produktionsskript ohne Sicherheitsnetz unter Zeitdruck umzubauen wurde
  als höheres Risiko bewertet als der Nutzen der Code-Deduplizierung.
- PCDiagLite.ps1 wurde in diesem Auftrag nicht verändert; HS-048 (Regressionstest)
  bestätigt, dass die bestehenden Tools unverändert funktionieren.

Empfehlung für einen Folgeauftrag: zuerst eine Fixture-basierte Regressionssuite für
PCDiagLites Restart-/Shutdown-Klassifikation aufbauen (analog zu
`HardwareStability.Fixtures.Tests.ps1`), dann den Refactor sicher durchführen.

## Bekannte Einschränkungen / BLOCKED (siehe ACCEPTANCE.md für Details)

- HS-017/018/019: Unsupported-Pfad für GPU_COMPUTE selbst sowie Device-Lost/TDR-Erkennung
  sind implementiert und code-reviewed (strukturell identisch zum real verifizierten
  UNSUPPORTED-Pfad von VRAM), aber nicht durch einen echten Fehlerzustand ausgelöst worden
  - auf der verfügbaren Testhardware war D3D11 durchgehend verfügbar und ein echter TDR
    wurde bewusst nicht erzwungen (reale Produktivmaschine).
- HS-026: Surface Read Error => FAIL folgt dem Standard-Win32-Fehlerpfad (Code-Review),
  wurde aber nicht durch einen echten I/O-Fehler ausgelöst.
- HS-038: Ctrl+C-Handling ist über Prozess-Registry + `PowerShell.Exiting`-Engine-Event +
  try/finally implementiert; ein echtes Ctrl+C-Signal ließ sich in dieser
  nicht-interaktiven Remote-Session nicht sicher auslösen. Der CancelCheck-basierte
  Abbruchpfad, der dieselbe Aufräum-Funktion nutzt, wurde real getestet (Timeout-Pfad,
  HS-039).
- Volle elevierte End-to-End-Ausführung von `HardwareStability.ps1` (kompletter,
  nicht-DryRun-Lauf mit allen Stages) wurde nicht in dieser Session durchgeführt: die
  Session ist nicht administrativ elevierbar (`Start-Process -Verb RunAs` schlägt mit
  "Vorgang durch Benutzer abgebrochen" fehl, da niemand einen UAC-Dialog auf der Remote-
  Session bestätigen kann). Jede einzelne Komponente wurde stattdessen isoliert real
  getestet (siehe oben); DryRun (kein Admin nötig) wurde vollständig end-to-end
  durchlaufen, inklusive über eine simulierte Bootstrap-Cache-Struktur.

## Nächster Arbeitsschritt

PR eröffnet: https://github.com/F1R3Burnout/PC-Diagnose/pull/1 (CI "syntax" grün).
Von Nutzer/Reviewer: einmal `HardwareStability.ps1 -Profile Quick` eleviert auf einer
Testmaschine ausführen, um den vollen orchestrierten Lauf (alle Stages, echtes Ergebnis-
Package, ZIP) zu bestätigen, sowie PR-Review.
