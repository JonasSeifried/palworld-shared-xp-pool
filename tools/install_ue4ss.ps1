<#
.SYNOPSIS
    Install the Palworld-specific UE4SS fork into a Palworld game directory.

.DESCRIPTION
    Stock RE-UE4SS does NOT work with Palworld any more -- the game made engine
    edits in 0.4.1.5 and needs Okaetsu's fork. This script downloads that fork's
    latest release and unpacks it into Pal/Binaries/Win64.

    Do not run this while Palworld is running, and do not combine it with the
    Steam Workshop build of UE4SS: two copies of ue4ss load at once and the game
    crashes on launch.

.PARAMETER GameDir
    Palworld install root (the folder holding Palworld.exe).

.PARAMETER Dev
    Install the zDev build (~44 MB) instead of the user build (~9 MB). The dev
    build carries the object dumper and live property viewer, which is what you
    want when writing or debugging a mod.
#>
param(
    [string]$GameDir = "D:\SteamLibrary\steamapps\common\Palworld",
    [switch]$Dev
)

$ErrorActionPreference = "Stop"

$target = Join-Path $GameDir "Pal\Binaries\Win64"
if (-not (Test-Path (Join-Path $GameDir "Palworld.exe"))) {
    throw "No Palworld.exe in $GameDir -- point -GameDir at the install root."
}
if (Get-Process -Name "Palworld-Win64-Shipping" -ErrorAction SilentlyContinue) {
    throw "Palworld is running. Close it first."
}

$asset = if ($Dev) { "zDev.zip" } else { ".zip" }
$rel = Invoke-RestMethod "https://api.github.com/repos/Okaetsu/RE-UE4SS/releases/latest"
$url = ($rel.assets | Where-Object { $_.name -like "*$asset" } | Select-Object -First 1).browser_download_url
if (-not $url) { throw "No asset matching *$asset in release $($rel.tag_name)" }

Write-Host "UE4SS $($rel.tag_name) -> $target"
$zip = Join-Path $env:TEMP "ue4ss-palworld.zip"
Invoke-WebRequest $url -OutFile $zip

# Keep any mods already installed: Expand-Archive -Force overwrites files it
# ships but leaves unrelated folders under ue4ss/Mods alone.
Expand-Archive -Path $zip -DestinationPath $target -Force
Remove-Item $zip

Write-Host "Installed. Launch the game once, then check:"
Write-Host "  $target\ue4ss\UE4SS.log"
