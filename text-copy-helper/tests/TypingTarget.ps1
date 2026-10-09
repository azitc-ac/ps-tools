# Zielfenster für TextCopyHelper.Typing.Tests.ps1: nimmt Tastatureingaben entgegen
# und schreibt beim Schließen den empfangenen Text (UTF-8) nach $OutFile.
param([Parameter(Mandatory)][string]$OutFile, [Parameter(Mandatory)][string]$HwndFile)

Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing

$form               = New-Object System.Windows.Forms.Form
$form.Text          = "TextCopyHelper typing target"
$form.Size          = New-Object System.Drawing.Size(700, 300)
$form.StartPosition = 'CenterScreen'
$form.TopMost       = $true

$tb               = New-Object System.Windows.Forms.TextBox
$tb.Multiline     = $true
$tb.AcceptsReturn = $true
$tb.AcceptsTab    = $true
$tb.WordWrap      = $false
$tb.Dock          = 'Fill'
$tb.Font          = New-Object System.Drawing.Font("Consolas", 11)
$form.Controls.Add($tb)

$form.Add_Shown({
    $form.Activate()
    $tb.Focus() | Out-Null
    [IO.File]::WriteAllText($HwndFile, $form.Handle.ToInt64().ToString())
})
$form.Add_FormClosing({
    [IO.File]::WriteAllText($OutFile, $tb.Text, (New-Object Text.UTF8Encoding $false))
})

[System.Windows.Forms.Application]::Run($form)
