param(
    [switch]$NoPause,
    [switch]$Validate
)

$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'

try {
    [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
} catch {}

$Base = 'C:\PS'
$WulfTarget = Join-Path $Base 'WULF'
$BinTarget = Join-Path $Base 'binaries'
$ToolsTarget = Join-Path $Base 'tools'
$PsToolsTarget = Join-Path $Base 'Microsoft.Sysinternals.PsTools'
$WindowsApps = Join-Path $env:ProgramFiles 'WindowsApps'

$UiScript = Join-Path $PSScriptRoot 'Neonwulf_UI.ps1'
$ManifestPath = Join-Path $PSScriptRoot 'tools.json'
$PathUpdaterSource = Join-Path $PSScriptRoot 'Update_Paths.ps1'

$RunId = '{0}-{1}' -f $PID, ([Guid]::NewGuid().ToString('N').Substring(0,8))
$TempRoot = Join-Path $env:TEMP ('PSToolsInstallerWulf-' + $RunId)
$StatusFile = Join-Path $TempRoot 'ui-status.json'
$StatusTemp = Join-Path $TempRoot 'ui-status.tmp'
$StopFile = Join-Path $TempRoot 'ui-stop.signal'
$ProcessLog = Join-Path $TempRoot 'process.log'
$SelectionFile = Join-Path $WulfTarget 'selection.json'
$script:UiProcess = $null
$script:PythonCommand = $null

New-Item -ItemType Directory -Path $TempRoot -Force | Out-Null

function Test-Administrator {
    $identity = [Security.Principal.WindowsIdentity]::GetCurrent()
    $principal = New-Object Security.Principal.WindowsPrincipal($identity)
    return $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

function Write-UiState {
    param(
        [string]$Action,
        [string]$Detail = '',
        [string[]]$Menu = @(),
        [string]$Hint = ''
    )

    $state = [ordered]@{
        action = $Action
        detail = $Detail
        menu   = @($Menu)
        hint   = $Hint
    }

    $json = $state | ConvertTo-Json -Depth 5 -Compress
    $utf8 = New-Object Text.UTF8Encoding($false)
    [IO.File]::WriteAllText($StatusTemp, $json, $utf8)
    Move-Item -LiteralPath $StatusTemp -Destination $StatusFile -Force
}

function Start-Ui {
    if (-not (Test-Path -LiteralPath $UiScript -PathType Leaf)) {
        throw "Neonwulf_UI.ps1 wurde nicht gefunden: $UiScript"
    }

    if (Test-Path -LiteralPath $StopFile) {
        Remove-Item -LiteralPath $StopFile -Force -ErrorAction SilentlyContinue
    }

    Write-UiState 'Initialisiere Installer ...' 'Pruefe Systemzustand'

    $arguments = @(
        '-NoProfile',
        '-ExecutionPolicy', 'Bypass',
        '-File', ('"{0}"' -f $UiScript),
        '-Mode', 'Installer',
        '-StatusFile', ('"{0}"' -f $StatusFile),
        '-StopFile', ('"{0}"' -f $StopFile)
    )

    $script:UiProcess = Start-Process -FilePath 'powershell.exe' `
        -ArgumentList $arguments `
        -NoNewWindow `
        -PassThru
}

function Stop-Ui {
    try {
        if (-not (Test-Path -LiteralPath $StopFile)) {
            [IO.File]::WriteAllText($StopFile, 'stop')
        }
    } catch {}

    if ($script:UiProcess) {
        try {
            if (-not $script:UiProcess.HasExited) {
                [void]$script:UiProcess.WaitForExit(1200)
            }
        } catch {}

        try {
            if (-not $script:UiProcess.HasExited) {
                $script:UiProcess.Kill()
            }
        } catch {}
    }
}

function Wait-ForExit {
    param(
        [string]$Message = '[OK] ENTER zum Schliessen',
        [string]$Action = 'Vorgang beendet'
    )

    if ($NoPause) { return }

    Write-UiState $Action $Message
    while ($true) {
        $key = [Console]::ReadKey($true)
        if ($key.Key -eq [ConsoleKey]::Enter) { break }
    }
}

function Ensure-Directory {
    param([string]$Path)

    if (Test-Path -LiteralPath $Path -PathType Container) {
        Write-UiState 'Pruefe Verzeichnisstruktur ...' ("[OK] {0} vorhanden" -f $Path)
        return
    }

    Write-UiState 'Erstelle Verzeichnis ...' $Path
    New-Item -ItemType Directory -Path $Path -Force | Out-Null

    if (-not (Test-Path -LiteralPath $Path -PathType Container)) {
        throw "Verzeichnis konnte nicht erstellt werden: $Path"
    }

    Write-UiState 'Pruefe Verzeichnisstruktur ...' ("[OK] {0} erstellt" -f $Path)
}

function Get-NormalizedPath {
    param([string]$Path)

    try {
        return [IO.Path]::GetFullPath($Path.TrimEnd('\'))
    } catch {
        return $Path.TrimEnd('\')
    }
}

function Sync-WulfInfrastructure {
    Ensure-Directory $WulfTarget

    $source = Get-NormalizedPath $PSScriptRoot
    $target = Get-NormalizedPath $WulfTarget

    if ($source.Equals($target, [StringComparison]::OrdinalIgnoreCase)) {
        Write-UiState 'Pruefe WULF ...' '[OK] WULF bereits installiert'
        return
    }

    Write-UiState 'Installiere WULF Infrastruktur ...' 'Synchronisiere Installer-Dateien'

    foreach ($item in Get-ChildItem -LiteralPath $PSScriptRoot -Force) {
        if ($item.Name -eq 'selection.json') { continue }
        Copy-Item -LiteralPath $item.FullName -Destination $WulfTarget -Recurse -Force
    }

    Write-UiState 'Pruefe WULF ...' '[OK] WULF installiert und synchronisiert'
}

function Invoke-Download {
    param(
        [string]$Url,
        [string]$Destination
    )

    $parent = Split-Path -Parent $Destination
    if ($parent) {
        New-Item -ItemType Directory -Path $parent -Force | Out-Null
    }

    Invoke-WebRequest -Uri $Url `
        -UseBasicParsing `
        -Headers @{ 'User-Agent' = 'PSTools-InstallerWulf' } `
        -OutFile $Destination
}

function Assert-GitHubAssetDigest {
    param(
        $Asset,
        [string]$Path
    )

    $digest = [string]$Asset.digest
    if ([string]::IsNullOrWhiteSpace($digest)) { return }
    if ($digest -notmatch '^sha256:([0-9a-fA-F]{64})$') { return }

    $expected = $Matches[1].ToUpperInvariant()
    $actual = (Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash.ToUpperInvariant()

    if ($actual -ne $expected) {
        throw "SHA-256 Pruefung fehlgeschlagen: $($Asset.name)"
    }
}

function Get-GitHubReleaseAsset {
    param(
        [string]$Repo,
        [string]$AssetRegex
    )

    $api = "https://api.github.com/repos/$Repo/releases/latest"
    $release = Invoke-RestMethod -Uri $api `
        -Headers @{
            'User-Agent' = 'PSTools-InstallerWulf'
            'Accept' = 'application/vnd.github+json'
        }

    $asset = @($release.assets | Where-Object { $_.name -match $AssetRegex }) | Select-Object -First 1
    if (-not $asset) {
        throw "Kein passendes Windows-Artefakt gefunden: $Repo / $AssetRegex"
    }

    return $asset
}

function Expand-ZipNormalized {
    param(
        [string]$ZipPath,
        [string]$Destination
    )

    $scratch = Join-Path $TempRoot ('extract-' + [Guid]::NewGuid().ToString('N'))
    New-Item -ItemType Directory -Path $scratch -Force | Out-Null

    try {
        Expand-Archive -LiteralPath $ZipPath -DestinationPath $scratch -Force

        if (Test-Path -LiteralPath $Destination) {
            Remove-Item -LiteralPath $Destination -Recurse -Force
        }
        New-Item -ItemType Directory -Path $Destination -Force | Out-Null

        $children = @(Get-ChildItem -LiteralPath $scratch -Force)
        if ($children.Count -eq 1 -and $children[0].PSIsContainer) {
            foreach ($child in Get-ChildItem -LiteralPath $children[0].FullName -Force) {
                Copy-Item -LiteralPath $child.FullName -Destination $Destination -Recurse -Force
            }
        } else {
            foreach ($child in $children) {
                Copy-Item -LiteralPath $child.FullName -Destination $Destination -Recurse -Force
            }
        }
    }
    finally {
        Remove-Item -LiteralPath $scratch -Recurse -Force -ErrorAction SilentlyContinue
    }
}

function Expand-GZipFile {
    param(
        [string]$Source,
        [string]$Destination
    )

    $parent = Split-Path -Parent $Destination
    if ($parent) {
        New-Item -ItemType Directory -Path $parent -Force | Out-Null
    }

    $input = [IO.File]::OpenRead($Source)
    try {
        $gzip = New-Object IO.Compression.GZipStream($input, [IO.Compression.CompressionMode]::Decompress)
        try {
            $output = [IO.File]::Create($Destination)
            try {
                $gzip.CopyTo($output)
            }
            finally {
                $output.Dispose()
            }
        }
        finally {
            $gzip.Dispose()
        }
    }
    finally {
        $input.Dispose()
    }
}

function Invoke-ProcessLogged {
    param(
        [string]$FilePath,
        [string[]]$ArgumentList
    )

    $stdout = Join-Path $TempRoot ('stdout-' + [Guid]::NewGuid().ToString('N') + '.log')
    $stderr = Join-Path $TempRoot ('stderr-' + [Guid]::NewGuid().ToString('N') + '.log')

    try {
        $process = Start-Process -FilePath $FilePath `
            -ArgumentList $ArgumentList `
            -NoNewWindow `
            -Wait `
            -PassThru `
            -RedirectStandardOutput $stdout `
            -RedirectStandardError $stderr

        $combined = ''
        if (Test-Path -LiteralPath $stdout) {
            $combined += (Get-Content -LiteralPath $stdout -Raw -ErrorAction SilentlyContinue)
        }
        if (Test-Path -LiteralPath $stderr) {
            $combined += (Get-Content -LiteralPath $stderr -Raw -ErrorAction SilentlyContinue)
        }
        [IO.File]::WriteAllText($ProcessLog, $combined)

        return $process.ExitCode
    }
    finally {
        Remove-Item -LiteralPath $stdout, $stderr -Force -ErrorAction SilentlyContinue
    }
}

function Get-PythonCommand {
    if ($script:PythonCommand) { return $script:PythonCommand }

    $py = Get-Command 'py.exe' -ErrorAction SilentlyContinue
    if ($py) {
        $script:PythonCommand = [pscustomobject]@{
            File = $py.Source
            Prefix = @('-3')
        }
        return $script:PythonCommand
    }

    $python = Get-Command 'python.exe' -ErrorAction SilentlyContinue
    if ($python) {
        $script:PythonCommand = [pscustomobject]@{
            File = $python.Source
            Prefix = @()
        }
        return $script:PythonCommand
    }

    return $null
}

function Test-ToolRequirement {
    param($Tool)

    if (-not $Tool.requires) { return $true }

    if ([string]$Tool.requires -eq 'python') {
        return $null -ne (Get-PythonCommand)
    }

    return $true
}

function Get-ToolPath {
    param([string]$RelativePath)
    return Join-Path $Base $RelativePath
}

function Test-ToolInstalled {
    param($Tool)

    $path = Get-ToolPath ([string]$Tool.detectPath)

    if (-not (Test-Path -LiteralPath $path)) {
        return $false
    }

    if ($Tool.detectName -and (Test-Path -LiteralPath $path -PathType Container)) {
        $match = Get-ChildItem -LiteralPath $path -Recurse -File -Filter ([string]$Tool.detectName) -ErrorAction SilentlyContinue |
            Select-Object -First 1
        return $null -ne $match
    }

    return $true
}

function Remove-Tool {
    param($Tool)

    Write-UiState ("Entferne {0} ..." -f $Tool.name) 'Bereinige verwaltete Dateien'

    foreach ($relative in @($Tool.managedPaths)) {
        $path = Get-ToolPath ([string]$relative)
        if (Test-Path -LiteralPath $path) {
            Remove-Item -LiteralPath $path -Recurse -Force
        }
    }

    Write-UiState ("Entferne {0} ..." -f $Tool.name) '[OK] Tool entfernt'
}

function Install-PipTool {
    param($Tool)

    $python = Get-PythonCommand
    if (-not $python) {
        throw 'Python 3 wurde nicht gefunden'
    }

    $target = Get-ToolPath ([string]$Tool.target)
    $shim = Get-ToolPath ([string]$Tool.detectPath)

    if (Test-Path -LiteralPath $target) {
        Remove-Item -LiteralPath $target -Recurse -Force
    }

    New-Item -ItemType Directory -Path (Split-Path -Parent $target) -Force | Out-Null

    $venvArgs = @()
    $venvArgs += @($python.Prefix)
    $venvArgs += @('-m', 'venv', $target)

    if ((Invoke-ProcessLogged $python.File $venvArgs) -ne 0) {
        throw 'Python venv konnte nicht erstellt werden'
    }

    $venvPython = Join-Path $target 'Scripts\python.exe'
    if (-not (Test-Path -LiteralPath $venvPython)) {
        throw "venv python.exe fehlt: $venvPython"
    }

    $pipArgs = @(
        '-m', 'pip',
        '--disable-pip-version-check',
        'install',
        '--upgrade',
        [string]$Tool.package
    )

    if ((Invoke-ProcessLogged $venvPython $pipArgs) -ne 0) {
        throw "pip-Installation fehlgeschlagen: $($Tool.package)"
    }

    $commandExe = Join-Path $target ("Scripts\{0}.exe" -f $Tool.command)
    $commandCmd = Join-Path $target ("Scripts\{0}.cmd" -f $Tool.command)
    $commandPath = $null

    if (Test-Path -LiteralPath $commandExe) {
        $commandPath = $commandExe
    } elseif (Test-Path -LiteralPath $commandCmd) {
        $commandPath = $commandCmd
    } else {
        throw "Command wurde im venv nicht gefunden: $($Tool.command)"
    }

    New-Item -ItemType Directory -Path (Split-Path -Parent $shim) -Force | Out-Null
    $shimContent = "@echo off`r`n`"$commandPath`" %*`r`n"
    [IO.File]::WriteAllText($shim, $shimContent, (New-Object Text.UTF8Encoding($false)))
}

function Install-Tool {
    param($Tool)

    if (-not (Test-ToolRequirement $Tool)) {
        throw "Voraussetzung fehlt: $($Tool.requires)"
    }

    Write-UiState ("Installiere/Aktualisiere {0} ..." -f $Tool.name) 'Ermittle aktuelle Originalversion'

    switch ([string]$Tool.installType) {
        'github-exe' {
            $asset = Get-GitHubReleaseAsset ([string]$Tool.repo) ([string]$Tool.assetRegex)
            $target = Get-ToolPath ([string]$Tool.target)
            $download = Join-Path $TempRoot ([string]$asset.name)

            Write-UiState ("Installiere/Aktualisiere {0} ..." -f $Tool.name) ("Download: {0}" -f $asset.name)
            Invoke-Download ([string]$asset.browser_download_url) $download
            Assert-GitHubAssetDigest $asset $download

            New-Item -ItemType Directory -Path (Split-Path -Parent $target) -Force | Out-Null
            Move-Item -LiteralPath $download -Destination $target -Force
        }

        'github-zip-single' {
            $asset = Get-GitHubReleaseAsset ([string]$Tool.repo) ([string]$Tool.assetRegex)
            $zip = Join-Path $TempRoot ([string]$asset.name)
            $scratch = Join-Path $TempRoot ('single-' + [Guid]::NewGuid().ToString('N'))

            Write-UiState ("Installiere/Aktualisiere {0} ..." -f $Tool.name) ("Download: {0}" -f $asset.name)
            Invoke-Download ([string]$asset.browser_download_url) $zip
            Assert-GitHubAssetDigest $asset $zip

            New-Item -ItemType Directory -Path $scratch -Force | Out-Null
            try {
                Expand-Archive -LiteralPath $zip -DestinationPath $scratch -Force
                $source = Get-ChildItem -LiteralPath $scratch -Recurse -File -Filter ([string]$Tool.extractName) |
                    Select-Object -First 1
                if (-not $source) {
                    throw "Datei im Archiv nicht gefunden: $($Tool.extractName)"
                }

                $target = Get-ToolPath ([string]$Tool.target)
                New-Item -ItemType Directory -Path (Split-Path -Parent $target) -Force | Out-Null
                Copy-Item -LiteralPath $source.FullName -Destination $target -Force
            }
            finally {
                Remove-Item -LiteralPath $scratch -Recurse -Force -ErrorAction SilentlyContinue
                Remove-Item -LiteralPath $zip -Force -ErrorAction SilentlyContinue
            }
        }

        'github-gzip-exe' {
            $asset = Get-GitHubReleaseAsset ([string]$Tool.repo) ([string]$Tool.assetRegex)
            $gzip = Join-Path $TempRoot ([string]$asset.name)
            $target = Get-ToolPath ([string]$Tool.target)
            $tempTarget = $target + '.download'

            Write-UiState ("Installiere/Aktualisiere {0} ..." -f $Tool.name) ("Download: {0}" -f $asset.name)
            Invoke-Download ([string]$asset.browser_download_url) $gzip
            Assert-GitHubAssetDigest $asset $gzip
            Expand-GZipFile $gzip $tempTarget
            Move-Item -LiteralPath $tempTarget -Destination $target -Force
            Remove-Item -LiteralPath $gzip -Force -ErrorAction SilentlyContinue
        }

        'github-zip' {
            $asset = Get-GitHubReleaseAsset ([string]$Tool.repo) ([string]$Tool.assetRegex)
            $zip = Join-Path $TempRoot ([string]$asset.name)
            $target = Get-ToolPath ([string]$Tool.target)

            Write-UiState ("Installiere/Aktualisiere {0} ..." -f $Tool.name) ("Download: {0}" -f $asset.name)
            Invoke-Download ([string]$asset.browser_download_url) $zip
            Assert-GitHubAssetDigest $asset $zip
            Expand-ZipNormalized $zip $target
            Remove-Item -LiteralPath $zip -Force -ErrorAction SilentlyContinue
        }

        'pip-venv' {
            Write-UiState ("Installiere/Aktualisiere {0} ..." -f $Tool.name) ("Python package: {0}" -f $Tool.package)
            Install-PipTool $Tool
        }

        default {
            throw "Unbekannter InstallType: $($Tool.installType)"
        }
    }

    if (-not (Test-ToolInstalled $Tool)) {
        throw "Installationspruefung fehlgeschlagen: $($Tool.name)"
    }

    Write-UiState ("Installiere/Aktualisiere {0} ..." -f $Tool.name) '[OK] Tool bereit'
}

function Install-OrUpdatePsTools {
    $psexec = Join-Path $PsToolsTarget 'PsExec64.exe'
    $alreadyInstalled = Test-Path -LiteralPath $psexec -PathType Leaf

    if ($alreadyInstalled) {
        Write-UiState 'Pruefe Microsoft PsTools ...' '[OK] PsTools bereits installiert'
    } else {
        Write-UiState 'Pruefe Microsoft PsTools ...' 'PsTools noch nicht installiert'
    }

    $zip = Join-Path $TempRoot 'PSTools.zip'
    $url = 'https://download.sysinternals.com/files/PSTools.zip'

    try {
        Write-UiState 'Aktualisiere Microsoft PsTools ...' 'Download direkt von Microsoft Sysinternals'
        Invoke-Download $url $zip

        New-Item -ItemType Directory -Path $PsToolsTarget -Force | Out-Null

        Write-UiState 'Aktualisiere Microsoft PsTools ...' 'Entpacke zentral nach C:\PS\Microsoft.Sysinternals.PsTools'
        Expand-Archive -LiteralPath $zip -DestinationPath $PsToolsTarget -Force

        if (-not (Test-Path -LiteralPath $psexec -PathType Leaf)) {
            throw 'PsExec64.exe wurde nach dem Entpacken nicht gefunden'
        }

        Write-UiState 'Pruefe Microsoft PsTools ...' '[OK] PsTools aus Originalquelle bereit'
    }
    catch {
        if ($alreadyInstalled -and (Test-Path -LiteralPath $psexec -PathType Leaf)) {
            Write-UiState 'Aktualisiere Microsoft PsTools ...' '[WARNUNG] Download fehlgeschlagen - vorhandene PsTools bleiben aktiv'
            return
        }
        throw
    }
    finally {
        Remove-Item -LiteralPath $zip -Force -ErrorAction SilentlyContinue
    }
}

function Test-FullControlRule {
    param(
        [Security.AccessControl.DirectorySecurity]$Acl,
        [string]$Sid
    )

    foreach ($rule in $Acl.Access) {
        if ($rule.AccessControlType -ne [Security.AccessControl.AccessControlType]::Allow) { continue }

        $ruleSid = $null
        try {
            $ruleSid = $rule.IdentityReference.Translate([Security.Principal.SecurityIdentifier]).Value
        } catch {
            continue
        }

        if ($ruleSid -ne $Sid) { continue }

        $full = [Security.AccessControl.FileSystemRights]::FullControl
        if (($rule.FileSystemRights -band $full) -eq $full) {
            return $true
        }
    }

    return $false
}

function Ensure-WindowsAppsRights {
    if (-not (Test-Path -LiteralPath $WindowsApps -PathType Container)) {
        Write-UiState 'Pruefe WindowsApps Rechte ...' '[WARNUNG] WindowsApps wurde nicht gefunden'
        return
    }

    $currentSid = [Security.Principal.WindowsIdentity]::GetCurrent().User.Value
    $adminSid = 'S-1-5-32-544'

    $alreadySet = $false
    try {
        $acl = Get-Acl -LiteralPath $WindowsApps
        $alreadySet = (Test-FullControlRule $acl $currentSid) -and
                      (Test-FullControlRule $acl $adminSid)
    } catch {
        $alreadySet = $false
    }

    if ($alreadySet) {
        Write-UiState 'Pruefe WindowsApps Rechte ...' '[OK] Rechte bereits gesetzt - ueberspringe'
        return
    }

    $psexec = Join-Path $PsToolsTarget 'PsExec64.exe'
    if (-not (Test-Path -LiteralPath $psexec -PathType Leaf)) {
        throw 'PsExec64.exe fehlt fuer WindowsApps ACL'
    }

    Write-UiState 'Setze WindowsApps Rechte ...' 'TrustedInstaller bleibt Besitzer'

    $currentIdentity = '{0}\{1}' -f $env:USERDOMAIN, $env:USERNAME
    $arguments = @(
        '-accepteula',
        '-nobanner',
        '-s',
        (Join-Path $env:SystemRoot 'System32\icacls.exe'),
        ('"{0}"' -f $WindowsApps),
        '/grant',
        '*S-1-5-32-544:(OI)(CI)F',
        ('"{0}:(OI)(CI)F"' -f $currentIdentity)
    )

    if ((Invoke-ProcessLogged $psexec $arguments) -ne 0) {
        throw 'WindowsApps Berechtigungen konnten nicht gesetzt werden'
    }

    Write-UiState 'Setze WindowsApps Rechte ...' '[OK] Rechte gesetzt'
}

function Read-Manifest {
    if (-not (Test-Path -LiteralPath $ManifestPath -PathType Leaf)) {
        throw "tools.json wurde nicht gefunden: $ManifestPath"
    }

    return (Get-Content -LiteralPath $ManifestPath -Raw -Encoding UTF8 | ConvertFrom-Json)
}

function Load-Selection {
    param([object[]]$Tools)

    $savedIds = @()
    $hasSavedState = $false

    if (Test-Path -LiteralPath $SelectionFile -PathType Leaf) {
        try {
            $saved = Get-Content -LiteralPath $SelectionFile -Raw -Encoding UTF8 | ConvertFrom-Json
            $savedIds = @($saved.selected)
            $hasSavedState = $true
        } catch {
            $savedIds = @()
            $hasSavedState = $false
        }
    }

    $selection = @{}

    foreach ($tool in $Tools) {
        $id = [string]$tool.id

        if ($hasSavedState) {
            $selection[$id] = $savedIds -contains $id
        } else {
            $selection[$id] = (Test-ToolInstalled $tool) -or [bool]$tool.defaultSelected
        }
    }

    return $selection
}

function Save-Selection {
    param(
        [object[]]$Tools,
        [hashtable]$Selection
    )

    $selected = @()
    foreach ($tool in $Tools) {
        $id = [string]$tool.id
        if ($Selection[$id]) {
            $selected += $id
        }
    }

    $state = [ordered]@{
        schemaVersion = 1
        selected = @($selected)
    }

    $json = $state | ConvertTo-Json -Depth 4
    [IO.File]::WriteAllText($SelectionFile, $json, (New-Object Text.UTF8Encoding($false)))
}

function Build-MenuLines {
    param(
        [object[]]$Tools,
        [hashtable]$Selection,
        [int]$Cursor
    )

    $maxVisible = 9
    $count = $Tools.Count

    $start = 0
    if ($count -gt $maxVisible) {
        $half = [int][Math]::Floor($maxVisible / 2)
        $start = [Math]::Max(0, $Cursor - $half)
        $start = [Math]::Min($start, $count - $maxVisible)
    }

    $end = [Math]::Min($count - 1, $start + $maxVisible - 1)
    $lines = @()

    if ($start -gt 0) {
        $lines += '  ...'
    }

    for ($i = $start; $i -le $end; $i++) {
        $tool = $Tools[$i]
        $id = [string]$tool.id
        $pointer = ' '
        if ($i -eq $Cursor) { $pointer = '>' }

        $box = ' '
        if ($Selection[$id]) { $box = 'x' }

        $suffix = ''
        if (Test-ToolInstalled $tool) {
            $suffix = '  [installiert]'
        } elseif (-not (Test-ToolRequirement $tool)) {
            $suffix = '  [! Voraussetzung fehlt: {0}]' -f $tool.requires
        }

        $lines += ('{0} [{1}] {2}{3}' -f $pointer, $box, $tool.name, $suffix)
    }

    if ($end -lt ($count - 1)) {
        $lines += '  ...'
    }

    return $lines
}

function Show-ToolMenu {
    param([object[]]$Tools)

    $selection = Load-Selection $Tools
    $cursor = 0

    while ($true) {
        $lines = Build-MenuLines $Tools $selection $cursor

        Write-UiState `
            'PowerShell Tools verwalten' `
            'Installierte Tools wurden erkannt - Auswahl anpassen' `
            $lines `
            'Pfeile = Navigation  |  SPACE = an/aus  |  ENTER = anwenden'

        $key = [Console]::ReadKey($true)

        if ($key.Key -eq [ConsoleKey]::UpArrow) {
            $cursor--
            if ($cursor -lt 0) { $cursor = $Tools.Count - 1 }
        }
        elseif ($key.Key -eq [ConsoleKey]::DownArrow) {
            $cursor++
            if ($cursor -ge $Tools.Count) { $cursor = 0 }
        }
        elseif ($key.Key -eq [ConsoleKey]::Spacebar) {
            $id = [string]$Tools[$cursor].id
            $selection[$id] = -not [bool]$selection[$id]
        }
        elseif ($key.Key -eq [ConsoleKey]::Enter) {
            return $selection
        }
    }
}

function Apply-ToolSelection {
    param(
        [object[]]$Tools,
        [hashtable]$Selection
    )

    $errors = New-Object 'System.Collections.Generic.List[string]'

    foreach ($tool in $Tools) {
        $id = [string]$tool.id
        $wanted = [bool]$Selection[$id]
        $installed = Test-ToolInstalled $tool

        try {
            if ($wanted) {
                Install-Tool $tool
            } elseif ($installed) {
                Remove-Tool $tool
            } else {
                Write-UiState ("Pruefe {0} ..." -f $tool.name) '[OK] Nicht ausgewaehlt'
            }
        }
        catch {
            $errors.Add(('{0}: {1}' -f $tool.name, $_.Exception.Message))
            Write-UiState ("Toolfehler: {0}" -f $tool.name) ("[WARNUNG] {0}" -f $_.Exception.Message)
            Start-Sleep -Milliseconds 700
        }
    }

    Save-Selection $Tools $Selection
    return $errors
}

function Update-SystemPath {
    $installedUpdater = Join-Path $WulfTarget 'Update_Paths.ps1'

    if (-not (Test-Path -LiteralPath $installedUpdater -PathType Leaf)) {
        if (Test-Path -LiteralPath $PathUpdaterSource -PathType Leaf) {
            $installedUpdater = $PathUpdaterSource
        } else {
            throw 'Update_Paths.ps1 wurde nicht gefunden'
        }
    }

    Write-UiState 'Aktualisiere SYSTEM-PATH ...' 'Erkenne Command-Verzeichnisse unter C:\PS'

    $output = & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $installedUpdater -Embedded 2>&1
    if ($LASTEXITCODE -ne 0) {
        $message = ($output | Select-Object -First 1)
        if (-not $message) { $message = 'Unbekannter PATH-Fehler' }
        throw [string]$message
    }

    $result = ($output | Select-Object -First 1)
    if (-not $result) { $result = '[OK] SYSTEM-PATH synchronisiert' }

    Write-UiState 'Aktualisiere SYSTEM-PATH ...' ([string]$result)
}

function Invoke-Validation {
    $manifest = Read-Manifest
    $tools = @($manifest.tools | Where-Object { [bool]$_.menu })
    $errors = New-Object 'System.Collections.Generic.List[string]'
    $warnings = New-Object 'System.Collections.Generic.List[string]'
    $knownTypes = @('github-exe','github-zip-single','github-gzip-exe','github-zip','pip-venv')
    $ids = New-Object 'System.Collections.Generic.HashSet[string]' ([StringComparer]::OrdinalIgnoreCase)

    Write-UiState 'Validiere Installer ...' 'Pruefe Manifest und Microsoft PsTools Quelle'

    if (-not $manifest.schemaVersion -or [int]$manifest.schemaVersion -ne 1) {
        $errors.Add('tools.json: schemaVersion muss 1 sein')
    }

    try {
        $response = Invoke-WebRequest -Uri 'https://download.sysinternals.com/files/PSTools.zip' `
            -UseBasicParsing `
            -Method Head `
            -Headers @{ 'User-Agent' = 'PSTools-InstallerWulf' }
        if ([int]$response.StatusCode -lt 200 -or [int]$response.StatusCode -ge 400) {
            throw "HTTP $($response.StatusCode)"
        }
    } catch {
        $errors.Add(('Microsoft PsTools: {0}' -f $_.Exception.Message))
    }

    foreach ($tool in $tools) {
        $id = [string]$tool.id
        $name = [string]$tool.name
        $type = [string]$tool.installType

        Write-UiState ("Validiere {0} ..." -f $name) ("InstallType: {0}" -f $type)

        if ([string]::IsNullOrWhiteSpace($id) -or -not $ids.Add($id)) {
            $errors.Add(("tools.json: ungueltige oder doppelte ID '{0}'" -f $id))
            continue
        }

        if ($knownTypes -notcontains $type) {
            $errors.Add(("{0}: unbekannter InstallType '{1}'" -f $name, $type))
            continue
        }

        if ([string]::IsNullOrWhiteSpace([string]$tool.detectPath)) {
            $errors.Add(("{0}: detectPath fehlt" -f $name))
        }

        if ($type -like 'github-*') {
            if ([string]::IsNullOrWhiteSpace([string]$tool.repo) -or
                [string]::IsNullOrWhiteSpace([string]$tool.assetRegex)) {
                $errors.Add(("{0}: repo oder assetRegex fehlt" -f $name))
                continue
            }

            try {
                $asset = Get-GitHubReleaseAsset ([string]$tool.repo) ([string]$tool.assetRegex)
                Write-UiState ("Validiere {0} ..." -f $name) ("[OK] {0}" -f $asset.name)
            } catch {
                $errors.Add(("{0}: {1}" -f $name, $_.Exception.Message))
            }
        }
        elseif ($type -eq 'pip-venv') {
            if ([string]::IsNullOrWhiteSpace([string]$tool.package) -or
                [string]::IsNullOrWhiteSpace([string]$tool.command)) {
                $errors.Add(("{0}: package oder command fehlt" -f $name))
            }
            elseif (-not (Test-ToolRequirement $tool)) {
                $warnings.Add(("{0}: Python 3 ist auf diesem System nicht verfuegbar" -f $name))
            }
        }
    }

    if ($errors.Count -gt 0) {
        $detail = '[FEHLER] {0} Validierungsfehler - erster: {1}' -f $errors.Count, $errors[0]
        Write-UiState 'Validierung abgeschlossen' $detail @() 'ENTER zum Schliessen'
    }
    elseif ($warnings.Count -gt 0) {
        $detail = '[WARNUNG] Manifest/Downloads OK - {0} lokale Voraussetzung(en) fehlen' -f $warnings.Count
        Write-UiState 'Validierung abgeschlossen' $detail @() 'ENTER zum Schliessen'
    }
    else {
        $detail = '[OK] Manifest, PsTools und {0} Tool-Eintraege validiert' -f $tools.Count
        Write-UiState 'Validierung abgeschlossen' $detail @() 'ENTER zum Schliessen'
    }

    if (-not $NoPause) {
        while ($true) {
            $key = [Console]::ReadKey($true)
            if ($key.Key -eq [ConsoleKey]::Enter) { break }
        }
    }

    if ($errors.Count -gt 0) { return 1 }
    return 0
}

try {
    Start-Ui

    if ($Validate) {
        $validationExitCode = Invoke-Validation
        exit $validationExitCode
    }

    Write-UiState 'Pruefe Administratorrechte ...' 'Windows-Administrator erforderlich'
    if (-not (Test-Administrator)) {
        Write-UiState 'Administratorrechte erforderlich ...' 'UAC-Anfrage wird geoeffnet'
        Start-Sleep -Milliseconds 500
        Stop-Ui

        $arguments = @(
            '-NoProfile',
            '-ExecutionPolicy', 'Bypass',
            '-File', ('"{0}"' -f $PSCommandPath)
        )
        if ($NoPause) { $arguments += '-NoPause' }
        if ($Validate) { $arguments += '-Validate' }

        Start-Process -FilePath 'powershell.exe' -Verb RunAs -ArgumentList $arguments | Out-Null
        exit 0
    }

    Ensure-Directory $Base
    Ensure-Directory $WulfTarget
    Ensure-Directory $BinTarget
    Ensure-Directory $ToolsTarget

    Sync-WulfInfrastructure
    Install-OrUpdatePsTools
    Ensure-WindowsAppsRights

    $manifest = Read-Manifest
    $tools = @($manifest.tools | Where-Object { [bool]$_.menu })

    Write-UiState 'Analysiere installierte Tools ...' 'Ermittle aktuellen Zustand unter C:\PS'
    Start-Sleep -Milliseconds 350

    $selection = Show-ToolMenu $tools
    $toolErrors = Apply-ToolSelection $tools $selection

    Update-SystemPath

    if ($toolErrors.Count -gt 0) {
        $first = $toolErrors[0]
        Write-UiState 'Installation abgeschlossen' ("[WARNUNG] {0} Tool-Fehler - erster: {1}" -f $toolErrors.Count, $first)
    } else {
        Write-UiState 'Installation abgeschlossen' '[OK] PsTools, Tool-Auswahl und SYSTEM-PATH sind synchronisiert'
    }

    Wait-ForExit
    exit 0
}
catch {
    $message = $_.Exception.Message
    try {
        Write-UiState 'Installation abgebrochen' ("[FEHLER] {0}" -f $message)
        Wait-ForExit '[FEHLER] ENTER zum Schliessen'
    } catch {}
    exit 1
}
finally {
    Stop-Ui
    Remove-Item -LiteralPath $TempRoot -Recurse -Force -ErrorAction SilentlyContinue
}
