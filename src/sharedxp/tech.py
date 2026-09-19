"""Shared technology tree. Pure logic, same never-lower rule as the XP pool.

Three things are shared, and all three only ever move upward:

  unlocked recipes   union across everyone -- if anyone has researched it,
                     everyone has it
  TechnologyPoint    the highest balance anyone holds
  bossTechnologyPoint  likewise (ancient points, from bosses the group fought
                     together anyway)

Deliberately *not* modelled: what each technology costs. Players receive the
union for free rather than being charged for it. Doing otherwise would need the
game's technology cost table, and charging players for unlocks they did not ask
for would mean taking points away -- which is exactly what the never-lower rule
exists to prevent.
"""

from __future__ import annotations

from dataclasses import dataclass


@dataclass(frozen=True)
class PlayerTech:
    uid: str
    name: str
    points: int
    #: None means the save has no bossTechnologyPoint field at all
    boss_points: int | None
    unlocked: tuple[str, ...]


@dataclass(frozen=True)
class TechChange:
    player: PlayerTech
    target_points: int
    target_boss_points: int | None
    target_unlocked: tuple[str, ...]

    @property
    def added(self) -> tuple[str, ...]:
        have = set(self.player.unlocked)
        return tuple(t for t in self.target_unlocked if t not in have)

    @property
    def points_delta(self) -> int:
        return self.target_points - self.player.points

    @property
    def boss_delta(self) -> int:
        return (self.target_boss_points or 0) - (self.player.boss_points or 0)

    @property
    def changed(self) -> bool:
        return bool(self.added) or self.points_delta != 0 or self.boss_delta != 0


@dataclass(frozen=True)
class TechPlan:
    points: int
    boss_points: int | None
    unlocked: tuple[str, ...]
    changes: tuple[TechChange, ...]

    @property
    def touched(self) -> tuple[TechChange, ...]:
        return tuple(c for c in self.changes if c.changed)


def build_tech_plan(players: list[PlayerTech]) -> TechPlan:
    if not players:
        raise ValueError("cannot build a tech plan from zero players")
    if any(p.points < 0 or (p.boss_points or 0) < 0 for p in players):
        raise ValueError("technology point totals cannot be negative")

    # union, but keep a stable order: first-seen wins, so diffs stay readable
    union: list[str] = []
    seen: set[str] = set()
    for p in players:
        for tech in p.unlocked:
            if tech not in seen:
                seen.add(tech)
                union.append(tech)

    points = max(p.points for p in players)

    # if nobody has the field, leave it absent everywhere rather than inventing it
    boss_values = [p.boss_points for p in players if p.boss_points is not None]
    boss = max(boss_values) if boss_values else None

    target = tuple(union)
    changes = tuple(
        TechChange(
            player=p,
            target_points=max(p.points, points),
            target_boss_points=None if boss is None else max(p.boss_points or 0, boss),
            target_unlocked=target,
        )
        for p in players
    )
    return TechPlan(points=points, boss_points=boss, unlocked=target, changes=changes)
