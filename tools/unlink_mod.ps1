<#
.SYNOPSIS
    Undo link_mod.ps1, and clear out any installed copies of the mod.

.DESCRIPTION
    Run this before installing a release archive over the game. The archive
    contains Pal\Binaries\Win64\ue4ss\Mods\SharedXPPool\, and link_mod.ps1
    makes that path a junction into this repo -- so extracting the archive
    while the junction is there writes *through* it and overwrites the working
    tree with the archive's copies.

    Removes the junction without following it, so nothing in the repo is
    touched, and then removes real installed copies from every folder a UE4SS
    build reads mods from.

.PARAMETER KeepInstalled
    Remove only the junction, leaving real installed copies alone. For going
    back to a released build without reinstalling it.
#>
param(
    [string]$GameDir = "D:\SteamLibrary\steamapps\common\Palworld",
    [switch]$KeepInstalled
)

$ErrorActionPreference = "Stop"

# Every Mods directory a UE4SS build might read, relative to the game folder.
# The same list as tools/build_release.py, for the same reason.
$modsDirs = @(
    "Mods\NativeMods\UE4SS\Mods",
    "Pal\Binaries\Win64\ue4ss\Mods",
    "Pal\Binaries\Win64\Mods"
)

$removed = 0

foreach ($dir in $modsDirs) {
    $path = Join-Path $GameDir "$dir\SharedXPPool"
    if (-not (Test-Path $path)) { continue }

    $item = Get-Item $path -Force

    if ($item.LinkType) {
        # Read the target before removing it: afterwards there is nothing left
        # to resolve and the property comes back empty.
        $target = $item.Target
        # No -Recurse on a link: that deletes through it, into this repo.
        Remove-Item $path -Force
        Write-Host "unlinked  $path  ->  $target"
        $removed++
    } elseif ($KeepInstalled) {
        Write-Host "kept      $path"
    } else {
        Remove-Item $path -Recurse -Force
        Write-Host "removed   $path"
        $removed++
    }
}

if ($removed -eq 0) {
    Write-Host "nothing to do -- no copy of the mod found under $GameDir"
}
