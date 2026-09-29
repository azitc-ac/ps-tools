@echo off
rem Doppelklick-Start fuer Invoke-GrabbedTyping.ps1 (Muster pw, Delay 15 ms)
powershell.exe -NoProfile -STA -ExecutionPolicy Bypass -File "%~dp0Invoke-GrabbedTyping.ps1" %*
pause
