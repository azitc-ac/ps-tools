# Echte Tipp-Checks für „Paste clipboard as keyboard input" — ohne Pester, Exitcode 0 = grün.
# ACHTUNG: sendet echte Tastatureingaben. Öffnet dafür ein eigenes Zielfenster (TypingTarget.ps1)
# und holt es in den Vordergrund. Verliert es den Fokus, bricht das Tippen sofort ab
# (dieselbe Sicherung wie im Tool) — es landet also nichts in fremden Fenstern.
# Während des Laufs (~30 s) Maus und Tastatur nicht benutzen.
#
#   powershell.exe -STA -ExecutionPolicy Bypass -File .\tests\TextCopyHelper.Typing.Tests.ps1
param([string]$ScriptPath = (Join-Path $PSScriptRoot "..\TextCopyHelper.ps1"))

$TextCopyHelperNoRun = $true
. $ScriptPath

Add-Type -Namespace TcTest -Name Win -MemberDefinition @'
[DllImport("user32.dll")] public static extern bool SetForegroundWindow(IntPtr h);
[DllImport("user32.dll")] public static extern bool BringWindowToTop(IntPtr h);
[DllImport("user32.dll")] public static extern IntPtr GetForegroundWindow();
[DllImport("user32.dll")] public static extern uint GetWindowThreadProcessId(IntPtr h, IntPtr pid);
[DllImport("kernel32.dll")] public static extern uint GetCurrentThreadId();
[DllImport("user32.dll")] public static extern bool AttachThreadInput(uint a, uint b, bool attach);
[DllImport("user32.dll")] public static extern bool PostMessage(IntPtr h, uint msg, IntPtr w, IntPtr l);
'@

$script:failed = 0
function Check([string]$Name, [bool]$Condition, [string]$Detail = "") {
    if ($Condition) { Write-Host "  OK    $Name" }
    else            { Write-Host "  FAIL  $Name  $Detail" -ForegroundColor Red; $script:failed++ }
}

function Show-Diff([string]$Expected, [string]$Actual) {
    $n = [Math]::Min($Expected.Length, $Actual.Length)
    for ($i = 0; $i -lt $n; $i++) {
        if ($Expected[$i] -ne $Actual[$i]) {
            return "erste Abweichung an Pos $i : erwartet '$($Expected[$i])' (U+{0:X4}), bekommen '$($Actual[$i])' (U+{1:X4})" -f [int]$Expected[$i], [int]$Actual[$i]
        }
    }
    return "Länge erwartet $($Expected.Length), bekommen $($Actual.Length)"
}

function Set-Foreground([IntPtr]$Hwnd) {
    # Windows erlaubt SetForegroundWindow nur dem Vordergrund-Thread → kurz an ihn anhängen.
    for ($try = 0; $try -lt 5; $try++) {
        $fgThread = [TcTest.Win]::GetWindowThreadProcessId([TcTest.Win]::GetForegroundWindow(), [IntPtr]::Zero)
        $me       = [TcTest.Win]::GetCurrentThreadId()
        [TcTest.Win]::AttachThreadInput($me, $fgThread, $true) | Out-Null
        [TcTest.Win]::BringWindowToTop($Hwnd) | Out-Null
        [TcTest.Win]::SetForegroundWindow($Hwnd) | Out-Null
        [TcTest.Win]::AttachThreadInput($me, $fgThread, $false) | Out-Null
        Start-Sleep -Milliseconds 300
        if ([KeyTyper]::ForegroundWindow() -eq $Hwnd) { return $true }
    }
    return $false
}

# Tippt $Text in ein frisches Zielfenster und liefert @{ Result; Received; Layout }.
# $LayoutKey wie im Tool: 'auto', 'hkl:…' oder 'klid:…'
function Invoke-TypingRun([string]$Text, [string]$LayoutKey, [int]$DelayMs) {
    $tmp  = [IO.Path]::GetTempPath()
    $out  = Join-Path $tmp "tch-typing-out.txt"
    $hwf  = Join-Path $tmp "tch-typing-hwnd.txt"
    Remove-Item $out, $hwf -ErrorAction SilentlyContinue
    $proc = Start-Process powershell -PassThru -ArgumentList '-NoProfile', '-STA', '-ExecutionPolicy', 'Bypass',
            '-File', "`"$PSScriptRoot\TypingTarget.ps1`"", '-OutFile', "`"$out`"", '-HwndFile', "`"$hwf`""
    $sw = [Diagnostics.Stopwatch]::StartNew()
    while (-not (Test-Path $hwf) -and $sw.ElapsedMilliseconds -lt 15000) { Start-Sleep -Milliseconds 100 }
    if (-not (Test-Path $hwf)) { $proc | Stop-Process -ErrorAction SilentlyContinue; throw "Zielfenster startet nicht" }
    Start-Sleep -Milliseconds 300
    $hwnd = [IntPtr][int64](Get-Content $hwf)

    if (-not (Set-Foreground $hwnd)) {
        $proc | Stop-Process -ErrorAction SilentlyContinue
        throw "Zielfenster bekommt den Fokus nicht"
    }
    $layout = Resolve-TypingLayout -Key $LayoutKey -TargetWindow $hwnd
    try     { $r = [KeyTyper]::TypeText($Text, $layout.Hkl, $DelayMs, $hwnd) }
    finally { if ($layout.Unload) { [KeyTyper]::UnloadLayout($layout.Hkl) | Out-Null } }

    Start-Sleep -Milliseconds 300
    [TcTest.Win]::PostMessage($hwnd, 0x0010, [IntPtr]::Zero, [IntPtr]::Zero) | Out-Null   # WM_CLOSE
    $proc.WaitForExit(10000) | Out-Null
    $received = if (Test-Path $out) { [IO.File]::ReadAllText($out) } else { $null }
    return @{ Result = $r; Received = $received; Layout = $layout.Name }
}

$writeLayout = [KeyTyper]::LayoutOfWindow([KeyTyper]::ForegroundWindow())
Write-Host ("Aktives Layout: {0}" -f (Get-HklName $writeLayout))
$isGerman = (($writeLayout.ToInt64() -band 0xFFFF) -eq 0x0407)

# ── 1. Zuordnung Zeichen → Taste (ohne Tippen) ───────────────────────────────
Write-Host "Zuordnung"
$de = [IntPtr]0x04070407; $us = [IntPtr]0x04090409
$p = New-Object KeyTyper+KeyPlan
Check "DE '[' = AltGr+8"    ([KeyTyper]::TryPlan('[', $de, [ref]$p) -and $p.Ctrl -and $p.Alt -and $p.Scan -eq 0x09)
Check "DE '$' = Shift+4"    ([KeyTyper]::TryPlan('$', $de, [ref]$p) -and $p.Shift -and -not $p.Alt -and $p.Scan -eq 0x05)
Check "US '[' = eigene Taste ohne Modifier" ([KeyTyper]::TryPlan('[', $us, [ref]$p) -and -not ($p.Shift -or $p.Ctrl -or $p.Alt) -and $p.Scan -eq 0x1A)
Check "DE '^' ist Tottaste"  ([KeyTyper]::TryPlan('^', $de, [ref]$p) -and $p.Dead)
Check "DE '°' (Shift+^) ist keine Tottaste" ([KeyTyper]::TryPlan([char]0xB0, $de, [ref]$p) -and $p.Shift -and -not $p.Dead)
Check "DE '´' ist Tottaste"  ([KeyTyper]::TryPlan([char]0xB4, $de, [ref]$p) -and $p.Dead)
Check "US 'ä' fehlt im Layout" (-not [KeyTyper]::TryPlan([char]0xE4, $us, [ref]$p))

# Nicht installiertes Layout: nur laden, danach wieder entladen
$before = @([KeyTyper]::InstalledLayouts() | ForEach-Object { $_.ToInt64() }) -join ','
$fr = Resolve-TypingLayout -Key 'klid:0000040C' -TargetWindow ([IntPtr]::Zero)
Check "FR geladen, 'a' liegt auf der Q-Taste (AZERTY)" ([KeyTyper]::TryPlan('a', $fr.Hkl, [ref]$p) -and $p.Scan -eq 0x10) $fr.Name
if ($fr.Unload) { [KeyTyper]::UnloadLayout($fr.Hkl) | Out-Null }
$after = @([KeyTyper]::InstalledLayouts() | ForEach-Object { $_.ToInt64() }) -join ','
Check "Layout-Liste nach Entladen unverändert" ($before -eq $after) "$before -> $after"

# ── 2. Echt tippen ────────────────────────────────────────────────────────────
# Gesperrte Sitzung / minimiertes RDP-Fenster: kein Vordergrundfenster, Windows verwirft Eingaben.
# Das ist ein Umgebungsproblem, kein Fehler → Exitcode 2 statt 1.
if ([KeyTyper]::ForegroundWindow() -eq [IntPtr]::Zero) {
    Write-Host ""
    Write-Host "Tipp-Teil übersprungen: kein Vordergrundfenster (Sitzung gesperrt oder RDP-Fenster minimiert)." -ForegroundColor Yellow
    if ($script:failed) { Write-Host "$script:failed Check(s) fehlgeschlagen." -ForegroundColor Red; exit 1 }
    exit 2
}

$ascii  = -join (0x20..0x7E | ForEach-Object { [char]$_ })
$extra  = if ($isGerman) { -join ([char[]](0xE4,0xF6,0xFC,0xC4,0xD6,0xDC,0xDF,0x20AC,0xA7,0xB0,0xB2,0xB3,0xB5,0xB4)) } else { "" }
$sample = "$ascii$extra`r`nZeile 2`tTab ^ `` ´ ~ [x] {y} \z| @€`r`n"

Write-Host "Tippen, Layout Auto, 0 ms"
$run = Invoke-TypingRun $sample 'auto' 0
Check "alles angekommen ($($sample.Length) Zeichen, $($run.Layout))" ($run.Received -ceq $sample) (Show-Diff $sample $run.Received)
Check "kein Abbruch" (-not $run.Result.Aborted) $run.Result.Aborted
Check "keine Unicode-Ersatzzeichen" ($run.Result.Unicode -eq 0) $run.Result.Missing

Write-Host "Tippen, Layout Auto, 20 ms (Modifier mit Pause)"
$short = "Shift+AltGr: `$ [ ] { } \ | @ ~ € ° § & / ( ) = ? `" ' * + #`r`n"
$run = Invoke-TypingRun $short 'auto' 20
Check "alles angekommen" ($run.Received -ceq $short) (Show-Diff $short $run.Received)

# Gegenprobe: falsches Layout gewählt → so entsteht „8 statt [" (Muss fehlschlagen, sonst prüft der Test nichts)
$wrong = if ($isGerman) { 'hkl:04090409' } else { 'hkl:04070407' }
Write-Host "Gegenprobe: falsches Layout ($wrong)"
$probe = "[`$]"
$run = Invoke-TypingRun $probe $wrong 0
Check "falsches Layout verfälscht den Text (Test ist trennscharf)" ($run.Received -cne $probe) "bekommen '$($run.Received)'"
Write-Host "        gesendet '$probe' -> angekommen '$($run.Received)'"

Write-Host ""
if ($script:failed) { Write-Host "$script:failed Check(s) fehlgeschlagen." -ForegroundColor Red; exit 1 }
Write-Host "Alle Checks grün."
exit 0
