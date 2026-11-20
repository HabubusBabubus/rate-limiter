# Packs the mod into dist/<name>_<version>.zip, ready for the mods folder or the mod portal.
# Usage (from the repository root):  powershell -ExecutionPolicy Bypass -File tools/build.ps1
# Entries are written with forward slashes: archives made by Compress-Archive in Windows
# PowerShell 5.1 use backslashes, which Factorio does not accept.
$ErrorActionPreference = "Stop"
Add-Type -AssemblyName System.IO.Compression
Add-Type -AssemblyName System.IO.Compression.FileSystem

$root = Split-Path -Parent $PSScriptRoot
$src = Join-Path $root "rate-limiter"
$info = Get-Content (Join-Path $src "info.json") -Raw | ConvertFrom-Json
$folder = "$($info.name)_$($info.version)"
$dist = Join-Path $root "dist"
$zipPath = Join-Path $dist "$folder.zip"

New-Item -ItemType Directory -Force -Path $dist | Out-Null
if (Test-Path $zipPath) { Remove-Item $zipPath -Force }

$zip = [System.IO.Compression.ZipFile]::Open($zipPath, [System.IO.Compression.ZipArchiveMode]::Create)
try {
  Get-ChildItem $src -Recurse -File | ForEach-Object {
    $rel = $_.FullName.Substring($src.Length + 1).Replace('\', '/')
    [System.IO.Compression.ZipFileExtensions]::CreateEntryFromFile($zip, $_.FullName, "$folder/$rel") | Out-Null
  }
} finally {
  $zip.Dispose()
}
Write-Host "Built $zipPath"
