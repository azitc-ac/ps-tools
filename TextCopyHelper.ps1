Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing

[System.Windows.Forms.Application]::EnableVisualStyles()

# ========== Native SendInput (Keyboard / Scancode) ==========
if (-not ('ScanInput' -as [type])) {
Add-Type -Language CSharp @'
using System;
using System.Runtime.InteropServices;

public static class ScanInput
{
    [StructLayout(LayoutKind.Sequential)]
    public struct INPUT { public uint type; public InputUnion U; }

    [StructLayout(LayoutKind.Explicit)]
    public struct InputUnion {
        [FieldOffset(0)] public MOUSEINPUT mi;
        [FieldOffset(0)] public KEYBDINPUT ki;
        [FieldOffset(0)] public HARDWAREINPUT hi;
    }

    [StructLayout(LayoutKind.Sequential)]
    public struct MOUSEINPUT { public int dx, dy; public uint mouseData, dwFlags, time; public IntPtr dwExtraInfo; }

    [StructLayout(LayoutKind.Sequential)]
    public struct KEYBDINPUT { public ushort wVk, wScan; public uint dwFlags, time; public IntPtr dwExtraInfo; }

    [StructLayout(LayoutKind.Sequential)]
    public struct HARDWAREINPUT { public uint uMsg; public ushort wParamL, wParamH; }

    private const uint INPUT_KEYBOARD        = 1;
    private const uint KEYEVENTF_SCANCODE    = 0x0008;
    private const uint KEYEVENTF_KEYUP       = 0x0002;
    private const uint KEYEVENTF_EXTENDEDKEY = 0x0001;
    private const uint MAPVK_VK_TO_VSC_EX    = 0x04;

    [DllImport("user32.dll", SetLastError = true)]
    private static extern uint SendInput(uint nInputs, INPUT[] pInputs, int cbSize);
    [DllImport("user32.dll")]
    private static extern short VkKeyScanExW(char ch, IntPtr dwhkl);
    [DllImport("user32.dll")]
    private static extern uint MapVirtualKeyEx(uint code, uint mapType, IntPtr dwhkl);
    [DllImport("user32.dll")]
    private static extern IntPtr GetKeyboardLayout(uint threadId);

    public static bool TryGetScanAndMods(
        char ch, out ushort scan, out bool needShift, out bool needLCtrl,
        out bool needRAltExt, out bool ext, out bool isDeadKey)
    {
        scan = 0; needShift = false; needLCtrl = false;
        needRAltExt = false; ext = false; isDeadKey = false;

        IntPtr hkl = GetKeyboardLayout(0);
        short result = VkKeyScanExW(ch, hkl);
        if (result == -1) return false;

        byte vk = (byte)(result & 0xFF);
        byte sh = (byte)((result >> 8) & 0xFF);
        needShift = (sh & 1) != 0;
        bool ctrl = (sh & 2) != 0;
        bool alt  = (sh & 4) != 0;
        needLCtrl   = ctrl || alt;
        needRAltExt = alt;

        uint scEx = MapVirtualKeyEx(vk, MAPVK_VK_TO_VSC_EX, hkl);
        if (scEx == 0) return false;

        ext  = (scEx & 0x100) != 0;
        scan = (ushort)(scEx & 0xFF);
        if (ch == '^' || ch == '`') isDeadKey = true;
        return true;
    }

    private static void SendKey(ushort scan, bool ext, bool up)
    {
        INPUT[] inp = new INPUT[1];
        inp[0].type = INPUT_KEYBOARD;
        inp[0].U.ki.wVk = 0;
        inp[0].U.ki.wScan = scan;
        uint flags = KEYEVENTF_SCANCODE;
        if (ext) flags |= KEYEVENTF_EXTENDEDKEY;
        if (up)  flags |= KEYEVENTF_KEYUP;
        inp[0].U.ki.dwFlags = flags;
        inp[0].U.ki.time = 0;
        inp[0].U.ki.dwExtraInfo = IntPtr.Zero;
        uint sent = SendInput(1, inp, Marshal.SizeOf(typeof(INPUT)));
        if (sent == 0)
            throw new System.ComponentModel.Win32Exception(Marshal.GetLastWin32Error());
    }

    public static void ModDown_LCtrl()  { SendKey(0x1D, false, false); }
    public static void ModUp_LCtrl()    { SendKey(0x1D, false, true);  }
    public static void ModDown_LShift() { SendKey(0x2A, false, false); }
    public static void ModUp_LShift()   { SendKey(0x2A, false, true);  }
    public static void ModDown_RAlt()   { SendKey(0x38, true,  false); }
    public static void ModUp_RAlt()     { SendKey(0x38, true,  true);  }

    public static void SendCharByScan(char ch, int delayMs)
    {
        ushort scan;
        bool needShift, needLCtrl, needRAltExt, ext, isDeadKey;
        if (!TryGetScanAndMods(ch, out scan, out needShift, out needLCtrl, out needRAltExt, out ext, out isDeadKey))
            throw new InvalidOperationException("Char not representable in current layout: " + ch);

        if (needLCtrl)   ModDown_LCtrl();
        if (needRAltExt) ModDown_RAlt();
        if (needShift)   ModDown_LShift();

        if (isDeadKey) {
            SendKey(scan, ext, false); SendKey(scan, ext, true);
            SendKey(0x39, false, false); SendKey(0x39, false, true);
        } else {
            SendKey(scan, ext, false); SendKey(scan, ext, true);
        }

        if (needShift)   ModUp_LShift();
        if (needRAltExt) ModUp_RAlt();
        if (needLCtrl)   ModUp_LCtrl();
    }
}
'@
}

# ========== Clipboard helpers (native Win32, kein STA erforderlich) ==========
# Klassenname WinClip — eindeutig, kollidiert nicht mit alten Add-Type-Caches
if (-not ('WinClip' -as [type])) {
Add-Type -Language CSharp @'
using System;
using System.Runtime.InteropServices;

public static class WinClip
{
    // ── Read ──────────────────────────────────────────────────────────────────
    [DllImport("user32.dll", SetLastError=true)]  public static extern bool   OpenClipboard(IntPtr h);
    [DllImport("user32.dll", SetLastError=true)]  public static extern bool   CloseClipboard();
    [DllImport("user32.dll", SetLastError=true)]  public static extern IntPtr GetClipboardData(uint format);
    [DllImport("user32.dll", CharSet=CharSet.Auto)]
    public static extern uint RegisterClipboardFormat(string name);
    [DllImport("kernel32.dll", SetLastError=true)] public static extern IntPtr  GlobalLock(IntPtr h);
    [DllImport("kernel32.dll", SetLastError=true)] public static extern bool    GlobalUnlock(IntPtr h);
    [DllImport("kernel32.dll", SetLastError=true)] public static extern UIntPtr GlobalSize(IntPtr h);

    // ── Write ─────────────────────────────────────────────────────────────────
    [DllImport("user32.dll",   SetLastError=true)] public static extern bool   EmptyClipboard();
    [DllImport("user32.dll",   SetLastError=true)] public static extern IntPtr SetClipboardData(uint format, IntPtr hMem);
    [DllImport("kernel32.dll", SetLastError=true)] public static extern IntPtr GlobalAlloc(uint uFlags, UIntPtr dwBytes);

    public const uint CF_UNICODETEXT = 13;
    public const uint GMEM_MOVEABLE  = 0x0002;
}
'@
}

function Open-ClipboardRetry {
    # Andere Programme (Clipboard-Manager, RDP) halten das Clipboard oft kurz offen.
    # Laut Doku darf der Besitzer beim Schreiben nicht NULL sein → Fenster-Handle übergeben.
    param([IntPtr]$Owner = [IntPtr]::Zero)
    for ($i = 0; $i -lt 10; $i++) {
        if ([WinClip]::OpenClipboard($Owner)) { return $true }
        Start-Sleep -Milliseconds 30
    }
    return $false
}

function Get-ClipboardRaw {
    $text = ""
    if (Open-ClipboardRetry) {
        try {
            $h = [WinClip]::GetClipboardData([WinClip]::CF_UNICODETEXT)
            if ($h -ne [IntPtr]::Zero) {
                $p = [WinClip]::GlobalLock($h)
                if ($p -ne [IntPtr]::Zero) {
                    $text = [Runtime.InteropServices.Marshal]::PtrToStringUni($p)
                    [WinClip]::GlobalUnlock($h) | Out-Null
                }
            }
        } finally { [WinClip]::CloseClipboard() | Out-Null }
    }
    return $text
}

function Set-ClipboardMultiFormat {
    # Schreibt mehrere Clipboard-Formate auf einmal via natives Win32.
    # Einziger Schreibweg des Tools — auch „Copy" einer Einzelzeile läuft hierüber.
    # Exakte Encodings:
    #   CF_UNICODETEXT   → UTF-16LE + Null
    #   Rich Text Format → ANSI (Default) + Null
    #   HTML Format      → UTF-8 + Null  ← WinForms DataObject macht das falsch (UTF-16)
    param(
        [string]$PlainText  = "",
        [string]$RtfString  = "",
        [string]$HtmlString = "",
        [IntPtr]$Owner      = [IntPtr]::Zero
    )

    # Bytes in GMEM_MOVEABLE-Block schreiben, Handle zurückgeben
    function AllocBlock([byte[]]$bytes) {
        $hMem = [WinClip]::GlobalAlloc([WinClip]::GMEM_MOVEABLE, [UIntPtr][uint64]$bytes.Length)
        if ($hMem -eq [IntPtr]::Zero) { return [IntPtr]::Zero }
        $ptr = [WinClip]::GlobalLock($hMem)
        if ($ptr -eq [IntPtr]::Zero) { return [IntPtr]::Zero }
        [Runtime.InteropServices.Marshal]::Copy($bytes, 0, $ptr, $bytes.Length)
        [WinClip]::GlobalUnlock($hMem) | Out-Null
        return $hMem
    }

    if (-not (Open-ClipboardRetry -Owner $Owner)) { return $false }
    $ok = $true
    try {
        [WinClip]::EmptyClipboard() | Out-Null

        if (![string]::IsNullOrEmpty($PlainText)) {
            $bytes = [System.Text.Encoding]::Unicode.GetBytes($PlainText + [char]0)
            $hMem  = AllocBlock $bytes
            if ($hMem -eq [IntPtr]::Zero -or
                [WinClip]::SetClipboardData([WinClip]::CF_UNICODETEXT, $hMem) -eq [IntPtr]::Zero) { $ok = $false }
        }

        if (![string]::IsNullOrEmpty($RtfString)) {
            $bytes = [System.Text.Encoding]::Default.GetBytes($RtfString + [char]0)
            $fmt   = [WinClip]::RegisterClipboardFormat("Rich Text Format")
            $hMem  = AllocBlock $bytes
            if ($hMem -eq [IntPtr]::Zero -or
                [WinClip]::SetClipboardData($fmt, $hMem) -eq [IntPtr]::Zero) { $ok = $false }
        }

        if (![string]::IsNullOrEmpty($HtmlString)) {
            # CF_HTML muss UTF-8 sein
            $bytes = [System.Text.Encoding]::UTF8.GetBytes($HtmlString + [char]0)
            $fmt   = [WinClip]::RegisterClipboardFormat("HTML Format")
            $hMem  = AllocBlock $bytes
            if ($hMem -eq [IntPtr]::Zero -or
                [WinClip]::SetClipboardData($fmt, $hMem) -eq [IntPtr]::Zero) { $ok = $false }
        }
    } finally { [WinClip]::CloseClipboard() | Out-Null }
    return $ok
}

function Get-ClipboardFormat {
    # Liest ein beliebiges benanntes Clipboard-Format als String.
    # RTF  → ANSI  (Encoding = "Default")
    # HTML → UTF-8 (Encoding = "UTF8")
    param(
        [Parameter(Mandatory=$true)][string]$FormatName,
        [string]$Encoding = "Default"
    )
    $result = ""
    $fmt = [WinClip]::RegisterClipboardFormat($FormatName)
    if ($fmt -eq 0) { return $result }

    if (Open-ClipboardRetry) {
        try {
            $h = [WinClip]::GetClipboardData($fmt)
            if ($h -ne [IntPtr]::Zero) {
                $p = [WinClip]::GlobalLock($h)
                if ($p -ne [IntPtr]::Zero) {
                    $size = [WinClip]::GlobalSize($h).ToUInt64()
                    if ($size -gt 0) {
                        $bytes = New-Object byte[] ([int]$size)
                        [Runtime.InteropServices.Marshal]::Copy($p, $bytes, 0, [int]$size)
                        $nullIdx = [Array]::IndexOf($bytes, [byte]0)
                        if ($nullIdx -gt 0) { $bytes = $bytes[0..($nullIdx - 1)] }
                        $enc = if ($Encoding -eq "UTF8") { [System.Text.Encoding]::UTF8 } `
                               else                      { [System.Text.Encoding]::Default }
                        $result = $enc.GetString($bytes)
                    }
                    [WinClip]::GlobalUnlock($h) | Out-Null
                }
            }
        } finally { [WinClip]::CloseClipboard() | Out-Null }
    }
    return $result
}

# ========== Keyboard helpers ==========
function Type-Char {
    param([Parameter(Mandatory=$true)][char]$Char, [int]$DelayMs = 15)
    [ScanInput]::SendCharByScan($Char, $DelayMs)
    if ($DelayMs -gt 0) { Start-Sleep -Milliseconds $DelayMs }
}

function Type-ScancodeText {
    param([Parameter(Mandatory=$true)][string]$Text, [int]$DelayMs = 15)
    if ([string]::IsNullOrEmpty($Text)) { return }

    $normalized = $Text -replace "`r`n","`n" -replace "`r","`n"
    foreach ($c in $normalized.ToCharArray()) {
        switch ($c) {
            "`n" { [ScanInput]::SendCharByScan([char]0x0D, $DelayMs); if ($DelayMs -gt 0) { Start-Sleep -Milliseconds $DelayMs }; continue }
            "`t" { [ScanInput]::SendCharByScan([char]0x09, $DelayMs); if ($DelayMs -gt 0) { Start-Sleep -Milliseconds $DelayMs }; continue }
            "`b" { [ScanInput]::SendCharByScan([char]0x08, $DelayMs); if ($DelayMs -gt 0) { Start-Sleep -Milliseconds $DelayMs }; continue }
            default { Type-Char -Char $c -DelayMs $DelayMs }
        }
    }
}

# ========== HTML-Hilfsfunktionen ==========

function New-CfHtml {
    # Baut einen gültigen CF_HTML-String mit korrekten UTF-8-Byte-Offsets im Header.
    # OneNote, Outlook etc. erwarten exakt dieses Format.
    param([string]$HtmlFragment)
    $enc      = [System.Text.Encoding]::UTF8
    $pre      = "<html><body><!--StartFragment-->"
    $post     = "<!--EndFragment--></body></html>"
    # Dummy-Header gleicher Länge zum Messen
    $hdrDummy = "Version:0.9`r`nStartHTML:0000000000`r`nEndHTML:0000000000`r`nStartFragment:0000000000`r`nEndFragment:0000000000`r`n"
    $hdrLen   = $enc.GetByteCount($hdrDummy)
    $preLen   = $enc.GetByteCount($pre)
    $fragLen  = $enc.GetByteCount($HtmlFragment)
    $postLen  = $enc.GetByteCount($post)
    $startHtml     = $hdrLen
    $startFrag     = $hdrLen + $preLen
    $endFrag       = $startFrag + $fragLen
    $endHtml       = $endFrag + $postLen
    $header = "Version:0.9`r`nStartHTML:{0:D10}`r`nEndHTML:{1:D10}`r`nStartFragment:{2:D10}`r`nEndFragment:{3:D10}`r`n" `
              -f $startHtml, $endHtml, $startFrag, $endFrag
    return $header + $pre + $HtmlFragment + $post
}

function Convert-RichBoxToHtmlFragment {
    # Liest Farbe + Fett zeichenweise aus einem RichTextBox aus
    # und erzeugt ein HTML-Fragment mit Inline-Styles.
    # Ergebnis ist der <pre>...</pre>-Block, ohne CF_HTML-Header.
    param([System.Windows.Forms.RichTextBox]$Rtb)
    $len = $Rtb.TextLength
    if ($len -eq 0) { return "" }

    # Text einmal holen — $Rtb.Text[$i] in der Schleife liest jedes Mal den ganzen Inhalt (O(n²))
    $text     = $Rtb.Text
    $selStart = $Rtb.SelectionStart
    $selLen   = $Rtb.SelectionLength

    $sb        = New-Object System.Text.StringBuilder
    $sb.Append("<pre style='font-family:Consolas,monospace;font-size:10pt;'>") | Out-Null

    $prevColor = $null
    $prevBold  = $false
    $spanOpen  = $false

    for ($i = 0; $i -lt $len; $i++) {
        $Rtb.SelectionStart  = $i
        $Rtb.SelectionLength = 1
        $color = $Rtb.SelectionColor
        $font  = $Rtb.SelectionFont
        $bold  = $font -and $font.Bold

        if (($color -ne $prevColor) -or ($bold -ne $prevBold)) {
            if ($spanOpen) { $sb.Append("</span>") | Out-Null }
            $hex   = "#{0:X2}{1:X2}{2:X2}" -f $color.R, $color.G, $color.B
            $style = "color:$hex;" + $(if ($bold) { "font-weight:bold;" } else { "" })
            $sb.Append("<span style='$style'>") | Out-Null
            $spanOpen  = $true
            $prevColor = $color
            $prevBold  = $bold
        }

        $ch = $text[$i]
        switch ($ch) {
            '<'  { $sb.Append("&lt;")   | Out-Null }
            '>'  { $sb.Append("&gt;")   | Out-Null }
            '&'  { $sb.Append("&amp;")  | Out-Null }
            '"'  { $sb.Append("&quot;") | Out-Null }
            "`r" { } # CR überspringen, nur LF verwenden
            default { $sb.Append($ch) | Out-Null }
        }
    }

    if ($spanOpen) { $sb.Append("</span>") | Out-Null }
    $sb.Append("</pre>") | Out-Null

    $Rtb.SelectionStart  = $selStart
    $Rtb.SelectionLength = $selLen
    return $sb.ToString()
}

# ========== WinForms-UI ==========
# Layout ausschließlich über Dock/AutoSize — keine absoluten Pixelpositionen.
# Dadurch kann kein Steuerelement breiter werden als der Client-Bereich
# (Ursache der horizontalen Scrollbalken in v7).
$MIN_LINES      = 4      # so viele Zeilen gibt es mindestens (leeres Clipboard → leere Zeilen)
$MAX_LINES      = 200    # mehr Zeilen nur in der Vorschau (Startzeit, Fenster-Handles)
$MAX_HEIGHT_PCT = 0.6    # Starthöhe höchstens 60 % des Bildschirm-Arbeitsbereichs
$FORM_WIDTH     = 520
$PREVIEW_HEIGHT = 130    # Vorschau-Bereich (Label + RTF-Box), per Splitter verstellbar
$LOG_HEIGHT     = 80

$script:ui = $null

function Write-UiLog([string]$Message) {
    $script:ui.Log.AppendText("$Message`r`n")
}

function Format-Short([string]$Text, [int]$Max = 60) {
    $t = $Text -replace "`r?`n", " | "
    if ($t.Length -gt $Max) { return $t.Substring(0, $Max) + "..." }
    return $t
}

function Split-ClipboardLines([string]$Text) {
    $lines = @()
    if (![string]::IsNullOrEmpty($Text)) {
        $lines = @($Text -split "`r?`n")
        # abschließender Zeilenumbruch erzeugt sonst eine Scheinzeile
        if ($lines.Count -gt 0 -and $lines[-1] -eq "") { $lines = @($lines | Select-Object -First ($lines.Count - 1)) }
    }
    while ($lines.Count -lt $MIN_LINES) { $lines += "" }
    return ,$lines
}

function Get-LineRows {
    # Zeilen in Anzeigereihenfolge (oben → unten).
    # Dock=Top legt das Control mit dem höchsten Index nach oben, daher umgekehrt.
    $rows = @($script:ui.LinesHost.Controls)
    [array]::Reverse($rows)
    return ,$rows
}

function Add-LineRow {
    param([string]$Text = "", [switch]$Focus)

    $row              = New-Object System.Windows.Forms.TableLayoutPanel
    $row.Dock         = 'Top'
    $row.AutoSize     = $true
    $row.AutoSizeMode = 'GrowAndShrink'
    $row.ColumnCount  = 3
    $row.RowCount     = 1
    $row.Margin       = New-Object System.Windows.Forms.Padding(0)
    [void]$row.ColumnStyles.Add((New-Object System.Windows.Forms.ColumnStyle([System.Windows.Forms.SizeType]::Percent, 100)))
    [void]$row.ColumnStyles.Add((New-Object System.Windows.Forms.ColumnStyle([System.Windows.Forms.SizeType]::AutoSize)))
    [void]$row.ColumnStyles.Add((New-Object System.Windows.Forms.ColumnStyle([System.Windows.Forms.SizeType]::AutoSize)))

    $tb        = New-Object System.Windows.Forms.TextBox
    $tb.Text   = $Text
    $tb.Anchor = 'Left,Right'
    $tb.Margin = New-Object System.Windows.Forms.Padding(0, 3, 4, 3)

    $copy          = New-Object System.Windows.Forms.Button
    $copy.Text     = "Copy"
    $copy.AutoSize = $true
    $copy.Margin   = New-Object System.Windows.Forms.Padding(0, 2, 2, 2)
    $copy.Tag      = $tb
    $copy.Add_Click({ Copy-LineText -TextBox $this.Tag })

    $del           = New-Object System.Windows.Forms.Button
    $del.Text      = "-"
    $del.Size      = New-Object System.Drawing.Size(26, $copy.PreferredSize.Height)
    $del.Margin    = New-Object System.Windows.Forms.Padding(0, 2, 0, 2)
    $del.Tag       = $row
    $del.Add_Click({ Remove-LineRow -Row $this.Tag })
    $script:ui.ToolTip.SetToolTip($del, "Remove line")

    $row.Controls.Add($tb,   0, 0)
    $row.Controls.Add($copy, 1, 0)
    $row.Controls.Add($del,  2, 0)

    $script:ui.LinesHost.Controls.Add($row)
    $row.BringToFront()   # Index 0 = wird zuletzt angedockt = unterste Zeile

    if ($Focus) {
        $script:ui.LinesHost.ScrollControlIntoView($row)
        $tb.Focus() | Out-Null
    }
    return $row
}

function Remove-LineRow {
    param([System.Windows.Forms.Control]$Row)
    $script:ui.LinesHost.Controls.Remove($Row)
    $Row.Dispose()
}

function Copy-LineText {
    param([System.Windows.Forms.TextBox]$TextBox)
    $t = $TextBox.Text
    if ([string]::IsNullOrWhiteSpace($t)) { Write-UiLog "Nothing to copy (empty line)."; return }
    if (Set-ClipboardMultiFormat -PlainText $t -Owner $script:ui.Form.Handle) {
        Write-UiLog "Copied: $(Format-Short $t)"
    } else {
        Write-UiLog "Failed to set clipboard."
    }
}

function Copy-PreviewText {
    $t = $script:ui.Preview.Text
    if ([string]::IsNullOrWhiteSpace($t)) { Write-UiLog "Preview is empty."; return }
    if (Set-ClipboardMultiFormat -PlainText $t -Owner $script:ui.Form.Handle) {
        Write-UiLog "Copied preview (plain text)."
    } else {
        Write-UiLog "Failed to set clipboard."
    }
}

function Copy-PreviewRich {
    # DataObject mit allen Formaten (RTF + HTML + Text), damit OneNote, Word etc. das beste wählen.
    # Unverändert → Originalformate aus dem Clipboard. Bearbeitet → aus der Box neu erzeugt,
    # damit „Copy RTF" und „Copy text" denselben Inhalt liefern.
    $box = $script:ui.Preview
    if ([string]::IsNullOrWhiteSpace($box.Text)) { Write-UiLog "Preview is empty."; return }

    if ($box.Modified -or [string]::IsNullOrEmpty($script:ui.OrigRtf)) {
        $rtf   = $box.Rtf
        $plain = $box.Text
        $html  = ""
    } else {
        $rtf   = $script:ui.OrigRtf
        $plain = $script:ui.OrigPlain
        $html  = $script:ui.OrigHtml
    }
    if ([string]::IsNullOrEmpty($html)) {
        # PS ISE legt kein HTML Format ins Clipboard — selbst erzeugen,
        # damit OneNote (und andere HTML-only-Ziele) die Formatierung bekommen.
        try   { $html = New-CfHtml -HtmlFragment (Convert-RichBoxToHtmlFragment -Rtb $box) }
        catch { $html = "" }
    }

    $formats = @()
    if (![string]::IsNullOrEmpty($rtf))   { $formats += "RTF" }
    if (![string]::IsNullOrEmpty($html))  { $formats += "HTML" }
    if (![string]::IsNullOrEmpty($plain)) { $formats += "Text" }
    if (Set-ClipboardMultiFormat -PlainText $plain -RtfString $rtf -HtmlString $html -Owner $script:ui.Form.Handle) {
        Write-UiLog "Copied rich text ($($formats -join ' + '))."
    } else {
        Write-UiLog "Failed to set clipboard."
    }
}

function Invoke-TypeClipboard {
    $form = $script:ui.Form
    try   { $clipText = Get-ClipboardRaw }
    catch { Write-UiLog "Failed to read clipboard: $($_.Exception.Message)"; return }
    if ([string]::IsNullOrEmpty($clipText)) { Write-UiLog "Clipboard is empty. Nothing to type."; return }

    Write-UiLog "Typing $($clipText.Length) chars in 2 s: $(Format-Short $clipText)"
    $form.WindowState = 'Minimized'
    [System.Windows.Forms.Application]::DoEvents()
    try {
        Start-Sleep -Seconds 2
        Type-ScancodeText -Text $clipText
        Write-UiLog "Done typing."
    } catch {
        Write-UiLog "Typing aborted: $($_.Exception.Message)"
    } finally {
        $form.WindowState = 'Normal'
        $form.Activate()
    }
}

function New-TextCopyForm {
    param(
        [string]$PlainContent = "",
        # Vollständiger RTF-String für die Preview-Box (leer = kein RTF verfügbar)
        [string]$RtfContent   = "",
        # HTML Format-String (CF_HTML) — für OneNote & Co.
        [string]$HtmlContent  = ""
    )

    $form               = New-Object System.Windows.Forms.Form
    $form.Text          = "TextCopyHelper"
    $form.StartPosition = "CenterScreen"
    $form.TopMost       = $true
    $form.MinimumSize   = New-Object System.Drawing.Size(360, 320)
    $form.Font          = New-Object System.Drawing.Font("Segoe UI", 9)

    $tip = New-Object System.Windows.Forms.ToolTip

    # ── Log (unten, feste Höhe) ──────────────────────────────────────────────
    $logBox            = New-Object System.Windows.Forms.TextBox
    $logBox.Multiline  = $true
    $logBox.ScrollBars = "Vertical"
    $logBox.ReadOnly   = $true
    $logBox.Dock       = 'Bottom'
    $logBox.Height     = $LOG_HEIGHT

    # ── Splitter: oben Zeilen, unten Vorschau ────────────────────────────────
    $split             = New-Object System.Windows.Forms.SplitContainer
    $split.Dock        = 'Fill'
    $split.Orientation = 'Horizontal'
    $split.FixedPanel  = 'Panel2'   # beim Größerziehen wachsen die Zeilen, nicht die Vorschau

    # Zeilenbereich: nur vertikal scrollbar, Zeilen sind angedockt und damit nie breiter als der Client
    $linesHost            = New-Object System.Windows.Forms.Panel
    $linesHost.Dock       = 'Fill'
    $linesHost.AutoScroll = $true
    $linesHost.Padding    = New-Object System.Windows.Forms.Padding(8, 6, 8, 0)

    $toolbar              = New-Object System.Windows.Forms.FlowLayoutPanel
    $toolbar.Dock         = 'Bottom'
    $toolbar.AutoSize     = $true
    $toolbar.AutoSizeMode = 'GrowAndShrink'
    $toolbar.WrapContents = $false
    $toolbar.Padding      = New-Object System.Windows.Forms.Padding(5, 2, 5, 2)

    $addBtn          = New-Object System.Windows.Forms.Button
    $addBtn.Text     = "+"
    $addBtn.Size     = New-Object System.Drawing.Size(32, 26)
    $addBtn.Add_Click({ Add-LineRow -Focus | Out-Null })
    $tip.SetToolTip($addBtn, "Add empty line")

    $typeBtn          = New-Object System.Windows.Forms.Button
    $typeBtn.Text     = "Paste clipboard as keyboard input"
    $typeBtn.AutoSize = $true
    $typeBtn.Add_Click({ Invoke-TypeClipboard })

    $toolbar.Controls.Add($addBtn)
    $toolbar.Controls.Add($typeBtn)

    $split.Panel1.Controls.Add($toolbar)
    $split.Panel1.Controls.Add($linesHost)
    $linesHost.BringToFront()   # Fill wird nach Bottom angedockt

    # Vorschau
    $previewLabel           = New-Object System.Windows.Forms.Label
    $previewLabel.Text      = "Clipboard preview"
    $previewLabel.Dock      = 'Top'
    $previewLabel.AutoSize  = $true
    $previewLabel.ForeColor = [System.Drawing.Color]::Gray
    $previewLabel.Padding   = New-Object System.Windows.Forms.Padding(5, 4, 0, 2)

    $previewGrid             = New-Object System.Windows.Forms.TableLayoutPanel
    $previewGrid.Dock        = 'Fill'
    $previewGrid.ColumnCount = 2
    $previewGrid.RowCount    = 1
    $previewGrid.Padding     = New-Object System.Windows.Forms.Padding(5, 0, 5, 4)
    [void]$previewGrid.ColumnStyles.Add((New-Object System.Windows.Forms.ColumnStyle([System.Windows.Forms.SizeType]::Percent, 100)))
    [void]$previewGrid.ColumnStyles.Add((New-Object System.Windows.Forms.ColumnStyle([System.Windows.Forms.SizeType]::AutoSize)))
    [void]$previewGrid.RowStyles.Add((New-Object System.Windows.Forms.RowStyle([System.Windows.Forms.SizeType]::Percent, 100)))

    $richBox                  = New-Object System.Windows.Forms.RichTextBox
    $richBox.Dock             = 'Fill'
    $richBox.AcceptsTab       = $true
    $richBox.ScrollBars       = 'Vertical'
    $richBox.WordWrap         = $true

    $previewBtns               = New-Object System.Windows.Forms.FlowLayoutPanel
    $previewBtns.FlowDirection = 'TopDown'
    $previewBtns.WrapContents  = $false
    $previewBtns.AutoSize      = $true
    $previewBtns.Margin        = New-Object System.Windows.Forms.Padding(4, 0, 0, 0)

    $copyTextBtn          = New-Object System.Windows.Forms.Button
    $copyTextBtn.Text     = "Copy text"
    $copyTextBtn.AutoSize = $true
    $copyTextBtn.Add_Click({ Copy-PreviewText })

    $copyRtfBtn          = New-Object System.Windows.Forms.Button
    $copyRtfBtn.Text     = "Copy RTF"
    $copyRtfBtn.AutoSize = $true
    $copyRtfBtn.Add_Click({ Copy-PreviewRich })

    $previewBtns.Controls.Add($copyTextBtn)
    $previewBtns.Controls.Add($copyRtfBtn)
    $previewGrid.Controls.Add($richBox, 0, 0)
    $previewGrid.Controls.Add($previewBtns, 1, 0)

    $split.Panel2.Controls.Add($previewLabel)
    $split.Panel2.Controls.Add($previewGrid)
    $previewGrid.BringToFront()

    $form.Controls.Add($logBox)
    $form.Controls.Add($split)
    $split.BringToFront()

    $script:ui = @{
        Form      = $form
        LinesHost = $linesHost
        Toolbar   = $toolbar
        AddButton = $addBtn
        Split     = $split
        Preview   = $richBox
        Log       = $logBox
        ToolTip   = $tip
        OrigRtf   = $RtfContent
        OrigHtml  = $HtmlContent
        OrigPlain = $PlainContent
    }

    # ── Vorschau füllen — RTF mit Fallback auf Plaintext ─────────────────────
    if (![string]::IsNullOrEmpty($RtfContent)) {
        try {
            $richBox.Rtf = $RtfContent
            # PS ISE fügt manchmal ein führendes Leerzeichen ein — entfernen
            $leadingSpaces = $richBox.Text.Length - $richBox.Text.TrimStart().Length
            if ($leadingSpaces -gt 0) {
                $richBox.SelectionStart  = 0
                $richBox.SelectionLength = $leadingSpaces
                $richBox.SelectedText    = ""
            }
        }
        catch { $richBox.Text = $PlainContent; $script:ui.OrigRtf = "" }
    } elseif (![string]::IsNullOrEmpty($PlainContent)) {
        $richBox.Text = $PlainContent
    }
    $richBox.Modified = $false

    # ── Zeilen ────────────────────────────────────────────────────────────────
    $lines = Split-ClipboardLines $PlainContent
    $linesHost.SuspendLayout()
    $shown = [Math]::Min($lines.Count, $MAX_LINES)
    for ($i = 0; $i -lt $shown; $i++) { Add-LineRow -Text $lines[$i] | Out-Null }
    $linesHost.ResumeLayout()
    if ($lines.Count -gt $MAX_LINES) {
        Write-UiLog "$($lines.Count) lines in clipboard - showing the first $MAX_LINES, the rest only in the preview."
    }

    # ── Starthöhe: so hoch wie nötig, höchstens MAX_HEIGHT_PCT des Bildschirms ─
    $rowHeight   = (Get-LineRows)[0].PreferredSize.Height
    $linesHeight = $shown * $rowHeight + $linesHost.Padding.Vertical
    $wanted      = $linesHeight + $toolbar.PreferredSize.Height + $split.SplitterWidth + $PREVIEW_HEIGHT + $LOG_HEIGHT
    $workArea    = [System.Windows.Forms.Screen]::PrimaryScreen.WorkingArea
    $maxClient   = [int]($workArea.Height * $MAX_HEIGHT_PCT)
    $form.ClientSize = New-Object System.Drawing.Size($FORM_WIDTH, [Math]::Min($wanted, $maxClient))

    $form.Add_Load({
        $s = $script:ui.Split
        $s.Panel1MinSize    = 60
        $s.Panel2MinSize    = 70
        $s.SplitterDistance = [Math]::Max($s.Panel1MinSize, $s.Height - $s.SplitterWidth - $PREVIEW_HEIGHT)
    })
    $form.Add_Shown({ $script:ui.Form.ActiveControl = $null })

    return $form
}

# ── Start ─────────────────────────────────────────────────────────────────────
# Tests laden das Skript per Dot-Sourcing mit $TextCopyHelperNoRun = $true.
if (-not $TextCopyHelperNoRun) {
    try { $plainText = Get-ClipboardRaw } catch { $plainText = "" }
    try { $rtfText   = Get-ClipboardFormat -FormatName "Rich Text Format" -Encoding "Default" } catch { $rtfText = "" }
    try { $htmlText  = Get-ClipboardFormat -FormatName "HTML Format"      -Encoding "UTF8" }    catch { $htmlText = "" }

    $form = New-TextCopyForm -PlainContent $plainText -RtfContent $rtfText -HtmlContent $htmlText
    $form.ShowDialog() | Out-Null
    $form.Dispose()
}
