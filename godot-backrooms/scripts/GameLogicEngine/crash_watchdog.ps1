# Crash watchdog for The Backrooms: Nullspace. crash_guard.gd copies this to user://crash/ and runs it hidden
# (Windows PowerShell 5.1, nothing to install). It waits for the game to end: a clean exit leaves run_<pid>.clean
# and it goes quietly; anything else is a crash, so it builds a report from the game's own log (flushed line by
# line, so it holds the last thing the game said) and shows it in a window at once.
# Keep this file ASCII: Windows PowerShell reads a file without a BOM in the ANSI code page.
param(
    [int]$GamePid,
    [string]$Dir,
    [string]$Reports,
    [string]$EngineLog,
    [switch]$NoWindow,
    [switch]$Editor
)
$ErrorActionPreference = 'SilentlyContinue'

try { $proc = Get-Process -Id $GamePid -ErrorAction Stop } catch { exit }
$null = $proc.Handle        # holding a handle now is what makes ExitCode / ExitTime readable after it ends
$proc.WaitForExit()

$base = Join-Path $Dir ('run_' + $GamePid)
if (Test-Path ($base + '.clean')) { Remove-Item ($base + '.clean') -Force; exit }
# the editor's Stop button (or the player ending it from outside) is not a crash: exit code 1 or Ctrl+C, nothing to report
$code = 0
try { $code = [BitConverter]::ToUInt32([BitConverter]::GetBytes([int]$proc.ExitCode), 0) } catch {}
if ($Editor -and ($code -eq 1 -or $code -eq 3221225786)) {
    foreach ($e in @('.json', '.log', '.alive', '.reported', '.report.txt')) { Remove-Item ($base + $e) -Force }
    exit
}
Set-Content -Path ($base + '.reported') -Value 'watchdog'      # first: a restart from the window must not show it twice

# ---- what happened --------------------------------------------------------------------------------------------
$hex = 'unknown'
try { $hex = '0x{0:X8}' -f [BitConverter]::ToUInt32([BitConverter]::GetBytes([int]$proc.ExitCode), 0) } catch {}
$meanings = @{
    '0xC0000005' = 'access violation: the engine or a driver touched memory it does not own'
    '0xC0000374' = 'heap corruption: memory was damaged earlier, usually by two threads using the same thing at once'
    '0xC000001D' = 'fatal engine error: Godot stopped itself on purpose (most often the graphics card / driver was lost)'
    '0xC0000409' = 'fail-fast stop inside a module (very often the graphics driver)'
    '0xC00000FD' = 'stack overflow: endless recursion'
    '0xE06D7363' = 'unhandled C++ exception (usually from a driver or a system library)'
    '0xC0000017' = 'out of memory'
    '0xC000012D' = 'out of memory (the page file is full)'
    '0x887A0005' = 'the graphics card was removed or reset by Windows (driver crash)'
    '0x887A0006' = 'the graphics card hung (driver timeout)'
    '0x887A0007' = 'the graphics card was reset'
    '0xC0000142' = 'a system library failed to start'
    '0xC000013A' = 'stopped with Ctrl+C, or its console was closed'
    '0x80000003' = 'breakpoint / assertion'
    '0x00000001' = 'ended from outside (Task Manager "End task") or a fatal error while starting'
    '0x00000000' = 'the game exited by itself but skipped the normal shutdown'
}
$meaning = $meanings[$hex]
if (-not $meaning) { $meaning = 'unrecognised exit code' }

$info = $null
try { $info = Get-Content ($base + '.json') -Raw -Encoding UTF8 | ConvertFrom-Json } catch {}
$log = @()
if (Test-Path ($base + '.log')) { $log = @(Get-Content ($base + '.log') -Encoding UTF8) }
$engine = @()
if ($EngineLog -and (Test-Path $EngineLog)) { $engine = @(Get-Content $EngineLog -Encoding UTF8 -Tail 60) }
$beat = -1
if (Test-Path ($base + '.alive')) { $beat = [int]((Get-Content ($base + '.alive') -Raw).Trim()) }
$ran = -1
try { $ran = [int]($proc.ExitTime - $proc.StartTime).TotalSeconds } catch {}

$all = $log + $engine
$verdict = 'a crash inside the engine or a driver (see the last step and the errors before it)'
if (@($all | Where-Object { $_ -match 'device was lost|VK_ERROR_DEVICE_LOST|DEVICE_REMOVED|0x887a000[567]' }).Count -gt 0) {
    $verdict = 'the graphics card / driver stopped responding (GPU lost): update the graphics driver, try a lower preset'
} elseif (@($all | Where-Object { $_ -match 'out of memory|ERR_OUT_OF_MEMORY|Failed to allocate' }).Count -gt 0) {
    $verdict = 'the game ran out of memory'
} elseif ($hex -eq '0x00000001' -and $beat -ge 0 -and $ran -ge 0 -and ($ran - $beat) -gt 20) {
    $verdict = ('the game FROZE: it stopped responding about {0} s before it was closed' -f ($ran - $beat))
} elseif ($hex -eq '0x00000001') {
    $verdict = 'it was closed from outside (End task) while still responding'
}
$step = $log | Where-Object { $_ -like '`[boot *' } | Select-Object -Last 1
if (-not $step) { $step = '(no step recorded: it died while starting up)' }

# the last 15 errors / warnings, each with its "at:" line and call stack (the lines indented under it)
$blocks = New-Object System.Collections.ArrayList
$cur = $null
foreach ($l in $log) {
    if ($l -match '^(ERROR|WARNING|SCRIPT ERROR|SHADER ERROR)') {
        $cur = New-Object System.Collections.ArrayList
        [void]$cur.Add($l)
        [void]$blocks.Add($cur)
    } elseif ($cur -ne $null -and $l -match '^\s') {
        [void]$cur.Add($l)
    } else {
        $cur = $null
    }
}
$errors = @()
foreach ($b in @($blocks | Select-Object -Last 15)) { $errors += $b }
if ($errors.Count -eq 0) { $errors = @('(none)') }

function Field($name) { if ($info -and $info.$name) { return [string]$info.$name } else { return '?' } }

$r = New-Object System.Collections.Generic.List[string]
$r.Add('THE BACKROOMS: NULLSPACE - CRASH REPORT')
$r.Add('')
$r.Add('Crashed:      ' + (Get-Date -Format 'yyyy-MM-dd HH:mm:ss') + ('   (ran for {0} s, last heartbeat at {1} s)' -f $ran, $beat))
$r.Add('Build:        ' + (Field 'build') + '   engine ' + (Field 'engine'))
$r.Add('PC:           ' + (Field 'os') + ' // ' + (Field 'cpu') + ' // ' + (Field 'ram_mb') + ' MB RAM')
$r.Add('GPU:          ' + (Field 'gpu'))
$r.Add('Exit code:    ' + $hex + ' - ' + $meaning)
$r.Add('Verdict:      ' + $verdict)
$r.Add('Last step:    ' + $step)
$r.Add('')
$r.Add('== Errors and warnings (newest last)')
foreach ($l in $errors) { $r.Add($l) }
$r.Add('')
$r.Add('== The end of the game''s log')
foreach ($l in @($log | Select-Object -Last 80)) { $r.Add($l) }
$r.Add('')
$r.Add('== The end of the engine log (' + $EngineLog + ')')
foreach ($l in @($engine | Select-Object -Last 40)) { $r.Add($l) }
$report = [string]::Join("`r`n", $r)

$utf8 = New-Object System.Text.UTF8Encoding($false)
[IO.File]::WriteAllText($base + '.report.txt', $report, $utf8)
$null = New-Item -ItemType Directory -Force -Path $Reports
$out = Join-Path $Reports ('crash_' + (Get-Date -Format 'yyyy-MM-ddTHH-mm-ss') + '_' + $GamePid + '_summary.txt')
[IO.File]::WriteAllText($out, $report, $utf8)
if ($NoWindow) { exit }

# ---- the window -------------------------------------------------------------------------------------------------
Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing
[System.Windows.Forms.Application]::EnableVisualStyles()
$bg = [System.Drawing.Color]::FromArgb(16, 16, 14)
$panel = [System.Drawing.Color]::FromArgb(30, 30, 27)
$cream = [System.Drawing.Color]::FromArgb(230, 225, 205)
$dim = [System.Drawing.Color]::FromArgb(150, 146, 132)
$red = [System.Drawing.Color]::FromArgb(196, 39, 31)

$form = New-Object System.Windows.Forms.Form
$form.Text = 'The Backrooms: Nullspace - crash report'
$form.StartPosition = 'CenterScreen'
$form.Size = New-Object System.Drawing.Size(1000, 700)
$form.MinimumSize = New-Object System.Drawing.Size(640, 420)
$form.BackColor = $bg
$form.ForeColor = $cream
$form.TopMost = $true
$form.Font = New-Object System.Drawing.Font('Segoe UI', 10)
try { if ($info.exe) { $form.Icon = [System.Drawing.Icon]::ExtractAssociatedIcon([string]$info.exe) } } catch {}

$grid = New-Object System.Windows.Forms.TableLayoutPanel
$grid.Dock = 'Fill'
$grid.Padding = New-Object System.Windows.Forms.Padding(16, 12, 16, 8)
$grid.ColumnCount = 1
$grid.RowCount = 4
[void]$grid.RowStyles.Add((New-Object System.Windows.Forms.RowStyle('AutoSize')))
[void]$grid.RowStyles.Add((New-Object System.Windows.Forms.RowStyle('AutoSize')))
[void]$grid.RowStyles.Add((New-Object System.Windows.Forms.RowStyle('Percent', 100)))
[void]$grid.RowStyles.Add((New-Object System.Windows.Forms.RowStyle('AutoSize')))
$form.Controls.Add($grid)

$head = New-Object System.Windows.Forms.Label
$head.Text = 'The game crashed.'
$head.Font = New-Object System.Drawing.Font('Segoe UI', 18, [System.Drawing.FontStyle]::Bold)
$head.ForeColor = $red
$head.AutoSize = $true
$head.Margin = New-Object System.Windows.Forms.Padding(0, 0, 0, 6)
$grid.Controls.Add($head, 0, 0)

$sub = New-Object System.Windows.Forms.Label
$sub.Text = "What happened:  $meaning ($hex)`r`nVerdict:  $verdict`r`nIt was doing:  $step`r`n`r`nThe full report is below and saved in the crash folder. Send it to the developer (Copy report)."
$sub.AutoSize = $true
$sub.MaximumSize = New-Object System.Drawing.Size(940, 0)
$sub.Margin = New-Object System.Windows.Forms.Padding(0, 0, 0, 10)
$grid.Controls.Add($sub, 0, 1)

$box = New-Object System.Windows.Forms.TextBox
$box.Multiline = $true
$box.ReadOnly = $true
$box.WordWrap = $false
$box.ScrollBars = 'Both'
$box.Dock = 'Fill'
$box.BackColor = $panel
$box.ForeColor = $cream
$box.BorderStyle = 'FixedSingle'
$box.Font = New-Object System.Drawing.Font('Consolas', 9.5)
$box.Text = $report
$grid.Controls.Add($box, 0, 2)

$bar = New-Object System.Windows.Forms.FlowLayoutPanel
$bar.FlowDirection = 'RightToLeft'
$bar.AutoSize = $true
$bar.Dock = 'Fill'
$bar.Margin = New-Object System.Windows.Forms.Padding(0, 10, 0, 0)
$grid.Controls.Add($bar, 0, 3)

function Add-Button($text, $action) {
    $b = New-Object System.Windows.Forms.Button
    $b.Text = $text
    $b.AutoSize = $true
    $b.Padding = New-Object System.Windows.Forms.Padding(10, 4, 10, 4)
    $b.Margin = New-Object System.Windows.Forms.Padding(8, 0, 0, 0)
    $b.FlatStyle = 'Flat'
    $b.FlatAppearance.BorderColor = $dim
    $b.BackColor = $panel
    $b.ForeColor = $cream
    $b.Add_Click($action)
    $bar.Controls.Add($b)
    return $b
}
$close = Add-Button 'Close' { $form.Close() }
$form.AcceptButton = $close
$form.CancelButton = $close
if ($info -and $info.exe -and (Test-Path ([string]$info.exe))) {
    $null = Add-Button 'Restart the game' {
        $exe = [string]$info.exe
        $argv = @($info.args | ForEach-Object { if ([string]$_ -match '\s') { '"' + $_ + '"' } else { [string]$_ } })
        if ($argv.Count -gt 0) { Start-Process -FilePath $exe -ArgumentList $argv -WorkingDirectory (Split-Path $exe) }
        else { Start-Process -FilePath $exe -WorkingDirectory (Split-Path $exe) }
        $form.Close()
    }
}
$null = Add-Button 'Open crash folder' { Start-Process explorer.exe -ArgumentList ('/select,"' + $out + '"') }
$copy = Add-Button 'Copy report' {
    try { [System.Windows.Forms.Clipboard]::SetText($report); $copy.Text = 'Copied' } catch { $copy.Text = 'Could not copy' }
}

$form.Add_Shown({ $form.Activate(); $close.Focus() })
[void]$form.ShowDialog()
