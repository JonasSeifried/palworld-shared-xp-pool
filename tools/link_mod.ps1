<#
.SYNOPSIS
    Point the game's UE4SS Mods folder at this repo's mod.

.DESCRIPTION
    Creates a directory junction so the game loads mod/SharedXPPool straight out
    of the working tree. Together with UE4SS's hot reload that means editing a
    .lua file here takes effect without reinstalling anything.

    Junctions do not need admin rights, unlike symlinks.
#>
param(
    [string]$GameDir = "D:\SteamLibrary\steamapps\common\Palworld"
)

$ErrorActionPreference = "Stop"

$source = Join-Path $PSScriptRoot "..\mod\SharedXPPool" | Resolve-Path
$modsDir = Join-Path $GameDir "Pal\Binaries\Win64\ue4ss\Mods"
$link = Join-Path $modsDir "SharedXPPool"

if (-not (Test-Path $modsDir)) {
    throw "No UE4SS Mods folder at $modsDir -- run install_ue4ss.ps1 first."
}

if (Test-Path $link) {
    $existing = Get-Item $link -Force
    if ($existing.LinkType) {
        Remove-Item $link -Force
    } else {
        throw "$link exists and is a real folder, not a link. Move it aside first."
    }
}

New-Item -ItemType Junction -Path $link -Target $source | Out-Null
Write-Host "$link -> $source"

# UE4SS reads enabled.txt inside the mod folder, so mods.txt needs no edit.
Write-Host "Enabled via $source\enabled.txt"
