<#
.SYNOPSIS
    Zip up a hosted Palworld world so someone else can inspect it.

.DESCRIPTION
    Run this on the HOST's machine, with Palworld closed. It finds the worlds
    hosted locally, zips the one you pick, and drops the zip on the Desktop.

    Palworld writes the save on exit, so a copy taken while the game is running
    is a copy of whatever was last flushed -- usually stale, occasionally
    half-written. The script refuses to run rather than hand you one of those.

    The backup/ folder is left out. It is old copies of the same world and is
    often larger than the world itself.

.PARAMETER WorldId
    Which world, if more than one is hosted. The script lists them if you omit
    it and there is any ambiguity.
#>
param(
    [string]$WorldId,
    [string]$OutDir = [Environment]::GetFolderPath("Desktop")
)

$ErrorActionPreference = "Stop"

if (Get-Process -Name "Palworld-Win64-Shipping" -ErrorAction SilentlyContinue) {
    throw "Palworld is still running. Quit to the desktop first -- the game writes the save on exit."
}

$root = Join-Path $env:LOCALAPPDATA "Pal\Saved\SaveGames"
if (-not (Test-Path $root)) { throw "No Palworld saves at $root" }

# A hosted world has a Level.sav. A world you only ever joined has just a
# LocalData.sav, so this also filters out other people's worlds.
$worlds = Get-ChildItem $root -Directory -Recurse -Depth 1 |
    Where-Object { Test-Path (Join-Path $_.FullName "Level.sav") }

if (-not $worlds) {
    throw "No hosted worlds found. Worlds you only joined are not stored here -- only the host has them."
}

if ($WorldId) {
    $world = $worlds | Where-Object { $_.Name -eq $WorldId }
    if (-not $world) { throw "No world named $WorldId. Found: $($worlds.Name -join ', ')" }
} elseif ($worlds.Count -eq 1) {
    $world = $worlds[0]
} else {
    Write-Host "More than one hosted world. Re-run with -WorldId <name>:"
    foreach ($w in $worlds) {
        $players = @(Get-ChildItem (Join-Path $w.FullName "Players") -Filter *.sav -ErrorAction SilentlyContinue).Count
        $when = (Get-Item (Join-Path $w.FullName "Level.sav")).LastWriteTime
        Write-Host ("  {0}   {1} player(s), last played {2}" -f $w.Name, $players, $when)
    }
    exit 1
}

$staging = Join-Path $env:TEMP ("palworld-" + $world.Name)
if (Test-Path $staging) { Remove-Item $staging -Recurse -Force }
Copy-Item $world.FullName $staging -Recurse -Exclude "backup"
Remove-Item (Join-Path $staging "backup") -Recurse -Force -ErrorAction SilentlyContinue

$zip = Join-Path $OutDir ("palworld-" + $world.Name + ".zip")
if (Test-Path $zip) { Remove-Item $zip -Force }
Compress-Archive -Path (Join-Path $staging "*") -DestinationPath $zip
Remove-Item $staging -Recurse -Force

$size = "{0:N0} MB" -f ((Get-Item $zip).Length / 1MB)
$players = @(Get-ChildItem (Join-Path $world.FullName "Players") -Filter *.sav).Count
Write-Host ""
Write-Host "  $zip"
Write-Host "  $size, world $($world.Name), $players player save(s)"
