# Hardware-Stabilitätstest — Spezifikation

## 1. Ziel

Ein neuer Menüpunkt **Hardware-Stabilitätstest** (interne Tool-ID: `hardwarestability`) für
PC-Diagnose, der Hardwarestabilität primär durch **verifizierbare Tests** prüft, nicht durch
reine Maximallast.

Grundprinzip für jede Komponente:

```
bekannte Daten / bekannte Berechnung
        -> Hardware verarbeitet sie
        -> Ergebnis zurücklesen
        -> gegen erwartetes Ergebnis prüfen
        -> Fehler/Mismatch erfassen
```

Hohe Last/Temperatur sind erlaubte Nebenprodukte, nicht das Testziel selbst.

## 2. Architekturentscheidungen

| Entscheidung | Begründung |
|---|---|
| Neues Verzeichnis `lib/HardwareStability/*.psm1` statt Erweiterung von `PCDiagLite.ps1` | PCDiagLite ist ein 6000+ Zeilen Monolith-Skript (kein Modul). Ein neuer, modularer Baum vermeidet unnötige Kopplung und Regressionsrisiko. |
| Gemeinsame Event-/Restart-Logik wird nach `lib/PCDiagnoseCommon.psm1` extrahiert und von **beiden** (`PCDiagLite.ps1` und `HardwareStability.ps1`) verwendet | Vermeidet doppelte, unabhängig gepflegte Eventlog-Auswertung (User32 1074, EventLog 6005/6006/6008, Kernel-Power 41, BugCheck 1001). Die Funktionen werden verbatim aus PCDiagLite übernommen, nicht neu geschrieben, um Verhaltensänderungen/Regressionen zu vermeiden. |
| GPU-Compute-Verifier basiert auf **Direct3D 11 Compute Shaders** (HLSL, zur Laufzeit über `D3DCompile` kompiliert) statt Vulkan | D3D11 ist auf jeder Windows-10/11-Installation systemseitig vorhanden (kein separates Vulkan-ICD/-Runtime nötig, WARP-Fallback möglich). Die Entwicklungsumgebung dieses Auftrags hat nachweislich **keine** `vulkan-1.dll` installiert, aber D3D11 ist immer verfügbar. Das ist eine technisch geeignete, lizenzkostenfreie, automatisierbare Alternative im Sinne von Abschnitt 13 des Auftrags. Für VRAM (reiner Bandbreiten-/Musterschreibtest, kein Shader-Compute nötig) wird trotzdem das vom Auftrag bevorzugte `memtest_vulkan` verwendet — dessen Nichtverfügbarkeit (kein Vulkan-Runtime) wird korrekt als `UNSUPPORTED` behandelt und dient zugleich als realer Test dieses Pfads. |
| GPU Load/Thermal Validation ohne FurMark2 | FurMark2 ist proprietär (Geeks3D) und noch nicht im Projekt vorhanden. Ein neuer, zusätzlicher Closed-Source-Download für einen bereits durch den D3D11-Verifier abgedeckten Lastfall wurde als unnötige Abhängigkeit bewertet (Auftrag Abschnitt 36: "keine unnötige zusätzliche Abhängigkeit"). Stattdessen wird der bereits verifizierte D3D11-Compute-Kernel in einer Dauerschleife mit Telemetrie-Sampling betrieben. Funktional identisches Ergebnis (Last, Temperatur, TDR/Device-Lost-Erkennung), ohne zusätzliche Lizenz-/Downloadkomplexität. Sollte ein Nutzer FurMark2 bereits selbst nutzen, steht dem nichts entgegen — es wird nur nicht automatisch heruntergeladen. |
| Prime95 für CPU_COMPUTE und CPU_CACHE_IMC (unterschiedliche Worker-Konfiguration: Small FFT vs. Large FFT/Blend) | Offizielle GIMPS-Software (mersenne.org), Freeware, dokumentiertes Verhalten (`results.txt`, FATAL ERROR/ROUNDOFF/SUMOUT), CLI-Flag `-t` bestätigt in `readme.txt` der aktuellen Version 30.19 Build 20. |
| MemoryChecker (lordmulder) für RAM | CC0-1.0, dokumentierte CLI (`--batch`, `MEMCHCK_PASSES`), Exitcode 0/1, Schreiben+Zurücklesen+Vergleichen laut Autor-README. |
| smartmontools (`smartctl`) für SMART | GPLv2, offiziell veröffentlichter MD5-Hash für Version 7.5, dynamische Unterstützungserkennung. |
| Kein OCCT | Nicht integriert. Persönliche Lizenz erlaubt keine gewerbliche Nutzung; keine Abhängigkeit des Stabilitätstests davon. |
| Storage Surface Read: PowerShell + eingebettetem C# Win32-Helper (`Add-Type`), ausschließlich `GENERIC_READ` | Wie im Auftrag gefordert; kein NuGet/SDK nötig (Add-Type kompiliert über die in PowerShell 7 gebündelte Roslyn-Instanz, bestätigt lauffähig ohne separates .NET SDK). |
| Storage Write/Read Verification: eigener Testfile-Verifier (kein `fio`) | Vermeidet zusätzliche Binary-Abhängigkeit für einen einfachen, gut selbst und sicher implementierbaren Anwendungsfall (Datei schreiben/lesen/CRC32 vergleichen). |

## 3. Sicherheitsanforderungen

- Storage Surface Scan öffnet `\\.\PhysicalDriveN` **ausschließlich** mit `GENERIC_READ`. Kein `GENERIC_WRITE`, kein `WriteFile`, keine Partitionierungs-/Formatierungsbefehle gegen Raw-Disks.
- Storage Write/Read Verification schreibt ausschließlich in eine normale temporäre Datei auf einem bestehenden Dateisystem (kein Raw-Disk-Zugriff).
- Keine automatische Datenträgerreparatur (`chkdsk /scan` ohne `/f /r /x /b`).
- Downloads nur von offiziellen HTTPS-Quellen; SHA256 wird gegen den in `config/HardwareStabilityTools.json` hinterlegten Wert geprüft (offizieller Hash sofern veröffentlicht, sonst dokumentierter Pinning-Ansatz nach erstem verifiziertem Download).
- `-NoDownload` unterdrückt jeden Download; fehlende Tools führen zu `SKIPPED`/`UNSUPPORTED`, nicht zum Abbruch des gesamten Laufs.
- Keine dauerhafte Scheduled Task, kein permanenter Autostart für Recovery nach Reboot.
- Thermal Guard mit konservativen Default-Grenzwerten (Abschnitt 26 des Auftrags); bei Abort werden alle Kindprozesse beendet.

## 4. Statusmodell

`PASS`, `FAIL`, `WARNING`, `SKIPPED`, `UNSUPPORTED`, `INTERRUPTED`, `THERMAL_ABORT`, `SYSTEM_RESET`, `BLOCKED`.

`PASS` bedeutet ausschließlich: *"Innerhalb des tatsächlich getesteten Bereichs wurden keine Fehler erkannt."* Es ist keine Garantie für vollständige Fehlerfreiheit.

## 5. Testprofile

Zentral in `lib/HardwareStability/Profiles.psm1`. Siehe `docs/HARDWARE_STABILITY_STATE.md` für den aktuellen Implementierungsstand der konkreten Werte.

## 6. Komponentenübersicht

Siehe Abschnitte 10–23 des ursprünglichen Auftrags; Umsetzung und Stand je Komponente in
`docs/HARDWARE_STABILITY_STATE.md` und `docs/HARDWARE_STABILITY_ACCEPTANCE.md`.
