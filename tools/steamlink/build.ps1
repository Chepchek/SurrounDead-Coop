# Builds SDCoopSteamLink.exe (the Steam join helper) with the C# compiler of
# .NET Framework 4 that ships with Windows - nothing to download.
#   powershell -ExecutionPolicy Bypass -File tools\steamlink\build.ps1 [-Out <folder>]
# Default output: mods\SDCoop\steamlink\SDCoopSteamLink.exe
param([string]$Out = "")
$ErrorActionPreference = "Stop"
$src = $PSScriptRoot
$root = Split-Path -Parent (Split-Path -Parent $src)
if (-not $Out) { $Out = Join-Path $root "mods\SDCoop\steamlink" }
$csc = Join-Path $env:WINDIR "Microsoft.NET\Framework64\v4.0.30319\csc.exe"
if (-not (Test-Path $csc)) { throw "csc.exe of .NET Framework 4 not found: $csc" }
New-Item -ItemType Directory -Force $Out | Out-Null
$exe = Join-Path $Out "SDCoopSteamLink.exe"
$files = @(Get-ChildItem -Path $src -Filter *.cs | Sort-Object Name | ForEach-Object { $_.FullName })
if ($files.Count -eq 0) { throw "no .cs files in $src" }
& $csc /nologo /target:winexe /platform:x64 /optimize+ /warn:4 /utf8output "/out:$exe" $files
if ($LASTEXITCODE -ne 0) { throw "csc failed (exit $LASTEXITCODE)" }
"steamlink: built $exe ($([math]::Round((Get-Item $exe).Length / 1KB)) KB)"
