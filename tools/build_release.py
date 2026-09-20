#!/usr/bin/env python3
"""Build the release archives.

Two of them, because the two places this is published install it differently.

`SharedXPPool-<version>.zip` is the manual download, for Nexus and for anyone
extracting it by hand. It carries the mod three times over, once for each place
a UE4SS build looks for mods:

    Mods/NativeMods/UE4SS/Mods/       the Steam Workshop UE4SS, by far the most
                                     installed one
    Pal/Binaries/Win64/ue4ss/Mods/    UE4SS installed from Okaetsu's GitHub
                                     release, and what the wiki documents
    Pal/Binaries/Win64/Mods/          UE4SS 3.0.1 and older

All three are relative to the Palworld folder, so one extraction covers every
build and the user does not have to know which one they have. Only the build
they actually installed reads its own folder -- UE4SS finds its Mods directory
next to its own dll, and two UE4SS builds cannot be installed at once -- so
exactly one copy is ever live and the other two are inert text.

Paying 40KB to delete the most common support question is a good trade. The
alternative, picking one path, silently does nothing for whoever guessed wrong.

`SharedXPPool-<version>-workshop.zip` is the Steam Workshop payload: the
Scripts folder on its own, to drop into the folder the Palworld Mod Uploader
creates. It deliberately has no enabled.txt, because Palworld's own Mod
Management screen enables Workshop mods and the file would be redundant.
"""

from __future__ import annotations

import argparse
import shutil
import zipfile
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
MOD = ROOT / "mod" / "SharedXPPool"

# Every Mods directory a UE4SS build might read, relative to the Palworld
# folder. See the module docstring for which build uses which.
MODS_DIRS = [
    "Mods/NativeMods/UE4SS/Mods",
    "Pal/Binaries/Win64/ue4ss/Mods",
    "Pal/Binaries/Win64/Mods",
]


def _scripts() -> list[Path]:
    files = sorted((MOD / "Scripts").glob("*.lua"))
    if not files:
        raise SystemExit(f"no Lua sources under {MOD / 'Scripts'}")
    return files


def _zip(path: Path, files: dict[str, Path]) -> Path:
    path.parent.mkdir(parents=True, exist_ok=True)
    with zipfile.ZipFile(path, "w", zipfile.ZIP_DEFLATED) as archive:
        for arcname, source in sorted(files.items()):
            archive.write(source, arcname)
    return path


def build_manual(version: str, out: Path) -> Path:
    """The extract-over-your-Palworld-folder archive, all three layouts."""
    files: dict[str, Path] = {}
    for mods_dir in MODS_DIRS:
        base = f"{mods_dir}/SharedXPPool"
        files[f"{base}/enabled.txt"] = MOD / "enabled.txt"
        files[f"{base}/INSTALL.txt"] = ROOT / "mod" / "INSTALL.txt"
        files[f"{base}/LICENSE.txt"] = ROOT / "LICENSE"
        for script in _scripts():
            files[f"{base}/Scripts/{script.name}"] = script
    return _zip(out / f"SharedXPPool-{version}.zip", files)


def build_workshop(version: str, out: Path) -> Path:
    """The Steam Workshop payload: Scripts/ only, and no enabled.txt."""
    files = {f"Scripts/{s.name}": s for s in _scripts()}
    files["Scripts/LICENSE.txt"] = ROOT / "LICENSE"
    return _zip(out / f"SharedXPPool-{version}-workshop.zip", files)


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("version", help="version string, without a leading v")
    parser.add_argument("--out", default="dist", type=Path)
    args = parser.parse_args()

    out = (ROOT / args.out).resolve()
    shutil.rmtree(out, ignore_errors=True)

    for archive in (build_manual(args.version, out), build_workshop(args.version, out)):
        print(f"{archive}  ({archive.stat().st_size:,} bytes)")
        for name in zipfile.ZipFile(archive).namelist():
            print(f"    {name}")


if __name__ == "__main__":
    main()
