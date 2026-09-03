@echo off
setlocal EnableExtensions EnableDelayedExpansion

:: ============================================================
:: C:\PS PsTools Installer
:: Neonwulf animated ANSI UI + WindowsApps permissions
:: ============================================================
set "BASE=C:\PS"
set "TARGET=%BASE%\Microsoft.Sysinternals.PsTools"
set "BIN_TARGET=%BASE%\binaries"
set "ZIP=%~dp0PsTools.zip"
set "SOURCE_BIN=%~dp0binaries"
set "UPDATER=%SOURCE_BIN%\Update_Paths.bat"
set "UI_SCRIPT=%SOURCE_BIN%\Neonwulf_UI.ps1"
set "INSTALLED_UPDATER=%BIN_TARGET%\Update_Paths.bat"
set "INSTALLED_UI=%BIN_TARGET%\Neonwulf_UI.ps1"
set "WINDOWSAPPS=%ProgramFiles%\WindowsApps"
set "CURRENT_USER=%USERDOMAIN%\%USERNAME%"
set "LOG=%TEMP%\PSToolsInstaller-%RANDOM%-%RANDOM%.log"
set "STATUS_FILE=%TEMP%\PSToolsInstaller-status-%RANDOM%-%RANDOM%.txt"
set "STATUS_TMP=%STATUS_FILE%.tmp"
set "STOP_FILE=%TEMP%\PSToolsInstaller-stop-%RANDOM%-%RANDOM%.signal"
set "PSTW_INSTALLER=%~f0"
set "PSTW_ZIP=%ZIP%"
set "PSTW_TARGET=%TARGET%"

title C:\PS PsTools Installer

if not exist "%UI_SCRIPT%" (
    echo [FEHLER] binaries\Neonwulf_UI.ps1 wurde nicht gefunden:
    echo "%UI_SCRIPT%"
    pause
    exit /b 1
)
if not exist "%UPDATER%" (
    echo [FEHLER] binaries\Update_Paths.bat wurde nicht gefunden:
    echo "%UPDATER%"
    pause
    exit /b 1
)

call :UpdateContent "Initialisiere Installer ..." "Pruefe Administratorrechte"
call :StartUI

:: --------------------------------------------------
:: Administratorrechte pruefen
:: --------------------------------------------------
net session >nul 2>&1
if not "%errorlevel%"=="0" (
    call :UpdateContent "Administratorrechte erforderlich ..." "UAC-Anfrage wird geoeffnet"
    timeout /t 1 /nobreak >nul
    call :StopUI
    powershell.exe -NoProfile -ExecutionPolicy Bypass -Command ^
        "Start-Process -FilePath $env:PSTW_INSTALLER -Verb RunAs"
    exit /b
)

:: --------------------------------------------------
:: 1. Verzeichnisse erstellen
:: --------------------------------------------------
call :UpdateContent "Erstelle Verzeichnisse ..." "%BASE%"
if not exist "%BASE%\" mkdir "%BASE%" >"%LOG%" 2>&1
if not exist "%BASE%\" (
    call :Abort "Verzeichnisse konnten nicht erstellt werden" "%BASE%"
    exit /b 1
)

call :UpdateContent "Erstelle Verzeichnisse ..." "%TARGET%"
if not exist "%TARGET%\" mkdir "%TARGET%" >"%LOG%" 2>&1
if not exist "%TARGET%\" (
    call :Abort "PsTools-Namespace konnte nicht erstellt werden" "%TARGET%"
    exit /b 1
)

call :UpdateContent "Erstelle Verzeichnisse ..." "%BIN_TARGET%"
if not exist "%BIN_TARGET%\" mkdir "%BIN_TARGET%" >"%LOG%" 2>&1
if not exist "%BIN_TARGET%\" (
    call :Abort "binaries-Verzeichnis konnte nicht erstellt werden" "%BIN_TARGET%"
    exit /b 1
)
call :UpdateContent "Erstelle Verzeichnisse ..." "[OK] C:\PS, PsTools und binaries sind bereit"

:: --------------------------------------------------
:: 2. Quelldaten pruefen
:: --------------------------------------------------
call :UpdateContent "Pruefe Quelldaten ..." "%ZIP%"
if not exist "%ZIP%" (
    call :Abort "PsTools.zip wurde nicht gefunden" "%ZIP%"
    exit /b 1
)
if not exist "%SOURCE_BIN%\" (
    call :Abort "binaries-Quellordner wurde nicht gefunden" "%SOURCE_BIN%"
    exit /b 1
)
call :UpdateContent "Pruefe Quelldaten ..." "[OK] PsTools.zip und binaries gefunden"

:: --------------------------------------------------
:: 3. PsTools entpacken
:: --------------------------------------------------
call :UpdateContent "Kopiere Daten ..." "PsTools.zip  ->  %TARGET%"
powershell.exe -NoProfile -ExecutionPolicy Bypass -Command ^
    "Expand-Archive -LiteralPath $env:PSTW_ZIP -DestinationPath $env:PSTW_TARGET -Force" >"%LOG%" 2>&1
if not "%errorlevel%"=="0" (
    call :AbortFromLog "PsTools konnte nicht entpackt werden" "%LOG%"
    exit /b 1
)
call :UpdateContent "Kopiere Daten ..." "[OK] PsTools wurde installiert"

:: --------------------------------------------------
:: 4. binaries inklusive PATH-Updater + UI installieren
:: --------------------------------------------------
call :UpdateContent "Installiere binaries ..." "%SOURCE_BIN%  ->  %BIN_TARGET%"
for %%I in ("%SOURCE_BIN%") do set "SOURCE_BIN_FULL=%%~fI"
for %%I in ("%BIN_TARGET%") do set "BIN_TARGET_FULL=%%~fI"
if /I "!SOURCE_BIN_FULL!"=="!BIN_TARGET_FULL!" (
    >"%LOG%" echo [OK] binaries befinden sich bereits im Zielordner
) else (
    robocopy "%SOURCE_BIN%" "%BIN_TARGET%" /E /COPY:DAT /DCOPY:DAT /R:2 /W:1 /NFL /NDL /NJH /NJS /NP >"%LOG%" 2>&1
    set "ROBOCOPY_EXIT=!errorlevel!"
    if !ROBOCOPY_EXIT! GEQ 8 (
        call :AbortFromLog "binaries konnten nicht kopiert werden" "%LOG%"
        exit /b 1
    )
)
if not exist "%INSTALLED_UPDATER%" (
    call :Abort "Installierter PATH-Updater wurde nicht gefunden" "%INSTALLED_UPDATER%"
    exit /b 1
)
if not exist "%INSTALLED_UI%" (
    call :Abort "Installierte Neonwulf-UI wurde nicht gefunden" "%INSTALLED_UI%"
    exit /b 1
)
call :UpdateContent "Installiere binaries ..." "[OK] Tools, PATH-Updater und Neonwulf-UI sind bereit"

:: --------------------------------------------------
:: 5. PsExec64 pruefen
:: --------------------------------------------------
call :UpdateContent "Pruefe PsExec64 ..." "%TARGET%\PsExec64.exe"
if not exist "%TARGET%\PsExec64.exe" (
    call :Abort "PsExec64.exe wurde nicht gefunden" "%TARGET%\PsExec64.exe"
    exit /b 1
)
call :UpdateContent "Pruefe PsExec64 ..." "[OK] SYSTEM-Werkzeug ist bereit"

:: --------------------------------------------------
:: 6. WindowsApps-Rechte setzen
:: - KEIN takeown
:: - TrustedInstaller bleibt Besitzer
:: - Administratoren + ausfuehrender Benutzer: (OI)(CI)F
:: - KEIN /T
:: --------------------------------------------------
call :UpdateContent "Setze Rechte fuer %USERNAME% ..." "TrustedInstaller bleibt Besitzer"
if not exist "%WINDOWSAPPS%\" (
    call :UpdateContent "Setze Rechte fuer %USERNAME% ..." "[WARNUNG] WindowsApps wurde nicht gefunden"
) else (
    "%TARGET%\PsExec64.exe" -accepteula -nobanner -s ^
        "%SystemRoot%\System32\icacls.exe" "%WINDOWSAPPS%" ^
        /grant "*S-1-5-32-544:(OI)(CI)F" "%CURRENT_USER%:(OI)(CI)F" >"%LOG%" 2>&1

    if not "!errorlevel!"=="0" (
        call :AbortFromLog "WindowsApps-Berechtigungen konnten nicht gesetzt werden" "%LOG%"
        exit /b 1
    )
    call :UpdateContent "Setze Rechte fuer %USERNAME% ..." "[OK] Administratoren + %CURRENT_USER% = Vollzugriff"
)

:: --------------------------------------------------
:: 7. SYSTEM-PATH aktualisieren
:: --------------------------------------------------
call :UpdateContent "Aktualisiere SYSTEM-PATH ..." "Durchsuche %BASE% rekursiv"
call "%INSTALLED_UPDATER%" --embedded >"%LOG%" 2>&1
if not "%errorlevel%"=="0" (
    call :AbortFromLog "SYSTEM-PATH konnte nicht aktualisiert werden" "%LOG%"
    exit /b 1
)
set "PATH_RESULT="
for /F "usebackq delims=" %%L in ("%LOG%") do if not defined PATH_RESULT set "PATH_RESULT=%%L"
if not defined PATH_RESULT set "PATH_RESULT=[OK] SYSTEM-PATH wurde aktualisiert"
call :UpdateContent "Aktualisiere SYSTEM-PATH ..." "%PATH_RESULT%"

:: --------------------------------------------------
:: Abschluss
:: --------------------------------------------------
del /Q "%LOG%" >nul 2>&1
call :UpdateContent "Installation abgeschlossen" "[OK] PsTools + binaries + WindowsApps-Rechte + PATH sind eingerichtet"
call :WaitExit
exit /b 0

:: ============================================================
:: UI helpers
:: ============================================================
:StartUI
if exist "%STOP_FILE%" del /Q "%STOP_FILE%" >nul 2>&1
start "" /b powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%UI_SCRIPT%" -Mode Installer -StatusFile "%STATUS_FILE%" -StopFile "%STOP_FILE%"
exit /b 0

:StopUI
>"%STOP_FILE%" echo stop
>nul 2>&1 timeout /t 1 /nobreak
exit /b 0

:UpdateContent
set "UI_ACTION=%~1"
set "UI_DETAIL=%~2"
>"%STATUS_TMP%" (
    echo(!UI_ACTION!
    echo(!UI_DETAIL!
)
move /Y "%STATUS_TMP%" "%STATUS_FILE%" >nul 2>&1
exit /b 0

:Abort
call :UpdateContent "%~1" "[FEHLER] %~2"
del /Q "%LOG%" >nul 2>&1
call :WaitExit
exit /b 1

:AbortFromLog
set "ERRLINE="
for /F "usebackq delims=" %%L in ("%~2") do if not defined ERRLINE set "ERRLINE=%%L"
if not defined ERRLINE set "ERRLINE=Unbekannter Fehler"
call :UpdateContent "%~1" "[FEHLER] !ERRLINE!"
del /Q "%LOG%" >nul 2>&1
call :WaitExit
exit /b 1

:WaitExit
call :UpdateContent "Vorgang beendet" "[OK] ENTER zum Schliessen"
pause >nul
call :StopUI
del /Q "%STATUS_FILE%" "%STATUS_TMP%" "%STOP_FILE%" >nul 2>&1
exit /b 0
