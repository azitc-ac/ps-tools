# Tippt ein Testmuster in die VMware-Konsole, OHNE dass vorher ein anderes Fenster den Fokus hatte.
# Trennt zwei Ursachen, wenn im Gast nichts ankommt:
#   - Workstation hat die Eingabe-Übernahme verloren (Klick auf den Knopf im Tool)  → hier kommt OK
#   - Workstation verwirft eingespeiste Tasten grundsätzlich                        → hier kommt auch nichts
#
# Start per Doppelklick auf grabbed-typing-test.cmd oder:
#   powershell -ExecutionPolicy Bypass -File .\tests\vmconsole\Invoke-GrabbedTyping.ps1 [-Pattern pw|ascii] [-DelayMs 15]
param(
    [ValidateSet('pw', 'ascii')][string]$Pattern = 'pw',
    [int]$DelayMs   = 15,
    [int]$Countdown = 8
)
$ErrorActionPreference = 'Stop'

$TextCopyHelperNoRun = $true
. (Join-Path $PSScriptRoot "..\..\TextCopyHelper.ps1")

$text = [IO.File]::ReadAllText((Join-Path $PSScriptRoot "iso\$Pattern.txt"))

while ($true) {
    Write-Host ""
    Write-Host "Muster '$Pattern' ($($text.Length) Zeichen), Delay $DelayMs ms" -ForegroundColor Cyan
    Write-Host "Im Gast muss 'sh /mnt/check.sh $Pattern' laufen und auf Eingabe warten."
    Write-Host "Jetzt in die VM-Konsole klicken (unten muss 'press Ctrl+Alt' stehen), dann nichts anfassen."
    for ($i = $Countdown; $i -gt 0; $i--) { Write-Host -NoNewline "$i "; Start-Sleep -Seconds 1 }
    Write-Host ""

    $h     = [KeyTyper]::ForegroundWindow()
    $title = [KeyTyper]::WindowTitle($h)
    if ($title -notmatch 'VMware') {
        # Schutz: Muster nicht in ein fremdes Fenster tippen
        Write-Host "Abbruch: Vorn ist '$title', kein VMware-Fenster. Nichts getippt." -ForegroundColor Red
    } else {
        $hkl = [KeyTyper]::LayoutOfWindow($h)
        $r   = [KeyTyper]::TypeText($text, $hkl, $DelayMs, $h)
        Write-Host "Ziel: '$title', Layout $(Get-HklName $hkl)"
        if ($r.Aborted) { Write-Host "Getippt: $($r.Typed) von $($text.Length) - abgebrochen: $($r.Aborted)" -ForegroundColor Yellow }
        else            { Write-Host "Getippt: $($r.Typed) von $($text.Length) Zeichen." -ForegroundColor Green }
        Write-Host "Jetzt im Gast Enter drücken und das Ergebnis ablesen."
    }

    Write-Host ""
    $a = Read-Host "Nochmal? Neues Delay in ms eingeben (z. B. 0 oder 50), Enter = gleiches Delay, q = Ende"
    if ($a -eq 'q') { break }
    if ($a -match '^\d+$') { $DelayMs = [int]$a }
}
