@echo off
setlocal EnableExtensions
set "SCRIPT=%~dp0Update_Paths.ps1"

if not exist "%SCRIPT%" (
    echo [FEHLER] Update_Paths.ps1 wurde nicht gefunden: "%SCRIPT%"
    exit /b 1
)

if /I "%~1"=="--embedded" (
    powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%SCRIPT%" -Embedded
) else (
    powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%SCRIPT%"
)

exit /b %errorlevel%
