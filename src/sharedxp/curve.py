"""The player XP curve: cumulative XP -> level.

The table is data, not code. It is extracted from the installed game's own
DataTable so it matches the running version; community tables have been wrong.
`validate` exists so a table can always be re-checked against real saves.
"""

from __future__ import annotations

import json
from dataclasses import dataclass
from pathlib import Path


class CurveError(Exception):
    pass


@dataclass(frozen=True)
class Observation:
    """A real (level, exp) pair read out of a save -- used to check a table."""

    name: str
    level: int
    exp: int


@dataclass(frozen=True)
class ExpCurve:
    #: level -> cumulative XP needed to have reached that level
    cumulative: dict[int, int]
    source: str = "unknown"

    def __post_init__(self) -> None:
        if not self.cumulative:
            raise CurveError("curve table is empty")
        levels = sorted(self.cumulative)
        if levels[0] != 1:
            raise CurveError(f"curve must start at level 1, starts at {levels[0]}")
        prev = -1
        for lv in levels:
            cur = self.cumulative[lv]
            if cur < prev:
                raise CurveError(f"curve is not monotonic at level {lv}")
            prev = cur

    @property
    def max_level(self) -> int:
        return max(self.cumulative)

    def level_for_exp(self, exp: int) -> int:
        """Highest level whose cumulative requirement this XP total meets."""
        if exp < 0:
            raise ValueError("exp cannot be negative")
        best = 1
        for lv in sorted(self.cumulative):
            if self.cumulative[lv] <= exp:
                best = lv
            else:
                break
        return best

    def exp_for_level(self, level: int) -> int:
        try:
            return self.cumulative[level]
        except KeyError:
            raise CurveError(f"level {level} is not in the table") from None

    def validate(self, observations: list[Observation]) -> list[str]:
        """Return a failure line per observation the table cannot explain.

        A player sitting at level L with X XP means the table must satisfy
        cumulative[L] <= X < cumulative[L+1]. Anything else means the table does
        not describe the game that produced this save.
        """
        failures = []
        for o in observations:
            got = self.level_for_exp(o.exp)
            if got != o.level:
                failures.append(
                    f"{o.name}: save says level {o.level} at {o.exp:,} XP, "
                    f"table says level {got}"
                )
        return failures

    @classmethod
    def from_json(cls, path: str | Path) -> ExpCurve:
        raw = json.loads(Path(path).read_text(encoding="utf-8"))
        table = {int(k): int(v) for k, v in raw["cumulative"].items()}
        return cls(cumulative=table, source=raw.get("source", str(path)))
