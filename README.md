# Palworld Shared XP Pool

One XP pool for everyone on a server. Everybody contributes, everybody benefits.

**Status: v0 (offline save editor).** Works end-to-end on a real save. The live
UE4SS mod is not started yet.

## What v0 does

Reads every player out of a world's `Level.sav`, averages their XP into a single
pool, and pulls anyone below the pool up to it.

    .venv/Scripts/python -m sharedxp.cli report <world-dir>
    .venv/Scripts/python -m sharedxp.cli apply  <world-dir>

`report` never writes. `apply` backs up `Level.sav` first, then re-reads from
disk afterwards and fails loudly if the values did not land.

`<world-dir>` is the folder containing `Level.sav`, e.g.
`%LOCALAPPDATA%\Pal\Saved\SaveGames\<steamid>\<worldid>`.

## The two rules

**Average, don't sum.** Summing would hand a 4-player group a 4x XP multiplier.
The pool is the mean of everyone's XP (`--mode` also offers `max` and `sum`).

**Never de-level.** A player already ahead of the pool keeps everything and is
left alone; the pool has to grow past them before they move again. So averaging
only ever pulls people *up* -- it never takes progress away.

These interact in a way worth being explicit about: on a group with a wide
spread, most players will not move at all. Only those below the average do.

## Curve drift

The XP table in `data/exp_table.json` is datamined from the current build. Old
saves were made under an older curve, so their stored levels can be ahead of
what their XP implies under the current table. `report` prints this as drift
rather than an error -- the never-de-level rule makes it harmless, since those
players simply keep their grandfathered level.

The table is data, not code. `ExpCurve.validate()` re-checks any table against
real `(level, xp)` pairs from a save.

## Known gaps

- **Technology points are not granted.** Levels in Palworld award technology
  points, which live in `Players/<uid>.sav`, not `Level.sav`. A player lifted by
  the pool gets the levels but not the points they would have earned. This needs
  fixing before v0 is used on a save anyone cares about.
- **Pals are not touched.** Only player characters are pooled.
- **Offline-only.** The server must be stopped; the game writes on exit and will
  overwrite anything changed underneath it.

## Testing

See [TESTING.md](TESTING.md). You do not need other players -- the pool math is
pure and unit-tested, and multi-player scenarios are simulated at the data layer.

    .venv/Scripts/python -m pytest -q
