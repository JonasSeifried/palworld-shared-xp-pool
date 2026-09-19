"""Reading and writing player XP in a Palworld Level.sav.

Player level/XP lives in Level.sav, not the per-player files:
    worldSaveData.CharacterSaveParameterMap[].value.RawData.value.object
        .SaveParameter.value -> {IsPlayer, Level, Exp, NickName, ...}
The per-player Players/<uid>.sav holds inventory and TechnologyPoint instead.
"""

from __future__ import annotations

import contextlib
import io
import shutil
import time
from dataclasses import dataclass
from pathlib import Path

from palworld_save_tools.gvas import GvasFile
from palworld_save_tools.paltypes import PALWORLD_TYPE_HINTS

from .compression import SaveFormat, compress_sav, decompress_sav, zlib_format_for
from .pool import Player
from .rawdata import CUSTOM_PROPERTIES, read_exp, read_level, write_exp, write_level

LEVEL_SAV = "Level.sav"


class SaveError(Exception):
    pass


@contextlib.contextmanager
def _quiet():
    """Swallow palworld-save-tools' running commentary.

    It prints a "Struct type for X not found, assuming StructProperty" line for
    every struct it has no hint for -- 321 of them on one current-patch save,
    none of them actionable. Suppressing stdout does not hide failures; those
    come back as exceptions.
    """
    with contextlib.redirect_stdout(io.StringIO()):
        yield


@dataclass
class LevelSave:
    path: Path
    gvas: GvasFile
    fmt: SaveFormat

    @classmethod
    def load(cls, world_dir: str | Path) -> LevelSave:
        path = Path(world_dir) / LEVEL_SAV
        if not path.is_file():
            raise SaveError(f"no {LEVEL_SAV} in {world_dir}")
        with open(path, "rb") as f:
            raw, fmt = decompress_sav(f.read())
        with _quiet():
            gvas = GvasFile.read(raw, PALWORLD_TYPE_HINTS, CUSTOM_PROPERTIES)
        return cls(path=path, gvas=gvas, fmt=fmt)

    def _player_entries(self):
        try:
            cmap = self.gvas.properties["worldSaveData"]["value"][
                "CharacterSaveParameterMap"
            ]["value"]
        except KeyError as e:
            raise SaveError(f"unexpected save layout, missing {e}") from None

        for entry in cmap:
            try:
                sp = entry["value"]["RawData"]["value"]["object"]["SaveParameter"]["value"]
            except (KeyError, TypeError):
                continue
            if sp.get("IsPlayer", {}).get("value") is not True:
                continue
            yield entry, sp

    def players(self) -> list[Player]:
        out = []
        for entry, sp in self._player_entries():
            uid = str(entry["key"]["PlayerUId"]["value"])
            out.append(
                Player(
                    uid=uid,
                    name=sp.get("NickName", {}).get("value", "<unnamed>"),
                    level=read_level(sp),
                    exp=read_exp(sp),
                )
            )
        return out

    def apply(self, targets: dict[str, tuple[int, int]]) -> int:
        """Write {uid: (level, exp)} into the in-memory save. Returns count written."""
        written = 0
        for entry, sp in self._player_entries():
            uid = str(entry["key"]["PlayerUId"]["value"])
            if uid not in targets:
                continue
            level, exp = targets[uid]
            if "Level" not in sp or "Exp" not in sp:
                raise SaveError(f"player {uid} has no Level/Exp field to write")
            write_level(sp, level)
            write_exp(sp, exp)
            written += 1
        return written

    def backup(self) -> Path:
        stamp = time.strftime("%Y%m%d-%H%M%S")
        dest = self.path.with_suffix(f".sav.bak-{stamp}")
        shutil.copy2(self.path, dest)
        return dest

    def save(self) -> bool:
        """Write the file back. Returns True if the format was converted.

        An Oodle save cannot be written as Oodle -- there is no open compressor
        -- so it comes back as zlib. Callers surface that rather than swallowing
        it, because it is a change to the file beyond the values we edited.
        """
        fmt = self.fmt
        converted = fmt.is_oodle
        if converted:
            fmt = zlib_format_for(self.path.name)

        with _quiet():
            raw = self.gvas.write(CUSTOM_PROPERTIES)
        blob = compress_sav(raw, fmt)
        tmp = self.path.with_suffix(".sav.tmp")
        with open(tmp, "wb") as f:
            f.write(blob)
        tmp.replace(self.path)
        self.fmt = fmt
        return converted


def normalize_uid(uid: str) -> str:
    """Players/<uid>.sav names the uid without dashes; Level.sav uses a UUID."""
    return uid.replace("-", "").lower()


@dataclass
class PlayerSave:
    """One Players/<uid>.sav -- where technology points and unlocks live."""

    path: Path
    gvas: GvasFile
    fmt: SaveFormat

    @classmethod
    def load(cls, path: str | Path) -> PlayerSave:
        path = Path(path)
        with open(path, "rb") as f:
            raw, fmt = decompress_sav(f.read())
        with _quiet():
            gvas = GvasFile.read(raw, PALWORLD_TYPE_HINTS, CUSTOM_PROPERTIES)
        return cls(path=path, gvas=gvas, fmt=fmt)

    @classmethod
    def load_all(cls, world_dir: str | Path) -> dict[str, PlayerSave]:
        """Every player file in the world, keyed by normalized uid."""
        folder = Path(world_dir) / "Players"
        if not folder.is_dir():
            raise SaveError(f"no Players/ folder in {world_dir}")
        out = {}
        for p in sorted(folder.glob("*.sav")):
            out[normalize_uid(p.stem)] = cls.load(p)
        return out

    @property
    def _data(self) -> dict:
        try:
            return self.gvas.properties["SaveData"]["value"]
        except KeyError:
            raise SaveError(f"{self.path.name}: no SaveData") from None

    @property
    def uid(self) -> str:
        return normalize_uid(str(self._data["PlayerUId"]["value"]))

    def read_tech(self) -> tuple[int, int | None, tuple[str, ...]]:
        d = self._data
        points = d.get("TechnologyPoint", {}).get("value", 0)
        boss = d["bossTechnologyPoint"]["value"] if "bossTechnologyPoint" in d else None
        unlocked = tuple(d.get("UnlockedRecipeTechnologyNames", {}).get("value", {}).get("values", []))
        return points, boss, unlocked

    def write_tech(
        self, points: int, boss_points: int | None, unlocked: tuple[str, ...]
    ) -> None:
        d = self._data

        if "TechnologyPoint" in d:
            d["TechnologyPoint"]["value"] = points
        else:
            d["TechnologyPoint"] = {"id": None, "value": points, "type": "IntProperty"}

        if boss_points is not None:
            if "bossTechnologyPoint" in d:
                d["bossTechnologyPoint"]["value"] = boss_points
            else:
                # the field is genuinely absent on players who never earned one.
                # insert it where the game puts it, right after TechnologyPoint,
                # so the property order matches every other save.
                rebuilt = {}
                for k, v in d.items():
                    rebuilt[k] = v
                    if k == "TechnologyPoint":
                        rebuilt["bossTechnologyPoint"] = {
                            "id": None,
                            "value": boss_points,
                            "type": "IntProperty",
                        }
                d.clear()
                d.update(rebuilt)

        if "UnlockedRecipeTechnologyNames" in d:
            d["UnlockedRecipeTechnologyNames"]["value"]["values"] = list(unlocked)
        else:
            d["UnlockedRecipeTechnologyNames"] = {
                "array_type": "NameProperty",
                "id": None,
                "value": {"values": list(unlocked)},
                "type": "ArrayProperty",
            }

    def backup(self) -> Path:
        stamp = time.strftime("%Y%m%d-%H%M%S")
        dest = self.path.with_suffix(f".sav.bak-{stamp}")
        shutil.copy2(self.path, dest)
        return dest

    def save(self) -> bool:
        """Write the file back. Returns True if the format was converted.

        An Oodle save cannot be written as Oodle -- there is no open compressor
        -- so it comes back as zlib. Callers surface that rather than swallowing
        it, because it is a change to the file beyond the values we edited.
        """
        fmt = self.fmt
        converted = fmt.is_oodle
        if converted:
            fmt = zlib_format_for(self.path.name)

        with _quiet():
            raw = self.gvas.write(CUSTOM_PROPERTIES)
        blob = compress_sav(raw, fmt)
        tmp = self.path.with_suffix(".sav.tmp")
        with open(tmp, "wb") as f:
            f.write(blob)
        tmp.replace(self.path)
        self.fmt = fmt
        return converted
