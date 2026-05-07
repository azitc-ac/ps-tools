param(
    [string]$folderName = "",
    [switch]$doSubst = $false,
    [switch]$register = $false
)

# --- Register context menu entry and exit ---
if ($register) {
    $scriptPath = $MyInvocation.MyCommand.Path
    $baseKey = 'HKCU:\Software\Classes\Directory\shell\UnblockFiles'
    $cmdKey  = Join-Path $baseKey 'command'

    New-Item -Path $baseKey -Force | Out-Null
    Set-ItemProperty -Path $baseKey -Name 'MUIVerb' -Value 'Unblock files'
    Set-ItemProperty -Path $baseKey -Name 'Icon' -Value 'powershell.exe'

    New-Item -Path $cmdKey -Force | Out-Null
    $command = 'powershell.exe -NoProfile -ExecutionPolicy Bypass -STA -File "' + $scriptPath + '" -folderName "%V"'
    Set-Item -Path $cmdKey -Value $command

    Write-Host "Kontextmenü-Eintrag 'Unblock files' erfolgreich registriert."
    return
}

Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing

# Determine initial path
$initialPath = if ($folderName -ne "") { $folderName } else { $PSScriptRoot }

# --- Build dialog ---
$dialog = New-Object System.Windows.Forms.Form
$dialog.Text = "Dateien entsperren"
$dialog.Size = New-Object System.Drawing.Size(520, 140)
$dialog.StartPosition = "CenterScreen"
$dialog.TopMost = $true
$dialog.FormBorderStyle = "FixedDialog"
$dialog.MaximizeBox = $false
$dialog.MinimizeBox = $false

$txtPath = New-Object System.Windows.Forms.TextBox
$txtPath.Location = New-Object System.Drawing.Point(10, 12)
$txtPath.Size = New-Object System.Drawing.Size(370, 23)
$txtPath.Text = $initialPath

$btnBrowse = New-Object System.Windows.Forms.Button
$btnBrowse.Text = "Durchsuchen..."
$btnBrowse.Location = New-Object System.Drawing.Point(388, 10)
$btnBrowse.Size = New-Object System.Drawing.Size(110, 26)

$btnUnblock = New-Object System.Windows.Forms.Button
$btnUnblock.Text = "Unblock"
$btnUnblock.Location = New-Object System.Drawing.Point(388, 48)
$btnUnblock.Size = New-Object System.Drawing.Size(110, 26)

$lblStatus = New-Object System.Windows.Forms.Label
$lblStatus.Location = New-Object System.Drawing.Point(10, 50)
$lblStatus.Size = New-Object System.Drawing.Size(370, 40)
$lblStatus.Text = ""

$dialog.Controls.AddRange(@($txtPath, $btnBrowse, $btnUnblock, $lblStatus))

# --- Browse button handler ---
$btnBrowse.Add_Click({
    $fb = New-Object System.Windows.Forms.FolderBrowserDialog
    $fb.Description = "Ordner auswählen"
    $fb.ShowNewFolderButton = $true
    $fb.SelectedPath = if ($txtPath.Text -ne "" -and (Test-Path $txtPath.Text)) { $txtPath.Text } else { "C:\" }
    if ($fb.ShowDialog($dialog) -eq [System.Windows.Forms.DialogResult]::OK) {
        $txtPath.Text = $fb.SelectedPath
    }
})

# --- Unblock logic as scriptblock ---
$unblockAction = {
    $dir = $txtPath.Text.Trim()
    if (-not (Test-Path $dir)) {
        $lblStatus.Text = "Pfad nicht gefunden: $dir"
        return
    }

    $lblStatus.Text = "Scan läuft..."
    $dialog.Refresh()

    if ($doSubst) {
        try {
            subst u: "$dir"
            Start-Sleep -Milliseconds 500
        } catch {}
    }

    $allFiles = Get-ChildItem -Path $dir -Recurse -File

    $blockedFiles = @()
    foreach ($file in $allFiles) {
        try {
            if (Get-Item -Path $file.FullName -Stream Zone.Identifier -ErrorAction SilentlyContinue) {
                $blockedFiles += $file
            }
        } catch {}
    }

    $unblocked = 0
    foreach ($file in $blockedFiles) {
        try {
            if ($file.IsReadOnly) { $file.IsReadOnly = $false }
            Remove-Item -Path "$($file.FullName):Zone.Identifier" -Force -ErrorAction Stop
            $unblocked++
        } catch {}
    }

    if ($doSubst) {
        try { subst u: /d | Out-Null } catch {}
    }

    $lblStatus.Text = "$unblocked von $($blockedFiles.Count) Datei(en) entsperrt."
}

$btnUnblock.Add_Click($unblockAction)

$dialog.ShowDialog() | Out-Null
$dialog.Dispose()
