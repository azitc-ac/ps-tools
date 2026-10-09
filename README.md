# ps-tools

Kleine Windows-Werkzeuge für den Alltag. Jedes Werkzeug liegt in einem eigenen Ordner mit eigenem README,
den Skripten und, wo vorhanden, den Tests. Befehle in den READMEs gelten für den Ordner des Werkzeugs.

| Werkzeug | Zweck |
|---|---|
| [`unblock-files/`](unblock-files/README.md) | Entfernt den `Zone.Identifier`-Stream von blockierten Dateien (GUI, Explorer-Kontextmenü) |
| [`uninstall-apps/`](uninstall-apps/README.md) | Listet installierte Programme auf und deinstalliert mehrere davon still |
| [`text-copy-helper/`](text-copy-helper/README.md) | Zerlegt den Clipboard-Inhalt in Zeilen mit Copy-Knöpfen und tippt ihn bei Bedarf als Tastatureingabe |
| [`mini-dateimanager/`](mini-dateimanager/README.md) | Zweispaltiger Dateimanager für die Konsole (Server Core), mit Dateien per RDP-Zwischenablage zum Server und zurück |

## Aufbau

```
ps-tools/
├── unblock-files/        unblock-Files.ps1
├── uninstall-apps/       uninstall-Apps.ps1
├── text-copy-helper/     TextCopyHelper.ps1, tests/ (Layout-, Tipp- und VMware-Konsolentests)
└── mini-dateimanager/    fm.ps1, test-fm.ps1, test-zwischenablage.ps1, ansicht.py
```

Wer ein Skript per Download braucht, nimmt die Datei aus dem jeweiligen Ordner, zum Beispiel
`mini-dateimanager/fm.ps1`.
