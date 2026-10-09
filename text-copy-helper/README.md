# TextCopyHelper.ps1

> Befehle auf dieser Seite im Ordner `text-copy-helper` ausführen.

Version 8.1 (Nachfolger von `TextCopyHelper-v7.ps1`). Liest beim Start das Clipboard und zeigt jede Zeile in einem eigenen Feld mit
**Copy**-Knopf – praktisch, um Benutzername, Kennwort, Pfade o. Ä. einzeln in
Anwendungen zu übertragen.

## Features

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

## Layout

- Starthöhe nach Zeilenzahl, höchstens **60 % der Bildschirmhöhe**; das Fenster
  lässt sich größer ziehen, der Zeilenbereich wächst mit.
- Der Zeilenbereich scrollt nur **vertikal** – die Felder passen sich der
  Fensterbreite an, horizontale Scrollbalken entstehen nicht.
- Zwischen Zeilen und Vorschau sitzt ein verschiebbarer Splitter.
- Mehr als 200 Zeilen im Clipboard: die ersten 200 als Felder, der Rest nur in
  der Vorschau (Hinweis im Protokoll).

## Als Tastatureingabe tippen

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

## Verwendung

```powershell
powershell.exe -STA -ExecutionPolicy Bypass -File .\TextCopyHelper.ps1
```

## Tests

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

Zurück zur [Übersicht](../README.md).
