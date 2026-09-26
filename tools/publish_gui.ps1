# One-click publisher: window with version + notes + a Publish button. Runs tools\publish.ps1 for you.
# Start it by double-clicking Publish.bat in the repo root.
Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing

$root = Split-Path $PSScriptRoot -Parent
$repo = "MehdiBen2/godot-backrooms"
$log = Join-Path $env:TEMP "backrooms_publish.log"
$err = Join-Path $env:TEMP "backrooms_publish.err"

# Next version = latest release with the patch number + 1 (v0.1.0 -> v0.1.1); v0.1.0 if none yet
function Get-NextVersion {
    try {
        $tag = (& gh release list --repo $repo --limit 1 --json tagName --jq ".[0].tagName" 2>$null)
        if ($tag -match '^v(\d+)\.(\d+)\.(\d+)$') { return "v$($Matches[1]).$($Matches[2]).$([int]$Matches[3] + 1)" }
    } catch { }
    return "v0.1.0"
}

$form = New-Object Windows.Forms.Form
$form.Text = "Backrooms - Publish"
$form.Size = New-Object Drawing.Size(560, 520)
$form.StartPosition = "CenterScreen"
$form.BackColor = [Drawing.Color]::FromArgb(20, 20, 18)
$form.ForeColor = [Drawing.Color]::FromArgb(230, 225, 205)
$form.Font = New-Object Drawing.Font("Consolas", 10)

function Add-Label($text, $y) {
    $l = New-Object Windows.Forms.Label
    $l.Text = $text; $l.Location = New-Object Drawing.Point(16, $y); $l.AutoSize = $true
    $form.Controls.Add($l)
}
function Style-Box($b) { $b.BackColor = [Drawing.Color]::FromArgb(36, 36, 32); $b.ForeColor = $form.ForeColor; $b.BorderStyle = "FixedSingle" }

Add-Label "VERSION" 14
$ver = New-Object Windows.Forms.TextBox
$ver.Location = New-Object Drawing.Point(16, 36); $ver.Size = New-Object Drawing.Size(200, 26); $ver.Text = "..."
Style-Box $ver; $form.Controls.Add($ver)

Add-Label "WHAT CHANGED (optional)" 74
$notes = New-Object Windows.Forms.TextBox
$notes.Location = New-Object Drawing.Point(16, 96); $notes.Size = New-Object Drawing.Size(510, 70); $notes.Multiline = $true
Style-Box $notes; $form.Controls.Add($notes)

$btn = New-Object Windows.Forms.Button
$btn.Text = "PUBLISH"; $btn.Location = New-Object Drawing.Point(16, 178); $btn.Size = New-Object Drawing.Size(510, 40)
$btn.FlatStyle = "Flat"; $btn.BackColor = [Drawing.Color]::FromArgb(196, 39, 31); $btn.ForeColor = [Drawing.Color]::White
$form.Controls.Add($btn)

$out = New-Object Windows.Forms.TextBox
$out.Location = New-Object Drawing.Point(16, 232); $out.Size = New-Object Drawing.Size(510, 240)
$out.Multiline = $true; $out.ReadOnly = $true; $out.ScrollBars = "Vertical"; $out.Font = New-Object Drawing.Font("Consolas", 9)
Style-Box $out; $form.Controls.Add($out)

$script:proc = $null
$timer = New-Object Windows.Forms.Timer
$timer.Interval = 500
$timer.Add_Tick({
    $text = ""
    foreach ($f in @($log, $err)) {
        if (Test-Path $f) { $text += (Get-Content $f -Raw -ErrorAction SilentlyContinue) }
    }
    if ($text -and $out.Text -ne $text) { $out.Text = $text; $out.SelectionStart = $out.Text.Length; $out.ScrollToCaret() }
    if ($script:proc -and $script:proc.HasExited) {
        $timer.Stop()
        $btn.Enabled = $true; $btn.Text = "PUBLISH"
        $published = (Test-Path $log) -and ((Get-Content $log -Raw) -match "Published v")
        if ($published -or $script:proc.ExitCode -eq 0) {
            $out.AppendText("`r`n`r`nDONE. Your friend's launcher will offer the update on its next start.")
            $ver.Text = Get-NextVersion
        } else {
            $out.AppendText("`r`n`r`nFAILED (see the text above).")
        }
        $script:proc = $null
    }
})

$btn.Add_Click({
    if (-not (Get-Command gh -ErrorAction SilentlyContinue)) {
        [Windows.Forms.MessageBox]::Show("GitHub CLI (gh) not found. Install it with:  winget install GitHub.cli   then run  gh auth login", "Backrooms") | Out-Null
        return
    }
    $v = $ver.Text.Trim()
    if ($v -notmatch '^v\d+\.\d+\.\d+$') {
        [Windows.Forms.MessageBox]::Show("Version must look like v0.1.1", "Backrooms") | Out-Null
        return
    }
    $n = ($notes.Text -replace '["`]', "'" -replace '\r?\n', ' ').Trim()
    Remove-Item $log, $err -ErrorAction SilentlyContinue
    $out.Text = "Exporting and publishing $v ... (1-3 minutes, don't close this window)"
    $btn.Enabled = $false; $btn.Text = "PUBLISHING..."
    $args = "-NoProfile -ExecutionPolicy Bypass -File `"$PSScriptRoot\publish.ps1`" -Version $v -Notes `"$n`""
    $script:proc = Start-Process powershell -ArgumentList $args -WindowStyle Hidden -PassThru `
        -RedirectStandardOutput $log -RedirectStandardError $err
    $null = $script:proc.Handle          # PS 5.1 only keeps ExitCode if the handle is cached
    $timer.Start()
})

$form.Add_Shown({ $ver.Text = Get-NextVersion })
[void]$form.ShowDialog()
