# Layout-Checks für TextCopyHelper.ps1 — ohne Pester, Exitcode 0 = alles grün.
# Baut das Fenster unsichtbar auf (Opacity 0) und misst Scrollbalken, Höhe und Zeilen.
# Das Clipboard wird dabei weder gelesen noch geschrieben.
#
#   powershell.exe -STA -ExecutionPolicy Bypass -File .\tests\TextCopyHelper.Tests.ps1
param([string]$ScriptPath = (Join-Path $PSScriptRoot "..\TextCopyHelper.ps1"))

$TextCopyHelperNoRun   = $true
$TextCopyHelperRegPath = 'HKCU:\Software\ps-tools\TextCopyHelper-Test'   # echte Einstellungen bleiben unberührt
Remove-Item $TextCopyHelperRegPath -Recurse -ErrorAction SilentlyContinue
. $ScriptPath

$script:failed = 0
function Check([string]$Name, [bool]$Condition, [string]$Detail = "") {
    if ($Condition) { Write-Host "  OK    $Name" }
    else            { Write-Host "  FAIL  $Name  $Detail" -ForegroundColor Red; $script:failed++ }
}

function Open-TestForm([string]$Plain) {
    $f = New-TextCopyForm -PlainContent $Plain
    $f.StartPosition = 'Manual'
    $f.Location      = New-Object System.Drawing.Point(0, 0)
    $f.Opacity       = 0
    $f.ShowInTaskbar = $false
    $f.Show()
    [System.Windows.Forms.Application]::DoEvents()
    return $f
}

function Assert-NoHScroll([string]$When) {
    $lh = $script:ui.LinesHost
    Check "$When - kein horizontaler Balken im Zeilenbereich" (-not $lh.HorizontalScroll.Visible)
    Check "$When - kein horizontaler Balken im Fenster" (-not $script:ui.Form.HorizontalScroll.Visible)
    $rows = Get-LineRows
    if ($rows.Count -gt 0) {
        $tooWide = @($rows | Where-Object { $_.Width -gt $lh.ClientSize.Width })
        Check "$When - keine Zeile breiter als der Client" ($tooWide.Count -eq 0) "client=$($lh.ClientSize.Width) row=$($rows[0].Width)"
        $lastBtn = $rows[0].GetControlFromPosition(2, 0)
        Check "$When - Zeilen-Knöpfe vollständig sichtbar" ($lastBtn.Right -le $rows[0].ClientSize.Width) "btnRight=$($lastBtn.Right) rowWidth=$($rows[0].ClientSize.Width)"
    }
    foreach ($bar in $script:ui.Toolbar, $script:ui.TypeBar) {
        $cut = @($bar.Controls | Where-Object { $_.Right -gt $bar.ClientSize.Width -or $_.Width -le 0 })
        Check "$When - $($bar.GetType().Name) vollständig sichtbar" ($cut.Count -eq 0) (($cut | ForEach-Object { "$($_.GetType().Name) right=$($_.Right)" }) -join ', ')
    }
}

$maxClient = [int]([System.Windows.Forms.Screen]::PrimaryScreen.WorkingArea.Height * $MAX_HEIGHT_PCT)

# ── 1. Leeres Clipboard ───────────────────────────────────────────────────────
Write-Host "Leeres Clipboard"
$f = Open-TestForm ""
$rows = Get-LineRows
Check "$MIN_LINES leere Zeilen" ($rows.Count -eq $MIN_LINES -and @($rows | Where-Object { $_.GetControlFromPosition(0,0).Text -ne "" }).Count -eq 0) "rows=$($rows.Count)"
Check "kein vertikaler Balken bei wenigen Zeilen" (-not $script:ui.LinesHost.VerticalScroll.Visible)
Assert-NoHScroll "leer"

# + Knopf
1..3 | ForEach-Object { $script:ui.AddButton.PerformClick() }
[System.Windows.Forms.Application]::DoEvents()
$rows = Get-LineRows
Check "+ fügt Zeilen an" ($rows.Count -eq $MIN_LINES + 3) "rows=$($rows.Count)"
Check "+ hängt unten an (Reihenfolge nach Top)" (@($rows | ForEach-Object { $_.Top }) -join ',' -eq (@($rows | ForEach-Object { $_.Top } | Sort-Object) -join ','))
Check "neue Zeile hat den Fokus" ($rows[-1].GetControlFromPosition(0,0).Focused)

# - Knopf
$rows[1].GetControlFromPosition(2,0).PerformClick()
[System.Windows.Forms.Application]::DoEvents()
Check "- entfernt genau eine Zeile" ((Get-LineRows).Count -eq $MIN_LINES + 2)
$f.Close(); $f.Dispose()

# ── 2. Reihenfolge der Clipboard-Zeilen ──────────────────────────────────────
Write-Host "Reihenfolge"
$f = Open-TestForm "eins`r`nzwei`r`ndrei`r`nvier`r`nfuenf`r`n"
$texts = @(Get-LineRows | ForEach-Object { $_.GetControlFromPosition(0,0).Text })
Check "Zeilen in Clipboard-Reihenfolge, ohne Scheinzeile am Ende" (($texts -join ',') -eq 'eins,zwei,drei,vier,fuenf') ($texts -join ',')
$f.Close(); $f.Dispose()

# ── 3. Viele und lange Zeilen ────────────────────────────────────────────────
Write-Host "Viele / lange Zeilen"
$many = (1..300 | ForEach-Object { if ($_ -eq 7) { "x" * 3000 } else { "Zeile $_" } }) -join "`r`n"
$f = Open-TestForm $many
Check "Starthöhe begrenzt" ($f.ClientSize.Height -le $maxClient) "client=$($f.ClientSize.Height) max=$maxClient"
Check "höchstens $MAX_LINES Zeilen als Steuerelemente" ((Get-LineRows).Count -eq $MAX_LINES)
Check "vertikaler Balken im Zeilenbereich" ($script:ui.LinesHost.VerticalScroll.Visible)
Assert-NoHScroll "300 Zeilen"
$script:ui.AddButton.PerformClick(); [System.Windows.Forms.Application]::DoEvents()
Check "+ scrollt neue Zeile ins Bild" ((Get-LineRows)[-1].Bottom -le $script:ui.LinesHost.ClientSize.Height + 1)

# Wiederholte Benutzung: Minimieren/Wiederherstellen (Paste-Knopf), Log füllen, Größe ändern
$sizeBefore = $f.Size
for ($i = 0; $i -lt 3; $i++) {
    $f.WindowState = 'Minimized'; [System.Windows.Forms.Application]::DoEvents()
    $f.WindowState = 'Normal';    [System.Windows.Forms.Application]::DoEvents()
}
1..200 | ForEach-Object { Write-UiLog ("Copied: " + ("y" * 150)) }
[System.Windows.Forms.Application]::DoEvents()
Check "Größe nach Minimieren/Wiederherstellen unverändert" ($f.Size -eq $sizeBefore) "$sizeBefore -> $($f.Size)"
Assert-NoHScroll "nach Min/Restore + Log"

foreach ($w in 360, 800, 420) {
    $f.Width = $w; [System.Windows.Forms.Application]::DoEvents()
    Assert-NoHScroll "Breite $w"
}
$f.Height = $maxClient + 200; [System.Windows.Forms.Application]::DoEvents()
Check "Größerziehen vergrößert den Zeilenbereich" ($script:ui.Split.Panel1.Height -gt 200) "panel1=$($script:ui.Split.Panel1.Height)"
$f.Close(); $f.Dispose()

# ── 4. Tipp-Einstellungen: UI ↔ Registry ─────────────────────────────────────
Write-Host "Einstellungen"
$f = Open-TestForm ""
Check "Titel trägt die Version" ($f.Text -eq "TextCopyHelper v$VERSION") $f.Text
Check "Standard: Layout Auto" ($script:ui.LayoutBox.SelectedItem.Key -eq 'auto')
Check "Standard: Verzögerung $TYPE_DELAY_MS ms" ($script:ui.DelayBox.Value -eq $TYPE_DELAY_MS)
Check "Standard schreibt nichts in die Registry" (-not (Test-Path $TextCopyHelperRegPath))
$usIdx = -1
for ($i = 0; $i -lt $script:ui.LayoutBox.Items.Count; $i++) { if ($script:ui.LayoutBox.Items[$i].Key -match '0409$|00000409$') { $usIdx = $i; break } }
Check "US-Layout steht zur Auswahl" ($usIdx -ge 0)
$script:ui.LayoutBox.SelectedIndex = $usIdx
$script:ui.DelayBox.Value = 42
$chosen = $script:ui.LayoutBox.SelectedItem.Key
$f.Close(); $f.Dispose()
Check "Layout gespeichert" ((Get-ItemProperty $TextCopyHelperRegPath).TypingLayout -eq $chosen)
Check "Verzögerung gespeichert" ((Get-ItemProperty $TextCopyHelperRegPath).TypingDelayMs -eq 42)
$f = Open-TestForm ""
Check "Layout beim nächsten Start wieder gewählt" ($script:ui.LayoutBox.SelectedItem.Key -eq $chosen) $script:ui.LayoutBox.SelectedItem.Key
Check "Verzögerung beim nächsten Start wieder gesetzt" ($script:ui.DelayBox.Value -eq 42)
$f.Close(); $f.Dispose()
Set-ItemProperty $TextCopyHelperRegPath -Name TypingLayout -Value 'hkl:DEADBEEF'
$f = Open-TestForm ""
Check "unbekanntes gespeichertes Layout fällt auf Auto zurück" ($script:ui.LayoutBox.SelectedItem.Key -eq 'auto')
$f.Close(); $f.Dispose()
Remove-Item $TextCopyHelperRegPath -Recurse -ErrorAction SilentlyContinue

Write-Host ""
if ($script:failed) { Write-Host "$script:failed Check(s) fehlgeschlagen." -ForegroundColor Red; exit 1 }
Write-Host "Alle Checks grün."
exit 0
