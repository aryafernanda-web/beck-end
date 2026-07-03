@echo off
echo =========================================
echo Starting Biznet Intranet Sync Server...
echo =========================================
echo.
powershell -ExecutionPolicy Bypass -File "%~dp0sync_intranet.ps1"
if %ERRORLEVEL% NEQ 0 (
    echo.
    echo Server stopped or encountered an error.
    pause
)
