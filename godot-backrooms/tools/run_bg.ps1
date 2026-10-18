# Run the game (or a --script tool) in the background for testing: the window never takes the focus, starts
# minimized (or, with -Offscreen, parked off the screen so its frames are still drawn: Godot draws nothing while
# every window is minimized), on the Low graphics preset (graphics.gd `--bg`, never saved to graphics.cfg).
#
#   powershell -File tools/run_bg.ps1 [-Offscreen] [-Timeout 300] -GodotArgs "--resolution 1280x720 --script res://tools/shot_tallone.gd"
#
# The window settings have to be in place before Godot creates its window, so they go in a temporary
# res://override.cfg that is removed again when the run ends (whatever happens).
param(
	[switch]$Offscreen,
	[int]$Timeout = 300,
	[string]$Godot = "C:\Users\alhyu\Desktop\Godot_v4.7.2-stable_win64_console.exe",
	[string]$GodotArgs = ""
)
$proj = Split-Path -Parent $PSScriptRoot
$ovr = Join-Path $proj "override.cfg"
if (Test-Path $ovr) { throw "override.cfg already exists in the project: not touching it" }
$mode = if ($Offscreen) { 0 } else { 1 }
@"
[display]

window/size/no_focus=true
window/size/mode=$mode
window/size/initial_position_type=0
window/size/initial_position=Vector2i(-20000, -20000)
"@ | Set-Content -Path $ovr -Encoding ascii
$flag = if ($Offscreen) { "--bg-offscreen" } else { "--bg" }
$argLine = "--path `"$proj`" --audio-driver Dummy $GodotArgs -- $flag"
try {
	$out = [System.IO.Path]::GetTempFileName()
	$err = [System.IO.Path]::GetTempFileName()
	$p = Start-Process -FilePath $Godot -ArgumentList $argLine -PassThru -WindowStyle Minimized `
		-RedirectStandardOutput $out -RedirectStandardError $err
	# the override is read at startup: take it away as soon as the window is up, not at the end of the run
	Start-Sleep -Seconds 3
	Remove-Item $ovr -ErrorAction SilentlyContinue
	if (-not $p.WaitForExit($Timeout * 1000)) { $p.Kill(); Write-Output "run_bg: killed after $Timeout s" }
	Get-Content $out
	Get-Content $err
	Remove-Item $out, $err -ErrorAction SilentlyContinue
} finally {
	Remove-Item $ovr -ErrorAction SilentlyContinue
}
