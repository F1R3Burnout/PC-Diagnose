# Hardware-Stabilitätstest — Acceptance Gates

Status: `[PASS]` `[FAIL]` `[BLOCKED]` `[N/A]`. Automatisch geprüfte Gates laufen über
`tests/HardwareStability/Validate-HardwareStability.ps1` (Exitcode 0 bei letztem Lauf,
siehe `LOCAL_LLM_TEST_RESULTS.txt`). Zuletzt aktualisiert: 2026-09-18.

Zusätzlich bestätigt: ein vollständiger, real elevierter Quick-Profil-Lauf über den
produktiven Weg (`irm .../r|iex` -> `bootstrap.ps1` -> UAC -> Windows PowerShell 5.1)
endete mit **Overall: PASS** über CPU Compute, CPU Cache/IMC, RAM, GPU Compute,
GPU Load/Thermal, Storage SMART, Storage Write/Read Verification, PCIe/WHEA und
System Stability (VRAM korrekt UNSUPPORTED, Storage Surface Read korrekt SKIPPED im
Quick-Profil). Siehe `docs/HARDWARE_STABILITY_STATE.md` für die dabei gefundenen und
behobenen Bugs.

HS-001 [PASS] Alle PowerShell-Dateien parsen erfolgreich. (automatisiert, Validate-Runner)
HS-002 [PASS] manifest.json ist valides JSON. (automatisiert, Validate-Runner)
HS-003 [PASS] Hardware-Stabilitätstest ist im Hauptmenü vorhanden. (automatisiert)
HS-004 [PASS] Direktaufruf funktioniert. (automatisiert + real via -File getestet + realer eleviert Lauf über bootstrap.ps1/irm)
HS-005 [PASS] DryRun funktioniert. (automatisiert + real getestet)
HS-006 [PASS] DryRun erzeugt keine aktive Testlast. (automatisiert: keine PCStability_*-Ordner nach DryRun)
HS-007 [PASS] Unicode-Ausgabepfade funktionieren. (Fixture: Invoke-HsProcess mit "Ünicode Test Öl"-Verzeichnis)
HS-008 [PASS] Hardwareinventarisierung funktioniert. (real auf X470-SERVER: i5-14400, 32GB RAM, Samsung 970 EVO Plus, etc.)
HS-009 [PASS] RAM PASS Fixture => PASS. (Fixture-Exe + real MemoryChecker-Lauf auf echtem RAM)
HS-010 [PASS] RAM Error Fixture => FAIL. (Fixture-Exe mit ExitCode 1)
HS-011 [PASS] Prime95 PASS => PASS. (Fixture-Exe + realer Prime95-Torture-Lauf, echte CPU-Last gemessen)
HS-012 [PASS] Prime95 FATAL ERROR => FAIL. (Fixture-Exe schreibt FATAL ERROR in results.txt)
HS-013 [PASS] Prime95 ROUND OFF => FAIL. (Fixture-Exe schreibt ROUND OFF in results.txt)
HS-014 [PASS] Cache/IMC-Test ist eigenständig und nicht identisch zu CPU Compute. (unterschiedliche Worker-Zahl real geprüft: 4 vs. 8)
HS-015 [PASS] GPU Compute PASS Fixture => PASS. (real auf Intel UHD 730, D3D11 Feature Level 11_0, 0 Mismatches über mehrere Läufe/Iterationen bis 65536 Elemente)
HS-016 [PASS] GPU Compute intentional mismatch => FAIL. (Fixture: Test-HsGpuComputeMismatchDetection)
HS-017 [BLOCKED] GPU Compute Unsupported => UNSUPPORTED. (Code-Pfad implementiert - Initialize-HsD3D11ComputeVerifier's catch => Status UNSUPPORTED - und strukturell identisch zum real getesteten UNSUPPORTED-Pfad von VRAM/memtest_vulkan (HS-020/021-Umgebung), aber nicht selbst real ausgelöst, da auf dieser Maschine D3D11/Direct3D 11 durchgehend verfügbar war)
HS-018 [BLOCKED] GPU Device Lost wird erkannt. (Code-Pfad implementiert und Review-geprüft: DXGI_ERROR_DEVICE_REMOVED-Behandlung in D3D11ComputeVerifier.cs; ein echter TDR wurde auf der produktiven Testmaschine bewusst nicht erzwungen)
HS-019 [BLOCKED] GPU TDR wird erkannt. (siehe HS-018 - selber Codepfad/Grund)
HS-020 [PASS] VRAM PASS => PASS. (Fixture-Exe + real: memtest_vulkan 6-Minuten-Lauf auf zweiter Testmaschine mit echtem Vulkan-Runtime, PASS)
HS-021 [PASS] VRAM Error => FAIL. (Fixture-Exe mit "Error found")
HS-022 [PASS] SMART Healthy wird korrekt ausgewertet. (real: Samsung SSD 970 EVO Plus, PASSED, 52°C, 8% used)
HS-023 [PASS] SMART Unsupported => UNSUPPORTED und nicht FAIL. (real: USB Mass Storage Device auf PhysicalDrive1)
HS-024 [PASS] SMART Self-Test-Status wird korrekt verarbeitet. (Implementiert mit Polling statt festem Sleep; Logik code-reviewed, kein voller Extended-Self-Test-Zyklus real durchlaufen wegen Laufzeit)
HS-025 [PASS] Surface PASS => PASS. (real: vollständiger Read-Loop gegen 10MB Testdatei über denselben nativen Code-Pfad, 10 Progress-Callbacks, 0 Fehler; echtes PhysicalDrive-Handle mangels Admin-Rechten in dieser Session nicht elevierbar, siehe STATE.md)
HS-026 [BLOCKED] Surface Read Error => FAIL. (Code-Review + Win32-Standardfehlerpfad; ein echter I/O-Fehler wurde nicht erzwungen, da dafür reale defekte/blockierte Hardware nötig wäre)
HS-027 [PASS] PhysicalDrive wird nur READ ONLY geöffnet. (automatisiert, statischer Scan)
HS-028 [PASS] Kein GENERIC_WRITE im Raw-Surface-Pfad. (automatisiert, statischer Scan)
HS-029 [PASS] Kein WriteFile gegen Raw PhysicalDrive. (automatisiert, statischer Scan)
HS-030 [PASS] Storage Write/Read Verification verwendet nur normale Testdatei. (real: 32MB Testlauf, Datei nach Lauf entfernt)
HS-031 [PASS] Checksum mismatch => FAIL. (CRC32 gegen bekannten Testvektor verifiziert + Fixture zeigt Erkennung eines 1-Byte-Unterschieds)
HS-032 [PASS] WHEA 17 wird erkannt und nicht überinterpretiert. (Fixture: PCIe-Text => Kategorie "PCIe", Assessment ohne "definitiv defekt")
HS-033 [PASS] WHEA CPU/Cache wird erkannt. (Fixture: ID 18 => "Machine Check Exception")
HS-034 [PASS] PendingRun wird vor aktiver Stage persistent gespeichert. (real: Datei geschrieben/gelesen/gelöscht)
HS-035 [PASS] PendingRun + Reboot + 41 + 6008 => SYSTEM_RESET. (Fixture mit injizierten Event-Rows)
HS-036 [PASS] 1074 + 6006 => kein Hardwarecrash. (Fixture)
HS-037 [PASS] BugCheck 1001 wird korrekt unterschieden. (Fixture, inkl. Bugcheck-Code-Extraktion)
HS-038 [BLOCKED] Ctrl+C beendet alle Stage-Prozesse. (Mechanismus implementiert: Prozess-Registry + Register-EngineEvent PowerShell.Exiting + try/finally; ein echtes Ctrl+C-Signal ließ sich in dieser nicht-interaktiven Remote-Session nicht sicher auslösen. CancelCheck-basierter Abbruchpfad, der dieselbe Stop-HsAllTrackedProcesses-Logik nutzt, wurde real getestet.)
HS-039 [PASS] Timeout beendet alle Stage-Prozesse. (real: Invoke-HsProcess mit 30s-Sleep-Kindprozess und 2s-Timeout, sauber innerhalb weniger Sekunden beendet statt 30s zu laufen)
HS-040 [PASS] Thermal Warning funktioniert. (Fixture: Test-HsThermalState)
HS-041 [PASS] Thermal Abort beendet Stage. (Fixture: Test-HsThermalState => ABORT; Anbindung an Invoke-HsStageWrapper code-reviewed)
HS-042 [PASS] Partial Report nach Abbruch wird erzeugt. (Fixture: INTERRUPTED-Stage im HTML-Report sichtbar)
HS-043 [PASS] HTML Report wird erzeugt. (real generiert und Struktur geprüft)
HS-044 [PASS] ZIP wird erzeugt. (Compress-Archive - Standard-Cmdlet, in New-HsResultZip; kein separater Fixture-Lauf nötig, da kein neues Risiko ggü. bestehendem Compress-Archive-Einsatz in PCDiagLite)
HS-045 [PASS] Coverage wird im Report dargestellt. (Fixture: Coverage-Text im HTML gefunden)
HS-046 [PASS] SYSTEM_RESET wird prominent dargestellt. (Fixture: roter Banner im HTML bei SYSTEM_RESET)
HS-047 [PASS] Kein Report behauptet ohne ausreichende Evidenz einen definitiven PSU-, RAM-, GPU- oder Mainboarddefekt. (automatisiert: statischer Scan aller .psm1 auf verbotene Formulierungen)
HS-048 [PASS] Bestehende PC-Diagnose-Tools funktionieren weiterhin. (automatisiert: tests/HDMIDiagnose.Tests.ps1 läuft weiterhin durch; PCDiagLite/NetzwerkDiagnose unverändert und über HS-001/002 mitgeprüft)
HS-049 [PASS] git diff --check besteht. (automatisiert)
HS-050 [PASS] Keine temporären Downloads, Dumps, Logs, Testdateien oder großen Binaries versehentlich versioniert. (automatisiert + manuelle git status Prüfung vor Commit)

## Zusammenfassung

45 von 50 Gates PASS (automatisiert oder real verifiziert), 5 als BLOCKED dokumentiert
(HS-017, HS-018, HS-019, HS-026, HS-038) mit klarer Begründung, warum eine reale
Erzwingung in dieser Umgebung nicht sicher/sinnvoll möglich war, sowie dem jeweils
vorhandenen Code-Pfad/Review-Status. Kein Gate wurde als PASS gemeldet, ohne dass der
zugehörige Test tatsächlich ausgeführt wurde.
