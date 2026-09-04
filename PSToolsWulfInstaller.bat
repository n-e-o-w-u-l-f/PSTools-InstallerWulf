@echo off
setlocal EnableExtensions

set "INSTALLER=%~dp0WULF\Installer.ps1"

if not exist "%INSTALLER%" (
    echo [FEHLER] Installer wurde nicht gefunden:
    echo "%INSTALLER%"
    pause
    exit /b 1
)

powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%INSTALLER%" %*
exit /b %errorlevel%
