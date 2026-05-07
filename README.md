# ps-unblock-files

PowerShell-Skript zum Entfernen des `Zone.Identifier`-Streams (NTFS Alternate Data Stream) von Dateien, die Windows als "blockiert" markiert hat – z. B. nach dem Download aus dem Internet oder dem Kopieren von einem Netzlaufwerk.

## Hintergrund

Windows markiert Dateien aus dem Internet oder aus Netzwerkfreigaben mit einem `Zone.Identifier`-Stream. Dieser verursacht Warnmeldungen beim Öffnen und kann die Ausführung von Skripten oder Anwendungen blockieren. `Unblock-File` (bzw. das manuelle Entfernen des Streams) hebt diese Sperre auf.

## Features

- **GUI-Dialog** mit Pfad-Textbox, Durchsuchen-Button und Unblock-Button
- **Explorer-Kontextmenü-Integration**: Rechtsklick auf einen Ordner → *Unblock files*
- Verarbeitet alle Dateien **rekursiv** im gewählten Ordner
- Entfernt automatisch das **Read-only-Attribut** falls gesetzt
- Optionales **Subst-Laufwerk** (`U:`) für den Verarbeitungszeitraum

## Parameter

| Parameter | Typ | Beschreibung |
|---|---|---|
| `-folderName` | String | Startwert der Pfad-Textbox. Ohne Angabe wird das Skriptverzeichnis verwendet. |
| `-doSubst` | Switch | Bindet den Ordner während der Verarbeitung temporär als Laufwerk `U:` ein. |
| `-register` | Switch | Registriert den Explorer-Kontextmenüeintrag *Unblock files* für Ordner. |

## Verwendung

### GUI starten
```powershell
.\unblock-Files.ps1
```

### GUI mit vorausgefülltem Pfad
```powershell
.\unblock-Files.ps1 -folderName "C:\Downloads\MeinOrdner"
```

### Kontextmenü registrieren (einmalig)
```powershell
.\unblock-Files.ps1 -register
```

Danach steht im Windows Explorer beim Rechtsklick auf jeden Ordner der Eintrag **"Unblock files"** zur Verfügung.

## Voraussetzungen

- Windows mit NTFS-Dateisystem
- PowerShell 5.1 oder höher
- Ausführungsrichtlinie: `RemoteSigned` oder `Bypass`
