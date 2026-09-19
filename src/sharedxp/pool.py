"""Pure pooling math. No save-file or game dependencies -- fully unit testable."""

from __future__ import annotations

from dataclasses import dataclass
from enum import Enum


class Mode(str, Enum):
    """How the shared pool total is derived from the individual players."""

    MEAN = "mean"  # average XP across players (the default)
    MAX = "max"  # everyone jumps to the furthest-ahead player
    SUM = "sum"  # everyone gets the combined total (very generous)


@dataclass(frozen=True)
class Player:
    uid: str
    name: str
    level: int
    exp: int


@dataclass(frozen=True)
class Change:
    player: Player
    target_exp: int
    target_level: int

    @property
    def changed(self) -> bool:
        return self.target_exp != self.player.exp or self.target_level != self.player.level

    @property
    def exp_delta(self) -> int:
        return self.target_exp - self.player.exp

    @property
    def level_delta(self) -> int:
        return self.target_level - self.player.level


@dataclass(frozen=True)
class Plan:
    mode: Mode
    pool_exp: int
    pool_level: int
    changes: tuple[Change, ...]

    @property
    def touched(self) -> tuple[Change, ...]:
        return tuple(c for c in self.changes if c.changed)


def pool_exp(players: list[Player], mode: Mode = Mode.MEAN) -> int:
    """Combine individual XP totals into the single shared total.

    Averaging uses floor division so the pool never rounds *up* past what the
    group actually earned.
    """
    if not players:
        raise ValueError("cannot build a pool from zero players")

    totals = [p.exp for p in players]
    if any(t < 0 for t in totals):
        raise ValueError("player XP totals cannot be negative")

    if mode is Mode.MEAN:
        return sum(totals) // len(totals)
    if mode is Mode.MAX:
        return max(totals)
    if mode is Mode.SUM:
        return sum(totals)
    raise ValueError(f"unknown mode: {mode}")


def build_plan(players: list[Player], curve, mode: Mode = Mode.MEAN) -> Plan:
    """Work out the per-player target, never lowering anyone.

    A player already ahead of the pool keeps their own XP -- the pool has to
    grow past them before they move again. Everyone behind is pulled up to it.
    """
    total = pool_exp(players, mode)
    changes = []
    for p in players:
        target_exp = max(p.exp, total)
        target_level = max(p.level, curve.level_for_exp(target_exp))
        changes.append(Change(player=p, target_exp=target_exp, target_level=target_level))

    return Plan(
        mode=mode,
        pool_exp=total,
        pool_level=curve.level_for_exp(total),
        changes=tuple(changes),
    )
