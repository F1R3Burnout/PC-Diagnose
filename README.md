# PC-Diagnose

PowerShell-basierte Diagnose- und Wartungstools fuer Windows-PCs und kleine Server.

## Schnellstart

Kurzbefehl fuer ServerDiagLite:

```powershell
irm https://raw.githubusercontent.com/F1R3Burnout/PC-Diagnose/main/s|iex
```

Menue starten:

```powershell
irm https://raw.githubusercontent.com/F1R3Burnout/PC-Diagnose/main/b|iex
```

ServerDiagLite direkt starten:

```powershell
& ([scriptblock]::Create((irm https://raw.githubusercontent.com/F1R3Burnout/PC-Diagnose/main/bootstrap.ps1))) -Tool serverdiag
```

Mit Privacy-Modus:

```powershell
& ([scriptblock]::Create((irm https://raw.githubusercontent.com/F1R3Burnout/PC-Diagnose/main/bootstrap.ps1))) -Tool serverdiag -PrivacyMode
```

Mit kurzem Event-Zeitraum:

```powershell
& ([scriptblock]::Create((irm https://raw.githubusercontent.com/F1R3Burnout/PC-Diagnose/main/bootstrap.ps1))) -Tool serverdiag -DaysBack 7
```

## Aktuelle Tools

| Tool-ID | Name | Zweck | Admin |
| --- | --- | --- | --- |
| `serverdiag` | ServerDiagLite | Schlankes Diagnosepaket fuer Windows-Probleme sammeln | Ja |

## ServerDiagLite

ServerDiagLite sammelt ein ZIP unter `C:\Temp` mit:

- automatischer Ersteinschaetzung
- HTML-Report
- Manifest
- System- und Hardwaredaten
- Storage- und Volume-Status
- Netzwerkadapter, IP-Konfiguration und DNS
- Power/Wake-Informationen
- begrenzte System/Application-Eventauswertung
- Minidumps, falls vorhanden

Das Tool ist in der aktuellen Version bewusst `collect-only`: Es sammelt Diagnoseinformationen und nimmt keine Reparaturen am System vor.

## Datenschutz

Diagnosepakete koennen IP-Adressen, Benutzernamen, Computernamen, Seriennummern, MAC-Adressen, Pfade und Geraete-IDs enthalten.

Nutze fuer Weitergabe an Dritte nach Moeglichkeit:

```powershell
& ([scriptblock]::Create((irm https://raw.githubusercontent.com/F1R3Burnout/PC-Diagnose/main/bootstrap.ps1))) -Tool serverdiag -PrivacyMode
```

Der Privacy-Modus ist ein Hilfsfilter. Pruefe Pakete vor oeffentlicher Weitergabe trotzdem manuell.

## Entwicklung

Struktur:

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

Neue Tools werden als PowerShell-Script unter `scripts/` abgelegt und in `manifest.json` eingetragen.

## Hinweise

Das Ausfuehren von Remote-Code per `irm ... | iex` ist bequem, setzt aber Vertrauen in dieses Repository voraus. Fuer produktive Nutzung sind getaggte Releases oder signierte Scripte empfehlenswert.
