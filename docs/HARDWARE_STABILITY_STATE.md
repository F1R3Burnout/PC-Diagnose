# Hardware-Stabilitätstest — Projektstatus

Letztes Update: 2026-11-26 (Telemetrie unter PS 5.1, Review-Fixes, PCDiagLite-Tests)

## Nachtrag 2026-11-26 (2) — Bedienung: Dauer, Fortschritt, Wiederholung

- Start ohne `-Profile`: Auswahl Kurz/Mittel/Lang (Quick/Standard/Extended) mit
  geschätzten Minuten der Lastphasen. Der Starter erzwingt nicht mehr Quick und
  reicht Profil/Komponenten/Optionen jetzt auch über die UAC-Erhöhung weiter
  (gingen vorher verloren).
- Fortschritt: Gesamtbalken + Balken je Phase (echte Prozente für Surface-Scan,
  Schreib-/Lesetest, RAM-Durchläufe, SMART-Selbsttest, GPU Compute; Zeitanteil
  für Prime95, VRAM, GPU-Last, Systemtest).
- System Stability belastet jetzt CPU + GPU + RAM gleichzeitig.
- Nach dem Lauf: auffällige Phasen gezielt wiederholen (10/30/60 Min. oder
  eigene Dauer), Ergebnisse als "(Retest n, x min)" im selben Bericht.
- Weitere Fixes: RAM-Exitcode 1 ohne "Memory corrupted" = BLOCKED statt FAIL;
  NVMe-Selbsttest "in progress" wurde nicht erkannt; Surface-Scan nahm pro 4 MB
  eine Sensormessung; CRC32 in C#.
- CI: zusätzlicher echter End-to-End-Lauf unter PS 5.1 mit 30-s-Phasen und
  automatischer Wiederholung (GitHub-Runner: Prime95-Server nicht erreichbar,
  virtuelle Platten ohne SMART/Rohzugriff - dort korrekt SKIPPED/UNSUPPORTED).
- Noch offen: Bedienung (Auswahlmenü, Wiederholungsfrage, Fortschrittsbalken)
  real in einer elevierten Konsole ansehen.

## Nachtrag 2026-11-26 — Branch `feature/telemetry-ps51-pcdiaglite-tests`

Status: implementiert, **noch nicht real auf Windows verifiziert** (die
Entwicklungsumgebung hatte kein PowerShell). CI prüft Parse und die neuen
PCDiagLite-Tests; Fixture-Suite und ein elevierter Quick-Lauf unter
`powershell.exe` 5.1 stehen noch aus.

### Telemetrie unter Windows PowerShell 5.1

- Ursache des alten Fehlers: `Add-Type -Path` ruft `Assembly.GetTypes()` auf und
  scheitert unter .NET Framework an jeder fehlenden optionalen Abhängigkeit.
- Neu: unter PS 5.1 wird der `net472`-Build per `[Reflection.Assembly]::LoadFrom`
  geladen; seine .NET-Framework-Abhängigkeiten (System.Memory, System.Buffers,
  System.Numerics.Vectors, System.Runtime.CompilerServices.Unsafe,
  System.Threading.AccessControl, System.Security.AccessControl,
  System.Security.Principal.Windows) kommen als eigene Einträge in
  `config/HardwareStabilityTools.json`, geprüft gegen den von nuget.org
  veröffentlichten SHA512-Pakethash. Ein kleiner C#-AssemblyResolve-Handler
  ersetzt die fehlenden Binding-Redirects und protokolliert, was trotzdem fehlt.
- PowerShell 7 bleibt unverändert beim `netstandard2.0`-Build mit `Add-Type`.
- **Wichtig:** LibreHardwareMonitor ab 0.9.5 liest CPU-Temperatur und alle
  Mainboard-/VRM-Sensoren nur über den separat zu installierenden
  **PawnIO-Treiber**. Ohne PawnIO gibt es auch mit funktionierender Bibliothek
  keine CPU-Temperatur (GPU-Temperaturen über die Herstellertreiber dagegen
  schon). Das Tool installiert bewusst keinen Treiber, sondern meldet es im
  Report-Abschnitt "Temperature monitoring" und in
  `02_Telemetry\TelemetryStatus.json`.

### Review-Fixes

- Prime95, das sich vor Ablauf der geplanten Dauer ohne Fehler beendet, ergab
  PASS - jetzt BLOCKED.
- System Stability ergab PASS, auch wenn Prime95 übersprungen wurde oder die
  GPU-Last nicht lief - jetzt nur noch PASS, wenn beide Teile PASS sind.
  Das CPU-Log überschreibt nicht mehr das der CPU-Compute-Stage.
- Storage SMART lief nur auf der zuerst aufgezählten Platte (auf der X670E ein
  USB-Laufwerk, die NVMe blieb ungeprüft). Jetzt alle Platten, Windows-Platte
  zuerst; Self-Test und Surface Scan auf der Windows-Platte.
- Tool-Downloads ohne konfigurierten Hash werden verweigert (vorher
  ungeprüft akzeptiert).
- Validate-Runner führt die Fixture-Suite zusätzlich unter `powershell.exe` 5.1 aus.

### PCDiagLite-Regressionstests

`tests/PCDiagLite.RestartShutdown.Tests.ps1` lädt nur die reinen
Hilfsfunktionen aus `PCDiagLite.ps1` (per AST, ohne das Skript auszuführen) und
prüft die Neustart-/Shutdown-Klassifikation mit Fixture-Events. Damit ist die
Voraussetzung für den empfohlenen Refactor auf `EventCorrelation.psm1`
geschaffen; der Refactor selbst ist noch nicht gemacht.


## Aktuelle Phase

ABGESCHLOSSEN UND REAL END-TO-END BESTÄTIGT. Der erste echte, voll elevierte Lauf durch
den Nutzer selbst (über `irm .../r|iex`) deckte fünf reale Bugs auf, die in der
Entwicklungssession unentdeckt blieben, weil dort ausschließlich unter PowerShell 7
(`pwsh`) getestet wurde, während die Elevation in `bootstrap.ps1` bewusst
`powershell.exe` (Windows PowerShell 5.1, .NET Framework) startet, da das auf jeder
Windows-Installation vorhanden ist. Alle Bugs sind behoben. Ein vollständiger,
elevierter Quick-Profil-Lauf auf X470-SERVER (Run `PCStability_X470-SERVER_20260918_132338`,
~22 Minuten) endete mit **Overall: PASS** über alle Stages (CPU Compute, CPU Cache/IMC,
RAM, GPU Compute, GPU Load/Thermal, Storage SMART, Storage Write/Read Verification,
PCIe/WHEA, System Stability - VRAM korrekt UNSUPPORTED mangels Vulkan-Runtime, Storage
Surface Read korrekt SKIPPED da im Quick-Profil deaktiviert). Damit ist der komplette
Pfad einmal real durch die tatsächliche Produktionsumgebung (elevierte Windows
PowerShell 5.1 via `bootstrap.ps1`) bestätigt, nicht nur durch Fixtures/pwsh.

**Zweite Maschine bestätigt (AMD X670E-Plattform, User "olive", Run
`PCStability_X670E_20260918_132907`, ~28 Minuten):** ebenfalls **Overall: PASS**, und
zusätzlich der erste reale Beleg für den VRAM-Pfad (`memtest_vulkan`, 6 Minuten, PASS,
0 Fehler) sowie GPU Load/Thermal mit 1657 Iterationen - beides auf X470-SERVER mangels
Vulkan-Runtime nie real auslösbar. HS-014 (CPU_COMPUTE 8 Worker vs. CPU_CACHE_IMC 16
Worker) ebenfalls auf echter, anderer Hardware bestätigt. Storage SMART dort
UNSUPPORTED (PhysicalDrive2, vermutlich USB/RAID-angebunden) statt PASS - korrektes
Verhalten, keine Regression. Damit ist das Projekt auf zwei unterschiedlichen realen
Systemen End-to-End validiert.

### Alle real gefundenen und behobenen Bugs (chronologisch)

1. `ProcessStartInfo.ArgumentList` existiert nicht unter .NET Framework (RAM, SMART).
2. Leeres Array wird bei `return` zu `$null`, Bindung an Mandatory-Parameter schlägt fehl
   (CPU/GPU-Thermal-Check, System Stability).
3. Downloaddatei-Namensgebung: URL endend auf Versionsnummer (`.../0.9.6`) wurde
   fälschlich als "hat Endung .6" erkannt (Telemetrie-Download unter PS5.1).
4. `$null`-Element wurde per `+=` in ein Telemetrie-Array injiziert, wenn ein
   Hardware-Objekt keine Sensoren hatte (`Get-HsHardwareSensorRows`).
5. Eigene, zu vorsichtige `@()`-Nachrüstung um bereits Komma-geschützte Funktionsaufrufe
   verursachte doppelte Array-Verschachtelung (zwei separate Stellen: innerhalb
   `Telemetry.psm1` und in `HardwareStability.ps1`s `Test-HsThermalAbortOrCancel`/
   Idle-Baseline-Pfad).
6. `bootstrap.ps1` nutzte die GitHub-REST-Contents-API (60 Anfragen/Stunde/IP) statt
   `raw.githubusercontent.com` zum Laden jeder Datei - bei 19 Dateien pro
   Hardwarestability-Lauf nach 2-3 Versuchen aufgebraucht ("API rate limit exceeded").
7. `-EncodedCommand`-basierte Selbst-Elevation wurde von Windows Defenders ML-Heuristik
   als "Trojan:Win32/Commando.A!ml" fehlklassifiziert (False Positive); auf eine
   lesbare temporäre `.ps1`-Datei mit `-File` umgestellt.

Alle Fixes wurden sowohl unter `pwsh` als auch real unter `powershell.exe` 5.1 verifiziert
(40/40 Fixtures unter beiden Hosts), zusätzlich zum finalen echten Elevated-Gesamtlauf.

### Bekannte, akzeptierte Restlimitierung

Telemetrie (LibreHardwareMonitorLib) lädt unter Windows PowerShell 5.1 weiterhin nicht
(fehlende optionale NuGet-Abhängigkeiten, .NET Framework validiert beim Laden strikter
als .NET Core). Das führt zu `Telemetry available: False` im produktiven Elevation-Pfad,
degradiert aber sauber (kein Crash, siehe die vorherigen Fixes) - der Thermal Guard hat
dadurch aktuell keine echten Live-Temperaturen. Für Quick-Profil unkritisch; vor
intensiverem Standard/Extended-Einsatz sollte das nachgezogen werden (siehe unten).

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
- README, SPEC/STATE/ACCEPTANCE-Dokumente, `docs/history/HARDWARE_STABILITY_IMPLEMENTATION_REPORT_2026-09.md`,
  `docs/history/HARDWARE_STABILITY_TEST_RESULTS_2026-09.txt`.

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

Erledigt: PR #1 gemerged nach `main`, vollständiger elevierter Quick-Profil-Lauf auf
echter Produktionshardware bestätigt PASS. Offene, freiwillige Folgepunkte:

- ~~Telemetrie unter Windows PowerShell 5.1 zum Laufen bringen~~ - umgesetzt
  im Nachtrag 2026-11-26, reale Verifikation steht noch aus. CPU-Temperatur
  braucht zusätzlich PawnIO.
- `kiwus-it.de/r` (Wix-Weiterleitung) zeigt zeitweise noch veraltete Inhalte -
  vermutlich Client- oder Wix-seitiges Caching des 301/302-Redirects; nicht im
  Code behebbar, siehe Chat-Verlauf für Diagnosehinweise.
- Standard-/Extended-Profil-Läufe (deutlich länger) noch nicht real eleviert
  durchgeführt - nur Quick verifiziert.
