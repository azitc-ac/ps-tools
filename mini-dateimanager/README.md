# Mini-Dateimanager für Server Core (`fm.ps1`)

Zwei Spalten wie beim Norton Commander, nur Bordmittel: Windows PowerShell 5.1 und .NET, kein Explorer, kein Notepad,
keine Module. Dateien kopieren, verschieben, löschen, umbenennen, Ordner anlegen, Textansicht, **Dateien per RDP-Zwischenablage
zum Server und zurück**.

## Starten

```powershell
powershell -STA -ExecutionPolicy Bypass -File .\fm.ps1 C:\ProgramData D:\
```

(`-STA` ist bei Windows PowerShell 5.1 schon Vorgabe, die Zwischenablage braucht es.)

## Tasten

| Taste | Aktion |
|---|---|
| Pfeile, Bild, Pos1, Ende | bewegen |
| Enter / Pfeil rechts | Ordner öffnen (Dateien: Ansicht) |
| Rück / Pfeil links | eine Ebene hoch |
| Tab | andere Spalte |
| Leertaste, Einfg | markieren |
| A | alle markieren / aufheben |
| F5 oder C | kopieren in die andere Spalte |
| F6 oder M | verschieben in die andere Spalte |
| F7 oder N | neuer Ordner |
| F8 oder Entf | löschen (mit Rückfrage) |
| F2 oder R | umbenennen |
| F3 oder V | Textansicht |
| G | zu Pfad (auch `\\Server\Freigabe`) |
| D | Laufwerke |
| = | andere Spalte auf denselben Pfad |
| **K oder Strg+C** | markierte Dateien in die Zwischenablage (am RDP-Client mit Strg+V im Explorer einfügbar) |
| **P oder Strg+V** | Dateien aus der Zwischenablage in den aktuellen Ordner einfügen (auch vom RDP-Client) |
| F9 | neu lesen |
| F10, Q, Esc | beenden |

## Dateien per RDP

- **Server → Client:** Dateien markieren, `K`. Am Client im Explorer `Strg+V`.
- **Client → Server:** Am Client im Explorer Dateien kopieren (`Strg+C`), auf dem Server im Manager in den Zielordner gehen, `P`.
- Namen aus der Zwischenablage mit `..\` oder absoluten Pfaden werden nicht geschrieben.
- Voraussetzung: RDP-Zwischenablage ist aktiv (Laufwerks-/Zwischenablage-Umleitung im RDP-Client, `rdpclip.exe` läuft in der Sitzung).
- Während großer Übertragungen zeigt der Manager keinen Fortschritt.

## Tests

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File .\test-fm.ps1                # Tastenlogik, 5.1 und 7
powershell -NoProfile -STA -ExecutionPolicy Bypass -File .\test-zwischenablage.ps1  # überschreibt kurz die Zwischenablage
```

`test-zwischenablage.ps1` simuliert den RDP-Client mit einer eigenen Datenquelle für virtuelle Dateien
(`FileGroupDescriptorW` + `FileContents` als `IStream`, wie `rdpclip` sie liefert). Eine echte RDP-Sitzung ersetzt das nicht.

`ansicht.py` startet den Manager in einem Pseudo-Terminal und gibt den Bildschirm als Text aus (braucht `pywinpty`, `pyte`).
