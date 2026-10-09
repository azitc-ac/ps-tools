# Legt die Test-VM für den VMware-Konsolen-Test an: Alpine-Live-ISO + CD mit Prüfskript.
# Keine Festplatte, kein Netzwerk. Braucht keine Adminrechte.
#
#   powershell -ExecutionPolicy Bypass -File .\tests\vmconsole\New-ConsoleTestVm.ps1 -Start
#
# Ablauf des Tests: siehe tests\vmconsole\README.md
param(
    [string]$VmDir = "$env:USERPROFILE\VMs\alpine-test",
    [switch]$Start
)
$ErrorActionPreference = 'Stop'

# Fest gepinnte Version, Prüfsumme aus latest-releases.yaml von alpinelinux.org
$AlpineIso    = "alpine-virt-3.24.2-x86_64.iso"
$AlpineUrl    = "https://dl-cdn.alpinelinux.org/alpine/v3.24/releases/x86_64/$AlpineIso"
$AlpineSha256 = "3ab424762af704b2c2a9e57df1dc37f982af260071504d977f2fb96822e7130b"

New-Item -ItemType Directory -Force -Path $VmDir | Out-Null
$isoPath = Join-Path $VmDir $AlpineIso
if (-not (Test-Path $isoPath)) {
    "Lade $AlpineUrl ..."
    [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
    (New-Object Net.WebClient).DownloadFile($AlpineUrl, $isoPath)
}
$hash = (Get-FileHash $isoPath -Algorithm SHA256).Hash.ToLower()
if ($hash -ne $AlpineSha256) { Remove-Item $isoPath; throw "SHA256 des Alpine-ISO stimmt nicht ($hash) - Datei gelöscht." }
"Alpine-ISO geprüft: $isoPath"

# ── CD mit Prüfskript per IMAPI2 (Windows-Bordmittel) ─────────────────────────
if (-not ('IsoStream' -as [type])) {
Add-Type -TypeDefinition @'
using System;
using System.IO;
using System.Runtime.InteropServices.ComTypes;
public static class IsoStream {
    public static void Save(object comStream, string path) {
        IStream s = (IStream)comStream;
        byte[] buf = new byte[65536];
        IntPtr pRead = System.Runtime.InteropServices.Marshal.AllocHGlobal(4);
        try {
            using (FileStream fs = File.Create(path)) {
                while (true) {
                    s.Read(buf, buf.Length, pRead);
                    int n = System.Runtime.InteropServices.Marshal.ReadInt32(pRead);
                    if (n <= 0) break;
                    fs.Write(buf, 0, n);
                }
            }
        } finally { System.Runtime.InteropServices.Marshal.FreeHGlobal(pRead); }
    }
}
'@
}
$fsi = New-Object -ComObject IMAPI2FS.MsftFileSystemImage
$fsi.FileSystemsToCreate = 3          # ISO9660 + Joliet (Joliet behält Kleinschreibung)
$fsi.VolumeName = "TCHCHECK"
$fsi.Root.AddTree((Join-Path $PSScriptRoot "iso"), $false)
$checkIso = Join-Path $VmDir "tch-check.iso"
[IsoStream]::Save($fsi.CreateResultImage().ImageStream, $checkIso)
"CD erzeugt: $checkIso ($((Get-Item $checkIso).Length) Bytes)"

# ── VMX ──────────────────────────────────────────────────────────────────────
$vmx = Join-Path $VmDir "alpine-tch-test.vmx"
@"
.encoding = "UTF-8"
config.version = "8"
virtualHW.version = "19"
displayName = "alpine-tch-test"
guestOS = "other5xlinux-64"
firmware = "bios"
memsize = "512"
numvcpus = "1"
sata0.present = "TRUE"
sata0:0.present = "TRUE"
sata0:0.deviceType = "cdrom-image"
sata0:0.fileName = "$AlpineIso"
sata0:0.startConnected = "TRUE"
sata0:1.present = "TRUE"
sata0:1.deviceType = "cdrom-image"
sata0:1.fileName = "tch-check.iso"
sata0:1.startConnected = "TRUE"
ethernet0.present = "FALSE"
usb.present = "FALSE"
sound.present = "FALSE"
floppy0.present = "FALSE"
"@ | Set-Content -Path $vmx -Encoding ASCII
"VM angelegt: $vmx"

if ($Start) {
    $vmrun = @("$env:ProgramFiles\VMware\VMware Workstation\vmrun.exe",
               "${env:ProgramFiles(x86)}\VMware\VMware Workstation\vmrun.exe") | Where-Object { Test-Path $_ } | Select-Object -First 1
    if (-not $vmrun) { throw "vmrun.exe nicht gefunden - ist VMware Workstation Pro installiert?" }
    & $vmrun -T ws start $vmx gui
    if ($LASTEXITCODE) { throw "vmrun start fehlgeschlagen (Exitcode $LASTEXITCODE)" }
    "VM gestartet."
}
