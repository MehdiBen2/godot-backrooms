# One-click publisher, dressed like the launcher: the VCR font, cream on near-black over the background
# picture, a REC tag, red for the action. Version + notes + PUBLISH; runs tools\publish.ps1 in the background
# and follows it on a progress bar. Start it by double-clicking Publish.bat in the repo root.
#
# The bar follows what publish.ps1 is really doing (it appends each stage's name to a status file):
#   check   gh signed in, the version free                      a moment
#   export  Godot writes build\game\backrooms.pck               its size against the last export's
#   zip     Compress-Archive writes build\backrooms-windows.zip its size against the last zip's
#   upload  gh uploads the zip (it prints nothing meanwhile)     time against the last upload's speed
# Sizes and the upload speed are remembered after each publish (%LOCALAPPDATA%\BackroomsPublisher).
Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing
Add-Type -ReferencedAssemblies System.Windows.Forms, System.Drawing -TypeDefinition @"
using System;
using System.Runtime.InteropServices;
using System.Windows.Forms;
public class PubCanvas : Panel {
    public PubCanvas() {
        SetStyle(ControlStyles.AllPaintingInWmPaint | ControlStyles.OptimizedDoubleBuffer | ControlStyles.ResizeRedraw
            | ControlStyles.UserPaint | ControlStyles.SupportsTransparentBackColor, true);
    }
}
public static class PubWin {
    [DllImport("user32.dll")] public static extern bool ReleaseCapture();
    [DllImport("user32.dll")] public static extern IntPtr SendMessage(IntPtr h, int msg, int w, int l);
    public static void Drag(IntPtr h) { ReleaseCapture(); SendMessage(h, 0xA1, 0x2, 0); }
}
"@
[Windows.Forms.Application]::EnableVisualStyles()

$root = Split-Path $PSScriptRoot -Parent
$repo = "MehdiBen2/godot-backrooms"
$log = Join-Path $env:TEMP "backrooms_publish.log"
$err = Join-Path $env:TEMP "backrooms_publish.err"
$statusFile = Join-Path $env:TEMP "backrooms_publish.status"
$notesFile = Join-Path $env:TEMP "backrooms_publish_notes.txt"
$pck = Join-Path $root "build\game\backrooms.pck"
$zip = Join-Path $root "build\backrooms-windows.zip"
$statsDir = Join-Path $env:LOCALAPPDATA "BackroomsPublisher"
$statsPath = Join-Path $statsDir "stats.json"

# ---- palette and type (launcher.gd) ------------------------------------------------------------
function C([string]$hex, [int]$a = 255) { $c = [Drawing.ColorTranslator]::FromHtml("#$hex"); [Drawing.Color]::FromArgb($a, $c) }
$CREAM = C "e6e1cd"; $TITLE = C "d8d3bd"; $RED = C "c4271f"; $RED_HOT = C "e0453b"; $RED_DARK = C "8f1c16"
$REC = C "ff3b30"; $AMBER = C "ffc107"; $GREEN = C "7fae72"; $BLACK = C "030302"
function Ink([int]$a) { [Drawing.Color]::FromArgb($a, 230, 225, 205) }
function Mix([Drawing.Color]$a, [Drawing.Color]$b, [double]$k) {
    [Drawing.Color]::FromArgb(255, [int]($a.R + ($b.R - $a.R) * $k), [int]($a.G + ($b.G - $a.G) * $k), [int]($a.B + ($b.B - $a.B) * $k))
}
$FIELD = C "0e0e0b"                 # input fill: near-black, opaque (a native text box can't be see-through)

$fonts = New-Object Drawing.Text.PrivateFontCollection
$vcrPath = Join-Path $root "launcher\fonts\vcr.ttf"
if (Test-Path $vcrPath) { $fonts.AddFontFile($vcrPath) }
$fontCache = @{}
function Vcr([float]$px) {       # (kept: the paint handlers ask for these every frame)
    if (-not $fontCache.ContainsKey($px)) {
        $fontCache[$px] = if ($fonts.Families.Count -gt 0) { New-Object Drawing.Font($fonts.Families[0], $px, [Drawing.GraphicsUnit]::Pixel) } `
            else { New-Object Drawing.Font("Consolas", $px, [Drawing.GraphicsUnit]::Pixel) }
    }
    return $fontCache[$px]
}
$MONO = New-Object Drawing.Font("Consolas", 13, [Drawing.GraphicsUnit]::Pixel)
$UI = New-Object Drawing.Font("Segoe UI", 13, [Drawing.GraphicsUnit]::Pixel)

# ---- remembered sizes and upload speed --------------------------------------------------------
$stats = @{ pck = 680MB; zip = 380MB; upload_bps = 3MB }
if (Test-Path $statsPath) {
    try { $j = Get-Content $statsPath -Raw | ConvertFrom-Json; foreach ($k in @("pck", "zip", "upload_bps")) { if ($j.$k -gt 0) { $stats[$k] = [double]$j.$k } } } catch { }
}

# ---- window -----------------------------------------------------------------------------------
$W = 760; $H = 560
$form = New-Object Windows.Forms.Form
$form.Text = "Backrooms - Publish"
$form.FormBorderStyle = "None"
$form.ClientSize = New-Object Drawing.Size($W, $H)
$form.StartPosition = "CenterScreen"
$form.BackColor = $BLACK
$form.ForeColor = $CREAM
$form.Font = $UI
$iconPath = Join-Path $root "launcher\icon.ico"
if (Test-Path $iconPath) { $form.Icon = New-Object Drawing.Icon($iconPath) }
$form.GetType().GetProperty("DoubleBuffered", [Reflection.BindingFlags]"Instance,NonPublic").SetValue($form, $true, $null)

# The backdrop, composed once: the launcher's picture covering the window, lifted a little, a veil at the
# top for the title bar, the bottom fading to near-black behind the controls, a hairline frame.
$bg = New-Object Drawing.Bitmap($W, $H)
$g = [Drawing.Graphics]::FromImage($bg)
$g.Clear($BLACK)
$pic = Join-Path $root "launcher\img\background.png"
if (Test-Path $pic) {
    $img = [Drawing.Image]::FromFile($pic)
    $s = [Math]::Max($W / $img.Width, $H / $img.Height)
    $iw = $img.Width * $s; $ih = $img.Height * $s
    $cm = New-Object Drawing.Imaging.ColorMatrix
    $cm.Matrix00 = 1.8; $cm.Matrix11 = 1.7; $cm.Matrix22 = 1.5          # the same lift as the launcher's
    $ia = New-Object Drawing.Imaging.ImageAttributes
    $ia.SetColorMatrix($cm)
    $g.DrawImage($img, (New-Object Drawing.Rectangle([int](($W - $iw) / 2), [int](($H - $ih) / 2), [int]$iw, [int]$ih)), 0, 0, $img.Width, $img.Height, [Drawing.GraphicsUnit]::Pixel, $ia)
    $img.Dispose()
}
function Fade([int]$y0, [int]$y1, [int]$a0, [int]$a1) {
    $r = New-Object Drawing.Rectangle(0, $y0, $W, ($y1 - $y0))
    $b = New-Object Drawing.Drawing2D.LinearGradientBrush($r, [Drawing.Color]::FromArgb($a0, 3, 3, 2), [Drawing.Color]::FromArgb($a1, 3, 3, 2), 90.0)
    $g.FillRectangle($b, $r); $b.Dispose()
}
Fade 0 120 200 40
Fade 120 260 40 185
$g.FillRectangle((New-Object Drawing.SolidBrush([Drawing.Color]::FromArgb(235, 3, 3, 2))), 0, 260, $W, $H - 260)
# faint scanlines, like the game's camcorder
$sl = New-Object Drawing.Pen([Drawing.Color]::FromArgb(18, 0, 0, 0))
for ($y = 0; $y -lt $H; $y += 3) { $g.DrawLine($sl, 0, $y, $W, $y) }
$g.DrawRectangle((New-Object Drawing.Pen((Ink 40))), 0, 0, $W - 1, $H - 1)
$g.Dispose()
$form.BackgroundImage = $bg

function Text([string]$t, [int]$x, [int]$y, $font, [Drawing.Color]$color) {
    $l = New-Object Windows.Forms.Label
    $l.Text = $t; $l.Location = New-Object Drawing.Point($x, $y); $l.AutoSize = $true
    $l.Font = $font; $l.ForeColor = $color; $l.BackColor = [Drawing.Color]::Transparent
    $l.UseCompatibleTextRendering = $true       # (GDI+ text: the only way a private font like the VCR one draws)
    $form.Controls.Add($l)
    return $l
}

# ---- title bar: drag it to move the window; REC on the left, minimise / close on the right -------
$bar = New-Object PubCanvas
$bar.Location = New-Object Drawing.Point(0, 0); $bar.Size = New-Object Drawing.Size(($W - 80), 48)
$bar.BackColor = [Drawing.Color]::Transparent
$bar.Add_MouseDown({ if ($_.Button -eq "Left") { [PubWin]::Drag($form.Handle) } })
$script:blink = 0
$bar.Add_Paint({
    $gg = $_.Graphics
    $gg.SmoothingMode = "AntiAlias"; $gg.TextRenderingHint = "AntiAliasGridFit"
    $on = ($script:proc -eq $null) -or ([int]($script:blink / 5) % 2 -eq 0)     # recording: the dot blinks
    $gg.FillEllipse((New-Object Drawing.SolidBrush($(if ($on) { $REC } else { [Drawing.Color]::FromArgb(70, 255, 59, 48) }))), 28, 19, 11, 11)
    $gg.DrawString("REC", (Vcr 15), (New-Object Drawing.SolidBrush($CREAM)), 46, 16)
    $gg.DrawString("BACKROOMS  //  PUBLISHER", (Vcr 13), (New-Object Drawing.SolidBrush((Ink 120))), 100, 18)
})
$form.Controls.Add($bar)

function WinButton([string]$t, [int]$x, [bool]$close) {
    $b = New-Object Windows.Forms.Label
    $b.Text = $t; $b.TextAlign = "MiddleCenter"; $b.Cursor = "Hand"
    $b.Location = New-Object Drawing.Point($x, 12); $b.Size = New-Object Drawing.Size(34, 26)
    $b.Font = Vcr 15; $b.ForeColor = (Ink 165); $b.BackColor = [Drawing.Color]::Transparent
    $b.UseCompatibleTextRendering = $true
    $hot = if ($close) { [Drawing.Color]::FromArgb(230, 196, 39, 31) } else { (Ink 36) }
    $cold = Ink 165
    $b.Add_MouseEnter({ $this.BackColor = $hot; $this.ForeColor = [Drawing.Color]::White }.GetNewClosure())
    $b.Add_MouseLeave({ $this.BackColor = [Drawing.Color]::Transparent; $this.ForeColor = $cold }.GetNewClosure())
    $form.Controls.Add($b)
    return $b
}
(WinButton "_" ($W - 80) $false).Add_Click({ $form.WindowState = "Minimized" })
(WinButton "X" ($W - 44) $true).Add_Click({ $form.Close() })

# ---- heading ------------------------------------------------------------------------------------
$null = Text "PUBLISH A RELEASE" 40 70 (Vcr 34) $TITLE
$null = Text "Exports the game, zips it and puts it on GitHub. Launchers offer it on their next start." 42 114 $UI (Ink 150)

# ---- checks: three chips (GitHub sign-in, Godot + templates, uncommitted work) --------------------
$chips = New-Object PubCanvas
$chips.Location = New-Object Drawing.Point(40, 148); $chips.Size = New-Object Drawing.Size(($W - 80), 26)
$chips.BackColor = [Drawing.Color]::Transparent
$script:checks = @(@{ name = "GITHUB"; text = "checking"; color = (Ink 120) }, @{ name = "GODOT"; text = "checking"; color = (Ink 120) }, @{ name = "GIT"; text = "checking"; color = (Ink 120) })
$chips.Add_Paint({
    $gg = $_.Graphics
    $gg.SmoothingMode = "AntiAlias"; $gg.TextRenderingHint = "AntiAliasGridFit"
    $x = 0
    foreach ($c in $script:checks) {
        $label = "$($c.name)  $($c.text.ToUpper())"
        $w = [int]$gg.MeasureString($label, (Vcr 12)).Width + 30
        $gg.FillRectangle((New-Object Drawing.SolidBrush([Drawing.Color]::FromArgb(120, 0, 0, 0))), $x, 0, $w, 24)
        $gg.DrawRectangle((New-Object Drawing.Pen([Drawing.Color]::FromArgb(110, $c.color))), $x, 0, $w, 24)
        $gg.FillEllipse((New-Object Drawing.SolidBrush($c.color)), $x + 9, 8, 8, 8)
        $gg.DrawString($label, (Vcr 12), (New-Object Drawing.SolidBrush((Ink 210))), $x + 22, 5)
        $x += $w + 10
    }
})
$form.Controls.Add($chips)

# ---- inputs: version, notes (underlined like the launcher's fields; red under the focused one) ------
$null = Text "VERSION" 40 196 (Vcr 13) (Ink 140)
$ver = New-Object Windows.Forms.TextBox
$ver.Location = New-Object Drawing.Point(40, 218); $ver.Size = New-Object Drawing.Size(200, 26)
$ver.Font = New-Object Drawing.Font("Consolas", 17, [Drawing.GraphicsUnit]::Pixel)
$ver.BorderStyle = "None"; $ver.BackColor = $FIELD; $ver.ForeColor = $CREAM; $ver.Text = "..."
$form.Controls.Add($ver)

$null = Text "WHAT CHANGED" 270 196 (Vcr 13) (Ink 140)
$null = Text "(optional)" 380 197 $UI (Ink 80)
$notes = New-Object Windows.Forms.TextBox
$notes.Location = New-Object Drawing.Point(270, 218); $notes.Size = New-Object Drawing.Size(($W - 310), 96)
$notes.Multiline = $true; $notes.ScrollBars = "None"; $notes.Font = $UI
$notes.BorderStyle = "None"; $notes.BackColor = $FIELD; $notes.ForeColor = $CREAM
$form.Controls.Add($notes)

# the log takes the notes' place while you look at it (DETAILS)
$out = New-Object Windows.Forms.TextBox
$out.Location = New-Object Drawing.Point(40, 192); $out.Size = New-Object Drawing.Size(($W - 80), 128)
$out.Multiline = $true; $out.ReadOnly = $true; $out.ScrollBars = "Vertical"; $out.Font = $MONO
$out.BorderStyle = "None"; $out.BackColor = $FIELD; $out.ForeColor = (Ink 200); $out.Visible = $false
$form.Controls.Add($out)
$out.BringToFront()         # over the field labels

# underlines under the fields, drawn on the form itself
$form.Add_Paint({
    $gg = $_.Graphics
    foreach ($box in @($ver, $notes)) {
        if (-not $box.Visible) { continue }
        $pen = New-Object Drawing.Pen($(if ($box.Focused) { $RED } else { (Ink 80) }), $(if ($box.Focused) { 2 } else { 1 }))
        $gg.DrawLine($pen, $box.Left, $box.Bottom + 5, $box.Right, $box.Bottom + 5)
        $gg.FillRectangle((New-Object Drawing.SolidBrush($FIELD)), $box.Left - 8, $box.Top - 6, $box.Width + 16, $box.Height + 10)
    }
})
foreach ($box in @($ver, $notes)) { $box.Add_Enter({ $form.Invalidate() }); $box.Add_Leave({ $form.Invalidate() }) }

# ---- progress: stage steps, the bar, what it's doing ----------------------------------------------
$STAGES = @(
    @{ id = "check"; name = "CHECK"; w = 0.03 },
    @{ id = "export"; name = "EXPORT"; w = 0.45 },
    @{ id = "chunk"; name = "CHUNK"; w = 0.10 },
    @{ id = "zip"; name = "ZIP"; w = 0.12 },
    @{ id = "upload"; name = "UPLOAD"; w = 0.30 }
)
$script:stage = ""             # the stage running now ("" before, "done" after)
$script:stageAt = @{}          # when each stage was first seen
$script:shown = 0.0            # the bar as drawn: eases toward the real figure
$script:target = 0.0
$script:detail = "READY"
$script:result = ""            # "", "ok", "fail"
$script:started = $null

$prog = New-Object PubCanvas
$prog.Location = New-Object Drawing.Point(40, 340); $prog.Size = New-Object Drawing.Size(($W - 80), 104)
$prog.BackColor = [Drawing.Color]::Transparent
$prog.Add_Paint({
    $gg = $_.Graphics
    $gg.SmoothingMode = "AntiAlias"; $gg.TextRenderingHint = "AntiAliasGridFit"
    $pw = $prog.Width
    # the steps along the top: done ones cream with a tick, the running one red, the rest faint
    $x = 0
    $idx = -1
    for ($i = 0; $i -lt $STAGES.Count; $i++) { if ($STAGES[$i].id -eq $script:stage) { $idx = $i } }
    if ($script:stage -eq "done") { $idx = $STAGES.Count }
    $seg = [int](($pw - 3 * 14) / 4)
    for ($i = 0; $i -lt $STAGES.Count; $i++) {
        $col = if ($script:result -eq "fail" -and $i -eq $idx) { $REC } elseif ($i -lt $idx) { (Ink 220) } elseif ($i -eq $idx) { $RED_HOT } else { (Ink 70) }
        $mark = if ($i -lt $idx) { "+ " } elseif ($i -eq $idx -and $script:result -ne "fail") { "> " } else { "  " }
        $gg.DrawString("$mark$($i + 1). $($STAGES[$i].name)", (Vcr 13), (New-Object Drawing.SolidBrush($col)), $x, 0)
        $gg.FillRectangle((New-Object Drawing.SolidBrush([Drawing.Color]::FromArgb($(if ($i -le $idx) { 200 } else { 50 }), $col))), $x, 22, $seg, 2)
        $x += $seg + 14
    }
    # the bar: a dark track, the red fill with stripes running along it while it works, a bright leading edge
    $by = 40; $bh = 18
    $gg.FillRectangle((New-Object Drawing.SolidBrush([Drawing.Color]::FromArgb(150, 0, 0, 0))), 0, $by, $pw, $bh)
    $gg.DrawRectangle((New-Object Drawing.Pen((Ink 60))), 0, $by, $pw - 1, $bh)
    $fw = [int](($pw - 4) * [Math]::Min(1.0, $script:shown))
    if ($fw -gt 0) {
        $fill = if ($script:result -eq "fail") { $RED_DARK } elseif ($script:result -eq "ok") { $GREEN } else { $RED }
        $gg.FillRectangle((New-Object Drawing.SolidBrush($fill)), 2, $by + 2, $fw, $bh - 4)
        if ($script:result -eq "") {
            $gg.SetClip((New-Object Drawing.Rectangle(2, ($by + 2), $fw, ($bh - 4))))
            $sp = New-Object Drawing.Pen([Drawing.Color]::FromArgb(45, 255, 255, 255), 6)
            $off = ($script:blink * 2) % 24
            for ($sx = -24 + $off; $sx -lt $fw + 24; $sx += 24) { $gg.DrawLine($sp, $sx, $by + $bh, $sx + 14, $by) }
            $gg.ResetClip()
            $gg.FillRectangle((New-Object Drawing.SolidBrush([Drawing.Color]::FromArgb(220, 255, 150, 140))), $fw, $by + 2, 2, $bh - 4)
        }
    }
    # under it: what it's doing on the left, the percentage and the clock on the right
    $gg.DrawString($script:detail, (Vcr 13), (New-Object Drawing.SolidBrush((Ink 200))), 0, $by + $bh + 10)
    $pct = "{0,3}%" -f [int]([Math]::Floor($script:shown * 100))
    $clock = if ($script:started) { $e = (Get-Date) - $script:started; "{0:00}:{1:00}" -f [int][Math]::Floor($e.TotalMinutes), $e.Seconds } else { "00:00" }
    $right = "$pct    $clock"
    $rw = $gg.MeasureString($right, (Vcr 15)).Width
    $gg.DrawString($right, (Vcr 15), (New-Object Drawing.SolidBrush($CREAM)), $pw - $rw, $by + $bh + 8)
})
$form.Controls.Add($prog)

# ---- bottom row: DETAILS (the log) on the left, PUBLISH on the right --------------------------------
$details = New-Object Windows.Forms.Label
$details.Text = "DETAILS"; $details.Cursor = "Hand"; $details.AutoSize = $true
$details.Location = New-Object Drawing.Point(40, ($H - 62)); $details.Font = Vcr 14; $details.ForeColor = (Ink 170)
$details.BackColor = [Drawing.Color]::Transparent; $details.UseCompatibleTextRendering = $true
$details.Add_MouseEnter({ $details.ForeColor = [Drawing.Color]::White })
$details.Add_MouseLeave({ $details.ForeColor = (Ink 170) })
$details.Add_Click({
    $show = -not $out.Visible
    $out.Visible = $show
    $notes.Visible = -not $show
    $ver.Visible = -not $show
    $details.Text = if ($show) { "HIDE DETAILS" } else { "DETAILS" }
    $form.Invalidate()
})
$form.Controls.Add($details)

$btn = New-Object Windows.Forms.Label
$btn.Text = "PUBLISH"; $btn.TextAlign = "MiddleCenter"; $btn.Cursor = "Hand"
$btn.Location = New-Object Drawing.Point(($W - 240), ($H - 76)); $btn.Size = New-Object Drawing.Size(200, 46)
$btn.Font = Vcr 18; $btn.ForeColor = [Drawing.Color]::White; $btn.BackColor = [Drawing.Color]::FromArgb(235, 196, 39, 31)
$btn.UseCompatibleTextRendering = $true
$script:busy = $false
$btn.Add_MouseEnter({ if (-not $script:busy) { $btn.BackColor = $RED_HOT } })
$btn.Add_MouseLeave({ if (-not $script:busy) { $btn.BackColor = [Drawing.Color]::FromArgb(235, 196, 39, 31) } })
$btn.Add_MouseDown({ if (-not $script:busy) { $btn.BackColor = $RED_DARK } })
$btn.Add_Paint({ $_.Graphics.DrawRectangle((New-Object Drawing.Pen($(if ($script:busy) { (Ink 40) } else { $RED_HOT }))), 0, 0, $btn.Width - 1, $btn.Height - 1) })
$form.Controls.Add($btn)

function Set-Busy([bool]$on) {
    $script:busy = $on
    $btn.Text = if ($on) { "PUBLISHING..." } else { "PUBLISH" }
    $btn.BackColor = if ($on) { [Drawing.Color]::FromArgb(140, 0, 0, 0) } else { [Drawing.Color]::FromArgb(235, 196, 39, 31) }
    $btn.ForeColor = if ($on) { (Ink 90) } else { [Drawing.Color]::White }
    $btn.Cursor = if ($on) { "Default" } else { "Hand" }
    $ver.ReadOnly = $on; $notes.ReadOnly = $on
}

function Say([string]$t) { $out.AppendText("$t`r`n") }
function Notice([string]$t) { [Windows.Forms.MessageBox]::Show($t, "Backrooms - Publish") | Out-Null }
function MB([double]$b) { "{0:N0} MB" -f ($b / 1MB) }

# ---- the checks and the next version (on show, and again after a publish) -------------------------
function Get-NextVersion {
    try {
        $tag = (& gh release list --repo $repo --limit 1 --json tagName --jq ".[0].tagName" 2>$null)
        if ($tag -match '^v(\d+)\.(\d+)\.(\d+)$') { return "v$($Matches[1]).$($Matches[2]).$([int]$Matches[3] + 1)" }
    } catch { }
    return "v0.1.0"
}

function Run-Checks {
    $ErrorActionPreference = "Continue"
    # GitHub
    if (-not (Get-Command gh -ErrorAction SilentlyContinue)) {
        $script:checks[0] = @{ name = "GITHUB"; text = "gh not installed"; color = $REC }
    } else {
        $st = (& gh auth status 2>&1 | Out-String)
        if ($LASTEXITCODE -eq 0) {
            $who = if ($st -match 'account (\S+)') { $Matches[1] } elseif ($st -match 'as (\S+)') { $Matches[1] } else { "signed in" }
            $script:checks[0] = @{ name = "GITHUB"; text = $who; color = $GREEN }
        } else {
            $script:checks[0] = @{ name = "GITHUB"; text = "not signed in"; color = $REC }
        }
    }
    # Godot and its export templates (publish.ps1 looks for it the same way)
    $godot = $env:GODOT
    if (-not $godot) { $cmd = Get-Command godot -ErrorAction SilentlyContinue; if ($cmd) { $godot = $cmd.Source } }
    if (-not $godot) { $godot = (Get-ChildItem "$env:USERPROFILE\Desktop" -Filter "Godot_v4*.exe" -ErrorAction SilentlyContinue | Where-Object { $_.Name -notmatch "console" } | Select-Object -First 1).FullName }
    if (-not $godot) {
        $script:checks[1] = @{ name = "GODOT"; text = "not found"; color = $REC }
    } else {
        $v = if ([IO.Path]::GetFileName($godot) -match 'v(\d+\.\d+(\.\d+)?)-([a-z]+)') { "$($Matches[1]).$($Matches[3])" } else { "" }
        $tpl = if ($v) { Test-Path (Join-Path $env:APPDATA "Godot\export_templates\$v\windows_release_x86_64.exe") } else { $true }
        $script:checks[1] = if ($tpl) { @{ name = "GODOT"; text = $(if ($v) { $v -replace '\.stable$', '' } else { "found" }); color = $GREEN } } else { @{ name = "GODOT"; text = "no export templates"; color = $REC } }
    }
    # uncommitted work: the release is tagged at what's on GitHub, the build is made from what's on disk
    $dirty = @(& git -C $root status --porcelain 2>$null | Where-Object { $_ -notmatch '^\?\? (build/|asetsuimprot/)' })
    $script:checks[2] = if ($dirty.Count -eq 0) { @{ name = "GIT"; text = "all committed"; color = $GREEN } } `
        else { @{ name = "GIT"; text = "$($dirty.Count) uncommitted"; color = $AMBER } }
    $chips.Invalidate()
    $ver.Text = Get-NextVersion
}

# ---- following the publish ------------------------------------------------------------------------
$script:proc = $null
$script:lastLog = ""
$timer = New-Object Windows.Forms.Timer
$timer.Interval = 60
$timer.Add_Tick({
    $script:blink++
    if ($script:proc) {
        # the stage: the last name in the status file
        if (Test-Path $statusFile) {
            $lines = @(Get-Content $statusFile -ErrorAction SilentlyContinue | Where-Object { $_ })
            foreach ($l in $lines) { if (-not $script:stageAt.ContainsKey($l)) { $script:stageAt[$l] = Get-Date } }
            if ($lines.Count -gt 0) { $script:stage = $lines[-1].Trim() }
        }
        # how far into it, from what's on disk (or the clock, for the upload)
        $before = 0.0; $w = 0.0; $k = 0.0
        foreach ($s in $STAGES) { if ($s.id -eq $script:stage) { $w = $s.w; break }; $before += $s.w }
        $since = if ($script:stageAt.ContainsKey($script:stage)) { ((Get-Date) - $script:stageAt[$script:stage]).TotalSeconds } else { 0 }
        switch ($script:stage) {
            "check" { $k = [Math]::Min(0.9, $since / 3.0); $script:detail = "CHECKING GITHUB" }
            "export" {
                $size = if (Test-Path $pck) { (Get-Item $pck).Length } else { 0 }
                $k = [Math]::Min(0.98, $size / $stats.pck)
                if ($size -le 0) { $k = 0.04 * (1 - [Math]::Exp(-$since / 8)) }      # Godot is still loading the project
                $script:detail = if ($size -gt 0) { "EXPORTING GAME   $(MB $size) / ~$(MB $stats.pck)" } else { "EXPORTING GAME   STARTING GODOT" }
            }
            "chunk" {
                # hashing and cutting the export: no byte counter to read, so go by the clock
                $k = [Math]::Min(0.95, $since / 45.0)
                $script:detail = "CUTTING GAME INTO CHUNKS"
            }
            "zip" {
                $size = if (Test-Path $zip) { (Get-Item $zip).Length } else { 0 }
                $k = [Math]::Min(0.98, $size / $stats.zip)
                $script:detail = "COMPRESSING   $(MB $size) / ~$(MB $stats.zip)"
            }
            "upload" {
                $size = if (Test-Path $zip) { (Get-Item $zip).Length } else { $stats.zip }
                $expect = [Math]::Max(5.0, $size / $stats.upload_bps)
                $k = [Math]::Min(0.97, $since / $expect)
                if ($since -gt $expect) { $k = 0.97 + 0.02 * (1 - [Math]::Exp(-($since - $expect) / 30)) }
                $left = [Math]::Max(0, [int]($expect - $since))
                $script:detail = if ($left -gt 0) { "UPLOADING TO GITHUB   $(MB $size)   ~$left S LEFT" } else { "UPLOADING TO GITHUB   $(MB $size)   ALMOST THERE" }
            }
        }
        if ($script:stage -eq "done") { $script:target = 1.0 } elseif ($w -gt 0) { $script:target = [Math]::Max($script:target, $before + $w * $k) }
        # the log, every half second or so
        if ($script:blink % 8 -eq 0) {
            $text = ""
            foreach ($f in @($log, $err)) { if (Test-Path $f) { $text += (Get-Content $f -Raw -ErrorAction SilentlyContinue) } }
            if ($text -and $text -ne $script:lastLog) { $script:lastLog = $text; $out.Text = $text; $out.SelectionStart = $out.Text.Length; $out.ScrollToCaret() }
        }
        if ($script:proc.HasExited) { Finish }
    }
    # the drawn bar eases toward the figure, so it never jumps
    $script:shown += ($script:target - $script:shown) * 0.12
    if ([Math]::Abs($script:target - $script:shown) -lt 0.0005) { $script:shown = $script:target }
    $prog.Invalidate()
    if ($script:proc -or $script:blink % 5 -eq 0) { $bar.Invalidate() }
})

function Finish {
    $code = $script:proc.ExitCode
    $text = ""
    foreach ($f in @($log, $err)) { if (Test-Path $f) { $text += (Get-Content $f -Raw -ErrorAction SilentlyContinue) } }
    $out.Text = $text
    if ($code -eq 0) {
        $script:result = "ok"
        $script:target = 1.0
        $script:detail = "PUBLISHED $($script:version). LAUNCHERS WILL OFFER IT ON THEIR NEXT START."
        Say "`r`nDONE. Launchers will offer $($script:version) on their next start."
        # remember the sizes and the upload speed for next time's bar
        try {
            $new = @{ pck = $stats.pck; zip = $stats.zip; upload_bps = $stats.upload_bps }
            if (Test-Path $pck) { $new.pck = (Get-Item $pck).Length }
            if (Test-Path $zip) { $new.zip = (Get-Item $zip).Length }
            if ($script:stageAt.ContainsKey("upload") -and $script:stageAt.ContainsKey("done")) {
                $secs = ($script:stageAt["done"] - $script:stageAt["upload"]).TotalSeconds
                if ($secs -gt 1) { $new.upload_bps = $new.zip / $secs }
            }
            New-Item -ItemType Directory -Force $statsDir | Out-Null
            $new | ConvertTo-Json | Set-Content $statsPath -Encoding utf8
            foreach ($k in $new.Keys) { $stats[$k] = $new[$k] }
        } catch { }
    } else {
        $script:result = "fail"
        # the last thing it said (publish.ps1 throws with the reason)
        $why = ($text -split "`r?`n" | Where-Object { $_ -match '\S' -and $_ -notmatch '^\s*(\+|Au caract|At |CategoryInfo|FullyQualified)' } | Select-Object -Last 1)
        $script:detail = "FAILED: " + $(if ($why) { $why.Trim().ToUpper() } else { "EXIT CODE $code" })
        if ($script:detail.Length -gt 78) { $script:detail = $script:detail.Substring(0, 75) + "..." }
        Say "`r`nFAILED (exit code $code)."
        if (-not $out.Visible) { $details.PerformClick() }      # show what went wrong
    }
    Remove-Item $notesFile, $statusFile -ErrorAction SilentlyContinue
    $script:proc = $null
    Set-Busy $false
    Run-Checks
}

function Start-Publish {
    if ($script:busy) { return }
    if (-not (Get-Command gh -ErrorAction SilentlyContinue)) { Notice "GitHub CLI (gh) not found. Install it with:  winget install GitHub.cli   then run  gh auth login"; return }
    $v = $ver.Text.Trim()
    if ($v -notmatch '^v\d+\.\d+\.\d+$') { Notice "Version must look like v0.1.1"; return }
    if ($script:checks[2].color -eq $AMBER) {
        $a = [Windows.Forms.MessageBox]::Show("There are uncommitted changes. The build is made from the files on disk, but the release is tagged at what's on GitHub.`n`nPublish anyway?", "Backrooms - Publish", "YesNo", "Warning")
        if ($a -ne "Yes") { return }
    }
    $ErrorActionPreference = "Continue"
    gh release view $v --repo $repo *> $null
    if ($LASTEXITCODE -eq 0) { Notice "Release $v already exists on GitHub. Pick a new version."; return }
    Remove-Item $log, $err, $statusFile -ErrorAction SilentlyContinue
    Set-Content -Path $notesFile -Value $notes.Text -Encoding utf8   # a file sidesteps all quoting/escaping issues
    $script:version = $v
    $script:stage = ""; $script:stageAt = @{}; $script:result = ""
    $script:shown = 0.0; $script:target = 0.0
    $script:detail = "STARTING"
    $script:started = Get-Date
    $script:lastLog = ""
    $out.Text = "Publishing $v ... (a few minutes; keep this window open)`r`n"
    Set-Busy $true
    $a = "-NoProfile -ExecutionPolicy Bypass -File `"$PSScriptRoot\publish.ps1`" -Version $v -NotesFile `"$notesFile`" -StatusFile `"$statusFile`""
    $script:proc = Start-Process powershell -ArgumentList $a -WindowStyle Hidden -PassThru `
        -RedirectStandardOutput $log -RedirectStandardError $err
    $null = $script:proc.Handle          # PS 5.1 only keeps ExitCode if the handle is cached
}
$btn.Add_Click({ Start-Publish })

$form.Add_FormClosing({
    if ($script:proc -and -not $script:proc.HasExited) {
        $a = [Windows.Forms.MessageBox]::Show("A publish is still running. Closing this window doesn't stop it, but you won't see how it ends.`n`nClose anyway?", "Backrooms - Publish", "YesNo", "Warning")
        if ($a -ne "Yes") { $_.Cancel = $true }
    }
})
$form.Add_Shown({ $form.Refresh(); Run-Checks; $timer.Start() })
[void]$form.ShowDialog()
$fonts.Dispose()
