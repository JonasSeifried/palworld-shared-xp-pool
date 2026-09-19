# Palworld Shared XP Pool

One XP pool and one technology tree for everyone on a server. Everybody
contributes, everybody benefits.

**Status: v0 (offline save editor).** Works end-to-end on a real save. The live
UE4SS mod is not started yet.

## What v0 does

Reads every player out of a world save, then:

- averages their XP into a single pool and pulls anyone below it up to that total
- unions their unlocked technologies, so anything one player researched,
  everyone has

```
.venv/Scripts/python -m sharedxp.cli report <world-dir>
.venv/Scripts/python -m sharedxp.cli apply  <world-dir>
```

`report` never writes. `apply` backs up every file it touches, then re-reads
from disk afterwards and fails loudly if the values did not land.
`--no-tech` pools XP only. `--mode` chooses `mean` (default), `max` or `sum`.

`<world-dir>` is the folder containing `Level.sav`:

- in-game host: `%LOCALAPPDATA%\Pal\Saved\SaveGames\<steamid>\<worldid>`
- dedicated server: `<PalServer>/Pal/Saved/SaveGames/0/<worldid>`

**Stop the game or server first.** Palworld writes on exit and will overwrite
anything changed underneath it.

## The rules

**Average, don't sum.** Summing would hand a 4-player group a 4x XP multiplier.
The pool is the mean of everyone's XP.

**Never lower anything.** A player ahead of the pool keeps their XP and level;
the pool must grow past them before they move. Unlocks are unioned, never
removed. Technology points rise to the highest balance anyone holds.

These interact in a way worth being explicit about: on a group with a wide XP
spread, most players will not move at all -- only those below the average do.
The tech tree is the opposite, and tends to change everyone at once.

## Where the data lives

| | |
|---|---|
| `Level.sav` | every player's `Level` and `Exp`, inside `CharacterSaveParameterMap` |
| `Players/<uid>.sav` | `TechnologyPoint`, `bossTechnologyPoint`, `UnlockedRecipeTechnologyNames` |

`bossTechnologyPoint` is genuinely absent on players who never earned one, so
the tool distinguishes "absent" from "zero" and inserts the field in the same
position the game uses.

## Curve drift

`data/exp_table.json` is datamined from the current build. Old saves were made
under an older curve, so their stored levels can be ahead of what their XP
implies today. `report` prints this as drift rather than failing -- the
never-lower rule makes it harmless, since those players keep their grandfathered
level. `ExpCurve.validate()` re-checks any table against real `(level, xp)`
pairs from a save.

## Known gaps

- **Technology costs are not modelled.** Players receive the unioned unlocks for
  free and their point balance rises to the group maximum. Nobody is charged for
  unlocks they did not choose, but it does mean a player lifted several levels
  gets the group's balance rather than per-level point awards.
- **Pals are not touched.** Only player characters are pooled.
- **Offline-only.** This is a save editor, not a live mod.

## Testing

See [TESTING.md](TESTING.md). You do not need other players -- the pool and tech
logic are pure and unit-tested, and multi-player scenarios are simulated at the
data layer.

```
.venv/Scripts/python -m pytest -q
```
