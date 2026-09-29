Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing

[System.Windows.Forms.Application]::EnableVisualStyles()

# ========== Native SendInput (Keyboard / Scancode) ==========
# Tippt Text als Scancodes — nötig für Konsolen, VMs und Remote-Sitzungen, die kein Einfügen kennen.
# Das Layout für die Zuordnung Zeichen → Taste kommt vom ZIELFENSTER (oder wird fest gewählt),
# nicht vom eigenen Thread: sonst kommt z. B. „[" (DE: AltGr+8) in einem US-Ziel als „8" an.
# Modifier gehen gebündelt runter, dann Pause, dann die Taste — manche VM-/Remote-Konsolen
# verlieren Shift/AltGr, wenn Modifier und Taste im selben Augenblick eintreffen.
if (-not ('KeyTyper' -as [type])) {
Add-Type -Language CSharp @'
using System;
using System.Collections.Generic;
using System.Runtime.InteropServices;
using System.Text;
using System.Threading;

public static class KeyTyper
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

    public struct KeyPlan { public ushort Scan; public bool Ext, Shift, Ctrl, Alt, Dead; }

    public class TypeResult {
        public int Typed;          // gesendete Zeichen
        public int Unicode;        // davon als Unicode-Paket (Zeichen fehlt im Layout)
        public string Missing = ""; // welche Zeichen das waren
        public string Aborted = ""; // leer = vollständig
    }

    private const uint INPUT_KEYBOARD        = 1;
    private const uint KEYEVENTF_EXTENDEDKEY = 0x0001;
    private const uint KEYEVENTF_KEYUP       = 0x0002;
    private const uint KEYEVENTF_UNICODE     = 0x0004;
    private const uint KEYEVENTF_SCANCODE    = 0x0008;
    private const uint MAPVK_VK_TO_VSC_EX    = 4;
    private const int  VK_SHIFT              = 0x10;
    private const int  VK_CONTROL            = 0x11;
    private const int  VK_MENU               = 0x12;
    private const uint KLF_NOTELLSHELL       = 0x0080;
    private const int  VK_ESCAPE             = 0x1B;

    private const ushort SC_LCTRL  = 0x1D;
    private const ushort SC_LSHIFT = 0x2A;
    private const ushort SC_ALT    = 0x38;   // mit Extended-Flag = rechte Alt-Taste (AltGr)
    private const ushort SC_SPACE  = 0x39;

    [DllImport("user32.dll", SetLastError = true)] private static extern uint SendInput(uint nInputs, INPUT[] pInputs, int cbSize);
    [DllImport("user32.dll")] private static extern short VkKeyScanExW(char ch, IntPtr hkl);
    [DllImport("user32.dll")] private static extern uint MapVirtualKeyExW(uint code, uint mapType, IntPtr hkl);
    [DllImport("user32.dll")] private static extern IntPtr GetKeyboardLayout(uint threadId);
    [DllImport("user32.dll")] private static extern int GetKeyboardLayoutList(int n, [Out] IntPtr[] list);
    [DllImport("user32.dll", CharSet = CharSet.Unicode)] private static extern IntPtr LoadKeyboardLayoutW(string klid, uint flags);
    [DllImport("user32.dll")] private static extern bool UnloadKeyboardLayout(IntPtr hkl);
    [DllImport("user32.dll")] private static extern IntPtr GetForegroundWindow();
    [DllImport("user32.dll")] private static extern uint GetWindowThreadProcessId(IntPtr hwnd, out uint pid);
    [DllImport("user32.dll", CharSet = CharSet.Unicode)] private static extern int GetWindowTextW(IntPtr hwnd, StringBuilder sb, int max);
    [DllImport("user32.dll")] private static extern short GetAsyncKeyState(int vk);
    [DllImport("user32.dll", CharSet = CharSet.Unicode)]
    private static extern int ToUnicodeEx(uint vk, uint scan, byte[] keyState, StringBuilder buf, int bufSize, uint flags, IntPtr hkl);

    // ── Fenster / Layouts ────────────────────────────────────────────────────
    public static IntPtr ForegroundWindow() { return GetForegroundWindow(); }

    public static IntPtr LayoutOfWindow(IntPtr hwnd) {
        uint pid;
        uint tid = GetWindowThreadProcessId(hwnd, out pid);
        return GetKeyboardLayout(tid);
    }

    public static string WindowTitle(IntPtr hwnd) {
        StringBuilder sb = new StringBuilder(256);
        GetWindowTextW(hwnd, sb, sb.Capacity);
        return sb.ToString();
    }

    public static IntPtr[] InstalledLayouts() {
        int n = GetKeyboardLayoutList(0, null);
        IntPtr[] list = new IntPtr[n];
        GetKeyboardLayoutList(n, list);
        return list;
    }

    // Lädt ein nicht installiertes Layout nur zum Nachschlagen (ohne Aktivierung, ohne Shell-Meldung).
    public static IntPtr LoadLayout(string klid) { return LoadKeyboardLayoutW(klid, KLF_NOTELLSHELL); }
    public static bool UnloadLayout(IntPtr hkl) { return UnloadKeyboardLayout(hkl); }

    // ── Zeichen → Taste ──────────────────────────────────────────────────────
    public static bool TryPlan(char ch, IntPtr hkl, out KeyPlan p) {
        p = new KeyPlan();
        short r = VkKeyScanExW(ch, hkl);
        if (r == -1) return false;
        uint vk = (uint)(r & 0xFF);
        int  sh = (r >> 8) & 0xFF;
        if ((sh & 0x38) != 0) return false;          // Hankaku/Kana-Zustände: nicht unterstützt
        p.Shift = (sh & 1) != 0;
        p.Ctrl  = (sh & 2) != 0;
        p.Alt   = (sh & 4) != 0;

        uint sc = MapVirtualKeyExW(vk, MAPVK_VK_TO_VSC_EX, hkl);
        if (sc == 0) return false;
        p.Scan = (ushort)(sc & 0xFF);
        p.Ext  = (sc & 0xFF00) == 0xE000 || (sc & 0xFF00) == 0xE100;   // Präfix E0/E1

        // Tottaste? (^ ´ ` bei DE, ' " ~ bei US-International …) — hängt vom Umschaltzustand ab:
        // DE „^" ist tot, „°" (Shift+^) nicht. ToUnicodeEx < 0 = tot; Flag 4 = Tastaturzustand nicht verändern.
        byte[] ks = new byte[256];
        if (p.Shift) ks[VK_SHIFT]   = 0x80;
        if (p.Ctrl)  ks[VK_CONTROL] = 0x80;
        if (p.Alt)   ks[VK_MENU]    = 0x80;
        StringBuilder buf = new StringBuilder(8);
        p.Dead = ToUnicodeEx(vk, sc & 0xFF, ks, buf, buf.Capacity, 4, hkl) < 0;
        return true;
    }

    private static INPUT Key(ushort scan, bool ext, bool up) {
        INPUT i = new INPUT();
        i.type = INPUT_KEYBOARD;
        i.U.ki.wScan = scan;
        i.U.ki.dwFlags = KEYEVENTF_SCANCODE | (ext ? KEYEVENTF_EXTENDEDKEY : 0) | (up ? KEYEVENTF_KEYUP : 0);
        return i;
    }

    private static INPUT Uni(char ch, bool up) {
        INPUT i = new INPUT();
        i.type = INPUT_KEYBOARD;
        i.U.ki.wScan = ch;
        i.U.ki.dwFlags = KEYEVENTF_UNICODE | (up ? KEYEVENTF_KEYUP : 0);
        return i;
    }

    private static void Send(params INPUT[] inputs) {
        uint sent = SendInput((uint)inputs.Length, inputs, Marshal.SizeOf(typeof(INPUT)));
        if (sent != inputs.Length)
            throw new System.ComponentModel.Win32Exception(Marshal.GetLastWin32Error());
    }

    private static void Pause(int ms) { if (ms > 0) Thread.Sleep(ms); }

    // Liefert false, wenn das Zeichen im Layout fehlt und als Unicode-Paket ging
    // (funktioniert in lokalen Programmen, in VM-Konsolen meist nicht).
    public static bool TypeChar(char ch, IntPtr hkl, int delayMs) {
        KeyPlan p;
        if (!TryPlan(ch, hkl, out p)) {
            Send(Uni(ch, false), Uni(ch, true));
            Pause(delayMs);
            return false;
        }

        List<INPUT> down = new List<INPUT>();
        List<INPUT> up   = new List<INPUT>();
        if (p.Ctrl || p.Alt) { down.Add(Key(SC_LCTRL, false, false)); up.Insert(0, Key(SC_LCTRL, false, true)); }
        if (p.Alt)           { down.Add(Key(SC_ALT, true, false));    up.Insert(0, Key(SC_ALT, true, true)); }
        if (p.Shift)         { down.Add(Key(SC_LSHIFT, false, false)); up.Insert(0, Key(SC_LSHIFT, false, true)); }

        try {
            if (down.Count > 0) { Send(down.ToArray()); Pause(delayMs); }
            Send(Key(p.Scan, p.Ext, false), Key(p.Scan, p.Ext, true));
            if (down.Count > 0) Pause(delayMs);
        } finally {
            // Modifier IMMER loslassen — sonst hängt Shift/AltGr nach einem Fehler fest
            if (up.Count > 0) Send(up.ToArray());
        }
        if (p.Dead) {
            // Tottaste + Leertaste = das Zeichen selbst
            Pause(delayMs);
            Send(Key(SC_SPACE, false, false), Key(SC_SPACE, false, true));
        }
        Pause(delayMs);
        return true;
    }

    // Tippt den Text. Bricht ab, wenn das Vordergrundfenster wechselt oder Esc gedrückt wird.
    public static TypeResult TypeText(string text, IntPtr hkl, int delayMs, IntPtr expectedWindow) {
        TypeResult res = new TypeResult();
        string t = text.Replace("\r\n", "\r").Replace("\n", "\r");
        GetAsyncKeyState(VK_ESCAPE);                         // „seit letztem Aufruf gedrückt" zurücksetzen
        StringBuilder missing = new StringBuilder();

        foreach (char c in t) {
            if (expectedWindow != IntPtr.Zero && GetForegroundWindow() != expectedWindow) {
                res.Aborted = "target window lost focus"; break;
            }
            if ((GetAsyncKeyState(VK_ESCAPE) & 0x8000) != 0) { res.Aborted = "Esc pressed"; break; }
            if (c < 0x20 && c != '\r' && c != '\t' && c != '\b') continue;   // übrige Steuerzeichen nicht tippen

            if (!TypeChar(c, hkl, delayMs)) {
                res.Unicode++;
                if (missing.ToString().IndexOf(c) < 0) missing.Append(c);
            }
            res.Typed++;
        }
        res.Missing = missing.ToString();
        return res;
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

$VERSION        = "8.0"

# Tippen („Paste clipboard as keyboard input")
$TYPE_START_S   = 2      # Wartezeit nach dem Minimieren, um ins Zielfenster zu wechseln
$TYPE_DELAY_MS  = 15     # Standard: Pause zwischen Zeichen bzw. zwischen Modifier und Taste
$TYPE_DELAY_MAX = 500
# Häufige Ziel-Layouts (KLID), auch wenn lokal nicht installiert — für VM-/Remote-Konsolen,
# deren Layout Windows nicht kennt. Namen kommen aus der Registry.
$COMMON_KLIDS   = @('00000407', '00000807', '00000409', '00020409', '00000809', '0000040C', '0000080C', '00000410', '0000040A')

# Einstellungen (Layout-Auswahl, Verzögerung) — Tests setzen $TextCopyHelperRegPath auf einen eigenen Schlüssel
$REG_PATH = if ($TextCopyHelperRegPath) { $TextCopyHelperRegPath } else { 'HKCU:\Software\ps-tools\TextCopyHelper' }

$script:ui = $null

function Get-Setting([string]$Name, $Default) {
    try {
        $v = (Get-ItemProperty -Path $REG_PATH -Name $Name -ErrorAction Stop).$Name
        if ($null -ne $v) { return $v }
    } catch { }
    return $Default
}

function Set-Setting([string]$Name, $Value) {
    try {
        if (-not (Test-Path $REG_PATH)) { New-Item -Path $REG_PATH -Force | Out-Null }
        Set-ItemProperty -Path $REG_PATH -Name $Name -Value $Value
    } catch { Write-UiLog "Could not save setting ${Name}: $($_.Exception.Message)" }
}

function Get-KlidName([string]$Klid) {
    try {
        $p = Get-ItemProperty "HKLM:\SYSTEM\CurrentControlSet\Control\Keyboard Layouts\$Klid" -ErrorAction Stop
        if ($p.'Layout Text') { return $p.'Layout Text' }
    } catch { }
    return "Layout $Klid"
}

function Get-HklName([IntPtr]$Hkl) {
    $v    = $Hkl.ToInt64() -band 0xFFFFFFFF
    $lang = $v -band 0xFFFF
    $dev  = ($v -shr 16) -band 0xFFFF
    $culture = try { [Globalization.CultureInfo]::GetCultureInfo([int]$lang).Name } catch { '{0:X4}' -f $lang }
    if ($dev -eq $lang -or $dev -eq 0) { return "$(Get-KlidName ('{0:X8}' -f $lang)) ($culture)" }
    return "$culture ({0:X8})" -f $v
}

function Get-LayoutChoices {
    # Einträge für die Auswahlliste: Key wird so in der Registry gespeichert.
    $choices = @([pscustomobject]@{ Key = 'auto'; Name = 'Auto (target window)' })
    $installedKlids = @()
    foreach ($h in [KeyTyper]::InstalledLayouts()) {
        $v = $h.ToInt64() -band 0xFFFFFFFF
        $choices += [pscustomobject]@{ Key = ('hkl:{0:X8}' -f $v); Name = (Get-HklName $h) }
        if ((($v -shr 16) -band 0xFFFF) -eq ($v -band 0xFFFF)) { $installedKlids += ('{0:X8}' -f ($v -band 0xFFFF)) }
    }
    foreach ($k in $COMMON_KLIDS) {
        if ($installedKlids -notcontains $k) {
            $choices += [pscustomobject]@{ Key = "klid:$k"; Name = "$(Get-KlidName $k) (not installed)" }
        }
    }
    return ,$choices
}

function Resolve-TypingLayout {
    # Liefert @{ Hkl; Name; Unload } für den gewählten Eintrag.
    # Unload = true, wenn das Layout nur zum Tippen geladen wurde und danach wieder weg soll.
    param([string]$Key, [IntPtr]$TargetWindow)
    if ($Key -like 'hkl:*') {
        $h = [IntPtr][int64][Convert]::ToUInt32($Key.Substring(4), 16)
        return @{ Hkl = $h; Name = (Get-HklName $h); Unload = $false }
    }
    if ($Key -like 'klid:*') {
        $klid   = $Key.Substring(5)
        $before = @([KeyTyper]::InstalledLayouts() | ForEach-Object { $_.ToInt64() })
        $h      = [KeyTyper]::LoadLayout($klid)
        if ($h -ne [IntPtr]::Zero) {
            return @{ Hkl = $h; Name = (Get-KlidName $klid); Unload = ($before -notcontains $h.ToInt64()) }
        }
        Write-UiLog "Layout $klid could not be loaded - using the target window's layout."
    }
    $h = [KeyTyper]::LayoutOfWindow($TargetWindow)
    return @{ Hkl = $h; Name = "$(Get-HklName $h), from target window"; Unload = $false }
}

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

    $delay = [int]$script:ui.DelayBox.Value
    $key   = $script:ui.LayoutBox.SelectedItem.Key
    Write-UiLog "Typing $($clipText.Length) chars in $TYPE_START_S s - switch to the target window (Esc aborts): $(Format-Short $clipText)"
    $form.WindowState = 'Minimized'
    [System.Windows.Forms.Application]::DoEvents()
    $layout = $null
    try {
        Start-Sleep -Seconds $TYPE_START_S
        $target = [KeyTyper]::ForegroundWindow()
        $layout = Resolve-TypingLayout -Key $key -TargetWindow $target
        Write-UiLog "Target: '$([KeyTyper]::WindowTitle($target))', layout $($layout.Name), delay $delay ms"
        $r = [KeyTyper]::TypeText($clipText, $layout.Hkl, $delay, $target)
        if ($r.Aborted) { Write-UiLog "Typing aborted after $($r.Typed) chars: $($r.Aborted)." }
        else            { Write-UiLog "Done typing ($($r.Typed) chars)." }
        if ($r.Unicode) {
            Write-UiLog "$($r.Unicode) chars not on this layout, sent as Unicode (may fail in VM/remote consoles): $($r.Missing)"
        }
    } catch {
        Write-UiLog "Typing aborted: $($_.Exception.Message)"
    } finally {
        if ($layout -and $layout.Unload) { [KeyTyper]::UnloadLayout($layout.Hkl) | Out-Null }
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
    $form.Text          = "TextCopyHelper v$VERSION"
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

    # Tipp-Optionen: Layout (Spalte wächst mit der Fensterbreite) und Verzögerung
    $typeBar              = New-Object System.Windows.Forms.TableLayoutPanel
    $typeBar.Dock         = 'Bottom'
    $typeBar.AutoSize     = $true
    $typeBar.AutoSizeMode = 'GrowAndShrink'
    $typeBar.ColumnCount  = 4
    $typeBar.RowCount     = 1
    $typeBar.Padding      = New-Object System.Windows.Forms.Padding(5, 0, 5, 4)
    [void]$typeBar.ColumnStyles.Add((New-Object System.Windows.Forms.ColumnStyle([System.Windows.Forms.SizeType]::AutoSize)))
    [void]$typeBar.ColumnStyles.Add((New-Object System.Windows.Forms.ColumnStyle([System.Windows.Forms.SizeType]::Percent, 100)))
    [void]$typeBar.ColumnStyles.Add((New-Object System.Windows.Forms.ColumnStyle([System.Windows.Forms.SizeType]::AutoSize)))
    [void]$typeBar.ColumnStyles.Add((New-Object System.Windows.Forms.ColumnStyle([System.Windows.Forms.SizeType]::AutoSize)))

    $layoutLabel          = New-Object System.Windows.Forms.Label
    $layoutLabel.Text     = "Layout"
    $layoutLabel.AutoSize = $true
    $layoutLabel.Anchor   = 'Left'

    $layoutBox               = New-Object System.Windows.Forms.ComboBox
    $layoutBox.DropDownStyle = 'DropDownList'
    $layoutBox.DisplayMember = 'Name'
    $layoutBox.Anchor        = 'Left,Right'
    $layoutBox.MinimumSize   = New-Object System.Drawing.Size(80, 0)
    $layoutBox.DropDownWidth = 280
    $tip.SetToolTip($layoutBox, "Keyboard layout of the TARGET. Auto uses the layout of the window that has the focus when typing starts. For VM/remote consoles choose the layout used inside the remote system.")

    $delayLabel          = New-Object System.Windows.Forms.Label
    $delayLabel.Text     = "Delay ms"
    $delayLabel.AutoSize = $true
    $delayLabel.Anchor   = 'Left'

    $delayBox         = New-Object System.Windows.Forms.NumericUpDown
    $delayBox.Minimum = 0
    $delayBox.Maximum = $TYPE_DELAY_MAX
    $delayBox.Width   = 55
    $delayBox.Anchor  = 'Left'
    $tip.SetToolTip($delayBox, "Pause between characters and between Shift/AltGr and the key. Raise it if a remote console drops Shift or AltGr.")

    $typeBar.Controls.Add($layoutLabel, 0, 0)
    $typeBar.Controls.Add($layoutBox,   1, 0)
    $typeBar.Controls.Add($delayLabel,  2, 0)
    $typeBar.Controls.Add($delayBox,    3, 0)

    $split.Panel1.Controls.Add($toolbar)
    $split.Panel1.Controls.Add($typeBar)   # zuletzt hinzugefügt = zuerst angedockt = ganz unten
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
        TypeBar   = $typeBar
        LayoutBox = $layoutBox
        DelayBox  = $delayBox
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

    # ── Tipp-Einstellungen aus der Registry, Änderungen sofort zurückschreiben ─
    $savedKey = [string](Get-Setting 'TypingLayout' 'auto')
    foreach ($c in (Get-LayoutChoices)) {
        $idx = $layoutBox.Items.Add($c)
        if ($c.Key -eq $savedKey) { $layoutBox.SelectedIndex = $idx }
    }
    if ($layoutBox.SelectedIndex -lt 0) { $layoutBox.SelectedIndex = 0 }   # gespeichertes Layout nicht mehr vorhanden → Auto
    $delay = [int](Get-Setting 'TypingDelayMs' $TYPE_DELAY_MS)
    $delayBox.Value = [Math]::Max(0, [Math]::Min($TYPE_DELAY_MAX, $delay))

    $layoutBox.Add_SelectedIndexChanged({ Set-Setting 'TypingLayout' $script:ui.LayoutBox.SelectedItem.Key })
    $delayBox.Add_ValueChanged({ Set-Setting 'TypingDelayMs' ([int]$script:ui.DelayBox.Value) })

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
    $wanted      = $linesHeight + $toolbar.PreferredSize.Height + $typeBar.PreferredSize.Height + $split.SplitterWidth + $PREVIEW_HEIGHT + $LOG_HEIGHT
    $workArea    = [System.Windows.Forms.Screen]::PrimaryScreen.WorkingArea
    $maxClient   = [int]($workArea.Height * $MAX_HEIGHT_PCT)
    $form.ClientSize = New-Object System.Drawing.Size($FORM_WIDTH, [Math]::Min($wanted, $maxClient))

    $form.Add_Load({
        $s = $script:ui.Split
        # Knopfleisten + mindestens eine sichtbare Zeile
        $s.Panel1MinSize    = $script:ui.Toolbar.Height + $script:ui.TypeBar.Height + 30
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
