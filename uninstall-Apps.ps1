param(
    [string]$filter = "",
    [switch]$includeSystemComponents = $false,
    [switch]$noElevationCheck = $false
)

Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing
[System.Windows.Forms.Application]::EnableVisualStyles()

# =====================================================================
#  Hilfsfunktionen
# =====================================================================

function Test-IsAdmin {
    $id = [System.Security.Principal.WindowsIdentity]::GetCurrent()
    $principal = New-Object System.Security.Principal.WindowsPrincipal($id)
    return $principal.IsInRole([System.Security.Principal.WindowsBuiltInRole]::Administrator)
}

# Zerlegt eine Kommandozeile in Programmdatei und Argumente.
# Berücksichtigt Anführungszeichen und Pfade mit Leerzeichen ohne Quotes.
function Split-CommandLine {
    param([string]$commandLine)

    $cmd = $commandLine.Trim()
    if ($cmd -eq "") { return $null }

    if ($cmd.StartsWith('"')) {
        $end = $cmd.IndexOf('"', 1)
        if ($end -lt 0) { return $null }
        return [pscustomobject]@{
            File      = $cmd.Substring(1, $end - 1)
            Arguments = $cmd.Substring($end + 1).Trim()
        }
    }

    # Ohne Quotes: kürzesten passenden Pfadteil suchen (Pfade mit Leerzeichen).
    # Von links nach rechts, damit Argumente wie /log=c:\x.exe den Pfad nicht verlängern.
    $parts = $cmd -split ' '
    for ($i = 1; $i -le $parts.Count; $i++) {
        $candidate = ($parts[0..($i - 1)] -join ' ')
        if ($candidate -match '\.(exe|com|bat|cmd)$' -or (Test-Path -LiteralPath $candidate -PathType Leaf -ErrorAction SilentlyContinue)) {
            return [pscustomobject]@{
                File      = $candidate
                Arguments = (($parts | Select-Object -Skip $i) -join ' ').Trim()
            }
        }
    }

    return [pscustomobject]@{
        File      = $parts[0]
        Arguments = (($parts | Select-Object -Skip 1) -join ' ').Trim()
    }
}

# Liest alle Deinstallations-Registry-Schlüssel aus.
function Get-InstalledApp {
    param([switch]$withSystemComponents)

    $roots = @(
        @{ Path = 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall';            Scope = 'Maschine (64)' },
        @{ Path = 'HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall'; Scope = 'Maschine (32)' },
        @{ Path = 'HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall';            Scope = 'Benutzer' },
        @{ Path = 'HKCU:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall'; Scope = 'Benutzer (32)' }
    )

    $result = @()

    foreach ($root in $roots) {
        if (-not (Test-Path $root.Path)) { continue }

        foreach ($key in (Get-ChildItem -Path $root.Path -ErrorAction SilentlyContinue)) {
            $p = $null
            try { $p = Get-ItemProperty -Path $key.PSPath -ErrorAction Stop } catch { continue }

            if (-not $p.DisplayName) { continue }

            # Office Click-to-Run immer anzeigen - es ist teils als SystemComponent markiert
            $isOfficeC2R = [bool]($p.UninstallString -match 'OfficeClickToRun\.exe')

            if (-not $withSystemComponents -and -not $isOfficeC2R) {
                if ($p.SystemComponent -eq 1) { continue }
                if ($p.ParentKeyName) { continue }
                if ($p.ReleaseType -match 'Update|Hotfix|Security Update') { continue }
                if ($key.PSChildName -match '^KB\d{6,}$') { continue }
            }

            $uninstallString = $p.UninstallString
            $quietString     = $p.QuietUninstallString
            if (-not $uninstallString -and -not $quietString) { continue }

            $size = $null
            if ($p.EstimatedSize) { $size = [math]::Round($p.EstimatedSize / 1024, 1) }

            $result += [pscustomobject]@{
                Name            = [string]$p.DisplayName
                Version         = [string]$p.DisplayVersion
                Publisher       = [string]$p.Publisher
                InstallDate     = [string]$p.InstallDate
                SizeMB          = $size
                Scope           = $root.Scope
                KeyName         = $key.PSChildName
                RegistryPath    = $key.PSPath
                UninstallString = [string]$uninstallString
                QuietString     = [string]$quietString
                InstallLocation = [string]$p.InstallLocation
                IsBundle        = [bool]($p.BundleVersion -or $p.BundleProviderKey -or $p.BundleCachePath)
                IsInno          = [bool]($p.'Inno Setup: App Path' -or $p.'Inno Setup: Setup Version')
                Status          = ""
            }
        }
    }

    # Duplikate (gleicher Name + Version + Scope) entfernen, nach Name sortieren
    $result |
        Group-Object Name, Version, Scope |
        ForEach-Object { $_.Group[0] } |
        Sort-Object Name
}

# Erzeugt eine Office-Setup-Konfigurationsdatei für die stille Deinstallation (MSI-Office).
function New-OfficeSilentConfig {
    param([string]$productCode)

    $tempDir = if ($env:TEMP) { $env:TEMP } else { [System.IO.Path]::GetTempPath() }
    $file = Join-Path $tempDir ("office-silent-uninstall-{0}.xml" -f ([guid]::NewGuid().ToString('N')))
    $xml = @"
<Configuration Product="$productCode">
  <Display Level="none" CompletionNotice="no" SuppressModal="yes" AcceptEula="yes" />
  <Setting Id="SETUP_REBOOT" Value="Never" />
</Configuration>
"@
    Set-Content -LiteralPath $file -Value $xml -Encoding UTF8
    return $file
}

# Ermittelt den auszuführenden Befehl inklusive Silent-Schaltern.
# Rückgabe: File, Arguments, Kind, Silent (bekannt/unbekannt), Note
function Get-UninstallPlan {
    param(
        [Parameter(Mandatory = $true)] $app,
        [switch]$guessSilent
    )

    # 1) Office Click-to-Run -----------------------------------------------
    $officeSource = if ($app.UninstallString) { $app.UninstallString } else { $app.QuietString }
    if ($officeSource -match 'OfficeClickToRun\.exe') {
        $parsed = Split-CommandLine $officeSource
        if (-not $parsed) { return $null }
        $args = $parsed.Arguments
        if ($args -match '(?i)\bDisplayLevel\s*=\s*\S+') {
            $args = $args -replace '(?i)\bDisplayLevel\s*=\s*\S+', 'DisplayLevel=False'
        } else {
            $args = ($args + ' DisplayLevel=False').Trim()
        }
        if ($args -notmatch '(?i)\bforceappshutdown\s*=') {
            $args = ($args + ' forceappshutdown=True').Trim()
        }
        return [pscustomobject]@{
            File = $parsed.File; Arguments = $args; Kind = 'Office C2R'
            Silent = $true; Note = 'DisplayLevel=False'; TempFile = $null
        }
    }

    # 2) Office MSI (setup.exe /uninstall <Produkt> /config <xml>) ---------
    if ($officeSource -match '(?i)\\Office\w*\\setup\.exe' -or
        ($officeSource -match '(?i)setup\.exe' -and $officeSource -match '(?i)/uninstall\s+\w+')) {
        $parsed = Split-CommandLine $officeSource
        if ($parsed) {
            $product = 'ProPlus'
            if ($parsed.Arguments -match '(?i)/uninstall\s+(\S+)') { $product = $Matches[1] }
            $cfg  = New-OfficeSilentConfig -productCode $product
            $args = $parsed.Arguments -replace '(?i)/config\s+"[^"]*"', '' -replace '(?i)/config\s+\S+', ''
            $args = $args -replace '\s{2,}', ' '
            if ($cfg) { $args = ($args.Trim() + ' /config "' + $cfg + '"').Trim() } else { $args = $args.Trim() }
            return [pscustomobject]@{
                File = $parsed.File; Arguments = $args; Kind = 'Office MSI'
                Silent = $true; Note = 'Display Level=none'; TempFile = $cfg
            }
        }
    }

    # 3) MSI ---------------------------------------------------------------
    # Nur wenn der Befehl wirklich msiexec aufruft. Ein GUID-Schlüsselname allein
    # genügt nicht: Nicht-MSI-Programme mit GUID-Schlüssel würden sonst mit
    # msiexec entfernt, was folgenlos mit 1605 ("nicht installiert") endet.
    $msiSource = if ($app.UninstallString) { $app.UninstallString } else { $app.QuietString }
    if ($msiSource -match '(?i)msiexec') {
        $code = $null
        if ($msiSource -match '(\{[0-9A-Fa-f\-]{36}\})') { $code = $Matches[1] }
        elseif ($app.KeyName -match '^\{[0-9A-Fa-f\-]{36}\}$') { $code = $app.KeyName }

        if ($code) {
            return [pscustomobject]@{
                File = $(if ($env:SystemRoot) { "$env:SystemRoot\System32\msiexec.exe" } else { 'msiexec.exe' })
                Arguments = "/x $code /qn /norestart"
                Kind = 'MSI'; Silent = $true; Note = '/qn /norestart'; TempFile = $null
            }
        }
    }

    # 4) QuietUninstallString (vom Hersteller geliefert) -------------------
    if ($app.QuietString) {
        $parsed = Split-CommandLine $app.QuietString
        if ($parsed) {
            return [pscustomobject]@{
                File = $parsed.File; Arguments = $parsed.Arguments; Kind = 'QuietUninstallString'
                Silent = $true; Note = 'Hersteller-Silent-Befehl'; TempFile = $null
            }
        }
    }

    if (-not $app.UninstallString) { return $null }
    $parsed = Split-CommandLine $app.UninstallString
    if (-not $parsed) { return $null }

    $file = $parsed.File
    $args = $parsed.Arguments
    $leaf = ($file -split '[\\/]')[-1]

    # 5) Bekannte Installer-Typen -----------------------------------------
    # Inno Setup
    if ($app.IsInno -or $leaf -match '(?i)^unins\d*\.exe$') {
        return [pscustomobject]@{
            File = $file
            Arguments = ($args + ' /VERYSILENT /SUPPRESSMSGBOXES /NORESTART').Trim()
            Kind = 'Inno Setup'; Silent = $true
            Note = '/VERYSILENT /SUPPRESSMSGBOXES /NORESTART'; TempFile = $null
        }
    }

    # WiX Burn Bundle
    if ($app.IsBundle) {
        $a = $args
        if ($a -notmatch '(?i)/uninstall') { $a = ($a + ' /uninstall').Trim() }
        return [pscustomobject]@{
            File = $file; Arguments = ($a + ' /quiet /norestart').Trim()
            Kind = 'WiX Burn'; Silent = $true; Note = '/uninstall /quiet /norestart'; TempFile = $null
        }
    }

    # Squirrel (Update.exe --uninstall)
    if ($leaf -match '(?i)^update\.exe$' -and $args -match '(?i)--uninstall') {
        return [pscustomobject]@{
            File = $file; Arguments = ($args + ' -s').Trim()
            Kind = 'Squirrel'; Silent = $true; Note = '-s'; TempFile = $null
        }
    }

    # InstallShield
    if ($args -match '(?i)-runfromtemp|/removeonly|InstallShield' -or $file -match '(?i)InstallShield') {
        $a = $args
        if ($a -notmatch '(?i)(^|\s)/s(\s|$)') { $a = ($a + ' /s').Trim() }
        if ($a -notmatch '(?i)/SMS') { $a = ($a + ' /SMS').Trim() }
        return [pscustomobject]@{
            File = $file; Arguments = $a; Kind = 'InstallShield'; Silent = $true
            Note = '/s /SMS (benötigt ggf. Antwortdatei)'; TempFile = $null
        }
    }

    # NSIS
    if ($leaf -match '(?i)^(uninstall|uninst|uninstaller|au_)\S*\.exe$') {
        return [pscustomobject]@{
            File = $file; Arguments = ($args + ' /S').Trim()
            Kind = 'NSIS'; Silent = $true; Note = '/S'; TempFile = $null
        }
    }

    # 6) Unbekannt ---------------------------------------------------------
    if ($guessSilent) {
        return [pscustomobject]@{
            File = $file; Arguments = ($args + ' /S').Trim()
            Kind = 'Unbekannt'; Silent = $false; Note = '/S (geraten)'; TempFile = $null
        }
    }

    return [pscustomobject]@{
        File = $file; Arguments = $args; Kind = 'Unbekannt'; Silent = $false
        Note = 'interaktiv'; TempFile = $null
    }
}

function Get-ExitCodeText {
    param([int]$code)
    switch ($code) {
        0     { 'OK' }
        1602  { 'Abgebrochen (Benutzer)' }
        1603  { 'Schwerwiegender Fehler (1603)' }
        1605  { 'Produkt nicht installiert (1605)' }
        1618  { 'Andere Installation läuft (1618)' }
        1619  { 'Installationspaket nicht gefunden (1619)' }
        1641  { 'OK - Neustart eingeleitet' }
        3010  { 'OK - Neustart erforderlich' }
        default { "Exitcode $code" }
    }
}

function Test-ExitCodeSuccess {
    param([int]$code)
    return ($code -eq 0 -or $code -eq 3010 -or $code -eq 1641 -or $code -eq 1605)
}

# =====================================================================
#  GUI
# =====================================================================

$script:allApps         = @()
$script:checkedKeys     = New-Object 'System.Collections.Generic.HashSet[string]'
$script:sortColumn      = 0
$script:sortAscending   = $true
$script:cancelRequested = $false
$script:isRunning       = $false
$script:suppressCheck   = $false

$form = New-Object System.Windows.Forms.Form
$form.Text = "Programme deinstallieren"
$form.Size = New-Object System.Drawing.Size(980, 660)
$form.StartPosition = "CenterScreen"
$form.MinimumSize = New-Object System.Drawing.Size(760, 480)

# --- Kopfbereich: Suche und Aktionen ---
$lblSearch = New-Object System.Windows.Forms.Label
$lblSearch.Text = "Suche:"
$lblSearch.Location = New-Object System.Drawing.Point(12, 15)
$lblSearch.Size = New-Object System.Drawing.Size(45, 20)

$txtSearch = New-Object System.Windows.Forms.TextBox
$txtSearch.Location = New-Object System.Drawing.Point(60, 12)
$txtSearch.Size = New-Object System.Drawing.Size(260, 23)
$txtSearch.Text = $filter

$btnRefresh = New-Object System.Windows.Forms.Button
$btnRefresh.Text = "Aktualisieren"
$btnRefresh.Location = New-Object System.Drawing.Point(330, 11)
$btnRefresh.Size = New-Object System.Drawing.Size(100, 25)

$btnSelectAll = New-Object System.Windows.Forms.Button
$btnSelectAll.Text = "Alle wählen"
$btnSelectAll.Location = New-Object System.Drawing.Point(436, 11)
$btnSelectAll.Size = New-Object System.Drawing.Size(100, 25)

$btnSelectNone = New-Object System.Windows.Forms.Button
$btnSelectNone.Text = "Auswahl leeren"
$btnSelectNone.Location = New-Object System.Drawing.Point(542, 11)
$btnSelectNone.Size = New-Object System.Drawing.Size(100, 25)

$chkSystem = New-Object System.Windows.Forms.CheckBox
$chkSystem.Text = "Systemkomponenten/Updates anzeigen"
$chkSystem.Location = New-Object System.Drawing.Point(656, 13)
$chkSystem.Size = New-Object System.Drawing.Size(280, 22)
$chkSystem.Checked = [bool]$includeSystemComponents

# --- Liste ---
$listView = New-Object System.Windows.Forms.ListView
$listView.Location = New-Object System.Drawing.Point(12, 45)
$listView.Size = New-Object System.Drawing.Size(944, 380)
$listView.View = [System.Windows.Forms.View]::Details
$listView.CheckBoxes = $true
$listView.FullRowSelect = $true
$listView.GridLines = $true
$listView.HideSelection = $false
$listView.Anchor = 'Top,Left,Right,Bottom'
[void]$listView.Columns.Add("Name", 300)
[void]$listView.Columns.Add("Version", 100)
[void]$listView.Columns.Add("Herausgeber", 170)
[void]$listView.Columns.Add("Größe (MB)", 90)
[void]$listView.Columns.Add("Quelle", 100)
[void]$listView.Columns.Add("Modus", 120)
[void]$listView.Columns.Add("Status", 200)

# --- Optionen ---
$chkGuess = New-Object System.Windows.Forms.CheckBox
$chkGuess.Text = "Bei unbekannten Installern Silent-Schalter raten (/S)"
$chkGuess.Location = New-Object System.Drawing.Point(12, 433)
$chkGuess.Size = New-Object System.Drawing.Size(340, 22)
$chkGuess.Checked = $true
$chkGuess.Anchor = 'Left,Bottom'

$chkSkipUnknown = New-Object System.Windows.Forms.CheckBox
$chkSkipUnknown.Text = "Nicht-stille Deinstallationen überspringen"
$chkSkipUnknown.Location = New-Object System.Drawing.Point(360, 433)
$chkSkipUnknown.Size = New-Object System.Drawing.Size(300, 22)
$chkSkipUnknown.Checked = $false
$chkSkipUnknown.Anchor = 'Left,Bottom'

# --- Fortschritt ---
$lblCurrent = New-Object System.Windows.Forms.Label
$lblCurrent.Location = New-Object System.Drawing.Point(12, 460)
$lblCurrent.Size = New-Object System.Drawing.Size(944, 20)
$lblCurrent.Text = ""
$lblCurrent.Anchor = 'Left,Right,Bottom'

$progress = New-Object System.Windows.Forms.ProgressBar
$progress.Location = New-Object System.Drawing.Point(12, 482)
$progress.Size = New-Object System.Drawing.Size(944, 20)
$progress.Anchor = 'Left,Right,Bottom'

$txtLog = New-Object System.Windows.Forms.TextBox
$txtLog.Location = New-Object System.Drawing.Point(12, 508)
$txtLog.Size = New-Object System.Drawing.Size(944, 70)
$txtLog.Multiline = $true
$txtLog.ScrollBars = 'Vertical'
$txtLog.ReadOnly = $true
$txtLog.Anchor = 'Left,Right,Bottom'

# --- Fußbereich ---
$lblCount = New-Object System.Windows.Forms.Label
$lblCount.Location = New-Object System.Drawing.Point(12, 588)
$lblCount.Size = New-Object System.Drawing.Size(500, 22)
$lblCount.Anchor = 'Left,Bottom'

$btnUninstall = New-Object System.Windows.Forms.Button
$btnUninstall.Text = "Deinstallieren"
$btnUninstall.Location = New-Object System.Drawing.Point(746, 584)
$btnUninstall.Size = New-Object System.Drawing.Size(120, 30)
$btnUninstall.Anchor = 'Right,Bottom'

$btnCancel = New-Object System.Windows.Forms.Button
$btnCancel.Text = "Abbrechen"
$btnCancel.Location = New-Object System.Drawing.Point(872, 584)
$btnCancel.Size = New-Object System.Drawing.Size(84, 30)
$btnCancel.Enabled = $false
$btnCancel.Anchor = 'Right,Bottom'

$form.Controls.AddRange(@(
    $lblSearch, $txtSearch, $btnRefresh, $btnSelectAll, $btnSelectNone, $chkSystem,
    $listView, $chkGuess, $chkSkipUnknown, $lblCurrent, $progress, $txtLog,
    $lblCount, $btnUninstall, $btnCancel
))

# =====================================================================
#  Anzeige-Logik
# =====================================================================

function Write-Log {
    param([string]$message)
    $txtLog.AppendText(("[{0}] {1}{2}" -f (Get-Date -Format 'HH:mm:ss'), $message, [Environment]::NewLine))
}

function Get-AppKey {
    param($app)
    return ($app.Scope + '|' + $app.KeyName + '|' + $app.Name)
}

function Update-CountLabel {
    $lblCount.Text = "{0} Programm(e) angezeigt, {1} ausgewählt." -f $listView.Items.Count, $script:checkedKeys.Count
}

function Show-Apps {
    # Während einer laufenden Deinstallation nicht neu aufbauen - der Lauf hält
    # Referenzen auf die vorhandenen Zeilen und schreibt dort den Status hinein.
    if ($script:isRunning) { return }

    $script:suppressCheck = $true
    $listView.BeginUpdate()
    $listView.Items.Clear()

    $needle = $txtSearch.Text.Trim()
    $items = $script:allApps
    if ($needle -ne "") {
        $items = $items | Where-Object {
            $_.Name -like "*$needle*" -or $_.Publisher -like "*$needle*"
        }
    }

    $prop = switch ($script:sortColumn) {
        0 { 'Name' } 1 { 'Version' } 2 { 'Publisher' } 3 { 'SizeMB' }
        4 { 'Scope' } 5 { 'Kind' } 6 { 'Status' } default { 'Name' }
    }
    $items = $items | Sort-Object -Property $prop -Descending:(-not $script:sortAscending)

    foreach ($app in $items) {
        $item = New-Object System.Windows.Forms.ListViewItem($app.Name)
        [void]$item.SubItems.Add($app.Version)
        [void]$item.SubItems.Add($app.Publisher)
        [void]$item.SubItems.Add($(if ($null -ne $app.SizeMB) { [string]$app.SizeMB } else { "" }))
        [void]$item.SubItems.Add($app.Scope)
        [void]$item.SubItems.Add($app.Kind)
        [void]$item.SubItems.Add($app.Status)
        $item.Tag = $app
        $item.Checked = $script:checkedKeys.Contains((Get-AppKey $app))
        [void]$listView.Items.Add($item)
    }

    $listView.EndUpdate()
    $script:suppressCheck = $false
    Update-CountLabel
}

# Ermittelt den Deinstallations-Modus jedes Eintrags für die Spalte "Modus".
function Update-AppKinds {
    foreach ($app in $script:allApps) {
        $plan = Get-UninstallPlan -app $app -guessSilent:$chkGuess.Checked
        $kind = if ($plan) { $plan.Kind } else { "kein Befehl" }
        if ($plan -and -not $plan.Silent) { $kind = $kind + " (nicht still)" }
        $app | Add-Member -NotePropertyName Kind -NotePropertyValue $kind -Force

        # Die Vorschau erzeugt bei Office-MSI eine Konfigurationsdatei, die hier
        # nicht gebraucht wird - sie wird erst beim echten Lauf neu geschrieben.
        if ($plan -and $plan.TempFile -and (Test-Path -LiteralPath $plan.TempFile)) {
            Remove-Item -LiteralPath $plan.TempFile -Force -ErrorAction SilentlyContinue
        }
    }
}

function Refresh-Apps {
    if ($script:isRunning) { return }

    $form.Cursor = [System.Windows.Forms.Cursors]::WaitCursor
    $lblCurrent.Text = "Lese installierte Programme..."
    $form.Refresh()

    $script:allApps = @(Get-InstalledApp -withSystemComponents:$chkSystem.Checked)
    Update-AppKinds
    Show-Apps

    $lblCurrent.Text = ""
    $form.Cursor = [System.Windows.Forms.Cursors]::Default
}

# =====================================================================
#  Deinstallation
# =====================================================================

# Sperrt während eines Laufs alles, was die Liste verändern würde.
function Set-ControlsEnabled {
    param([bool]$enabled)

    foreach ($ctl in @($btnUninstall, $btnRefresh, $btnSelectAll, $btnSelectNone,
                       $txtSearch, $chkSystem, $chkGuess, $chkSkipUnknown)) {
        $ctl.Enabled = $enabled
    }
    # ListView.CheckBoxes bleibt unangetastet: Umschalten würde die Haken löschen.
    # Die bereits eingesammelte Liste des Laufs ist davon ohnehin unabhängig.
    $btnCancel.Enabled = -not $enabled
}

function Invoke-Uninstall {
    param($app, $plan, $listItem)

    $display = "{0} ({1})" -f $app.Name, $plan.Kind
    $lblCurrent.Text = "Deinstalliere: $display"
    $listItem.SubItems[6].Text = "läuft..."
    if ($listItem.Index -ge 0) { $listView.EnsureVisible($listItem.Index) }
    [System.Windows.Forms.Application]::DoEvents()

    Write-Log ("Start: {0}" -f $app.Name)
    Write-Log ("  Befehl: `"{0}`" {1}" -f $plan.File, $plan.Arguments)

    if (-not (Test-Path -LiteralPath $plan.File -ErrorAction SilentlyContinue)) {
        # msiexec o.ä. liegen im PATH - nur warnen, nicht abbrechen
        Write-Log ("  Hinweis: Datei nicht direkt gefunden, Start wird trotzdem versucht.")
    }

    try {
        $startArgs = @{ FilePath = $plan.File; PassThru = $true; ErrorAction = 'Stop' }
        if ($plan.Arguments -and $plan.Arguments.Trim() -ne "") {
            $startArgs['ArgumentList'] = $plan.Arguments
        }
        $proc = Start-Process @startArgs
    }
    catch {
        $listItem.SubItems[6].Text = "Fehler beim Start"
        Write-Log ("  FEHLER: {0}" -f $_.Exception.Message)
        return $false
    }

    # Warten, ohne die Oberfläche einzufrieren
    while (-not $proc.HasExited) {
        [System.Windows.Forms.Application]::DoEvents()
        Start-Sleep -Milliseconds 200
    }
    $proc.WaitForExit()
    $code = try { [int]$proc.ExitCode } catch { -1 }

    if ($plan.TempFile -and (Test-Path -LiteralPath $plan.TempFile)) {
        Remove-Item -LiteralPath $plan.TempFile -Force -ErrorAction SilentlyContinue
    }

    $text = Get-ExitCodeText -code $code
    $ok   = Test-ExitCodeSuccess -code $code
    $listItem.SubItems[6].Text = $text
    $listItem.ForeColor = if ($ok) { [System.Drawing.Color]::DarkGreen } else { [System.Drawing.Color]::Firebrick }
    Write-Log ("  Ergebnis: {0}" -f $text)
    return $ok
}

$uninstallAction = {
    if ($script:isRunning) { return }

    # Die Auswahl bleibt über den Suchfilter hinweg erhalten. Damit auch aktuell
    # ausgeblendete Einträge deinstalliert werden und einen Status bekommen,
    # wird der Filter vor dem Lauf zurückgesetzt.
    if ($script:checkedKeys.Count -gt 0 -and $txtSearch.Text.Trim() -ne "") {
        $txtSearch.Text = ""
    }

    $selected = @()
    foreach ($item in $listView.Items) {
        if ($item.Checked) { $selected += $item }
    }

    if ($selected.Count -eq 0) {
        [System.Windows.Forms.MessageBox]::Show($form, "Bitte mindestens ein Programm auswählen.", "Keine Auswahl",
            [System.Windows.Forms.MessageBoxButtons]::OK, [System.Windows.Forms.MessageBoxIcon]::Information) | Out-Null
        return
    }

    $names = ($selected | Select-Object -First 15 | ForEach-Object { " - " + $_.Tag.Name }) -join [Environment]::NewLine
    if ($selected.Count -gt 15) { $names += [Environment]::NewLine + ("   ... und {0} weitere" -f ($selected.Count - 15)) }

    $answer = [System.Windows.Forms.MessageBox]::Show($form,
        ("{0} Programm(e) werden nacheinander deinstalliert:{1}{1}{2}" -f $selected.Count, [Environment]::NewLine, $names),
        "Deinstallation bestätigen",
        [System.Windows.Forms.MessageBoxButtons]::OKCancel, [System.Windows.Forms.MessageBoxIcon]::Warning)
    if ($answer -ne [System.Windows.Forms.DialogResult]::OK) { return }

    $script:isRunning       = $true
    $script:cancelRequested = $false
    Set-ControlsEnabled -enabled $false

    $progress.Minimum = 0
    $progress.Maximum = $selected.Count
    $progress.Value   = 0

    $done = 0; $failed = 0; $skipped = 0

    try {
        foreach ($item in $selected) {
            if ($script:cancelRequested) {
                $item.SubItems[6].Text = "abgebrochen"
                $skipped++
                $progress.Value = [Math]::Min($progress.Maximum, $progress.Value + 1)
                continue
            }

            $app  = $item.Tag
            $plan = Get-UninstallPlan -app $app -guessSilent:$chkGuess.Checked

            if (-not $plan) {
                $item.SubItems[6].Text = "kein Deinstallationsbefehl"
                Write-Log ("Übersprungen (kein Befehl): {0}" -f $app.Name)
                $skipped++
            }
            elseif ($chkSkipUnknown.Checked -and -not $plan.Silent) {
                $item.SubItems[6].Text = "übersprungen (nicht still)"
                Write-Log ("Übersprungen (kein Silent-Modus): {0}" -f $app.Name)
                $skipped++
            }
            else {
                if (Invoke-Uninstall -app $app -plan $plan -listItem $item) { $done++ } else { $failed++ }
            }

            $progress.Value = [Math]::Min($progress.Maximum, $progress.Value + 1)
            $lblCount.Text = "Fortschritt: {0}/{1} - erfolgreich: {2}, fehlgeschlagen: {3}, übersprungen: {4}" -f `
                $progress.Value, $progress.Maximum, $done, $failed, $skipped
            [System.Windows.Forms.Application]::DoEvents()
        }

        $lblCurrent.Text = "Fertig. Erfolgreich: $done, fehlgeschlagen: $failed, übersprungen: $skipped"
        Write-Log $lblCurrent.Text
    }
    finally {
        # Auch bei einem unerwarteten Fehler muss die Oberfläche wieder bedienbar
        # sein - sonst blockiert FormClosing dauerhaft das Schließen des Fensters.
        $script:isRunning = $false
        Set-ControlsEnabled -enabled $true
    }

    [System.Windows.Forms.MessageBox]::Show($form, $lblCurrent.Text, "Deinstallation abgeschlossen",
        [System.Windows.Forms.MessageBoxButtons]::OK, [System.Windows.Forms.MessageBoxIcon]::Information) | Out-Null

    $script:checkedKeys.Clear()
    Refresh-Apps
}

# =====================================================================
#  Ereignisse
# =====================================================================

$listView.Add_ItemChecked({
    param($sender, $e)
    if ($script:suppressCheck) { return }
    $key = Get-AppKey $e.Item.Tag
    if ($e.Item.Checked) { [void]$script:checkedKeys.Add($key) } else { [void]$script:checkedKeys.Remove($key) }
    Update-CountLabel
})

$listView.Add_ColumnClick({
    param($sender, $e)
    if ($script:sortColumn -eq $e.Column) { $script:sortAscending = -not $script:sortAscending }
    else { $script:sortColumn = $e.Column; $script:sortAscending = $true }
    Show-Apps
})

$txtSearch.Add_TextChanged({ Show-Apps })
$btnRefresh.Add_Click({ Refresh-Apps })
$chkSystem.Add_CheckedChanged({ Refresh-Apps })
$chkGuess.Add_CheckedChanged({
    if ($script:isRunning -or $script:allApps.Count -eq 0) { return }
    Update-AppKinds
    Show-Apps
})

$btnSelectAll.Add_Click({
    $script:suppressCheck = $true
    foreach ($item in $listView.Items) {
        $item.Checked = $true
        [void]$script:checkedKeys.Add((Get-AppKey $item.Tag))
    }
    $script:suppressCheck = $false
    Update-CountLabel
})

$btnSelectNone.Add_Click({
    $script:suppressCheck = $true
    foreach ($item in $listView.Items) {
        $item.Checked = $false
        [void]$script:checkedKeys.Remove((Get-AppKey $item.Tag))
    }
    $script:suppressCheck = $false
    Update-CountLabel
})

$btnUninstall.Add_Click($uninstallAction)
$btnCancel.Add_Click({
    $script:cancelRequested = $true
    $lblCurrent.Text = "Abbruch angefordert - laufende Deinstallation wird noch beendet..."
    Write-Log "Abbruch angefordert."
})

$form.Add_FormClosing({
    param($sender, $e)
    if ($script:isRunning) {
        $e.Cancel = $true
        [System.Windows.Forms.MessageBox]::Show($form, "Es läuft noch eine Deinstallation.", "Bitte warten",
            [System.Windows.Forms.MessageBoxButtons]::OK, [System.Windows.Forms.MessageBoxIcon]::Warning) | Out-Null
    }
})

$form.Add_Shown({
    $form.Activate()

    if (-not $noElevationCheck -and -not (Test-IsAdmin)) {
        $answer = [System.Windows.Forms.MessageBox]::Show($form,
            ("Das Skript läuft ohne Administratorrechte. Maschinenweit installierte " +
             "Programme lassen sich damit meist nicht entfernen." + [Environment]::NewLine + [Environment]::NewLine +
             "Jetzt als Administrator neu starten?"),
            "Administratorrechte", [System.Windows.Forms.MessageBoxButtons]::YesNo,
            [System.Windows.Forms.MessageBoxIcon]::Question)

        if ($answer -eq [System.Windows.Forms.DialogResult]::Yes -and $PSCommandPath) {
            try {
                # Aufrufparameter mitnehmen, damit der Neustart identisch startet
                $relaunch = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-STA', '-File', ('"{0}"' -f $PSCommandPath))
                if ($filter) { $relaunch += @('-filter', ('"{0}"' -f $filter)) }
                if ($chkSystem.Checked) { $relaunch += '-includeSystemComponents' }

                Start-Process -FilePath 'powershell.exe' -Verb RunAs -ArgumentList $relaunch -ErrorAction Stop
                $form.Close()
                return
            }
            catch {
                [System.Windows.Forms.MessageBox]::Show($form,
                    ("Neustart als Administrator fehlgeschlagen: " + $_.Exception.Message),
                    "Fehler", [System.Windows.Forms.MessageBoxButtons]::OK,
                    [System.Windows.Forms.MessageBoxIcon]::Error) | Out-Null
            }
        }

        Write-Log "Hinweis: ohne Administratorrechte gestartet - maschinenweite Programme können meist nicht entfernt werden."
    }

    Refresh-Apps
})

[void]$form.ShowDialog()
$form.Dispose()
