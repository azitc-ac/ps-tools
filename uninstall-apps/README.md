# uninstall-Apps.ps1

> Befehle auf dieser Seite im Ordner `uninstall-apps` ausführen.

Zeigt die installierten Programme in einer Liste mit Mehrfachauswahl. Die
angehakten Einträge werden nacheinander deinstalliert – möglichst still, also
ohne Klickstrecke durch die einzelnen Uninstaller.

## Features

- **Liste aller installierten Programme** aus allen vier Deinstallations-Zweigen
  der Registry (HKLM/HKCU, 64- und 32-Bit)
- **Mehrfachauswahl** über Checkboxen, dazu *Alle wählen* / *Auswahl leeren*
- **Suchfeld** (Name und Herausgeber) und sortierbare Spalten
- **Deinstallieren-Knopf**: arbeitet die Auswahl der Reihe nach ab
- **Fortschrittsanzeige**: Fortschrittsbalken, aktuell laufendes Programm,
  Status je Zeile (grün/rot) und ein Protokollfenster mit dem tatsächlich
  ausgeführten Befehl
- **Abbrechen**: stoppt nach der gerade laufenden Deinstallation
- Erkennt fehlende **Administratorrechte** und bietet den Neustart an

## Stille Deinstallation

Ausgangspunkt ist der `UninstallString` aus der Registry. Je nach erkanntem
Installertyp werden die passenden Schalter ergänzt:

| Typ | Erkennung | Ergänzte Schalter |
|---|---|---|
| MSI | `msiexec` im Befehl | `/x {GUID} /qn /norestart` |
| `QuietUninstallString` | Wert vorhanden | wird unverändert übernommen |
| Inno Setup | `unins###.exe` bzw. `Inno Setup:`-Werte | `/VERYSILENT /SUPPRESSMSGBOXES /NORESTART` |
| NSIS | `uninstall.exe`, `uninst*.exe`, `au_*.exe` | `/S` |
| WiX Burn | `Bundle*`-Werte im Schlüssel | `/uninstall /quiet /norestart` |
| Squirrel | `Update.exe --uninstall` | `-s` |
| InstallShield | `-runfromtemp`, `/removeonly` | `/s /SMS` |
| Office Click-to-Run | `OfficeClickToRun.exe` | `DisplayLevel=False forceappshutdown=True` |
| Office MSI | `setup.exe /uninstall <Produkt>` | erzeugte `/config`-XML mit `Display Level="none"` |
| unbekannt | – | optional `/S` (siehe unten) |

Der erkannte Modus steht in der Spalte **Modus**, bevor etwas passiert.

Zwei Optionen steuern den Umgang mit unbekannten Installern:

- **Bei unbekannten Installern Silent-Schalter raten (`/S`)** – standardmäßig
  aktiv. Ohne diese Option läuft ein unbekannter Uninstaller mit seiner
  normalen Oberfläche.
- **Nicht-stille Deinstallationen überspringen** – überspringt genau diese
  Fälle, damit ein unbeaufsichtigter Lauf nicht an einem Dialog hängen bleibt.

## Office

Office wird über den von Microsoft hinterlegten Befehl entfernt, nicht über
einen eigenen Weg:

- **Click-to-Run** (Microsoft 365, Office 2016/2019/2021): der ARP-Befehl wird
  um `DisplayLevel=False` ergänzt (ein vorhandener `DisplayLevel`-Wert wird
  ersetzt), dazu `forceappshutdown=True`, damit laufende Office-Anwendungen die
  Deinstallation nicht blockieren.
- **Office MSI** (2010/2013): das Skript schreibt eine temporäre
  `config.xml` mit `<Display Level="none" ... AcceptEula="yes" />` und übergibt
  sie per `/config`. Die Datei wird nach dem Lauf wieder gelöscht.

## Parameter

| Parameter | Typ | Beschreibung |
|---|---|---|
| `-filter` | String | Startwert für das Suchfeld. |
| `-includeSystemComponents` | Switch | Zeigt zusätzlich Systemkomponenten, Updates und untergeordnete Einträge an. |
| `-noElevationCheck` | Switch | Unterdrückt die Nachfrage nach Administratorrechten beim Start. |

## Verwendung

```powershell
powershell.exe -STA -ExecutionPolicy Bypass -File .\uninstall-Apps.ps1
```

Mit vorbelegter Suche:

```powershell
powershell.exe -STA -ExecutionPolicy Bypass -File .\uninstall-Apps.ps1 -filter "Office"
```

Für maschinenweit installierte Programme wird eine **erhöhte** PowerShell
benötigt. Startet das Skript ohne Administratorrechte, bietet es den Neustart
selbst an.

## Rückmeldungen

Der Exitcode des Uninstallers landet als Status in der Liste:

| Code | Bedeutung |
|---|---|
| `0` | erfolgreich |
| `3010` / `1641` | erfolgreich, Neustart erforderlich bzw. eingeleitet |
| `1605` | Produkt war nicht (mehr) installiert |
| `1602` | vom Benutzer abgebrochen |
| `1603` | schwerwiegender Fehler |
| `1618` | eine andere Installation läuft gerade |

## Hinweise

- Die Deinstallation lässt sich nicht rückgängig machen. Die Auswahl wird vor
  dem Start noch einmal zur Bestätigung angezeigt.
- Läuft eine Deinstallation, bleiben Liste und Optionen gesperrt, damit die
  laufende Abarbeitung nicht durcheinandergerät.
- Bei **InstallShield**-Programmen genügt `/s` nur, wenn der Hersteller eine
  Antwortdatei (`.iss`) mitliefert; sonst erscheint die Oberfläche trotzdem.
- Store-Apps (Appx/MSIX) stehen nicht in der Liste – sie besitzen keinen
  Registry-Eintrag zur Deinstallation.

## Voraussetzungen

- Windows, PowerShell 5.1 oder höher, gestartet im **STA**-Modus
  (`powershell.exe` tut das von sich aus)
- Administratorrechte für maschinenweit installierte Programme

Zurück zur [Übersicht](../README.md).
