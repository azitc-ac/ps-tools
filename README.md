# ps-tools

Kleine Windows-Werkzeuge für den Alltag. Aktuell drei PowerShell-Skripte mit
WinForms-Oberfläche:

| Skript | Zweck |
|---|---|
| [`unblock-Files.ps1`](#unblock-filesps1) | Entfernt den `Zone.Identifier`-Stream von blockierten Dateien |
| [`uninstall-Apps.ps1`](#uninstall-appsps1) | Listet installierte Programme auf und deinstalliert mehrere davon still |
| [`TextCopyHelper.ps1`](#textcopyhelperps1) | Zerlegt den Clipboard-Inhalt in Zeilen mit Copy-Knöpfen und tippt ihn bei Bedarf als Tastatureingabe |

---

## unblock-Files.ps1

PowerShell-Skript zum Entfernen des `Zone.Identifier`-Streams (NTFS Alternate Data Stream) von Dateien, die Windows als "blockiert" markiert hat – z. B. nach dem Download aus dem Internet oder dem Kopieren von einem Netzlaufwerk.

### Hintergrund

Windows markiert Dateien aus dem Internet oder aus Netzwerkfreigaben mit einem `Zone.Identifier`-Stream. Dieser verursacht Warnmeldungen beim Öffnen und kann die Ausführung von Skripten oder Anwendungen blockieren. `Unblock-File` (bzw. das manuelle Entfernen des Streams) hebt diese Sperre auf.

### Features

- **GUI-Dialog** mit Pfad-Textbox, Durchsuchen-Button und Unblock-Button
- **Explorer-Kontextmenü-Integration**: Rechtsklick auf einen Ordner → *Unblock files*
- Verarbeitet alle Dateien **rekursiv** im gewählten Ordner
- Entfernt automatisch das **Read-only-Attribut** falls gesetzt
- Optionales **Subst-Laufwerk** (`U:`) für den Verarbeitungszeitraum

### Parameter

| Parameter | Typ | Beschreibung |
|---|---|---|
| `-folderName` | String | Startwert der Pfad-Textbox. Ohne Angabe wird das Skriptverzeichnis verwendet. |
| `-doSubst` | Switch | Bindet den Ordner während der Verarbeitung temporär als Laufwerk `U:` ein. |
| `-register` | Switch | Registriert den Explorer-Kontextmenüeintrag *Unblock files* für Ordner. |

### Verwendung

#### GUI starten
```powershell
.\unblock-Files.ps1
```

#### GUI mit vorausgefülltem Pfad
```powershell
.\unblock-Files.ps1 -folderName "C:\Downloads\MeinOrdner"
```

#### Kontextmenü registrieren (einmalig)
```powershell
.\unblock-Files.ps1 -register
```

Danach steht im Windows Explorer beim Rechtsklick auf jeden Ordner der Eintrag **"Unblock files"** zur Verfügung.

### Voraussetzungen

- Windows mit NTFS-Dateisystem
- PowerShell 5.1 oder höher
- Ausführungsrichtlinie: `RemoteSigned` oder `Bypass`

---

## uninstall-Apps.ps1

Zeigt die installierten Programme in einer Liste mit Mehrfachauswahl. Die
angehakten Einträge werden nacheinander deinstalliert – möglichst still, also
ohne Klickstrecke durch die einzelnen Uninstaller.

### Features

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

### Stille Deinstallation

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

### Office

Office wird über den von Microsoft hinterlegten Befehl entfernt, nicht über
einen eigenen Weg:

- **Click-to-Run** (Microsoft 365, Office 2016/2019/2021): der ARP-Befehl wird
  um `DisplayLevel=False` ergänzt (ein vorhandener `DisplayLevel`-Wert wird
  ersetzt), dazu `forceappshutdown=True`, damit laufende Office-Anwendungen die
  Deinstallation nicht blockieren.
- **Office MSI** (2010/2013): das Skript schreibt eine temporäre
  `config.xml` mit `<Display Level="none" ... AcceptEula="yes" />` und übergibt
  sie per `/config`. Die Datei wird nach dem Lauf wieder gelöscht.

### Parameter

| Parameter | Typ | Beschreibung |
|---|---|---|
| `-filter` | String | Startwert für das Suchfeld. |
| `-includeSystemComponents` | Switch | Zeigt zusätzlich Systemkomponenten, Updates und untergeordnete Einträge an. |
| `-noElevationCheck` | Switch | Unterdrückt die Nachfrage nach Administratorrechten beim Start. |

### Verwendung

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

### Rückmeldungen

Der Exitcode des Uninstallers landet als Status in der Liste:

| Code | Bedeutung |
|---|---|
| `0` | erfolgreich |
| `3010` / `1641` | erfolgreich, Neustart erforderlich bzw. eingeleitet |
| `1605` | Produkt war nicht (mehr) installiert |
| `1602` | vom Benutzer abgebrochen |
| `1603` | schwerwiegender Fehler |
| `1618` | eine andere Installation läuft gerade |

### Hinweise

- Die Deinstallation lässt sich nicht rückgängig machen. Die Auswahl wird vor
  dem Start noch einmal zur Bestätigung angezeigt.
- Läuft eine Deinstallation, bleiben Liste und Optionen gesperrt, damit die
  laufende Abarbeitung nicht durcheinandergerät.
- Bei **InstallShield**-Programmen genügt `/s` nur, wenn der Hersteller eine
  Antwortdatei (`.iss`) mitliefert; sonst erscheint die Oberfläche trotzdem.
- Store-Apps (Appx/MSIX) stehen nicht in der Liste – sie besitzen keinen
  Registry-Eintrag zur Deinstallation.

### Voraussetzungen

- Windows, PowerShell 5.1 oder höher, gestartet im **STA**-Modus
  (`powershell.exe` tut das von sich aus)
- Administratorrechte für maschinenweit installierte Programme

---

## TextCopyHelper.ps1

Version 8.1 (Nachfolger von `TextCopyHelper-v7.ps1`). Liest beim Start das Clipboard und zeigt jede Zeile in einem eigenen Feld mit
**Copy**-Knopf – praktisch, um Benutzername, Kennwort, Pfade o. Ä. einzeln in
Anwendungen zu übertragen.

### Features

- **Eine Zeile pro Feld** mit *Copy* und *-* (Zeile entfernen). Leeres
  Clipboard ergibt vier leere Zeilen zum Selbstausfüllen.
- **+ Knopf** fügt eine leere Zeile an, scrollt hin und setzt den Cursor hinein.
- **Paste clipboard as keyboard input**: minimiert das Fenster, wartet 2 s und
  tippt den aktuellen Clipboard-Inhalt per Scancode – für Konsolen, VMs und
  Remote-Sitzungen, in denen Einfügen nicht geht (Details siehe unten).
- **Clipboard preview** mit Formatierung (RTF, z. B. aus PowerShell ISE):
  *Copy text* kopiert reinen Text, *Copy RTF* kopiert RTF + HTML + Text, damit
  auch OneNote die Farben übernimmt. Wurde die Vorschau bearbeitet, wird der
  bearbeitete Inhalt kopiert.

### Layout

- Starthöhe nach Zeilenzahl, höchstens **60 % der Bildschirmhöhe**; das Fenster
  lässt sich größer ziehen, der Zeilenbereich wächst mit.
- Der Zeilenbereich scrollt nur **vertikal** – die Felder passen sich der
  Fensterbreite an, horizontale Scrollbalken entstehen nicht.
- Zwischen Zeilen und Vorschau sitzt ein verschiebbarer Splitter.
- Mehr als 200 Zeilen im Clipboard: die ersten 200 als Felder, der Rest nur in
  der Vorschau (Hinweis im Protokoll).

### Als Tastatureingabe tippen

Getippt werden Scancodes, also physische Tasten. Welche Taste samt Shift/AltGr
ein Zeichen braucht, hängt vom Tastaturlayout **des Ziels** ab – `[` ist auf
Deutsch AltGr+8, auf US eine eigene Taste. Stimmt das Layout nicht, kommt aus
`[` eine `8`.

- **Layout**: *Auto (target window)* nimmt das Layout des Fensters, das nach
  den 2 s den Fokus hat. Für **VM- und Remote-Konsolen** (Hyper-V, VMware,
  iLO/iDRAC, Web-Konsolen) kennt Windows das Layout im Gast nicht – dort das
  im Gast eingestellte Layout wählen. Zur Auswahl stehen die installierten
  Layouts und gängige weitere (DE, CH, US, US-International, UK, FR, BE, IT,
  ES); nicht installierte werden nur für die Dauer des Tippens geladen.
- **Delay ms** (Standard 15): Pause zwischen Zeichen und zwischen
  Shift/AltGr und der Taste. Gehen bei einer Konsole Shift oder AltGr verloren
  (`4` statt `$`), den Wert erhöhen, z. B. auf 50.
- Tottasten (`^`, `´`, `` ` ``) werden mit Leertaste abgeschlossen.
- Zeichen, die es im Layout nicht gibt (z. B. `ä` auf US), gehen als
  Unicode-Eingabe raus – das klappt in lokalen Programmen, in VM-Konsolen
  meist nicht. Das Protokoll nennt diese Zeichen.
- **Abbruch**: Esc drücken oder ein anderes Fenster anklicken – getippt wird
  nur, solange das Zielfenster den Fokus hat.
- Shift/AltGr werden auch bei einem Fehler immer losgelassen.

Layout und Delay werden gespeichert unter
`HKCU:\Software\ps-tools\TextCopyHelper` (`TypingLayout`, `TypingDelayMs`).

### Verwendung

```powershell
powershell.exe -STA -ExecutionPolicy Bypass -File .\TextCopyHelper.ps1
```

### Tests

```powershell
powershell.exe -STA -ExecutionPolicy Bypass -File .\tests\TextCopyHelper.Tests.ps1
```

Baut das Fenster unsichtbar auf und prüft u. a.: keine horizontalen
Scrollbalken (bei 4 und 300 Zeilen, einer 3000-Zeichen-Zeile, nach
Minimieren/Wiederherstellen und bei Breiten von 360–800 px), vollständig
sichtbare Knopfleisten, begrenzte Starthöhe, Reihenfolge der Zeilen, *+* und
*-* sowie das Speichern und Wiederherstellen von Layout und Delay (unter einem
eigenen Test-Schlüssel). Das Clipboard bleibt dabei unberührt.

```powershell
powershell.exe -STA -ExecutionPolicy Bypass -File .\tests\TextCopyHelper.Typing.Tests.ps1
```

Prüft die Zuordnung Zeichen → Taste (AltGr, Shift, Tottasten, AZERTY) und
**tippt dann echt** in ein eigenes Zielfenster: alle druckbaren ASCII-Zeichen,
Umlaute, `€ § ° ² ³ µ ´`, Tab und Zeilenumbruch, einmal ohne und einmal mit
Pause. Zur Gegenprobe wird absichtlich mit falschem Layout getippt – das muss
den Text verfälschen. Dauer etwa 30 s, währenddessen Maus und Tastatur nicht
benutzen. Exitcode 2: übersprungen, weil die Sitzung gesperrt oder das
RDP-Fenster minimiert ist.

Test in einer echten **VMware-Konsole** (Alpine-VM in Workstation Pro mit
Prüfskript im Gast): siehe [`tests/vmconsole/README.md`](tests/vmconsole/README.md).
