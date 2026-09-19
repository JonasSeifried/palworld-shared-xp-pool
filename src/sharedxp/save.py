"""Reading and writing player XP in a Palworld Level.sav.

Player level/XP lives in Level.sav, not the per-player files:
    worldSaveData.CharacterSaveParameterMap[].value.RawData.value.object
        .SaveParameter.value -> {IsPlayer, Level, Exp, NickName, ...}
The per-player Players/<uid>.sav holds inventory and TechnologyPoint instead.
"""

from __future__ import annotations

import shutil
import time
from dataclasses import dataclass
from pathlib import Path

from palworld_save_tools.gvas import GvasFile
from palworld_save_tools.palsav import compress_gvas_to_sav, decompress_sav_to_gvas
from palworld_save_tools.paltypes import PALWORLD_CUSTOM_PROPERTIES, PALWORLD_TYPE_HINTS

from .pool import Player

LEVEL_SAV = "Level.sav"


class SaveError(Exception):
    pass


@dataclass
class LevelSave:
    path: Path
    gvas: GvasFile
    save_type: int

    @classmethod
    def load(cls, world_dir: str | Path) -> LevelSave:
        path = Path(world_dir) / LEVEL_SAV
        if not path.is_file():
            raise SaveError(f"no {LEVEL_SAV} in {world_dir}")
        with open(path, "rb") as f:
            raw, save_type = decompress_sav_to_gvas(f.read())
        gvas = GvasFile.read(raw, PALWORLD_TYPE_HINTS, PALWORLD_CUSTOM_PROPERTIES)
        return cls(path=path, gvas=gvas, save_type=save_type)

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
                    level=sp.get("Level", {}).get("value", 1),
                    exp=sp.get("Exp", {}).get("value", 0),
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
            sp["Level"]["value"] = level
            sp["Exp"]["value"] = exp
            written += 1
        return written

    def backup(self) -> Path:
        stamp = time.strftime("%Y%m%d-%H%M%S")
        dest = self.path.with_suffix(f".sav.bak-{stamp}")
        shutil.copy2(self.path, dest)
        return dest

    def save(self) -> None:
        raw = self.gvas.write(PALWORLD_CUSTOM_PROPERTIES)
        blob = compress_gvas_to_sav(raw, self.save_type)
        tmp = self.path.with_suffix(".sav.tmp")
        with open(tmp, "wb") as f:
            f.write(blob)
        tmp.replace(self.path)


def normalize_uid(uid: str) -> str:
    """Players/<uid>.sav names the uid without dashes; Level.sav uses a UUID."""
    return uid.replace("-", "").lower()


@dataclass
class PlayerSave:
    """One Players/<uid>.sav -- where technology points and unlocks live."""

    path: Path
    gvas: GvasFile
    save_type: int

    @classmethod
    def load(cls, path: str | Path) -> PlayerSave:
        path = Path(path)
        with open(path, "rb") as f:
            raw, save_type = decompress_sav_to_gvas(f.read())
        gvas = GvasFile.read(raw, PALWORLD_TYPE_HINTS, PALWORLD_CUSTOM_PROPERTIES)
        return cls(path=path, gvas=gvas, save_type=save_type)

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

    def save(self) -> None:
        raw = self.gvas.write(PALWORLD_CUSTOM_PROPERTIES)
        blob = compress_gvas_to_sav(raw, self.save_type)
        tmp = self.path.with_suffix(".sav.tmp")
        with open(tmp, "wb") as f:
            f.write(blob)
        tmp.replace(self.path)
