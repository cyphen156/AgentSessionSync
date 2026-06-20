@echo off
setlocal
cd /d "%~dp0"

powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0Finish-Work.ps1"
if errorlevel 1 (
    echo.
    echo [FINISH] failed
    pause
    exit /b 1
)

echo.
echo [FINISH] complete
pause
