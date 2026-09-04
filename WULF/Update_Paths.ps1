param(
    [switch]$Embedded
)

$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'

$Root = 'C:\PS'
$WulfRoot = Join-Path $Root 'WULF'
$InternalToolsRoot = Join-Path $Root 'tools'
$AppsRoot = Join-Path $Root 'apps'
$Binaries = Join-Path $Root 'binaries'
$CommandExtensions = @('.exe', '.cmd', '.bat', '.com')

$RunId = '{0}-{1}' -f $PID, ([Guid]::NewGuid().ToString('N').Substring(0,8))
$UiTempRoot = Join-Path $env:TEMP ('UpdatePathsWulf-' + $RunId)
$StatusFile = Join-Path $UiTempRoot 'status.json'
$StatusTemp = Join-Path $UiTempRoot 'status.tmp'
$StopFile = Join-Path $UiTempRoot 'stop.signal'
$UiScript = Join-Path $PSScriptRoot 'Neonwulf_UI.ps1'
$script:UiProcess = $null

function Test-Administrator {
    $identity = [Security.Principal.WindowsIdentity]::GetCurrent()
    $principal = New-Object Security.Principal.WindowsPrincipal($identity)
    return $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

function Set-UiState {
    param(
        [string]$Action,
        [string]$Detail = '',
        [string]$Hint = ''
    )

    if ($Embedded) { return }

    $state = [ordered]@{
        action = $Action
        detail = $Detail
        menu = @()
        hint = $Hint
    }

    $json = $state | ConvertTo-Json -Compress
    [IO.File]::WriteAllText($StatusTemp, $json, (New-Object Text.UTF8Encoding($false)))
    Move-Item -LiteralPath $StatusTemp -Destination $StatusFile -Force
}

function Start-Ui {
    if ($Embedded) { return }
    if (-not (Test-Path -LiteralPath $UiScript -PathType Leaf)) {
        throw "Neonwulf_UI.ps1 wurde nicht gefunden: $UiScript"
    }

    New-Item -ItemType Directory -Path $UiTempRoot -Force | Out-Null
    Set-UiState 'Initialisiere PATH-Updater ...' 'Pruefe Administratorrechte'

    $arguments = @(
        '-NoProfile',
        '-ExecutionPolicy', 'Bypass',
        '-File', ('"{0}"' -f $UiScript),
        '-Mode', 'PathUpdater',
        '-StatusFile', ('"{0}"' -f $StatusFile),
        '-StopFile', ('"{0}"' -f $StopFile)
    )

    $script:UiProcess = Start-Process -FilePath 'powershell.exe' `
        -ArgumentList $arguments `
        -NoNewWindow `
        -PassThru
}

function Stop-Ui {
    if ($Embedded) { return }

    try {
        if (-not (Test-Path -LiteralPath $StopFile)) {
            [IO.File]::WriteAllText($StopFile, 'stop')
        }
    } catch {}

    if ($script:UiProcess) {
        try {
            if (-not $script:UiProcess.HasExited) {
                [void]$script:UiProcess.WaitForExit(1000)
            }
        } catch {}
        try {
            if (-not $script:UiProcess.HasExited) {
                $script:UiProcess.Kill()
            }
        } catch {}
    }

    Remove-Item -LiteralPath $UiTempRoot -Recurse -Force -ErrorAction SilentlyContinue
}

function Wait-UiExit {
    if ($Embedded) { return }
    while ($true) {
        $key = [Console]::ReadKey($true)
        if ($key.Key -eq [ConsoleKey]::Enter) { break }
    }
}

function Get-NormalizedPath([string]$Path) {
    if ([string]::IsNullOrWhiteSpace($Path)) { return $null }
    try {
        return [IO.Path]::GetFullPath($Path.Trim().TrimEnd('\'))
    } catch {
        return $Path.Trim().TrimEnd('\')
    }
}

function Test-CommandDirectory([string]$Directory) {
    if (-not (Test-Path -LiteralPath $Directory -PathType Container)) { return $false }
    try {
        foreach ($file in Get-ChildItem -LiteralPath $Directory -File -Force -ErrorAction Stop) {
            if ($CommandExtensions -contains $file.Extension.ToLowerInvariant()) {
                return $true
            }
        }
    } catch {}
    return $false
}

function Broadcast-EnvironmentChange {
    try {
        if (-not ('Native.EnvBroadcast' -as [type])) {
            Add-Type @'
using System;
using System.Runtime.InteropServices;
namespace Native {
    public static class EnvBroadcast {
        [DllImport("user32.dll", SetLastError=true, CharSet=CharSet.Auto)]
        public static extern IntPtr SendMessageTimeout(
            IntPtr hWnd, uint Msg, UIntPtr wParam, string lParam,
            uint fuFlags, uint uTimeout, out UIntPtr lpdwResult);
    }
}
'@
        }
        $result = [UIntPtr]::Zero
        [void][Native.EnvBroadcast]::SendMessageTimeout(
            [IntPtr]0xffff, 0x001A, [UIntPtr]::Zero, 'Environment',
            0x0002, 5000, [ref]$result)
    } catch {}
}

try {
    Start-Ui

    if (-not (Test-Administrator)) {
        if ($Embedded) {
            Write-Output '[FEHLER] Administratorrechte erforderlich'
            exit 1
        }

        Set-UiState 'Administratorrechte erforderlich ...' 'UAC-Anfrage wird geoeffnet'
        Start-Sleep -Milliseconds 400
        Stop-Ui

        $arguments = @(
            '-NoProfile',
            '-ExecutionPolicy', 'Bypass',
            '-File', ('"{0}"' -f $PSCommandPath)
        )
        Start-Process -FilePath 'powershell.exe' -Verb RunAs -ArgumentList $arguments | Out-Null
        exit 0
    }

    if (-not (Test-Path -LiteralPath $Root -PathType Container)) {
        if ($Embedded) {
            Write-Output '[FEHLER] C:\PS existiert nicht'
            exit 1
        }
        throw 'C:\PS existiert nicht'
    }

    if (-not (Test-Path -LiteralPath $Binaries -PathType Container)) {
        New-Item -ItemType Directory -Path $Binaries -Force | Out-Null
    }

    Set-UiState 'Durchsuche C:\PS ...' 'Ermittle Verzeichnisse mit ausfuehrbaren Commands'

    $wanted = New-Object 'System.Collections.Generic.HashSet[string]' ([StringComparer]::OrdinalIgnoreCase)
    [void]$wanted.Add((Get-NormalizedPath $Binaries))

    $wulfNormalized = Get-NormalizedPath $WulfRoot
    $toolsNormalized = Get-NormalizedPath $InternalToolsRoot
    $appsNormalized = Get-NormalizedPath $AppsRoot
    $rootNormalized = Get-NormalizedPath $Root

    $directories = @(Get-ChildItem -LiteralPath $Root -Directory -Recurse -Force -ErrorAction SilentlyContinue)
    foreach ($directory in $directories) {
        $full = Get-NormalizedPath $directory.FullName
        if (-not $full) { continue }

        if ($full.Equals($wulfNormalized, [StringComparison]::OrdinalIgnoreCase) -or
            $full.StartsWith($wulfNormalized + '\', [StringComparison]::OrdinalIgnoreCase) -or
            $full.Equals($toolsNormalized, [StringComparison]::OrdinalIgnoreCase) -or
            $full.StartsWith($toolsNormalized + '\', [StringComparison]::OrdinalIgnoreCase) -or
            $full.Equals($appsNormalized, [StringComparison]::OrdinalIgnoreCase) -or
            $full.StartsWith($appsNormalized + '\', [StringComparison]::OrdinalIgnoreCase)) {
            continue
        }

        if (Test-CommandDirectory $full) {
            [void]$wanted.Add($full)
        }
    }

    $current = [Environment]::GetEnvironmentVariable('Path', 'Machine')
    $entries = New-Object 'System.Collections.Generic.List[string]'
    $seen = New-Object 'System.Collections.Generic.HashSet[string]' ([StringComparer]::OrdinalIgnoreCase)

    foreach ($entry in ($current -split ';')) {
        if ([string]::IsNullOrWhiteSpace($entry)) { continue }
        $normalized = Get-NormalizedPath $entry

        $isManagedPsPath = $normalized -and (
            $normalized.Equals($rootNormalized, [StringComparison]::OrdinalIgnoreCase) -or
            $normalized.StartsWith($rootNormalized + '\', [StringComparison]::OrdinalIgnoreCase)
        )

        if ($isManagedPsPath) {
            if ($wanted.Contains($normalized) -and $seen.Add($normalized)) {
                [void]$entries.Add($normalized)
            }
            continue
        }

        if ($seen.Add($entry.Trim())) {
            [void]$entries.Add($entry.Trim())
        }
    }

    $added = 0
    foreach ($path in $wanted) {
        if ($seen.Add($path)) {
            [void]$entries.Add($path)
            $added++
        }
    }

    Set-UiState 'Aktualisiere SYSTEM-PATH ...' 'Schreibe bereinigte Machine PATH Variable'

    [Environment]::SetEnvironmentVariable('Path', ($entries -join ';'), 'Machine')
    Broadcast-EnvironmentChange

    $result = "[OK] SYSTEM-PATH synchronisiert - $($wanted.Count) C:\PS Command-Pfade, $added neu"

    if ($Embedded) {
        Write-Output $result
        exit 0
    }

    Set-UiState 'PATH-Update abgeschlossen' $result 'ENTER zum Schliessen'
    Wait-UiExit
    exit 0
}
catch {
    $message = $_.Exception.Message

    if ($Embedded) {
        Write-Output ("[FEHLER] {0}" -f $message)
        exit 1
    }

    try {
        Set-UiState 'PATH-Update abgebrochen' ("[FEHLER] {0}" -f $message)
        Wait-UiExit
    } catch {}
    exit 1
}
finally {
    Stop-Ui
}
