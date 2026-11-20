# Run from an x64 Visual Studio Developer PowerShell with the Godot 4.7 editor executable.
param([Parameter(Mandatory)][string]$GodotExe)

$ErrorActionPreference = 'Stop'
$godot = (Resolve-Path -LiteralPath $GodotExe).Path
$sourceDir = Join-Path (Split-Path -Parent $PSScriptRoot) 'godot-backrooms/native/windows_shader_locale'
$buildDir = Join-Path ([System.IO.Path]::GetTempPath()) 'nullspace-windows-shader-locale'
New-Item -ItemType Directory -Path $buildDir -Force | Out-Null

Push-Location -LiteralPath $buildDir
try {
    & $godot --headless --dump-gdextension-interface
    if ($LASTEXITCODE -ne 0) { throw 'Could not export the GDExtension interface.' }

    & cl.exe /nologo /c /GS- /O2 /W3 "/I$buildDir" (Join-Path $sourceDir 'windows_shader_locale.c')
    if ($LASTEXITCODE -ne 0) { throw 'Could not compile the Windows GDExtension.' }
    & link.exe /nologo /DLL /NOENTRY /NODEFAULTLIB /Brepro /MACHINE:X64 windows_shader_locale.obj kernel32.lib
    if ($LASTEXITCODE -ne 0) { throw 'Could not link the Windows GDExtension.' }

    Copy-Item -LiteralPath (Join-Path $buildDir 'windows_shader_locale.dll') -Destination $sourceDir
} finally {
    Pop-Location
}
