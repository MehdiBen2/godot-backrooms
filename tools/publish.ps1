# Export the game, zip it, and publish it as a GitHub Release the launcher will pick up.
#   .\tools\publish.ps1 v0.2.0 -Notes "What changed"
#   .\tools\publish.ps1 v0.2.0 -NotesFile path\to\notes.txt
# Needs: Godot 4 + export templates (env GODOT or godot on PATH) and the GitHub CLI (gh auth login).
param(
    [Parameter(Mandatory = $true)][string]$Version,
    [string]$Notes = "",
    [string]$NotesFile = ""
)
$ErrorActionPreference = "Stop"
$repo = "MehdiBen2/godot-backrooms"
$root = Split-Path $PSScriptRoot -Parent

if ($Version -notmatch '^v\d+\.\d+\.\d+$') { throw "Version must look like v0.1.1 (got '$Version')" }

if (-not (Get-Command gh -ErrorAction SilentlyContinue)) { throw "GitHub CLI (gh) not found. Install: winget install GitHub.cli" }
$ErrorActionPreference = "Continue"   # PS 5.1 turns gh's stderr into a terminating error even when redirected, so
                                      # checks that rely on a non-zero/stderr exit as their expected path need this off
gh auth status *> $null
$signedIn = ($LASTEXITCODE -eq 0)
gh release view $Version --repo $repo *> $null
$releaseExists = ($LASTEXITCODE -eq 0)
$ErrorActionPreference = "Stop"
if (-not $signedIn) { throw "gh is not signed in. Run: gh auth login" }
if ($releaseExists) { throw "Release $Version already exists on GitHub. Pick a new version." }

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
if ($LASTEXITCODE -ne 0 -or -not (Test-Path (Join-Path $game "backrooms.exe"))) { throw "Godot export failed" }

Compress-Archive -Path (Join-Path $game "*") -DestinationPath $zip

# Notes always go through a file: a native exe (gh.exe) silently drops an empty-string
# argument from a variable, so `--notes $Notes` breaks when the notes box is left blank.
$notesPath = Join-Path $build "notes.md"
if ($NotesFile -and (Test-Path $NotesFile)) {
    $text = (Get-Content $NotesFile -Raw -ErrorAction SilentlyContinue)
    Set-Content -Path $notesPath -Value $(if ([string]::IsNullOrWhiteSpace($text)) { "Automated release $Version." } else { $text }) -Encoding utf8
} else {
    Set-Content -Path $notesPath -Value $(if ([string]::IsNullOrWhiteSpace($Notes)) { "Automated release $Version." } else { $Notes }) -Encoding utf8
}

gh release create $Version $zip --repo $repo --title $Version --notes-file $notesPath
if ($LASTEXITCODE -ne 0) { throw "gh release create failed (exit $LASTEXITCODE)" }

Write-Host "Published $Version. Launchers will offer the update on next start."
