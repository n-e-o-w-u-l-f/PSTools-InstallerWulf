param(
    [switch]$Embedded
)

$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'

$Root = 'C:\PS'
$WulfRoot = Join-Path $Root 'WULF'
$Binaries = Join-Path $Root 'binaries'
$CommandExtensions = @('.exe', '.cmd', '.bat', '.com')

function Test-Administrator {
    $identity = [Security.Principal.WindowsIdentity]::GetCurrent()
    $principal = New-Object Security.Principal.WindowsPrincipal($identity)
    return $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
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

if (-not (Test-Administrator)) {
    if ($Embedded) {
        Write-Output '[FEHLER] Administratorrechte erforderlich'
        exit 1
    }

    $arguments = @(
        '-NoProfile',
        '-ExecutionPolicy', 'Bypass',
        '-File', ('"{0}"' -f $PSCommandPath)
    )
    Start-Process -FilePath 'powershell.exe' -Verb RunAs -ArgumentList $arguments | Out-Null
    exit 0
}

if (-not (Test-Path -LiteralPath $Root -PathType Container)) {
    Write-Output '[FEHLER] C:\PS existiert nicht'
    exit 1
}

if (-not (Test-Path -LiteralPath $Binaries -PathType Container)) {
    New-Item -ItemType Directory -Path $Binaries -Force | Out-Null
}

$wanted = New-Object 'System.Collections.Generic.HashSet[string]' ([StringComparer]::OrdinalIgnoreCase)
[void]$wanted.Add((Get-NormalizedPath $Binaries))

$directories = @(Get-ChildItem -LiteralPath $Root -Directory -Recurse -Force -ErrorAction SilentlyContinue)
foreach ($directory in $directories) {
    $full = Get-NormalizedPath $directory.FullName
    if (-not $full) { continue }

    if ($full.Equals((Get-NormalizedPath $WulfRoot), [StringComparison]::OrdinalIgnoreCase) -or
        $full.StartsWith((Get-NormalizedPath $WulfRoot) + '\', [StringComparison]::OrdinalIgnoreCase)) {
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
        $normalized.Equals((Get-NormalizedPath $Root), [StringComparison]::OrdinalIgnoreCase) -or
        $normalized.StartsWith((Get-NormalizedPath $Root) + '\', [StringComparison]::OrdinalIgnoreCase)
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

$newPath = ($entries -join ';')
[Environment]::SetEnvironmentVariable('Path', $newPath, 'Machine')
Broadcast-EnvironmentChange

$managedCount = $wanted.Count
Write-Output ("[OK] SYSTEM-PATH synchronisiert - {0} C:\PS Command-Pfade, {1} neu" -f $managedCount, $added)
exit 0
