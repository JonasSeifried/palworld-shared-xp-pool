# Palworld Shared XP Pool

One XP pool for everyone on a server. Everybody contributes, everybody benefits.

**Status:** v0, the offline save editor, works end-to-end on a real save. v1,
the live UE4SS mod, is written and unit-tested but has not run inside Palworld
yet -- see [mod/README.md](mod/README.md).

The two are not rivals. The live mod shares XP between players who are connected
at the time; the save editor catches up anyone who was not. Once the mod is
running, `apply` becomes the between-sessions top-up rather than the whole
product.

## What v0 does

Reads every player out of a world save, averages their XP into a single pool,
and pulls anyone below the pool up to that total.

```
.venv/Scripts/python -m sharedxp.cli report <world-dir>
.venv/Scripts/python -m sharedxp.cli apply  <world-dir>
```

`report` never writes. `apply` backs up every file it touches, then re-reads
from disk afterwards and fails loudly if the values did not land.
`--mode` chooses `mean` (default), `max` or `sum`.

`<world-dir>` is the folder containing `Level.sav`:

- in-game host: `%LOCALAPPDATA%\Pal\Saved\SaveGames\<steamid>\<worldid>`
- dedicated server: `<PalServer>/Pal/Saved/SaveGames/0/<worldid>`

**Stop the game or server first.** Palworld writes on exit and will overwrite
anything changed underneath it.

## The rules

**Average, don't sum.** Summing would hand a 4-player group a 4x XP multiplier.
The pool is the mean of everyone's XP.

**Never lower anything.** A player ahead of the pool keeps their XP and level;
the pool must grow past them before they move. So averaging only ever pulls
people up -- it never takes progress away.

On a group with a wide XP spread, most players will not move at all. Only those
below the average do.

## Technology is deliberately not shared

Each player keeps their own technology tree. This is a balance decision, not an
oversight.

With a shared XP pool everyone is already the same level, so everyone earns the
same technology points and builds their own tree at exactly one player's rate.
That is vanilla balance per player, by construction.

Sharing the tree is a real feature, but it is a *buff* unless the group also
shares a single point balance -- three players each spending their own points on
one tree unlocks roughly three times as fast as a solo player. Making it neutral
offline would need each technology's point cost, which is not published and
would mean extracting the game's own DataTable. In the live mod it is nearly
free: the game charges the points, and the mod just mirrors one balance and one
unlock set to everyone. So it belongs there, not here.

The implementation exists and is tested. `--tech` opts in:

```
.venv/Scripts/python -m sharedxp.cli report <world-dir> --tech
```

It unions everyone's unlocks and raises every balance to the group maximum.
Treat it as experimental, and know that it hands the group more purchasing
power than a solo player has.

## Where the data lives

| | |
|---|---|
| `Level.sav` | every player's `Level` and `Exp`, inside `CharacterSaveParameterMap` |
| `Players/<uid>.sav` | `TechnologyPoint`, `bossTechnologyPoint`, `UnlockedRecipeTechnologyNames` |

`bossTechnologyPoint` is genuinely absent on players who never earned one, so
the tool distinguishes "absent" from "zero" and inserts the field in the same
position the game uses.

Note that `UnlockedRecipeTechnologyNames` mixes level-granted recipes with
purchased tech-tree nodes, so its length is not a count of points spent.

## Curve drift

`data/exp_table.json` is datamined from the current build. Old saves were made
under an older curve, so their stored levels can be ahead of what their XP
implies today. `report` prints this as drift rather than failing -- the
never-lower rule makes it harmless, since those players keep their grandfathered
level. `ExpCurve.validate()` re-checks any table against real `(level, xp)`
pairs from a save.

## Known gaps

- **Pals are not touched.** Only player characters are pooled.
- **Offline-only.** This half is a save editor. The live mod is in `mod/`.
- **Not yet loaded in Palworld.** Every check so far is at the data layer:
  files round-trip, structures intact, property order matches vanilla. Whether
  the game accepts an edited save is still unverified.

## Testing

See [TESTING.md](TESTING.md). You do not need other players -- the pool and tech
logic are pure and unit-tested, and multi-player scenarios are simulated at the
data layer.

```
.venv/Scripts/python -m pytest -q
```

That covers the live mod's Lua suite too, and skips it if Lua is not installed.
