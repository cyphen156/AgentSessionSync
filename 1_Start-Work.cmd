@echo off
setlocal
cd /d "%~dp0"

powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0Start-Work.ps1"
if errorlevel 1 (
    echo.
    echo [START] failed
    pause
    exit /b 1
)

echo.
echo [START] complete
pause
