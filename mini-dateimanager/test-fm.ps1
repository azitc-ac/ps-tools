<#
.SYNOPSIS
    Testet fm.ps1 ohne Tastatur: eine Tastenfolge laeuft gegen einen Testbaum, danach wird das Dateisystem geprueft.
    Aufruf: powershell -NoProfile -File .\test-fm.ps1      (laeuft auf 5.1 und 7)
#>
$ErrorActionPreference = "Stop"
$fm = Join-Path $PSScriptRoot "fm.ps1"
$wurzel = Join-Path ([IO.Path]::GetTempPath()) ("fm-test-" + [guid]::NewGuid().ToString("N").Substring(0, 8))
$fehler = 0

function Prüfe([string]$name, [bool]$ok) {
    if ($ok) { Write-Host "OK     $name" -ForegroundColor Green } else { Write-Host "FEHLER $name" -ForegroundColor Red; $script:fehler++ }
}
function Neu-Baum {
    Remove-Item $wurzel -Recurse -Force -ErrorAction SilentlyContinue
    New-Item -ItemType Directory "$wurzel\a\unter", "$wurzel\b" -Force | Out-Null
    Set-Content "$wurzel\a\eins.txt" "eins"; Set-Content "$wurzel\a\zwei.txt" "zwei"; Set-Content "$wurzel\a\drei.log" "drei"
    Set-Content "$wurzel\a\unter\tief.txt" "tief"; Set-Content "$wurzel\b\eins.txt" "ALT"
}
function Fahre([string[]]$tasten) { & $fm -Links "$wurzel\a" -Rechts "$wurzel\b" -Tasten $tasten }

# Reihenfolge links: "..", Ordner "unter", dann Dateien drei.log, eins.txt, zwei.txt
try {
    # 1 Kopieren der aktuellen Datei (Idx 0 = "..", also erst auf drei.log)
    Neu-Baum; Fahre @("DownArrow", "DownArrow", "F5")
    Prüfe "Kopieren: aktuelle Datei landet rechts, bleibt links" ((Test-Path "$wurzel\b\drei.log") -and (Test-Path "$wurzel\a\drei.log"))

    # 2 Markieren und kopieren, vorhandene ueberschreiben mit J
    Neu-Baum; Fahre @("DownArrow", "DownArrow", "DownArrow", "Spacebar", "Spacebar", "F5", "J")
    Prüfe "Mehrfachkopie mit Ueberschreiben: eins.txt rechts ersetzt" ((Get-Content "$wurzel\b\eins.txt") -eq "eins")
    Prüfe "Mehrfachkopie: zwei.txt rechts angelegt" (Test-Path "$wurzel\b\zwei.txt")

    # 3 Ueberschreiben verneint
    Neu-Baum; Fahre @("DownArrow", "DownArrow", "DownArrow", "F5", "N")
    Prüfe "Ueberschreiben verneint: rechts bleibt ALT" ((Get-Content "$wurzel\b\eins.txt") -eq "ALT")

    # 4 Ordner kopieren (rekursiv)
    Neu-Baum; Fahre @("DownArrow", "F5")
    Prüfe "Ordner rekursiv kopiert" (Test-Path "$wurzel\b\unter\tief.txt")

    # 5 Verschieben
    Neu-Baum; Fahre @("DownArrow", "DownArrow", "F6")
    Prüfe "Verschieben: weg links, da rechts" ((-not (Test-Path "$wurzel\a\drei.log")) -and (Test-Path "$wurzel\b\drei.log"))

    # 6 Alles markieren (A) und verschieben
    Neu-Baum; Fahre @("A", "F6", "J")
    Prüfe "Alles verschieben: links nur noch leer" (@(Get-ChildItem "$wurzel\a").Count -eq 0)
    Prüfe "Alles verschieben: rechts angekommen" ((Test-Path "$wurzel\b\unter\tief.txt") -and (Test-Path "$wurzel\b\zwei.txt"))

    # 7 Neuer Ordner und Umbenennen
    Neu-Baum; Fahre @("F7", "t:neu")
    Prüfe "Neuer Ordner" (Test-Path "$wurzel\a\neu" -PathType Container)
    Neu-Baum; Fahre @("DownArrow", "DownArrow", "F2", "t:umbenannt.log")
    Prüfe "Umbenennen" ((Test-Path "$wurzel\a\umbenannt.log") -and -not (Test-Path "$wurzel\a\drei.log"))

    # 8 Loeschen mit Rueckfrage
    Neu-Baum; Fahre @("DownArrow", "DownArrow", "F8", "N")
    Prüfe "Loeschen verneint: Datei bleibt" (Test-Path "$wurzel\a\drei.log")
    Neu-Baum; Fahre @("DownArrow", "DownArrow", "F8", "J")
    Prüfe "Loeschen bestaetigt: Datei weg" (-not (Test-Path "$wurzel\a\drei.log"))
    Neu-Baum; Fahre @("DownArrow", "F8", "J")
    Prüfe "Ordner loeschen (rekursiv)" (-not (Test-Path "$wurzel\a\unter"))

    # 9 Navigation: Enter in Ordner, Tab, kopieren aus Unterordner in die andere Spalte
    Neu-Baum; Fahre @("DownArrow", "Enter", "DownArrow", "F5")
    Prüfe "In Unterordner gehen und kopieren" (Test-Path "$wurzel\b\tief.txt")

    # 10 Sicherheitsnetze
    Neu-Baum; Fahre @("F5")
    Prüfe "Auf '..' passiert beim Kopieren nichts" (@(Get-ChildItem "$wurzel\b").Count -eq 1)
    Neu-Baum; & $fm -Links "$wurzel\a" -Rechts "$wurzel\a" -Tasten @("DownArrow", "DownArrow", "F5")
    Prüfe "Quelle gleich Ziel: nichts kaputt" ((Get-Content "$wurzel\a\drei.log") -eq "drei")
    Neu-Baum; & $fm -Links "$wurzel\a" -Rechts "$wurzel\a\unter" -Tasten @("DownArrow", "F6")
    Prüfe "Ordner nicht in sich selbst verschieben" (Test-Path "$wurzel\a\unter\tief.txt")

    # 11 Pfad mit Sonderzeichen ([ ] und Leerzeichen)
    Neu-Baum; [void][IO.Directory]::CreateDirectory("$wurzel\a\mit [eckig] und leer"); Set-Content -LiteralPath "$wurzel\a\mit [eckig] und leer\x.txt" "x"
    Fahre @("DownArrow", "F5")
    Prüfe "Ordner mit [] und Leerzeichen kopiert" (Test-Path -LiteralPath "$wurzel\b\mit [eckig] und leer\x.txt")
    Neu-Baum; Set-Content -LiteralPath "$wurzel\a\[x].txt" "klammer"
    Fahre @("DownArrow", "DownArrow", "F5")   # .. , unter, [x].txt (Sortierung: '[' vor Buchstaben)
    Prüfe "Datei mit [] im Namen kopiert" (Test-Path -LiteralPath "$wurzel\b\[x].txt")

    # 12 Ansicht, Gehe-zu, Laufwerke: duerfen nichts zerstoeren und nicht abstuerzen
    Neu-Baum; Fahre @("DownArrow", "DownArrow", "F3", "Escape", "G", "t:$wurzel\b", "D", "Tab", "H", "F10")
    Prüfe "Ansicht, Gehe-zu, Laufwerke ohne Absturz" $true
    Neu-Baum; Fahre @("DownArrow", "DownArrow", "G", "t:C:\gibt\es\nicht", "Tab", "Escape")
    Prüfe "Ungueltiger Pfad ohne Absturz" $true
} finally {
    Remove-Item $wurzel -Recurse -Force -ErrorAction SilentlyContinue
}
if ($fehler -gt 0) { Write-Host "`n$fehler Fehler" -ForegroundColor Red; exit 1 }
Write-Host "`nAlle Tests bestanden" -ForegroundColor Green
