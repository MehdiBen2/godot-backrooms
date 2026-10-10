# Export the launcher and put it on GitHub at a fixed link, so the download page never has to change:
#   https://github.com/MehdiBen2/godot-backrooms/releases/download/launcher/Backrooms-Launcher.exe
# The "launcher" release is kept out of "latest", so the game's own releases are unaffected.
#   .\tools\publish_launcher.ps1
#   .\tools\publish_launcher.ps1 -Notes "Fixes the update check"
# Needs: Godot 4 (env GODOT or godot on PATH, or a Godot_v4*.exe on the Desktop) and the GitHub CLI (gh auth login).
param(
    [string]$Notes = "The Backrooms launcher. Open it to install the game and keep it up to date."
)
$ErrorActionPreference = "Stop"
$repo = "MehdiBen2/godot-backrooms"
$tag = "launcher"
$assetName = "Backrooms-Launcher.exe"
$root = Split-Path $PSScriptRoot -Parent

Write-Output ">> check"
if (-not (Get-Command gh -ErrorAction SilentlyContinue)) { throw "GitHub CLI (gh) not found. Install: winget install GitHub.cli" }
gh auth status *> $null
if ($LASTEXITCODE -ne 0) { throw "gh is not signed in. Run: gh auth login" }

$godot = $env:GODOT
if (-not $godot) { $cmd = Get-Command godot -ErrorAction SilentlyContinue; if ($cmd) { $godot = $cmd.Source } }
if (-not $godot) { $godot = (Get-ChildItem "$env:USERPROFILE\Desktop" -Filter "Godot_v4*.exe" -ErrorAction SilentlyContinue | Where-Object { $_.Name -notmatch "console" } | Select-Object -First 1).FullName }
if (-not $godot) { throw "Godot not found: set `$env:GODOT to the editor exe" }

$build = Join-Path $root "build"
New-Item -ItemType Directory -Force $build | Out-Null
$exe = Join-Path $build $assetName
if (Test-Path $exe) { Remove-Item $exe -Force }

Write-Output ">> export"
$exportLog = Join-Path $build "launcher-export.log"
$exportErr = Join-Path $build "launcher-export.err.log"
# The editor exe is a windowed program, so it is started and waited on explicitly (same as publish.ps1)
$godotArgs = "--headless --path `"$(Join-Path $root "launcher")`" --export-release `"Windows Desktop`" `"$exe`""
$proc = Start-Process -FilePath $godot -ArgumentList $godotArgs -Wait -PassThru -NoNewWindow `
    -RedirectStandardOutput $exportLog -RedirectStandardError $exportErr
if ($proc.ExitCode -ne 0 -or -not (Test-Path $exe)) {
    Get-Content $exportLog, $exportErr -ErrorAction SilentlyContinue | Select-Object -Last 12 | ForEach-Object { Write-Output "   $_" }
    throw "Launcher export failed (full logs in $build)"
}

Write-Output ">> upload"
$ErrorActionPreference = "Continue"   # gh writes progress to stderr; only its exit code matters here
gh release view $tag --repo $repo *> $null
$exists = ($LASTEXITCODE -eq 0)
if ($exists) {
    gh release upload $tag $exe --repo $repo --clobber
} else {
    gh release create $tag $exe --repo $repo --title "Launcher" --notes $Notes --latest=false
}
$code = $LASTEXITCODE
$ErrorActionPreference = "Stop"
if ($code -ne 0) { throw "gh failed (exit $code)" }

Write-Output "Published. Download link: https://github.com/$repo/releases/download/$tag/$assetName"
