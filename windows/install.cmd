@echo off
rem Double-click to set up dictation (or to update it). Options: install.cmd -BigModel
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0install.ps1" %*
pause
