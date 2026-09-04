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

$parentPid = 0
try {
    $parentPid = (Get-CimInstance Win32_Process -Filter "ProcessId=$PID").ParentProcessId
} catch {}

function Test-ParentAlive {
    if ($parentPid -le 0) { return $true }
    return $null -ne (Get-Process -Id $parentPid -ErrorAction SilentlyContinue)
}

function Get-Layout {
    $w = [Math]::Max(40, [Console]::WindowWidth)
    $h = [Math]::Max(12, [Console]::WindowHeight)
    $dw = [Math]::Max(1, $w - 1)

    $footer1 = [Math]::Max(8, $h - 4)
    $footer2 = [Math]::Max(9, $h - 3)
    $footer3 = [Math]::Max(10, $h - 2)
    $footer4 = [Math]::Max(11, $h - 1)
    $footer5 = $h

    [pscustomobject]@{
        Width=$w
        DrawWidth=$dw
        Height=$h
        BodyStart=5
        BodyEnd=[Math]::Max(6, $footer1 - 1)
        Footer1=$footer1
        Footer2=$footer2
        Footer3=$footer3
        Footer4=$footer4
        Footer5=$footer5
    }
}

if ($Mode -eq 'PathUpdater') {
    $head1 = 'C:\PS  //  SYSTEM PATH UPDATER'
    $head2 = 'Command-Erkennung  //  Machine PATH'
    $foot1 = 'C:\PS  //  Automatische Command-Erkennung'
    $foot2 = 'Nur Verzeichnisse mit EXE/CMD/BAT/COM werden in PATH aufgenommen'
} else {
    $head1 = 'C:\PS  //  POWERSHELL TOOLS INSTALLER'
    $head2 = 'PsTools  //  Tool Manager  //  SYSTEM PATH'
    $foot1 = 'C:\PS  //  PsTools  //  binaries  //  Tool Manager'
    $foot2 = 'Downloads direkt von den jeweiligen Originalquellen'
}

$stops = @(
    @(8, 10, 48),
    @(10, 28, 104),
    @(8, 78, 158),
    @(42, 50, 166),
    @(104, 28, 168),
    @(170, 26, 144),
    @(186, 42, 116),
    @(124, 30, 166),
    @(26, 66, 164),
    @(8, 10, 48)
)

function Get-RgbKeyAt([double]$x, [double]$phase, [double]$brightness) {
    $cycle = $stops.Count - 1
    $p = (($x + $phase) % 1.0)
    if ($p -lt 0) { $p += 1.0 }

    $scaled = $p * $cycle
    $segment = [Math]::Min([int][Math]::Floor($scaled), $cycle - 1)
    $t = $scaled - $segment
    $a = $stops[$segment]
    $b = $stops[$segment + 1]

    $r = [int][Math]::Round(($a[0] + (($b[0] - $a[0]) * $t)) * $brightness)
    $g = [int][Math]::Round(($a[1] + (($b[1] - $a[1]) * $t)) * $brightness)
    $bl = [int][Math]::Round(($a[2] + (($b[2] - $a[2]) * $t)) * $brightness)

    $r = [Math]::Min(190, [Math]::Max(0, $r))
    $g = [Math]::Min(150, [Math]::Max(0, $g))
    $bl = [Math]::Min(180, [Math]::Max(0, $bl))

    return "$r;$g;$bl"
}

function Add-GradientRow(
    [System.Text.StringBuilder]$Builder,
    [int]$Row,
    [string]$Text,
    [double]$Brightness,
    [double]$Phase,
    [int]$DrawWidth
) {
    if ($Row -lt 1) { return }
    if ($null -eq $Text) { $Text = '' }

    if ($Text.Length -gt ($DrawWidth - 2)) {
        $Text = $Text.Substring(0, [Math]::Max(0, $DrawWidth - 5)) + '...'
    }

    $start = [Math]::Max(0, [int][Math]::Floor(($DrawWidth - $Text.Length) / 2))
    $den = [Math]::Max(1, $DrawWidth - 1)
    $cellWidth = $(if ($DrawWidth -ge 180) { 3 } else { 2 })

    [void]$Builder.Append("$esc[$Row;1H")

    for ($i = 0; $i -lt $DrawWidth; $i += $cellWidth) {
        $run = [Math]::Min($cellWidth, $DrawWidth - $i)
        $sample = [Math]::Min($DrawWidth - 1, $i + (($run - 1) / 2.0))
        $key = Get-RgbKeyAt ($sample / [double]$den) $Phase $Brightness
        [void]$Builder.Append("$esc[48;2;$key" + 'm')

        for ($j = 0; $j -lt $run; $j++) {
            $column = $i + $j
            $textIndex = $column - $start
            if ($textIndex -ge 0 -and $textIndex -lt $Text.Length) {
                [void]$Builder.Append("$esc[38;2;255;255;255m")
                [void]$Builder.Append($Text[$textIndex])
            } else {
                [void]$Builder.Append(' ')
            }
        }
    }

    [void]$Builder.Append("$esc[0m")
}

function Limit-Text([string]$Text, [int]$Width) {
    if ($null -eq $Text) { return '' }
    $limit = [Math]::Max(1, $Width - 4)
    if ($Text.Length -le $limit) { return $Text }
    if ($limit -le 3) { return $Text.Substring(0, $limit) }
    return $Text.Substring(0, $limit - 3) + '...'
}

function Add-CenteredLine(
    [System.Text.StringBuilder]$Builder,
    [int]$Row,
    [string]$Text,
    [string]$Color,
    [int]$Width
) {
    $Text = Limit-Text $Text $Width
    $col = [Math]::Max(1, [int][Math]::Floor(($Width - $Text.Length) / 2) + 1)
    [void]$Builder.Append("$esc[$Row;1H$esc[2K")
    [void]$Builder.Append("$esc[$Row;${col}H$esc[$Color" + "m$Text$esc[0m")
}

$script:CachedState = [pscustomobject]@{
    action='Initialisiere ...'
    detail=''
    menu=@()
    hint=''
}
$script:CachedStateStamp = -1L

function Read-StateCached {
    if (-not (Test-Path -LiteralPath $StatusFile)) {
        return $script:CachedState
    }

    try {
        $item = Get-Item -LiteralPath $StatusFile -ErrorAction Stop
        $stamp = $item.LastWriteTimeUtc.Ticks
        if ($stamp -eq $script:CachedStateStamp) {
            return $script:CachedState
        }

        $raw = Get-Content -LiteralPath $StatusFile -Raw -Encoding UTF8 -ErrorAction Stop
        if ([string]::IsNullOrWhiteSpace($raw)) {
            return $script:CachedState
        }

        $state = $raw | ConvertFrom-Json -ErrorAction Stop
        $menu = @()
        if ($null -ne $state.menu) { $menu = @($state.menu) }

        $script:CachedState = [pscustomobject]@{
            action=[string]$state.action
            detail=[string]$state.detail
            menu=$menu
            hint=[string]$state.hint
        }
        $script:CachedStateStamp = $stamp
    } catch {}

    return $script:CachedState
}

function Detail-Color([string]$Text) {
    if ($Text -like '[[]OK[]]*')      { return '38;2;105;255;150' }
    if ($Text -like '[[]WARNUNG[]]*') { return '38;2;255;205;70' }
    if ($Text -like '[[]FEHLER[]]*')  { return '38;2;255;90;110' }
    return '38;2;150;155;172'
}

try { [Console]::CursorVisible = $false } catch {}
[Console]::Write("$esc[?7l$esc[2J$esc[H$esc[?25l")

$clock = [Diagnostics.Stopwatch]::StartNew()
$lastWidth = -1
$lastHeight = -1
$lastBodyKey = $null
$lastStatePollMs = -1000.0
$state = $script:CachedState
$frameMs = 33.333
$nextFrameMs = 0.0

try {
    while (-not (Test-Path -LiteralPath $StopFile) -and (Test-ParentAlive)) {
        $layout = Get-Layout
        $phase = ($clock.Elapsed.TotalSeconds * 0.34) % 1.0
        $builder = New-Object System.Text.StringBuilder 24576

        if ($layout.Width -ne $lastWidth -or $layout.Height -ne $lastHeight) {
            [void]$builder.Append("$esc[2J$esc[H")
            $lastWidth = $layout.Width
            $lastHeight = $layout.Height
            $lastBodyKey = $null
        }

        Add-GradientRow $builder 1 $head1 1.00 $phase $layout.DrawWidth
        Add-GradientRow $builder 2 $head2 0.82 ($phase + 0.030) $layout.DrawWidth
        Add-GradientRow $builder 3 ''     0.28 ($phase + 0.060) $layout.DrawWidth
        Add-GradientRow $builder 4 ''     0.055 ($phase + 0.090) $layout.DrawWidth

        Add-GradientRow $builder $layout.Footer1 $foot1 0.90 ($phase + 0.020) $layout.DrawWidth
        Add-GradientRow $builder $layout.Footer2 $foot2 0.60 ($phase + 0.050) $layout.DrawWidth
        Add-GradientRow $builder $layout.Footer3 ''     0.30 ($phase + 0.080) $layout.DrawWidth
        Add-GradientRow $builder $layout.Footer4 ''     0.11 ($phase + 0.110) $layout.DrawWidth
        Add-GradientRow $builder $layout.Footer5 ''     0.025 ($phase + 0.140) $layout.DrawWidth

        $nowMs = $clock.Elapsed.TotalMilliseconds
        if (($nowMs - $lastStatePollMs) -ge 80.0) {
            $state = Read-StateCached
            $lastStatePollMs = $nowMs
        }

        $bodyKey = ($state | ConvertTo-Json -Compress -Depth 4) + "@$($layout.Width)x$($layout.Height)"

        if ($bodyKey -ne $lastBodyKey) {
            for ($row = $layout.BodyStart; $row -le $layout.BodyEnd; $row++) {
                [void]$builder.Append("$esc[$row;1H$esc[2K")
            }

            $available = [Math]::Max(1, $layout.BodyEnd - $layout.BodyStart + 1)
            $menuLines = @($state.menu)
            $needed = 2 + $menuLines.Count + $(if ($state.hint) { 1 } else { 0 })
            $startRow = $layout.BodyStart + [Math]::Max(0, [int][Math]::Floor(($available - $needed) / 2))

            Add-CenteredLine $builder $startRow $state.action '38;2;80;225;255' $layout.Width
            Add-CenteredLine $builder ($startRow + 1) $state.detail (Detail-Color $state.detail) $layout.Width

            $row = $startRow + 3
            foreach ($line in $menuLines) {
                if ($row -gt $layout.BodyEnd) { break }

                $color = '38;2;210;210;225'
                if ($line -like '> *') { $color = '38;2;255;110;215' }
                elseif ($line -match '\[x\]') { $color = '38;2;105;255;150' }
                elseif ($line -match '\[!\]') { $color = '38;2;255;205;70' }

                Add-CenteredLine $builder $row ([string]$line) $color $layout.Width
                $row++
            }

            if ($state.hint -and $layout.BodyEnd -ge $row) {
                Add-CenteredLine $builder $layout.BodyEnd $state.hint '38;2;120;125;145' $layout.Width
            }

            $lastBodyKey = $bodyKey
        }

        [Console]::Write($builder.ToString())

        $nextFrameMs += $frameMs
        $delay = $nextFrameMs - $clock.Elapsed.TotalMilliseconds
        if ($delay -gt 1.0) {
            Start-Sleep -Milliseconds ([int][Math]::Floor($delay))
        } elseif ($delay -lt -100.0) {
            $nextFrameMs = $clock.Elapsed.TotalMilliseconds
        }
    }
}
finally {
    [Console]::Write("$esc[0m$esc[?7h$esc[?25h")
    try { [Console]::CursorVisible = $true } catch {}
}
