<#
.SYNOPSIS
    Mini-Dateimanager fuer die Konsole (Server Core): zwei Spalten, Kopieren, Verschieben, Loeschen.

.DESCRIPTION
    Nur Bordmittel (Windows PowerShell 5.1, .NET): laeuft auf Server Core, ohne Explorer und ohne notepad.exe.
    Zwei Spalten wie beim Norton Commander. Kopiert/verschoben wird immer in die andere Spalte.

    Tasten
      Pfeil auf/ab, Bild auf/ab, Pos1, Ende   bewegen
      Enter, Pfeil rechts                     Ordner oeffnen (Dateien: Ansicht)
      Rueck, Pfeil links                      eine Ebene hoch
      Tab                                     andere Spalte
      Leertaste, Einfg                        markieren (und weiter)
      A                                       alle markieren / Markierung aufheben
      F5 oder C                               kopieren  -> andere Spalte
      F6 oder M                               verschieben -> andere Spalte
      F7 oder N                               neuer Ordner
      F8 oder Entf                            loeschen
      F2 oder R                               umbenennen
      F3 oder V                               Textansicht
      G                                       zu Pfad (auch \\Server\Freigabe)
      D                                       Laufwerke
      K oder Strg+C                           markierte Dateien in die Zwischenablage (RDP: am Client einfuegbar)
      P oder Strg+V                           Dateien aus der Zwischenablage hier einfuegen (RDP: vom Client)
      =                                       andere Spalte auf denselben Pfad
      F9                                      neu lesen
      F1 oder H                               Hilfe
      F10, Q, Esc                             beenden

.PARAMETER Links
    Startpfad links. Vorgabe: aktuelles Verzeichnis.
.PARAMETER Rechts
    Startpfad rechts. Vorgabe: wie links.
.PARAMETER Tasten
    Nur fuer Tests: Tastenfolge statt Tastatur (Namen wie Down, F5, Tab, J; "t:text" = Eingabe mit Enter).
.PARAMETER OhneAnzeige
    Nur fuer Tests: nichts zeichnen.

.EXAMPLE
    .\fm.ps1 C:\ProgramData D:\
#>
param(
    [string]$Links = "",
    [string]$Rechts = "",
    [string[]]$Tasten = @(),
    [switch]$OhneAnzeige
)

$script:Warteschlange = New-Object System.Collections.Queue
foreach ($t in $Tasten) { $script:Warteschlange.Enqueue($t) }
$script:Test = ($Tasten.Count -gt 0) -or $OhneAnzeige
$script:Meldung = ""
$script:Ende = $false
$script:Aktiv = 0

# -- Hilfsfunktionen -------------------------------------------------------------

function Eltern([string]$pfad) {
    $e = Split-Path -Parent $pfad
    if ([string]::IsNullOrEmpty($e)) { return "" }
    return $e
}

function Groesse([long]$b) {
    if ($b -lt 1KB) { return "$b B" }
    if ($b -lt 1MB) { return ("{0:N1} K" -f ($b / 1KB)) }
    if ($b -lt 1GB) { return ("{0:N1} M" -f ($b / 1MB)) }
    return ("{0:N1} G" -f ($b / 1GB))
}

function Neues-Fenster([string]$pfad) {
    $p = [pscustomobject]@{ Pfad = $pfad; Items = @(); Idx = 0; Top = 0; Marks = @{} }
    Lade $p ""
    return $p
}

function Lade($p, [string]$merke) {
    $items = @()
    if ($p.Pfad -eq "") {
        foreach ($d in [System.IO.DriveInfo]::GetDrives()) {
            if ($d.IsReady) {
                $items += [pscustomobject]@{ Name = $d.Name.TrimEnd('\'); Dir = $true; Size = $d.AvailableFreeSpace; Zeit = $null; Voll = $d.Name; Hoch = $false; Laufwerk = $true }
            }
        }
    } else {
        $items += [pscustomobject]@{ Name = ".."; Dir = $true; Size = 0; Zeit = $null; Voll = (Eltern $p.Pfad); Hoch = $true; Laufwerk = $false }
        try {
            $alle = @(Get-ChildItem -LiteralPath $p.Pfad -Force -ErrorAction Stop)
            foreach ($x in ($alle | Where-Object { $_.PSIsContainer } | Sort-Object Name)) {
                $items += [pscustomobject]@{ Name = $x.Name; Dir = $true; Size = 0; Zeit = $x.LastWriteTime; Voll = $x.FullName; Hoch = $false; Laufwerk = $false }
            }
            foreach ($x in ($alle | Where-Object { -not $_.PSIsContainer } | Sort-Object Name)) {
                $items += [pscustomobject]@{ Name = $x.Name; Dir = $false; Size = $x.Length; Zeit = $x.LastWriteTime; Voll = $x.FullName; Hoch = $false; Laufwerk = $false }
            }
        } catch {
            $script:Meldung = "Kein Zugriff: " + $_.Exception.Message
        }
    }
    $p.Items = $items
    $nochDa = @{}
    foreach ($i in $items) { $nochDa[$i.Name] = $true }
    foreach ($k in @($p.Marks.Keys)) { if (-not $nochDa.ContainsKey($k)) { $p.Marks.Remove($k) } }
    $p.Idx = 0
    if ($merke -ne "") {
        for ($n = 0; $n -lt $items.Count; $n++) { if ($items[$n].Name -eq $merke) { $p.Idx = $n; break } }
    }
    $p.Top = 0
}

function Gehe-Zu($p, [string]$pfad) {
    $merke = ""
    if ($pfad -ne "") {
        if (-not (Test-Path -LiteralPath $pfad -PathType Container)) { $script:Meldung = "Pfad nicht gefunden: $pfad"; return }
        $pfad = (Resolve-Path -LiteralPath $pfad).ProviderPath
    }
    if ($p.Pfad -ne "" -and (Eltern $p.Pfad) -eq $pfad) { $merke = Split-Path -Leaf $p.Pfad }
    $p.Pfad = $pfad
    $p.Marks = @{}
    Lade $p $merke
}

function Aktuell($p) {
    if ($p.Items.Count -eq 0) { return $null }
    return $p.Items[$p.Idx]
}

function Ziele($p) {
    $liste = @()
    foreach ($i in $p.Items) {
        if ($p.Marks.ContainsKey($i.Name) -and -not $i.Hoch -and -not $i.Laufwerk) { $liste += $i }
    }
    if ($liste.Count -eq 0) {
        $c = Aktuell $p
        if ($c -and -not $c.Hoch -and -not $c.Laufwerk) { $liste += $c }
    }
    return $liste
}

# -- Eingabe -----------------------------------------------------------------------

function Hole-Taste {
    if ($script:Test) {
        if ($script:Warteschlange.Count -eq 0) { return [pscustomobject]@{ Name = "Escape"; Char = [char]0; Strg = $false } }
        $t = [string]$script:Warteschlange.Dequeue()
        if ($t.StartsWith("^") -and $t.Length -eq 2) { return [pscustomobject]@{ Name = $t.Substring(1).ToUpper(); Char = [char]0; Strg = $true } }
        if ($t.Length -eq 1) { return [pscustomobject]@{ Name = $t.ToUpper(); Char = $t[0]; Strg = $false } }
        return [pscustomobject]@{ Name = $t; Char = [char]0; Strg = $false }
    }
    $ki = [Console]::ReadKey($true)
    $strg = (($ki.Modifiers -band [ConsoleModifiers]::Control) -ne 0)
    return [pscustomobject]@{ Name = $ki.Key.ToString(); Char = $ki.KeyChar; Strg = $strg }
}

function Frage-Text([string]$frage, [string]$vorgabe) {
    if ($script:Test) {
        if ($script:Warteschlange.Count -gt 0 -and ([string]$script:Warteschlange.Peek()).StartsWith("t:")) {
            return ([string]$script:Warteschlange.Dequeue()).Substring(2)
        }
        [void](Hole-Taste)
        return $null
    }
    $text = $vorgabe
    while ($true) {
        Zeichne-Eingabe $frage $text
        $ki = [Console]::ReadKey($true)
        if ($ki.Key -eq "Enter") { return $text }
        if ($ki.Key -eq "Escape") { return $null }
        if ($ki.Key -eq "Backspace") { if ($text.Length -gt 0) { $text = $text.Substring(0, $text.Length - 1) } }
        elseif ($ki.KeyChar -ne [char]0 -and -not [char]::IsControl($ki.KeyChar)) { $text += $ki.KeyChar }
    }
}

function Frage-Janein([string]$frage) {
    if (-not $script:Test) { Zeichne-Eingabe ($frage + " (J/N)") "" }
    $k = Hole-Taste
    return ($k.Name -eq "J" -or $k.Name -eq "Y")
}

function Frage-Ueberschreiben([string]$name) {
    if (-not $script:Test) { Zeichne-Eingabe ("Existiert: " + $name + "  Ueberschreiben? (J)a (N)ein (A)lle (Esc)") "" }
    $k = Hole-Taste
    if ($k.Name -eq "J" -or $k.Name -eq "Y") { return "ja" }
    if ($k.Name -eq "A") { return "alle" }
    if ($k.Name -eq "N") { return "nein" }
    return "abbruch"
}

# -- Aktionen ----------------------------------------------------------------------

function Anderes { return $script:Fenster[1 - $script:Aktiv] }
function Dieses { return $script:Fenster[$script:Aktiv] }

function Ziel-Pruefen($quelle, $ziel) {
    if ($ziel.Pfad -eq "") { $script:Meldung = "Zielspalte zeigt die Laufwerke - erst einen Ordner waehlen."; return $false }
    if ($quelle.Pfad -eq $ziel.Pfad) { $script:Meldung = "Quelle und Ziel sind derselbe Ordner."; return $false }
    return $true
}

function Kopiere-Oder-Verschiebe([bool]$verschieben) {
    $q = Dieses; $z = Anderes
    if (-not (Ziel-Pruefen $q $z)) { return }
    $liste = @(Ziele $q)
    if ($liste.Count -eq 0) { $script:Meldung = "Nichts ausgewaehlt."; return }
    $wort = if ($verschieben) { "verschoben" } else { "kopiert" }
    $ok = 0; $fehler = 0; $alle = $false
    foreach ($i in $liste) {
        $ziel = Join-Path $z.Pfad $i.Name
        if ($i.Dir -and ($z.Pfad + "\").StartsWith($i.Voll.TrimEnd('\') + "\", [System.StringComparison]::OrdinalIgnoreCase)) {
            $script:Meldung = "Ein Ordner kann nicht in sich selbst: " + $i.Name; $fehler++; continue
        }
        $vorhanden = Test-Path -LiteralPath $ziel
        if ($vorhanden -and -not $alle) {
            $a = Frage-Ueberschreiben $i.Name
            if ($a -eq "abbruch") { $script:Meldung = "Abgebrochen. $ok $wort."; Lade-Beide; return }
            if ($a -eq "nein") { continue }
            if ($a -eq "alle") { $alle = $true }
        }
        try {
            if ($verschieben) {
                if ($vorhanden -and $i.Dir) { throw "Zielordner existiert bereits (Verschieben nur nach Loeschen)." }
                Move-Item -LiteralPath $i.Voll -Destination $ziel -Force -ErrorAction Stop
            } elseif ($i.Dir -and $vorhanden) {
                Copy-Item -Path (Join-Path $i.Voll "*") -Destination $ziel -Recurse -Force -ErrorAction Stop
            } else {
                Copy-Item -LiteralPath $i.Voll -Destination $ziel -Recurse -Force -ErrorAction Stop
            }
            $ok++
        } catch {
            $fehler++; $script:Meldung = $i.Name + ": " + $_.Exception.Message
        }
    }
    $q.Marks = @{}
    if ($fehler -eq 0) { $script:Meldung = "$ok $wort." } else { $script:Meldung = "$ok $wort, $fehler Fehler. " + $script:Meldung }
    Lade-Beide
}

function Loesche {
    $q = Dieses
    $liste = @(Ziele $q)
    if ($liste.Count -eq 0) { $script:Meldung = "Nichts ausgewaehlt."; return }
    $was = if ($liste.Count -eq 1) { "'" + $liste[0].Name + "'" } else { "$($liste.Count) Elemente" }
    if (-not (Frage-Janein ("$was loeschen?"))) { $script:Meldung = "Nicht geloescht."; return }
    $ok = 0; $fehler = 0
    foreach ($i in $liste) {
        try { Remove-Item -LiteralPath $i.Voll -Recurse -Force -ErrorAction Stop; $ok++ }
        catch { $fehler++; $script:Meldung = $i.Name + ": " + $_.Exception.Message }
    }
    $q.Marks = @{}
    if ($fehler -eq 0) { $script:Meldung = "$ok geloescht." } else { $script:Meldung = "$ok geloescht, $fehler Fehler. " + $script:Meldung }
    Lade-Beide
}

function Neuer-Ordner {
    $q = Dieses
    if ($q.Pfad -eq "") { $script:Meldung = "Hier nicht moeglich (Laufwerksliste)."; return }
    $name = Frage-Text "Neuer Ordner: " ""
    if ([string]::IsNullOrWhiteSpace($name)) { return }
    try { New-Item -ItemType Directory -Path (Join-Path $q.Pfad $name) -ErrorAction Stop | Out-Null; $script:Meldung = "Ordner '$name' angelegt." }
    catch { $script:Meldung = $_.Exception.Message }
    Lade-Beide $name
}

function Benenne-Um {
    $q = Dieses
    $c = Aktuell $q
    if (-not $c -or $c.Hoch -or $c.Laufwerk) { return }
    $neu = Frage-Text "Umbenennen in: " $c.Name
    if ([string]::IsNullOrWhiteSpace($neu) -or $neu -eq $c.Name) { return }
    try { Rename-Item -LiteralPath $c.Voll -NewName $neu -ErrorAction Stop; $script:Meldung = "'" + $c.Name + "' -> '$neu'" }
    catch { $script:Meldung = $_.Exception.Message }
    Lade-Beide $neu
}

function Lade-Beide([string]$merke = "") {
    foreach ($p in $script:Fenster) {
        $m = ""
        if ($p -eq (Dieses)) { $m = $merke }
        if ($m -eq "") { $c = Aktuell $p; if ($c) { $m = $c.Name } }
        $alteMarks = $p.Marks
        Lade $p $m
    }
}

function Zeige-Datei($i) {
    if ($i.Dir) { return }
    try {
        $fs = [System.IO.File]::Open($i.Voll, 'Open', 'Read', 'ReadWrite')
        try {
            $puffer = New-Object byte[] ([Math]::Min(400KB, [Math]::Max(1, $fs.Length)))
            $n = $fs.Read($puffer, 0, $puffer.Length)
        } finally { $fs.Dispose() }
    } catch { $script:Meldung = $_.Exception.Message; return }
    $binaer = $false
    for ($b = 0; $b -lt [Math]::Min($n, 8000); $b++) { if ($puffer[$b] -eq 0) { $binaer = $true; break } }
    if ($binaer) {
        $zeilen = @("Binaerdatei, " + (Groesse $i.Size) + " - erste 512 Bytes:", "")
        for ($o = 0; $o -lt [Math]::Min($n, 512); $o += 16) {
            $teil = $puffer[$o..([Math]::Min($o + 15, $n - 1))]
            $hex = ($teil | ForEach-Object { $_.ToString("X2") }) -join " "
            $txt = -join ($teil | ForEach-Object { if ($_ -ge 32 -and $_ -lt 127) { [char]$_ } else { "." } })
            $zeilen += ("{0:X6}  {1}  {2}" -f $o, $hex.PadRight(47), $txt)
        }
    } else {
        try { $text = (New-Object System.Text.UTF8Encoding($false, $true)).GetString($puffer, 0, $n) }
        catch { $text = [System.Text.Encoding]::GetEncoding(1252).GetString($puffer, 0, $n) }
        $zeilen = @($text -split "`r?`n")
    }
    if ($script:Test) { $script:Meldung = "Ansicht: " + $zeilen.Count + " Zeilen"; [void](Hole-Taste); return }
    $top = 0
    while ($true) {
        $W = [Console]::WindowWidth; $H = [Console]::WindowHeight; $sicht = $H - 2
        [Console]::SetCursorPosition(0, 0)
        [Console]::BackgroundColor = "DarkCyan"; [Console]::ForegroundColor = "White"
        [Console]::Write((" " + $i.Name + "  (" + ($top + 1) + "/" + $zeilen.Count + ")").PadRight($W - 1).Substring(0, $W - 1))
        [Console]::ResetColor()
        for ($y = 0; $y -lt $sicht; $y++) {
            [Console]::SetCursorPosition(0, 1 + $y)
            $z = ""
            if ($top + $y -lt $zeilen.Count) { $z = $zeilen[$top + $y].Replace("`t", "    ") }
            [Console]::Write($z.PadRight($W - 1).Substring(0, $W - 1))
        }
        [Console]::SetCursorPosition(0, $H - 1)
        [Console]::BackgroundColor = "DarkCyan"; [Console]::ForegroundColor = "White"
        [Console]::Write(" Pfeile/Bild: blaettern   Pos1/Ende   Esc/Q: zurueck".PadRight($W - 1).Substring(0, $W - 1))
        [Console]::ResetColor()
        $k = Hole-Taste
        $max = [Math]::Max(0, $zeilen.Count - $sicht)
        switch ($k.Name) {
            "UpArrow"   { $top = [Math]::Max(0, $top - 1) }
            "DownArrow" { $top = [Math]::Min($max, $top + 1) }
            "PageUp"    { $top = [Math]::Max(0, $top - $sicht) }
            "PageDown"  { $top = [Math]::Min($max, $top + $sicht) }
            "Home"      { $top = 0 }
            "End"       { $top = $max }
            "Escape"    { return }
            "Q"         { return }
        }
    }
}

function Zeige-Hilfe {
    if ($script:Test) { return }
    [Console]::Clear()
    $text = (Get-Help $PSCommandPath -ErrorAction SilentlyContinue | Out-String)
    if ([string]::IsNullOrWhiteSpace($text)) { $text = "Tasten: siehe Kopf der Datei fm.ps1." }
    [Console]::Write($text.Substring(0, [Math]::Min($text.Length, 2500)))
    [Console]::Write("`n[Taste druecken]")
    [void][Console]::ReadKey($true)
}

# -- Zwischenablage (RDP: Dateien zum Server und zurueck) ---------------------------
#
# Server -> Client: Die markierten Dateien kommen als Dateiliste (CF_HDROP) in die Zwischenablage; der
#                   RDP-Dienst (rdpclip) reicht sie an den Client weiter -> dort im Explorer Strg+V.
# Client -> Server: Dateien, die am Client kopiert wurden, liegen auf dem Server als "virtuelle Dateien"
#                   (FileGroupDescriptorW + FileContents). Genau so liest sie auch der Explorer beim Einfuegen.

$script:QuelleCs = @'
using System;
using System.Collections.Generic;
using System.IO;
using System.Runtime.InteropServices;
using System.Runtime.InteropServices.ComTypes;
using System.Text;

public class FmZwischenablage
{
    [DllImport("ole32.dll")] static extern int OleGetClipboard(out System.Runtime.InteropServices.ComTypes.IDataObject o);
    [DllImport("ole32.dll")] static extern void ReleaseStgMedium(ref STGMEDIUM m);
    [DllImport("user32.dll", CharSet = CharSet.Unicode)] static extern uint RegisterClipboardFormat(string name);
    [DllImport("kernel32.dll")] static extern IntPtr GlobalLock(IntPtr h);
    [DllImport("kernel32.dll")] static extern bool GlobalUnlock(IntPtr h);
    [DllImport("kernel32.dll")] static extern UIntPtr GlobalSize(IntPtr h);

    public class Eintrag { public string Name; public bool IstOrdner; public long Groesse; public bool GroesseBekannt; }

    static System.Runtime.InteropServices.ComTypes.IDataObject Hole()
    {
        System.Runtime.InteropServices.ComTypes.IDataObject o;
        int hr = OleGetClipboard(out o);
        if (hr != 0) throw new COMException("Zwischenablage nicht lesbar", hr);
        return o;
    }

    static FORMATETC F(string name, int index, TYMED t)
    {
        FORMATETC f = new FORMATETC();
        f.cfFormat = unchecked((short)RegisterClipboardFormat(name));
        f.dwAspect = DVASPECT.DVASPECT_CONTENT;
        f.lindex = index;
        f.ptd = IntPtr.Zero;
        f.tymed = t;
        return f;
    }

    static byte[] Bytes(IntPtr h)
    {
        IntPtr p = GlobalLock(h);
        try
        {
            int n = (int)GlobalSize(h).ToUInt32();
            byte[] b = new byte[n];
            Marshal.Copy(p, b, 0, n);
            return b;
        }
        finally { GlobalUnlock(h); }
    }

    public static List<Eintrag> Liste()
    {
        List<Eintrag> res = new List<Eintrag>();
        System.Runtime.InteropServices.ComTypes.IDataObject o = Hole();
        FORMATETC f = F("FileGroupDescriptorW", -1, TYMED.TYMED_HGLOBAL);
        if (o.QueryGetData(ref f) != 0) return res;
        STGMEDIUM m;
        o.GetData(ref f, out m);
        try
        {
            byte[] b = Bytes(m.unionmember);
            int n = BitConverter.ToInt32(b, 0);
            for (int i = 0; i < n; i++)
            {
                int off = 4 + i * 592;                       // FILEDESCRIPTORW ist 592 Bytes gross
                if (off + 592 > b.Length) break;
                uint flags = BitConverter.ToUInt32(b, off);
                uint attr = BitConverter.ToUInt32(b, off + 36);
                uint hi = BitConverter.ToUInt32(b, off + 64);
                uint lo = BitConverter.ToUInt32(b, off + 68);
                string name = Encoding.Unicode.GetString(b, off + 72, 520);
                int z = name.IndexOf('\0');
                if (z >= 0) name = name.Substring(0, z);
                Eintrag e = new Eintrag();
                e.Name = name;
                e.IstOrdner = (attr & 0x10) != 0 && (flags & 0x4) != 0;
                e.GroesseBekannt = (flags & 0x40) != 0;
                e.Groesse = ((long)hi << 32) | lo;
                res.Add(e);
            }
        }
        finally { ReleaseStgMedium(ref m); }
        return res;
    }

    // Schreibt den Inhalt der virtuellen Datei Nr. index nach pfad. Liefert die Anzahl Bytes.
    public static long Speichere(int index, string pfad, long erwarteteGroesse)
    {
        System.Runtime.InteropServices.ComTypes.IDataObject o = Hole();
        FORMATETC f = F("FileContents", index, TYMED.TYMED_ISTREAM | TYMED.TYMED_HGLOBAL);
        STGMEDIUM m;
        o.GetData(ref f, out m);
        long gesamt = 0;
        try
        {
            using (FileStream fs = new FileStream(pfad, FileMode.Create, FileAccess.Write))
            {
                if (m.tymed == TYMED.TYMED_ISTREAM)
                {
                    IStream s = (IStream)Marshal.GetObjectForIUnknown(m.unionmember);
                    byte[] buf = new byte[81920];
                    IntPtr pn = Marshal.AllocCoTaskMem(4);
                    try
                    {
                        while (true)
                        {
                            s.Read(buf, buf.Length, pn);
                            int n = Marshal.ReadInt32(pn);
                            if (n <= 0) break;
                            fs.Write(buf, 0, n);
                            gesamt += n;
                        }
                    }
                    finally { Marshal.FreeCoTaskMem(pn); Marshal.ReleaseComObject(s); }
                }
                else if (m.tymed == TYMED.TYMED_HGLOBAL)
                {
                    byte[] b = Bytes(m.unionmember);
                    int n = b.Length;
                    if (erwarteteGroesse > 0 && erwarteteGroesse < n) n = (int)erwarteteGroesse;   // HGLOBAL kann gerundet sein
                    fs.Write(b, 0, n);
                    gesamt = n;
                }
                else throw new InvalidOperationException("Unbekanntes Datenformat: " + m.tymed);
            }
        }
        finally { ReleaseStgMedium(ref m); }
        return gesamt;
    }
}
'@

function Zwischenablage-Bereit {
    if ($script:ZwBereit) { return $true }
    try {
        if ([System.Threading.Thread]::CurrentThread.GetApartmentState() -ne "STA") {
            $script:Meldung = "Zwischenablage braucht STA: PowerShell mit -STA starten."; return $false
        }
        Add-Type -AssemblyName System.Windows.Forms
        if (-not ("FmZwischenablage" -as [type])) { Add-Type -TypeDefinition $script:QuelleCs -Language CSharp }
        $script:ZwBereit = $true
        return $true
    } catch { $script:Meldung = "Zwischenablage nicht verfuegbar: " + $_.Exception.Message; return $false }
}

function In-Zwischenablage {
    $q = Dieses
    $liste = @(Ziele $q)
    if ($liste.Count -eq 0) { $script:Meldung = "Nichts ausgewaehlt."; return }
    if (-not (Zwischenablage-Bereit)) { return }
    try {
        $sc = New-Object System.Collections.Specialized.StringCollection
        foreach ($i in $liste) { [void]$sc.Add($i.Voll) }
        $do = New-Object System.Windows.Forms.DataObject
        $do.SetFileDropList($sc)
        $do.SetData("Preferred DropEffect", (New-Object System.IO.MemoryStream (, [byte[]](1, 0, 0, 0))))   # 1 = kopieren
        [System.Windows.Forms.Clipboard]::SetDataObject($do, $true)
        $script:Meldung = "$($liste.Count) in der Zwischenablage. Am Client im Explorer mit Strg+V einfuegen."
    } catch { $script:Meldung = "Zwischenablage: " + $_.Exception.Message }
}

# Sicherer Zielpfad fuer einen Namen aus der Zwischenablage: nie ausserhalb des Zielordners ("..\..\", absolute Pfade).
function Sicherer-Pfad([string]$ordner, [string]$name) {
    if ([string]::IsNullOrWhiteSpace($name)) { return $null }
    if ([System.IO.Path]::IsPathRooted($name) -or $name.Contains(":")) { return $null }
    foreach ($teil in ($name -split '[\\/]')) { if ($teil -eq "..") { return $null } }
    $basis = [System.IO.Path]::GetFullPath($ordner).TrimEnd('\') + "\"
    $voll = [System.IO.Path]::GetFullPath((Join-Path $ordner $name))
    if (-not $voll.StartsWith($basis, [System.StringComparison]::OrdinalIgnoreCase)) { return $null }
    return $voll
}

function Aus-Zwischenablage {
    $z = Dieses
    if ($z.Pfad -eq "") { $script:Meldung = "Erst einen Ordner waehlen (Laufwerksliste)."; return }
    if (-not (Zwischenablage-Bereit)) { return }
    $ok = 0; $fehler = 0; $alle = $false; $abbruch = $false
    try {
        if ([System.Windows.Forms.Clipboard]::ContainsFileDropList()) {
            # Dateien, die lokal (auf diesem Rechner) kopiert wurden
            foreach ($quelle in @([System.Windows.Forms.Clipboard]::GetFileDropList())) {
                $name = Split-Path -Leaf $quelle
                $ziel = Join-Path $z.Pfad $name
                if ((Test-Path -LiteralPath $ziel) -and -not $alle) {
                    $a = Frage-Ueberschreiben $name
                    if ($a -eq "abbruch") { $abbruch = $true; break }
                    if ($a -eq "nein") { continue }
                    if ($a -eq "alle") { $alle = $true }
                }
                try { Copy-Item -LiteralPath $quelle -Destination $ziel -Recurse -Force -ErrorAction Stop; $ok++ }
                catch { $fehler++; $script:Meldung = "$name`: " + $_.Exception.Message }
            }
        } else {
            # Dateien vom RDP-Client: virtuelle Dateien
            $eintraege = @([FmZwischenablage]::Liste())
            if ($eintraege.Count -eq 0) { $script:Meldung = "Keine Dateien in der Zwischenablage."; return }
            for ($n = 0; $n -lt $eintraege.Count; $n++) {
                $e = $eintraege[$n]
                $ziel = Sicherer-Pfad $z.Pfad $e.Name
                if (-not $ziel) { $fehler++; $script:Meldung = "Unsicherer Name uebersprungen: " + $e.Name; continue }
                if ($e.IstOrdner) { [void][System.IO.Directory]::CreateDirectory($ziel); continue }
                if ((Test-Path -LiteralPath $ziel) -and -not $alle) {
                    $a = Frage-Ueberschreiben $e.Name
                    if ($a -eq "abbruch") { $abbruch = $true; break }
                    if ($a -eq "nein") { continue }
                    if ($a -eq "alle") { $alle = $true }
                }
                try {
                    [void][System.IO.Directory]::CreateDirectory([System.IO.Path]::GetDirectoryName($ziel))
                    $groesse = 0; if ($e.GroesseBekannt) { $groesse = $e.Groesse }
                    [void][FmZwischenablage]::Speichere($n, $ziel, $groesse)
                    $ok++
                } catch { $fehler++; $script:Meldung = $e.Name + ": " + $_.Exception.Message }
            }
        }
    } catch { $script:Meldung = "Zwischenablage: " + $_.Exception.Message; Lade-Beide; return }
    if ($abbruch) { $script:Meldung = "Abgebrochen. $ok eingefuegt." }
    elseif ($fehler -eq 0) { $script:Meldung = "$ok eingefuegt." }
    else { $script:Meldung = "$ok eingefuegt, $fehler Fehler. " + $script:Meldung }
    Lade-Beide
}

# -- Anzeige -----------------------------------------------------------------------

function Zeile-Fuer($i, [int]$breite, [bool]$markiert) {
    $mark = if ($markiert) { "*" } else { " " }
    if ($i.Hoch) { $rest = "<HOCH>" }
    elseif ($i.Laufwerk) { $rest = Groesse $i.Size; $rest = "frei " + $rest }
    elseif ($i.Dir) { $rest = "<DIR>" }
    else { $rest = Groesse $i.Size }
    $nameBreite = $breite - 2 - 12
    if ($nameBreite -lt 4) { $nameBreite = 4 }
    $name = $i.Name
    if ($name.Length -gt $nameBreite) { $name = $name.Substring(0, $nameBreite - 1) + "~" }
    return $mark + $name.PadRight($nameBreite) + " " + $rest.PadLeft(11)
}

function Zeichne {
    if ($script:Test) { return }
    $W = [Console]::WindowWidth; $H = [Console]::WindowHeight
    if ($W -lt 40 -or $H -lt 8) { return }
    $zeilen = $H - 4
    $bw = [int][Math]::Floor($W / 2)
    for ($k = 0; $k -lt 2; $k++) {
        $p = $script:Fenster[$k]
        $x = $k * $bw
        $breite = if ($k -eq 0) { $bw } else { $W - $bw }
        $breite = $breite - 1
        if ($p.Idx -lt $p.Top) { $p.Top = $p.Idx }
        if ($p.Idx -ge $p.Top + $zeilen) { $p.Top = $p.Idx - $zeilen + 1 }
        $kopf = if ($p.Pfad -eq "") { "Laufwerke" } else { $p.Pfad }
        if ($kopf.Length -gt $breite - 2) { $kopf = "~" + $kopf.Substring($kopf.Length - ($breite - 3)) }
        [Console]::SetCursorPosition($x, 0)
        if ($k -eq $script:Aktiv) { [Console]::BackgroundColor = "Cyan"; [Console]::ForegroundColor = "Black" } else { [Console]::BackgroundColor = "DarkGray"; [Console]::ForegroundColor = "White" }
        [Console]::Write((" " + $kopf).PadRight($breite))
        [Console]::ResetColor()
        for ($y = 0; $y -lt $zeilen; $y++) {
            [Console]::SetCursorPosition($x, 1 + $y)
            $n = $p.Top + $y
            if ($n -lt $p.Items.Count) {
                $i = $p.Items[$n]
                $text = Zeile-Fuer $i $breite ($p.Marks.ContainsKey($i.Name))
                if ($n -eq $p.Idx -and $k -eq $script:Aktiv) { [Console]::BackgroundColor = "Cyan"; [Console]::ForegroundColor = "Black" }
                elseif ($n -eq $p.Idx) { [Console]::BackgroundColor = "DarkGray"; [Console]::ForegroundColor = "White" }
                elseif ($p.Marks.ContainsKey($i.Name)) { [Console]::ForegroundColor = "Green" }
                elseif ($i.Dir) { [Console]::ForegroundColor = "Yellow" }
                [Console]::Write($text.PadRight($breite).Substring(0, $breite))
                [Console]::ResetColor()
            } else {
                [Console]::Write("".PadRight($breite))
            }
            [Console]::Write(" ")
        }
    }
    # Statuszeile: aktuelles Element bzw. Markierung
    $q = Dieses
    $c = Aktuell $q
    $info = ""
    if ($q.Marks.Count -gt 0) {
        $sum = 0; foreach ($i in $q.Items) { if ($q.Marks.ContainsKey($i.Name) -and -not $i.Dir) { $sum += $i.Size } }
        $info = " " + $q.Marks.Count + " markiert (" + (Groesse $sum) + ")"
    } elseif ($c -and -not $c.Hoch) {
        $info = " " + $c.Name
        if (-not $c.Dir) { $info += "  " + (Groesse $c.Size) }
        if ($c.Zeit) { $info += "  " + $c.Zeit.ToString("yyyy-MM-dd HH:mm") }
    }
    [Console]::SetCursorPosition(0, $H - 3)
    [Console]::BackgroundColor = "DarkBlue"; [Console]::ForegroundColor = "White"
    [Console]::Write($info.PadRight($W - 1).Substring(0, $W - 1))
    [Console]::ResetColor()
    [Console]::SetCursorPosition(0, $H - 2)
    [Console]::ForegroundColor = "Yellow"
    [Console]::Write((" " + $script:Meldung).PadRight($W - 1).Substring(0, $W - 1))
    [Console]::ResetColor()
    [Console]::SetCursorPosition(0, $H - 1)
    [Console]::BackgroundColor = "DarkCyan"; [Console]::ForegroundColor = "White"
    $hilfe = " F1 Hilfe F2 Umben F3 Ansicht F5 Kopie F6 Versch F7 Ordner F8 Loesch K>Zwabl P<Zwabl Tab D F10"
    [Console]::Write($hilfe.PadRight($W - 1).Substring(0, $W - 1))
    [Console]::ResetColor()
}

function Zeichne-Eingabe([string]$frage, [string]$text) {
    $W = [Console]::WindowWidth; $H = [Console]::WindowHeight
    [Console]::SetCursorPosition(0, $H - 2)
    [Console]::BackgroundColor = "DarkMagenta"; [Console]::ForegroundColor = "White"
    $zeile = " " + $frage + $text + "_"
    if ($zeile.Length -gt $W - 1) { $zeile = $zeile.Substring($zeile.Length - ($W - 1)) }
    [Console]::Write($zeile.PadRight($W - 1))
    [Console]::ResetColor()
}

# -- Hauptschleife -----------------------------------------------------------------

function Bewege([int]$delta) {
    $p = Dieses
    if ($p.Items.Count -eq 0) { return }
    $p.Idx = [Math]::Max(0, [Math]::Min($p.Items.Count - 1, $p.Idx + $delta))
}

function Oeffne($p, $i) {
    if (-not $i) { return }
    if ($i.Dir) { Gehe-Zu $p $i.Voll } else { Zeige-Datei $i }
}

function Behandle($k) {
    $p = Dieses
    $script:Meldung = ""
    if ($k.Strg -and $k.Name -eq "C") { In-Zwischenablage; return }
    if ($k.Strg -and $k.Name -eq "V") { Aus-Zwischenablage; return }
    $zeilen = 20
    if (-not $script:Test) { $zeilen = [Math]::Max(1, [Console]::WindowHeight - 5) }
    switch ($k.Name) {
        "UpArrow"    { Bewege -1 }
        "DownArrow"  { Bewege 1 }
        "PageUp"     { Bewege (-$zeilen) }
        "PageDown"   { Bewege $zeilen }
        "Home"       { Bewege (-100000) }
        "End"        { Bewege 100000 }
        "Enter"      { Oeffne $p (Aktuell $p) }
        "RightArrow" { $c = Aktuell $p; if ($c -and $c.Dir) { Oeffne $p $c } }
        "Backspace"  { if ($p.Pfad -ne "") { Gehe-Zu $p (Eltern $p.Pfad) } }
        "LeftArrow"  { if ($p.Pfad -ne "") { Gehe-Zu $p (Eltern $p.Pfad) } }
        "Tab"        { $script:Aktiv = 1 - $script:Aktiv }
        "Spacebar"   { Markiere $p }
        "Insert"     { Markiere $p }
        "F5"         { Kopiere-Oder-Verschiebe $false }
        "C"          { Kopiere-Oder-Verschiebe $false }
        "F6"         { Kopiere-Oder-Verschiebe $true }
        "M"          { Kopiere-Oder-Verschiebe $true }
        "F7"         { Neuer-Ordner }
        "N"          { Neuer-Ordner }
        "F8"         { Loesche }
        "Delete"     { Loesche }
        "F2"         { Benenne-Um }
        "R"          { Benenne-Um }
        "F3"         { $c = Aktuell $p; if ($c) { Zeige-Datei $c } }
        "V"          { $c = Aktuell $p; if ($c) { Zeige-Datei $c } }
        "G"          { $ziel = Frage-Text "Gehe zu Pfad: " $p.Pfad; if ($ziel) { Gehe-Zu $p $ziel } }
        "D"          { Gehe-Zu $p "" }
        "K"          { In-Zwischenablage }
        "P"          { Aus-Zwischenablage }
        "F9"         { Lade-Beide }
        "F1"         { Zeige-Hilfe }
        "H"          { Zeige-Hilfe }
        "F10"        { $script:Ende = $true }
        "Q"          { $script:Ende = $true }
        "Escape"     { $script:Ende = $true }
        "A"          { Markiere-Alle $p }
        default {
            if ($k.Char -eq "=") { Gehe-Zu (Anderes) $p.Pfad }
        }
    }
}

function Markiere($p) {
    $c = Aktuell $p
    if (-not $c -or $c.Hoch -or $c.Laufwerk) { Bewege 1; return }
    if ($p.Marks.ContainsKey($c.Name)) { $p.Marks.Remove($c.Name) } else { $p.Marks[$c.Name] = $true }
    Bewege 1
}

function Markiere-Alle($p) {
    if ($p.Marks.Count -gt 0) { $p.Marks = @{}; return }
    foreach ($i in $p.Items) { if (-not $i.Hoch -and -not $i.Laufwerk) { $p.Marks[$i.Name] = $true } }
}

# Start
if ($Links -eq "") { $Links = (Get-Location).ProviderPath }
if ($Rechts -eq "") { $Rechts = $Links }
$script:Fenster = @((Neues-Fenster $Links), (Neues-Fenster $Rechts))

try {
    if (-not $script:Test) { $script:StrgC = [Console]::TreatControlCAsInput; [Console]::TreatControlCAsInput = $true; [Console]::CursorVisible = $false; [Console]::Clear() }
    while (-not $script:Ende) {
        Zeichne
        $k = Hole-Taste
        Behandle $k
    }
} finally {
    if (-not $script:Test) { [Console]::TreatControlCAsInput = $script:StrgC; [Console]::ResetColor(); [Console]::CursorVisible = $true; [Console]::Clear() }
}
