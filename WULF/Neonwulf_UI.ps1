param(
    [ValidateSet('Installer','PathUpdater')]
    [string]$Mode = 'Installer',
    [Parameter(Mandatory=$true)]
    [string]$StatusFile,
    [Parameter(Mandatory=$true)]
    [string]$StopFile
)

$ErrorActionPreference = 'SilentlyContinue'
$esc = [char]27

# Child process stays attached to the current cmd.exe console. If that parent
# disappears unexpectedly, the renderer also exits instead of lingering.
$parentPid = 0
try {
    $parentPid = (Get-CimInstance Win32_Process -Filter "ProcessId=$PID").ParentProcessId
} catch {}

function Test-ParentAlive {
    if ($parentPid -le 0) { return $true }
    return $null -ne (Get-Process -Id $parentPid -ErrorAction SilentlyContinue)
}

function Get-Layout {
    $w = [Math]::Max(60, [Console]::WindowWidth)
    $h = [Math]::Max(16, [Console]::WindowHeight)
    # Leave the final terminal column untouched to avoid legacy conhost wrap/scroll.
    $dw = [Math]::Max(1, $w - 1)
    $body1 = [Math]::Max(7, [int][Math]::Floor($h / 2))
    $body2 = [Math]::Min($h - 5, $body1 + 2)
    $footer1 = $h - 3
    $footer2 = $h - 2
    $footer3 = $h - 1
    $footer4 = $h
    [pscustomobject]@{
        Width=$w; DrawWidth=$dw; Height=$h; Body1=$body1; Body2=$body2;
        Footer1=$footer1; Footer2=$footer2; Footer3=$footer3; Footer4=$footer4
    }
}

if ($Mode -eq 'PathUpdater') {
    $head1 = 'C:\PS  //  SYSTEM PATH UPDATER'
    $head2 = 'Rekursive Verzeichniserkennung  //  Machine PATH'
    $foot3 = 'C:\PS  //  Automatische PATH-Erkennung'
    $foot4 = 'Update laeuft  //  Live-Status in der Bildschirmmitte'
} else {
    $head1 = 'C:\PS  //  PsTools + WindowsApps Permissions'
    $head2 = 'Microsoft.Sysinternals.PsTools  //  TrustedInstaller-safe ACL'
    $foot3 = 'C:\PS  //  PsTools  //  WindowsApps ACL  //  SYSTEM-PATH'
    $foot4 = 'Installation laeuft  //  Live-Status in der Bildschirmmitte'
}

# Neonwulf RGB cycle. Saturated, but deliberately never pale/bright so white
# text remains readable. The phase moves continuously from left to right.
$stops = @(
    @(10, 12, 56),     # midnight blue
    @(12, 34, 112),    # deep blue
    @(10, 82, 160),    # deep cyan-blue
    @(42, 54, 166),    # electric blue/violet
    @(102, 32, 170),   # violet
    @(170, 30, 146),   # neon pink
    @(184, 46, 118),   # rose
    @(126, 34, 168),   # purple
    @(28, 72, 168),    # blue
    @(10, 12, 56)      # midnight blue
)

function Get-RgbAt([double]$x, [double]$phase, [double]$mul) {
    $cycle = $stops.Count - 1
    $p = (($x + $phase) % 1.0)
    if ($p -lt 0) { $p += 1.0 }
    $scaled = $p * $cycle
    $seg = [Math]::Min([int][Math]::Floor($scaled), $cycle - 1)
    $t = $scaled - $seg
    $a = $stops[$seg]
    $b = $stops[$seg + 1]
    $r = [int][Math]::Round(($a[0] + (($b[0] - $a[0]) * $t)) * $mul)
    $g = [int][Math]::Round(($a[1] + (($b[1] - $a[1]) * $t)) * $mul)
    $bl = [int][Math]::Round(($a[2] + (($b[2] - $a[2]) * $t)) * $mul)
    # Hard caps preserve white-text contrast.
    @([Math]::Min(190,$r), [Math]::Min(150,$g), [Math]::Min(180,$bl))
}

function Add-GradientRow(
    [System.Text.StringBuilder]$sb,
    [int]$row,
    [string]$text,
    [double]$brightness,
    [double]$phase,
    [int]$drawWidth
) {
    if ($null -eq $text) { $text = '' }
    $start = [Math]::Max(0, [int][Math]::Floor(($drawWidth - $text.Length) / 2))
    [void]$sb.Append("$esc[$row;1H")
    $den = [Math]::Max(1, $drawWidth - 1)
    for ($i = 0; $i -lt $drawWidth; $i++) {
        $rgb = Get-RgbAt ($i / [double]$den) $phase $brightness
        $ch = ' '
        $ti = $i - $start
        if ($ti -ge 0 -and $ti -lt $text.Length) { $ch = $text[$ti] }
        [void]$sb.Append("$esc[48;2;$($rgb[0]);$($rgb[1]);$($rgb[2])m$esc[38;2;255;255;255m$ch")
    }
    [void]$sb.Append("$esc[0m")
}

function Add-CenteredStatus(
    [System.Text.StringBuilder]$sb,
    [int]$row,
    [string]$text,
    [string]$fg,
    [int]$width
) {
    if ($null -eq $text) { $text = '' }
    $col = [Math]::Max(1, [int][Math]::Floor(($width - $text.Length) / 2) + 1)
    [void]$sb.Append("$esc[$row;1H$esc[2K$esc[48;2;0;0;0m$esc[$fg" + 'm')
    [void]$sb.Append("$esc[$row;${col}H$text$esc[0m")
}

function Read-Status {
    if (-not (Test-Path -LiteralPath $StatusFile)) { return @('Initialisiere ...','') }
    try {
        $lines = @(Get-Content -LiteralPath $StatusFile -Encoding Default -ErrorAction Stop)
        $a = if ($lines.Count -ge 1) { [string]$lines[0] } else { '' }
        $d = if ($lines.Count -ge 2) { [string]$lines[1] } else { '' }
        return @($a,$d)
    } catch {
        return @('Initialisiere ...','')
    }
}

function DetailColor([string]$text) {
    if ($text -like '[[]OK[]]*')      { return '38;2;105;255;150' }
    if ($text -like '[[]WARNUNG[]]*') { return '38;2;255;205;70' }
    if ($text -like '[[]FEHLER[]]*')  { return '38;2;255;90;110' }
    return '38;2;150;155;172'
}

try {
    [Console]::CursorVisible = $false
} catch {}

# Disable line wrap where supported and clear once. From here on there is no
# full-screen clear, only direct cursor-positioned updates.
[Console]::Write("$esc[?7l$esc[2J$esc[H$esc[?25l")

$sw = [Diagnostics.Stopwatch]::StartNew()
$lastStatusKey = $null
$lastW = -1
$lastH = -1

try {
    while (-not (Test-Path -LiteralPath $StopFile) -and (Test-ParentAlive)) {
        $layout = Get-Layout
        $phase = ($sw.Elapsed.TotalSeconds * 0.085) % 1.0
        $sb = [System.Text.StringBuilder]::new(32768)

        # Clear only when the terminal geometry changes.
        if ($layout.Width -ne $lastW -or $layout.Height -ne $lastH) {
            [void]$sb.Append("$esc[2J$esc[H")
            $lastW = $layout.Width
            $lastH = $layout.Height
            $lastStatusKey = $null
        }

        # HEADER: 2 animated neon rows + 2 inward rows that fade to black.
        Add-GradientRow $sb 1 $head1 1.00 $phase $layout.DrawWidth
        Add-GradientRow $sb 2 $head2 0.88 ($phase + 0.035) $layout.DrawWidth
        Add-GradientRow $sb 3 ''     0.36 ($phase + 0.070) $layout.DrawWidth
        Add-GradientRow $sb 4 ''     0.10 ($phase + 0.105) $layout.DrawWidth

        # FOOTER: symmetric black-to-neon transition toward the bottom edge.
        Add-GradientRow $sb $layout.Footer1 ''     0.10 ($phase + 0.105) $layout.DrawWidth
        Add-GradientRow $sb $layout.Footer2 ''     0.36 ($phase + 0.070) $layout.DrawWidth
        Add-GradientRow $sb $layout.Footer3 $foot3 0.88 ($phase + 0.035) $layout.DrawWidth
        Add-GradientRow $sb $layout.Footer4 $foot4 1.00 $phase $layout.DrawWidth

        # The renderer owns all terminal output. Status is pulled from a tiny file,
        # so batch commands cannot fight the animation for the cursor.
        $status = Read-Status
        $key = "$($status[0])`n$($status[1])@$($layout.Body1),$($layout.Body2),$($layout.Width)"
        if ($key -ne $lastStatusKey) {
            Add-CenteredStatus $sb $layout.Body1 $status[0] '38;2;80;225;255' $layout.Width
            Add-CenteredStatus $sb $layout.Body2 $status[1] (DetailColor $status[1]) $layout.Width
            $lastStatusKey = $key
        }

        [Console]::Write($sb.ToString())
        Start-Sleep -Milliseconds 65
    }
}
finally {
    [Console]::Write("$esc[0m$esc[?7h$esc[?25h")
    try { [Console]::CursorVisible = $true } catch {}
}
