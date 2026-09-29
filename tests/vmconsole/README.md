# Test: TextCopyHelper in einer VMware-Konsole

Prüft, ob „Paste clipboard as keyboard input“ in einer VMware-Konsole Zeichen
für Zeichen korrekt ankommt – vor allem Shift- und AltGr-Zeichen wie
`$ [ ] { } \ | @ ~`. Im Gast läuft eine verdeckte Abfrage wie bei einem
Passwort. Ein Skript vergleicht sie mit einem Muster von der Prüf-CD und meldet
`OK` oder die erste abweichende Stelle.

## Voraussetzungen

- **physischer x64-PC** (`$env:PROCESSOR_ARCHITECTURE` = `AMD64`); Workstation
  gibt es nicht für ARM64
- **VMware Workstation Pro**, kostenlos über das Broadcom Support Portal
- **nicht in einer RDP- oder Windows-365-Sitzung testen**: Dort verwirft
  Workstation eingespeiste Tastendrücke vollständig. Echte Tasten kommen an,
  Tastendrücke aus Programmen nicht. Festgestellt am 29.09.2026 in einem
  Windows 365 Cloud PC mit Workstation 26H1u1 im Host VBS Mode, mit zwei
  verschiedenen Eingabemethoden.

## Test-VM anlegen

```powershell
powershell -ExecutionPolicy Bypass -File .\tests\vmconsole\New-ConsoleTestVm.ps1 -Start
```

Das Skript lädt Alpine Linux 3.24.2 (69 MB, SHA256 wird geprüft), erzeugt die
Prüf-CD aus `iso\` und legt unter `%USERPROFILE%\VMs\alpine-test` eine VM an:
ohne Festplatte, ohne Netzwerk. Mit `-Start` startet sie gleich.

## Im Gast vorbereiten (einmal, von Hand tippen)

```sh
root                      # Login, kein Passwort
setup-keymap de de        # Gast-Tastatur auf Deutsch
mount -r /dev/sr1 /mnt    # Prüf-CD
```

Die Zeilen oben tippst du **mit der echten Tastatur**. Solange der Gast noch
das US-Layout hat, liegen `-` und `/` woanders als gewohnt: `-` auf `ß`, `/`
auf `-`.

## Einen Durchlauf machen

1. Auf dem Host das Testmuster ins Clipboard legen:
   ```powershell
   Get-Content .\tests\vmconsole\iso\pw.txt -Raw | Set-Clipboard
   ```
2. Im Gast die Abfrage starten: `sh /mnt/check.sh pw`
3. TextCopyHelper starten, **Layout** und **Delay ms** wie in der Tabelle unten
   einstellen, *Paste clipboard as keyboard input* klicken und **innerhalb von
   2 s in die VM-Konsole klicken**. Workstation leitet Tasten erst weiter,
   wenn die Konsole die Eingabe übernommen hat.
4. Nach dem Tippen im Gast **Enter** drücken. Die Ausgabe lautet
   `>>> OK: 22 von 22 Zeichen korrekt` oder
   `>>> FEHLER … erste Abweichung an Stelle N: erwartet [$] bekommen [4]`.

Für das große Muster mit allen 94 druckbaren ASCII-Zeichen in Schritt 1
`ascii.txt` und in Schritt 2 `sh /mnt/check.sh ascii` verwenden.

| # | Gast-Layout | Tool: Layout | Delay ms | Erwartung |
|---|---|---|---|---|
| 1 | DE | Auto | 15 | OK |
| 2 | DE | Auto | 0 | OK, sonst ist die Pause die Lösung für verlorenes Shift/AltGr |
| 3 | DE | Auto | 50 | OK |
| 4 | DE | English (US) | 15 | **FEHLER**: Gegenprobe, zeigt „8 statt [“ |

Fällt #4 nicht durch, ist der Test nicht trennscharf. Dann stimmt etwas am
Aufbau nicht, z. B. hat der Gast doch US-Layout.

## Kommt nichts an? Test ohne Fokuswechsel

Mit dem Klick auf den Knopf in TextCopyHelper verliert Workstation den Fokus und
damit die Eingabe-Übernahme. `grabbed-typing-test.cmd` (Doppelklick) trennt die
beiden möglichen Ursachen:

1. Im Gast `sh /mnt/check.sh pw` starten.
2. `tests\vmconsole\grabbed-typing-test.cmd` doppelklicken.
3. Während des Countdowns (8 s) in die VM-Konsole klicken, dann nichts anfassen.
4. Wenn das Skript `Getippt: 22 von 22` meldet, im Gast Enter drücken.

Tippt nur, wenn vorn ein Fenster mit „VMware“ im Titel ist. Danach lässt sich
direkt ein weiterer Durchlauf mit anderem Delay starten.

- `OK` → Ursache ist die verlorene Übernahme, das lässt sich im Tool lösen.
- wieder `0 bekommen` → Workstation verwirft eingespeiste Tasten grundsätzlich.

## Aufräumen

```powershell
& "$env:ProgramFiles\VMware\VMware Workstation\vmrun.exe" -T ws stop "$env:USERPROFILE\VMs\alpine-test\alpine-tch-test.vmx" hard
Remove-Item "$env:USERPROFILE\VMs\alpine-test" -Recurse -Force
```
