@echo off
setlocal EnableExtensions EnableDelayedExpansion

set "EMBEDDED=0"
if /I "%~1"=="--embedded" set "EMBEDDED=1"

set "ROOT=C:\PS"
set "RESULTFILE=%TEMP%\UpdatePaths-%RANDOM%-%RANDOM%.txt"
set "UI_SCRIPT=%~dp0Neonwulf_UI.ps1"
set "STATUS_FILE=%TEMP%\UpdatePaths-status-%RANDOM%-%RANDOM%.txt"
set "STATUS_TMP=%STATUS_FILE%.tmp"
set "STOP_FILE=%TEMP%\UpdatePaths-stop-%RANDOM%-%RANDOM%.signal"

title C:\PS System PATH Updater

if "%EMBEDDED%"=="0" (
    if not exist "%UI_SCRIPT%" (
        echo [FEHLER] Neonwulf_UI.ps1 wurde nicht gefunden: "%UI_SCRIPT%"
        pause
        exit /b 1
    )
    call :UpdateContent "Initialisiere PATH-Updater ..." "Pruefe Administratorrechte"
    call :StartUI
)

net session >nul 2>&1
if not "%errorlevel%"=="0" (
    if "%EMBEDDED%"=="1" (
        echo [FEHLER] Administratorrechte erforderlich
        exit /b 1
    )
    call :UpdateContent "Administratorrechte erforderlich ..." "UAC-Anfrage wird geoeffnet"
    timeout /t 1 /nobreak >nul
    call :StopUI
    powershell.exe -NoProfile -ExecutionPolicy Bypass -Command ^
        "Start-Process -FilePath '%~f0' -Verb RunAs"
    exit /b
)

if not exist "%ROOT%\" (
    if "%EMBEDDED%"=="1" (
        echo [FEHLER] %ROOT% existiert nicht
        exit /b 1
    )
    call :UpdateContent "SYSTEM-PATH konnte nicht aktualisiert werden" "[FEHLER] %ROOT% existiert nicht"
    call :WaitExit
    exit /b 1
)

if "%EMBEDDED%"=="0" call :UpdateContent "Durchsuche Verzeichnisse ..." "%ROOT%"

powershell.exe -NoProfile -ExecutionPolicy Bypass -Command ^
    "$root='C:\PS';" ^
    "$current=[Environment]::GetEnvironmentVariable('Path','Machine');" ^
    "$entries=[System.Collections.Generic.List[string]]::new();" ^
    "foreach($e in ($current -split ';')){if($e.Trim()){[void]$entries.Add($e.Trim())}};" ^
    "$existing=[System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase);" ^
    "foreach($e in $entries){[void]$existing.Add($e)};" ^
    "$folders=@($root)+@(Get-ChildItem -LiteralPath $root -Directory -Recurse -Force | Select-Object -ExpandProperty FullName);" ^
    "$added=0;" ^
    "foreach($folder in $folders){if(-not $existing.Contains($folder)){[void]$entries.Add($folder);[void]$existing.Add($folder);$added++}};" ^
    "[Environment]::SetEnvironmentVariable('Path',($entries -join ';'),'Machine');" ^
    "Set-Content -LiteralPath '%RESULTFILE%' -Value ('[OK] SYSTEM-PATH aktualisiert - ' + $added + ' neue Verzeichnisse') -Encoding ASCII;" >nul 2>&1

if not "%errorlevel%"=="0" (
    del /Q "%RESULTFILE%" >nul 2>&1
    if "%EMBEDDED%"=="1" (
        echo [FEHLER] SYSTEM-PATH konnte nicht aktualisiert werden
        exit /b 1
    )
    call :UpdateContent "SYSTEM-PATH konnte nicht aktualisiert werden" "[FEHLER] Schreiben der Machine-Variable fehlgeschlagen"
    call :WaitExit
    exit /b 1
)

set "RESULT=[OK] SYSTEM-PATH wurde aktualisiert"
if exist "%RESULTFILE%" set /p "RESULT="<"%RESULTFILE%"
del /Q "%RESULTFILE%" >nul 2>&1

if "%EMBEDDED%"=="1" (
    echo %RESULT%
    exit /b 0
)

call :UpdateContent "Aktualisiere SYSTEM-PATH ..." "%RESULT%"
call :UpdateContent "PATH-Update abgeschlossen" "[OK] Neue Terminals verwenden den aktualisierten PATH"
call :WaitExit
exit /b 0

:StartUI
if exist "%STOP_FILE%" del /Q "%STOP_FILE%" >nul 2>&1
start "" /b powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%UI_SCRIPT%" -Mode PathUpdater -StatusFile "%STATUS_FILE%" -StopFile "%STOP_FILE%"
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

:WaitExit
call :UpdateContent "PATH-Update beendet" "[OK] ENTER zum Schliessen"
pause >nul
call :StopUI
del /Q "%STATUS_FILE%" "%STATUS_TMP%" "%STOP_FILE%" >nul 2>&1
exit /b 0
