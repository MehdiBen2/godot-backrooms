# Export the game, zip it, and publish it as a GitHub Release the launcher will pick up.
#   .\tools\publish.ps1 v0.2.0 "What changed"
# Needs: Godot 4 + export templates (env GODOT or godot on PATH) and the GitHub CLI (gh auth login).
param(
    [Parameter(Mandatory = $true)][string]$Version,
    [string]$Notes = ""
)
$ErrorActionPreference = "Stop"
$root = Split-Path $PSScriptRoot -Parent
$godot = if ($env:GODOT) { $env:GODOT } else { "godot" }
$build = Join-Path $root "build"
$game = Join-Path $build "game"
$zip = Join-Path $build "backrooms-windows.zip"

if (Test-Path $build) { Remove-Item $build -Recurse -Force }
New-Item -ItemType Directory $game | Out-Null

& $godot --headless --path (Join-Path $root "godot-backrooms") --export-release "Windows Desktop" (Join-Path $game "backrooms.exe")
if ($LASTEXITCODE -ne 0 -or -not (Test-Path (Join-Path $game "backrooms.exe"))) { throw "Godot export failed" }

Compress-Archive -Path (Join-Path $game "*") -DestinationPath $zip
gh release create $Version $zip --repo MehdiBen2/godot-backrooms --title $Version --notes $Notes
Write-Host "Published $Version. Launchers will offer the update on next start."
