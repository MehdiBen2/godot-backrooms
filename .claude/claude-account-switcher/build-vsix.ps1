$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName System.IO.Compression
Add-Type -AssemblyName System.IO.Compression.FileSystem

$root = $PSScriptRoot
$pkg = Get-Content "$root\package.json" -Raw | ConvertFrom-Json
$out = Join-Path $root "$($pkg.name)-$($pkg.version).vsix"
if (Test-Path $out) { Remove-Item $out }

$contentTypes = @'
<?xml version="1.0" encoding="utf-8"?>
<Types xmlns="http://schemas.openxmlformats.org/package/2006/Content-Types"><Default Extension=".json" ContentType="application/json"/><Default Extension=".js" ContentType="application/javascript"/><Default Extension=".md" ContentType="text/markdown"/><Default Extension=".css" ContentType="text/css"/><Default Extension=".svg" ContentType="image/svg+xml"/><Default Extension=".png" ContentType="image/png"/><Default Extension=".vsixmanifest" ContentType="text/xml"/></Types>
'@

$manifest = @"
<?xml version="1.0" encoding="utf-8"?>
<PackageManifest Version="2.0.0" xmlns="http://schemas.microsoft.com/developer/vsx-schema/2011">
  <Metadata>
    <Identity Language="en-US" Id="$($pkg.name)" Version="$($pkg.version)" Publisher="$($pkg.publisher)"/>
    <DisplayName>$($pkg.displayName)</DisplayName>
    <Description xml:space="preserve">$($pkg.description)</Description>
    <Categories>Other</Categories>
    <Properties>
      <Property Id="Microsoft.VisualStudio.Code.Engine" Value="$($pkg.engines.vscode)"/>
    </Properties>
    <Icon>extension/media/icon.png</Icon>
  </Metadata>
  <Installation><InstallationTarget Id="Microsoft.VisualStudio.Code"/></Installation>
  <Dependencies/>
  <Assets>
    <Asset Type="Microsoft.VisualStudio.Code.Manifest" Path="extension/package.json" Addressable="true"/>
    <Asset Type="Microsoft.VisualStudio.Services.Icons.Default" Path="extension/media/icon.png" Addressable="true"/>
  </Assets>
</PackageManifest>
"@

$zip = [System.IO.Compression.ZipFile]::Open($out, 'Create')
function Add-Entry($name, $bytes) {
  $e = $zip.CreateEntry($name)
  $s = $e.Open(); $s.Write($bytes, 0, $bytes.Length); $s.Close()
}
$utf8 = New-Object System.Text.UTF8Encoding($false)
Add-Entry '[Content_Types].xml' $utf8.GetBytes($contentTypes)
Add-Entry 'extension.vsixmanifest' $utf8.GetBytes($manifest)
foreach ($f in 'package.json', 'extension.js', 'README.md') {
  Add-Entry "extension/$f" ([System.IO.File]::ReadAllBytes("$root\$f"))
}
Get-ChildItem "$root\media" -File | ForEach-Object {
  Add-Entry "extension/media/$($_.Name)" ([System.IO.File]::ReadAllBytes($_.FullName))
}
$zip.Dispose()
Write-Host "Built $out"
