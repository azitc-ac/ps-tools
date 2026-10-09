<#
.SYNOPSIS
    Testet die Zwischenablage von fm.ps1 (K / P): Dateiliste in beide Richtungen und virtuelle Dateien wie vom RDP-Client.
    ACHTUNG: ueberschreibt die Zwischenablage dieses Rechners (Text wird wiederhergestellt, Dateien/Bilder nicht).
    Aufruf: powershell -NoProfile -STA -File .\test-zwischenablage.ps1
#>
$ErrorActionPreference = "Stop"
if ([System.Threading.Thread]::CurrentThread.GetApartmentState() -ne "STA") { throw "Bitte mit powershell -STA starten." }
Add-Type -AssemblyName System.Windows.Forms
$fm = Join-Path $PSScriptRoot "fm.ps1"
$wurzel = Join-Path ([IO.Path]::GetTempPath()) ("fmz-test-" + [guid]::NewGuid().ToString("N").Substring(0, 8))
$fehler = 0
function Pruefe([string]$name, [bool]$ok) {
    if ($ok) { Write-Host "OK     $name" -ForegroundColor Green } else { Write-Host "FEHLER $name" -ForegroundColor Red; $script:fehler++ }
}
function Neu-Baum {
    Remove-Item $wurzel -Recurse -Force -ErrorAction SilentlyContinue
    [void](New-Item -ItemType Directory "$wurzel\links", "$wurzel\rechts", "$wurzel\aussen" -Force)
    Set-Content "$wurzel\links\eins.txt" "eins"; Set-Content "$wurzel\links\zwei.txt" "zwei"
    Set-Content "$wurzel\rechts\eins.txt" "ALT"
}

# Quelle fuer virtuelle Dateien: genau das, was rdpclip auf dem Server bereitstellt (FileGroupDescriptorW + FileContents als IStream).
$quelle = @'
using System;
using System.Runtime.InteropServices;
using System.Runtime.InteropServices.ComTypes;
using System.Text;

public class FakeRdpQuelle : System.Runtime.InteropServices.ComTypes.IDataObject
{
    [DllImport("ole32.dll")] static extern int OleInitialize(IntPtr p);
    [DllImport("ole32.dll")] static extern int OleSetClipboard(System.Runtime.InteropServices.ComTypes.IDataObject o);
    [DllImport("ole32.dll")] static extern int CreateStreamOnHGlobal(IntPtr h, bool del, out IStream s);
    [DllImport("shell32.dll")] static extern int SHCreateStdEnumFmtEtc(uint n, FORMATETC[] f, out IEnumFORMATETC e);
    [DllImport("user32.dll", CharSet = CharSet.Unicode)] static extern uint RegisterClipboardFormat(string n);
    [DllImport("kernel32.dll")] static extern IntPtr GlobalAlloc(uint flags, UIntPtr size);
    [DllImport("kernel32.dll")] static extern IntPtr GlobalLock(IntPtr h);
    [DllImport("kernel32.dll")] static extern bool GlobalUnlock(IntPtr h);

    string[] namen; string[] inhalte; bool[] ordner;
    short cfDesc, cfContents;

    public static void Setze(string[] namen, string[] inhalte, bool[] ordner)
    {
        OleInitialize(IntPtr.Zero);
        FakeRdpQuelle q = new FakeRdpQuelle();
        q.namen = namen; q.inhalte = inhalte; q.ordner = ordner;
        q.cfDesc = unchecked((short)RegisterClipboardFormat("FileGroupDescriptorW"));
        q.cfContents = unchecked((short)RegisterClipboardFormat("FileContents"));
        int hr = OleSetClipboard(q);
        if (hr != 0) throw new COMException("OleSetClipboard", hr);
    }

    public int QueryGetData(ref FORMATETC f)
    {
        if (f.cfFormat == cfDesc && (f.tymed & TYMED.TYMED_HGLOBAL) != 0) return 0;
        if (f.cfFormat == cfContents && (f.tymed & TYMED.TYMED_ISTREAM) != 0) return 0;
        return 1;
    }

    public void GetData(ref FORMATETC f, out STGMEDIUM m)
    {
        m = new STGMEDIUM();
        if (f.cfFormat == cfDesc)
        {
            byte[] b = new byte[4 + 592 * namen.Length];
            BitConverter.GetBytes(namen.Length).CopyTo(b, 0);
            for (int i = 0; i < namen.Length; i++)
            {
                int off = 4 + i * 592;
                uint flags = 0x4 | 0x40;                                  // FD_ATTRIBUTES | FD_FILESIZE
                uint attr = ordner[i] ? 0x10u : 0x80u;
                long len = ordner[i] ? 0 : Encoding.UTF8.GetByteCount(inhalte[i]);
                BitConverter.GetBytes(flags).CopyTo(b, off);
                BitConverter.GetBytes(attr).CopyTo(b, off + 36);
                BitConverter.GetBytes((uint)(len >> 32)).CopyTo(b, off + 64);
                BitConverter.GetBytes((uint)(len & 0xFFFFFFFF)).CopyTo(b, off + 68);
                Encoding.Unicode.GetBytes(namen[i]).CopyTo(b, off + 72);
            }
            IntPtr h = GlobalAlloc(0x2, (UIntPtr)b.Length);                // GMEM_MOVEABLE
            IntPtr p = GlobalLock(h); Marshal.Copy(b, 0, p, b.Length); GlobalUnlock(h);
            m.tymed = TYMED.TYMED_HGLOBAL; m.unionmember = h; m.pUnkForRelease = null;
            return;
        }
        if (f.cfFormat == cfContents && f.lindex >= 0 && f.lindex < namen.Length)
        {
            IStream s; CreateStreamOnHGlobal(IntPtr.Zero, true, out s);
            byte[] d = Encoding.UTF8.GetBytes(inhalte[f.lindex]);
            s.Write(d, d.Length, IntPtr.Zero);
            s.Seek(0, 0, IntPtr.Zero);
            m.tymed = TYMED.TYMED_ISTREAM; m.unionmember = Marshal.GetIUnknownForObject(s); m.pUnkForRelease = null;
            return;
        }
        Marshal.ThrowExceptionForHR(unchecked((int)0x80040064));           // DV_E_FORMATETC
    }

    public void GetDataHere(ref FORMATETC f, ref STGMEDIUM m) { throw new NotImplementedException(); }
    public int GetCanonicalFormatEtc(ref FORMATETC i, out FORMATETC o) { o = i; o.ptd = IntPtr.Zero; return 0x00040130; }
    public void SetData(ref FORMATETC f, ref STGMEDIUM m, bool r) { throw new NotImplementedException(); }
    public IEnumFORMATETC EnumFormatEtc(DATADIR d)
    {
        FORMATETC[] f = new FORMATETC[2];
        f[0].cfFormat = cfDesc; f[0].dwAspect = DVASPECT.DVASPECT_CONTENT; f[0].lindex = -1; f[0].tymed = TYMED.TYMED_HGLOBAL;
        f[1].cfFormat = cfContents; f[1].dwAspect = DVASPECT.DVASPECT_CONTENT; f[1].lindex = -1; f[1].tymed = TYMED.TYMED_ISTREAM;
        IEnumFORMATETC e; SHCreateStdEnumFmtEtc(2, f, out e); return e;
    }
    public int DAdvise(ref FORMATETC f, ADVF a, IAdviseSink s, out int c) { c = 0; return unchecked((int)0x80040003); }
    public void DUnadvise(int c) { throw new COMException("nicht unterstuetzt", unchecked((int)0x80040003)); }
    public int EnumDAdvise(out IEnumSTATDATA e) { e = null; return unchecked((int)0x80040003); }
}
'@
$quelleDatei = Join-Path ([IO.Path]::GetTempPath()) "fake-rdp-quelle.ps1"
@"
Add-Type -TypeDefinition @'
$quelle
'@ -Language CSharp
Add-Type -AssemblyName System.Windows.Forms
[FakeRdpQuelle]::Setze([string[]]@('virt.txt','ordner','ordner\innen.txt','..\..\boese.txt'), [string[]]@('virtueller Inhalt','','im Ordner','BOESE'), [bool[]]@(`$false,`$true,`$false,`$false))
Set-Content (Join-Path ([IO.Path]::GetTempPath()) 'fake-rdp-bereit.txt') 'ok'
`$ende = (Get-Date).AddSeconds(60)
while ((Get-Date) -lt `$ende) { [System.Windows.Forms.Application]::DoEvents(); Start-Sleep -Milliseconds 50 }
"@ | Set-Content $quelleDatei -Encoding UTF8

# Zwischenablage-Text sichern
$altText = $null; try { if ([System.Windows.Forms.Clipboard]::ContainsText()) { $altText = [System.Windows.Forms.Clipboard]::GetText() } } catch { }
$kind = $null
try {
    # A) K: markierte Dateien in die Zwischenablage
    Neu-Baum; & $fm -Links "$wurzel\links" -Rechts "$wurzel\rechts" -Tasten @("DownArrow", "K")
    $liste = @([System.Windows.Forms.Clipboard]::GetFileDropList())
    Pruefe "K: Datei steht als Dateiliste in der Zwischenablage" ($liste.Count -eq 1 -and $liste[0] -eq "$wurzel\links\eins.txt")
    Neu-Baum; & $fm -Links "$wurzel\links" -Rechts "$wurzel\rechts" -Tasten @("A", "^C")
    $liste = @([System.Windows.Forms.Clipboard]::GetFileDropList())
    Pruefe "Strg+C: alle markierten Dateien" ($liste.Count -eq 2)

    # B) P mit lokaler Dateiliste (CF_HDROP): in die rechte Spalte einfuegen, vorhandene mit J ueberschreiben
    Neu-Baum
    $sc = New-Object System.Collections.Specialized.StringCollection; [void]$sc.Add("$wurzel\links\eins.txt"); [void]$sc.Add("$wurzel\links\zwei.txt")
    [System.Windows.Forms.Clipboard]::SetFileDropList($sc)
    & $fm -Links "$wurzel\links" -Rechts "$wurzel\rechts" -Tasten @("Tab", "P", "J")
    Pruefe "P: lokale Dateiliste eingefuegt, eins.txt ueberschrieben" ((Get-Content "$wurzel\rechts\eins.txt") -eq "eins" -and (Test-Path "$wurzel\rechts\zwei.txt"))
    Neu-Baum; [System.Windows.Forms.Clipboard]::SetFileDropList($sc)
    & $fm -Links "$wurzel\links" -Rechts "$wurzel\rechts" -Tasten @("Tab", "^V", "N")
    Pruefe "Strg+V: Ueberschreiben verneint, zwei.txt trotzdem da" ((Get-Content "$wurzel\rechts\eins.txt") -eq "ALT" -and (Test-Path "$wurzel\rechts\zwei.txt"))

    # C) P mit virtuellen Dateien wie vom RDP-Client (IStream), inklusive Ordner und einem boesen Namen
    Neu-Baum; Remove-Item (Join-Path ([IO.Path]::GetTempPath()) "fake-rdp-bereit.txt") -ErrorAction SilentlyContinue
    $kind = Start-Process powershell.exe -ArgumentList "-NoProfile", "-STA", "-ExecutionPolicy", "Bypass", "-File", "`"$quelleDatei`"" -PassThru -WindowStyle Hidden
    $t0 = Get-Date; while (-not (Test-Path (Join-Path ([IO.Path]::GetTempPath()) "fake-rdp-bereit.txt")) -and ((Get-Date) - $t0).TotalSeconds -lt 40) { Start-Sleep -Milliseconds 300 }
    Pruefe "Testquelle (simulierter RDP-Client) ist bereit" (Test-Path (Join-Path ([IO.Path]::GetTempPath()) "fake-rdp-bereit.txt"))
    & $fm -Links "$wurzel\links" -Rechts "$wurzel\rechts" -Tasten @("Tab", "P")
    Pruefe "Virtuelle Datei kommt an" ((Test-Path "$wurzel\rechts\virt.txt") -and ((Get-Content "$wurzel\rechts\virt.txt") -eq "virtueller Inhalt"))
    Pruefe "Virtueller Ordner samt Inhalt kommt an" ((Test-Path "$wurzel\rechts\ordner\innen.txt") -and ((Get-Content "$wurzel\rechts\ordner\innen.txt") -eq "im Ordner"))
    Pruefe "Pfad mit ..\..\ wird NICHT geschrieben" ((-not (Test-Path "$wurzel\boese.txt")) -and (-not (Test-Path "$wurzel\aussen\boese.txt")) -and (-not (Test-Path "$wurzel\rechts\boese.txt")))
} finally {
    if ($kind -and -not $kind.HasExited) { Stop-Process -Id $kind.Id -Force -ErrorAction SilentlyContinue }
    try { if ($altText) { [System.Windows.Forms.Clipboard]::SetText($altText) } else { [System.Windows.Forms.Clipboard]::Clear() } } catch { }
    Remove-Item $wurzel -Recurse -Force -ErrorAction SilentlyContinue
    Remove-Item $quelleDatei, (Join-Path ([IO.Path]::GetTempPath()) "fake-rdp-bereit.txt") -ErrorAction SilentlyContinue
}
if ($fehler -gt 0) { Write-Host "`n$fehler Fehler" -ForegroundColor Red; exit 1 }
Write-Host "`nAlle Zwischenablage-Tests bestanden" -ForegroundColor Green
