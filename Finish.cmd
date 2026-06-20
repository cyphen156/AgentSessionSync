@echo off
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0Finish.ps1"
if errorlevel 1 pause
