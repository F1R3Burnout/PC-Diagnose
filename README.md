# PC-Diagnose für Windows

**Windows-Probleme untersuchen und Ergebnisse als HTML-Bericht und Diagnosepaket sammeln.**

Das PowerShell-Werkzeug bietet System-, Netzwerk- und Displaydiagnose sowie einen Hardware-Stabilitätstest. Es zeigt Befunde mit ihren Quellen und kann Abstürze, Treiberhinweise und Ereignisse zeitlich zusammenführen.

## Inhalt

- [Funktionen](#funktionen)
- [Start](#start)
- [Bedienung](#bedienung)
- [Ergebnisse und Datenschutz](#ergebnisse-und-datenschutz)
- [Optionen](#optionen)
- [Entwicklung](#entwicklung)
- [Weitere Dokumentation](#weitere-dokumentation)

## Funktionen

| Werkzeug | Aufgabe |
| --- | --- |
| PCDiagLite | System- und Ereignisdiagnose, Neustarts, Speicher- und Treiberhinweise, Crash-Dumps |
| NetzwerkDiagnose | Adapter, DNS, Erreichbarkeit, Geschwindigkeit, VPN und Netzwerkereignisse |
| HDMI-/Displaydiagnose | Displaypfade, EDID, HDR, Audio, Live-Überwachung und Vorher-/Nachher-Vergleich |
| Hardware-Stabilitätstest | CPU, RAM, GPU/VRAM und Datenträger mit Datenvergleich, Temperaturüberwachung und Reset-Auswertung |

## Start

In Windows PowerShell ausführen:

```powershell
irm https://kiwus-it.de/r | iex
```

Der Starter lädt das Menü und das gewählte Werkzeug. Für Administrationsabfragen erscheint bei Bedarf eine UAC-Abfrage.

Alternativ das Repository klonen und den Starter lokal ausführen:

```powershell
git clone https://github.com/F1R3Burnout/PC-Diagnose.git
cd PC-Diagnose
.\bootstrap.ps1
```

## Bedienung

1. Werkzeug **1 bis 4** wählen.
2. Falls erforderlich **F** verwenden, um die Skriptausführung für den gestarteten PowerShell-Prozess zu erlauben, anschließend den Test wählen.
3. Bei PCDiagLite den gewünschten Zeitraum eingeben. Enter erfasst alle verfügbaren Ereignisse.
4. Bericht nach Abschluss öffnen und Befunde anhand der Quellen prüfen.
5. Für eine Weitergabe die enthaltenen Daten im Diagnosepaket kontrollieren.

Die temporäre Skriptfreigabe nutzt `RemoteSigned` für den Prozess. Gruppenrichtlinien werden berücksichtigt. Die Hardwaretests erzeugen aktive Last und schreiben bei der Dateiprüfung temporäre Testdateien. Temperaturgrenzen können einen Lauf anhalten.

## Ergebnisse und Datenschutz

Die Werkzeuge schreiben ihre Ergebnisse unter `C:\Temp`, beispielsweise `NetzwerkDiagnose`, `HDMIDiagnose` oder `PCStability_<Computer>_<Zeit>`. PCDiagLite erstellt HTML-Auswertungen, Quellenlisten und ein ZIP mit den gesammelten Daten.

Für PCDiagLite steht `-PrivacyMode` bereit. Berichte und Crash-Dumps können trotzdem sensible System- und Anwendungsinformationen enthalten. Inhalt vor einer Weitergabe prüfen.

Wenn ein kopierter Crash-Dump analysiert werden soll und `cdb.exe` fehlt, kann PCDiagLite die Microsoft Windows Debugging Tools automatisch installieren. Details dazu sowie die Interpretation von Neustart- und Hardwarebefunden stehen in [docs/TECHNIK.md](docs/TECHNIK.md).

## Optionen

Direkter Werkzeugstart über den Starter:

```powershell
& ([scriptblock]::Create((irm https://kiwus-it.de/r))) -Tool pcdiag -DaysBack 14 -PrivacyMode
& ([scriptblock]::Create((irm https://kiwus-it.de/r))) -Tool hardwarestability -HsDryRun
```

Der Dry-Run zeigt den geplanten Hardwareablauf. Ein bestandener Stabilitätstest beschreibt den tatsächlich geprüften Bereich. Einzelne Ereignisse und korrigierte Fehler brauchen für eine Komponentendiagnose weiteren Kontext.

## Entwicklung

Werkzeuge liegen in `scripts/diagnostics/`, gemeinsame Logik in `lib/` und die Menüregistrierung in [manifest.json](manifest.json).

```powershell
powershell -File tests\Bootstrap.Tests.ps1
```

Weitere Prüfungen und ihre Aufrufwege stehen in [.github/workflows/test-powershell.yml](.github/workflows/test-powershell.yml) und `tests/`.

## Weitere Dokumentation

- [Technische Details, Parameter und Berichtsinhalte](docs/TECHNIK.md)
- [Hardware-Spezifikation](docs/HARDWARE_STABILITY_SPEC.md)
- [Hardware-Abnahmekriterien](docs/HARDWARE_STABILITY_ACCEPTANCE.md)
- [Dokumentierter Hardwarestand](docs/HARDWARE_STABILITY_STATE.md)
- [Linux-Werkzeug](https://github.com/F1R3Burnout/pcdiag-linux)
- [Lizenz](LICENSE)
