# Export the game and zip it so you can send it to a friend (no GitHub needed).
#   .\tools\pack.ps1
# Output: build\backrooms-windows.zip (unzip anywhere, run backrooms.exe)
# Needs: Godot 4.7 + its Windows export templates (env GODOT, godot on PATH, or the Desktop copy).
$ErrorActionPreference = "Stop"
$root = Split-Path $PSScriptRoot -Parent
$godot = $env:GODOT
if (-not $godot) { $cmd = Get-Command godot -ErrorAction SilentlyContinue; if ($cmd) { $godot = $cmd.Source } }
if (-not $godot) { $godot = (Get-ChildItem "$env:USERPROFILE\Desktop" -Filter "Godot_v4*.exe" -ErrorAction SilentlyContinue | Where-Object { $_.Name -notmatch "console" } | Select-Object -First 1).FullName }
if (-not $godot) { throw "Godot not found: set `$env:GODOT to the editor exe" }

$build = Join-Path $root "build"
$game = Join-Path $build "game"
$zip = Join-Path $build "backrooms-windows.zip"
if (Test-Path $build) { Remove-Item $build -Recurse -Force }
New-Item -ItemType Directory $game | Out-Null

$ErrorActionPreference = "Continue"   # PS 5.1 turns Godot's stderr into errors
& $godot --headless --path (Join-Path $root "godot-backrooms") --export-release "Windows Desktop" (Join-Path $game "backrooms.exe") 2>&1 | Out-Null
$ErrorActionPreference = "Stop"
if ($LASTEXITCODE -ne 0 -or -not (Test-Path (Join-Path $game "backrooms.exe"))) { throw "Godot export failed (are the export templates installed?)" }

Compress-Archive -Path (Join-Path $game "*") -DestinationPath $zip
"{0:N0} MB -> {1}" -f ((Get-Item $zip).Length / 1MB), $zip
