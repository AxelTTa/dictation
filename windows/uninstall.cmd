@echo off
rem Double-click to remove the dictation helper (Handy itself stays; remove it in Settings > Apps if you want).
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0uninstall.ps1" %*
pause
