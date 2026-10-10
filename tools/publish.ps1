# Export the game, cut it into chunks, and publish it as a GitHub Release the launcher will pick up.
#   .\tools\publish.ps1 v0.2.0 -Notes "What changed"
#   .\tools\publish.ps1 v0.2.0 -NotesFile path\to\notes.txt
# Needs: Godot 4 + export templates (env GODOT or godot on PATH) and the GitHub CLI (gh auth login).
#
# What goes up:
#   - the version release: backrooms-windows.zip (for the website's download link) and manifest.json, which lists
#     every game file as a sequence of chunks;
#   - the "store" release (a prerelease, shared by all versions): one asset per unique chunk, named by its sha256.
#     Only chunks the store doesn't have yet are uploaded, so a small change uploads a small amount.
# The launcher reads the manifest and downloads only the chunks its installed copy doesn't already have.
param(
    [Parameter(Mandatory = $true)][string]$Version,
    [string]$Notes = "",
    [string]$NotesFile = "",
    [string]$StatusFile = ""      # publish_gui.ps1: each stage's name is appended here as it starts (check, export, chunk, zip, upload, done)
)
$ErrorActionPreference = "Stop"
$repo = "MehdiBen2/godot-backrooms"
$storeTag = "store"           # the release holding every chunk; the launcher has the same name (STORE_TAG)
$root = Split-Path $PSScriptRoot -Parent

function Stage([string]$name) {
    Write-Output ">> $name"
    if ($StatusFile) { Add-Content -Path $StatusFile -Value $name -Encoding ascii }
}

# Content-defined chunking: a chunk's edges come from a rolling hash of the bytes, so an edit only changes the
# chunks it touches, and a file that grows in the middle doesn't re-cut everything after it. Compiled once here
# because PowerShell is far too slow to hash a gigabyte byte by byte.
$chunkerSource = @'
using System;
using System.IO;
using System.Collections.Generic;
using System.Security.Cryptography;

public class ChunkInfo { public string Hash; public long Size; }

public class SplitInfo {
    public string Sha256;
    public long Size;
    public List<ChunkInfo> Chunks = new List<ChunkInfo>();
}

public static class Chunker {
    const int MinSize = 1 << 20;          // 1 MB
    const int MaxSize = 16 << 20;         // 16 MB
    const ulong Mask = (1UL << 22) - 1;   // about 4 MB on average past MinSize
    static readonly ulong[] Gear = MakeGear();

    static ulong[] MakeGear() {
        // splitmix64: a fixed table, so the same bytes are cut the same way on every machine
        var table = new ulong[256];
        ulong s = 0;
        for (int i = 0; i < 256; i++) {
            s += 0x9E3779B97F4A7C15UL;
            ulong z = s;
            z = (z ^ (z >> 30)) * 0xBF58476D1CE4E5B9UL;
            z = (z ^ (z >> 27)) * 0x94D049BB133111EBUL;
            table[i] = z ^ (z >> 31);
        }
        return table;
    }

    public static string Hex(byte[] bytes) {
        return BitConverter.ToString(bytes).Replace("-", "").ToLowerInvariant();
    }

    // Cuts the file into chunks, writes each chunk that isn't in `known` to outDir (named by its hash),
    // and returns the file's sha256 with its chunk list.
    public static SplitInfo Split(string path, string outDir, HashSet<string> known, List<string> newChunks) {
        var info = new SplitInfo();
        var whole = SHA256.Create();
        var buf = new byte[1 << 20];
        var cur = new MemoryStream();
        ulong h = 0;
        using (var fs = File.OpenRead(path)) {
            int n;
            while ((n = fs.Read(buf, 0, buf.Length)) > 0) {
                whole.TransformBlock(buf, 0, n, null, 0);
                for (int i = 0; i < n; i++) {
                    cur.WriteByte(buf[i]);
                    h = (h << 1) + Gear[buf[i]];
                    long len = cur.Length;
                    if ((len >= MinSize && (h & Mask) == 0) || len >= MaxSize) {
                        Emit(cur, outDir, known, newChunks, info);
                        h = 0;
                    }
                }
            }
        }
        if (cur.Length > 0) Emit(cur, outDir, known, newChunks, info);
        whole.TransformFinalBlock(new byte[0], 0, 0);
        info.Sha256 = Hex(whole.Hash);
        return info;
    }

    static void Emit(MemoryStream cur, string outDir, HashSet<string> known, List<string> newChunks, SplitInfo info) {
        byte[] data = cur.ToArray();
        string hash = Hex(SHA256.Create().ComputeHash(data));
        if (!known.Contains(hash)) {
            File.WriteAllBytes(Path.Combine(outDir, hash), data);
            known.Add(hash);
            newChunks.Add(hash);
        }
        info.Chunks.Add(new ChunkInfo { Hash = hash, Size = data.Length });
        info.Size += data.Length;
        cur.SetLength(0);
    }
}
'@
Add-Type -TypeDefinition $chunkerSource -Language CSharp

Stage "check"
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

Stage "export"
$exportLog = Join-Path $build "export.log"
# The editor exe is a windowed program: PowerShell doesn't wait for one on its own, so the export is started
# as a process and waited on (its output goes to the log, and its exit code is the process's)
$exportErr = Join-Path $build "export.err.log"
$godotArgs = "--headless --path `"$(Join-Path $root "godot-backrooms")`" --export-release `"Windows Desktop`" `"$(Join-Path $game "backrooms.exe")`""
$exportProc = Start-Process -FilePath $godot -ArgumentList $godotArgs -Wait -PassThru -NoNewWindow `
    -RedirectStandardOutput $exportLog -RedirectStandardError $exportErr
$exportCode = $exportProc.ExitCode
Get-Content $exportErr -ErrorAction SilentlyContinue | Add-Content $exportLog
if ($exportCode -ne 0 -or -not (Test-Path (Join-Path $game "backrooms.exe"))) {
    # what Godot said about it (the export log is kept in build\export.log)
    Get-Content $exportLog -ErrorAction SilentlyContinue | Where-Object { $_ -match "ERROR|export|template|preset|Aucun|failed" } |
        Select-Object -Last 12 | ForEach-Object { Write-Output "   $_" }
    throw "Godot export failed (full log: $exportLog)"
}

Stage "chunk"
$chunkDir = Join-Path $build "chunks"
New-Item -ItemType Directory $chunkDir | Out-Null
# What the store already has (its asset names are the chunk hashes). No store yet: create it.
$ErrorActionPreference = "Continue"
$storeNames = @(gh release view $storeTag --repo $repo --json assets --jq ".assets[].name")
if ($LASTEXITCODE -ne 0) {
    gh release create $storeTag --repo $repo --prerelease --title "Chunk store" `
        --notes "Game chunks for the launcher's delta updates. Shared by every version: do not delete."
    if ($LASTEXITCODE -ne 0) { throw "gh release create $storeTag failed (exit $LASTEXITCODE)" }
    $storeNames = @()
}
$ErrorActionPreference = "Stop"
$known = New-Object 'System.Collections.Generic.HashSet[string]'
foreach ($n in $storeNames) { if ($n) { [void]$known.Add($n.Trim()) } }
$newChunks = New-Object 'System.Collections.Generic.List[string]'
$entries = @()
foreach ($file in (Get-ChildItem $game -File | Sort-Object Name)) {
    $info = [Chunker]::Split($file.FullName, $chunkDir, $known, $newChunks)
    $entries += [ordered]@{
        path = $file.Name
        size = $info.Size
        sha256 = $info.Sha256
        chunks = @($info.Chunks | ForEach-Object { [ordered]@{ h = $_.Hash; n = $_.Size } })
    }
}
$manifest = [ordered]@{ version = $Version; store = $storeTag; files = $entries }
$manifestPath = Join-Path $build "manifest.json"
[System.IO.File]::WriteAllText($manifestPath, ($manifest | ConvertTo-Json -Depth 8), (New-Object System.Text.UTF8Encoding($false)))
Write-Output "   $($newChunks.Count) new chunks, $(@($entries | ForEach-Object { $_.chunks.Count } | Measure-Object -Sum).Sum) chunks in the build"

Stage "zip"
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

Stage "upload"
# Chunks go up first, so a manifest never names a chunk the store doesn't have yet
$uploads = @($newChunks | ForEach-Object { Join-Path $chunkDir $_ })
for ($i = 0; $i -lt $uploads.Count; $i += 50) {
    $batch = $uploads[$i..([Math]::Min($i + 49, $uploads.Count - 1))]
    gh release upload $storeTag @batch --repo $repo
    if ($LASTEXITCODE -ne 0) { throw "gh release upload to $storeTag failed (exit $LASTEXITCODE)" }
}

gh release create $Version $zip $manifestPath --repo $repo --title $Version --notes-file $notesPath
if ($LASTEXITCODE -ne 0) { throw "gh release create failed (exit $LASTEXITCODE)" }

Stage "done"
Write-Output "Published $Version. Launchers will offer the update on next start."
