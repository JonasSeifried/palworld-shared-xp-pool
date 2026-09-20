# Testing a release

The suite covers the rule. It cannot cover UE4SS, and it cannot cover a second
player, so a release gets tried in a game as well.

```
lua mod/tests/test_pool.lua
```

**Run `.\tools\unlink_mod.ps1` before installing an archive.** `link_mod.ps1`
makes the game's mod folder a junction into this repo, and extracting an
archive while that junction is there writes through it and overwrites the
working tree.

The load path differs per install route; the behaviour does not. So test
loading on each route with one player, and test sharing once with two.

## Phase A -- does it load

Only one UE4SS can be installed at a time, so these are sequential. Ordered to
switch UE4SS once: A3 uses a manual install, A2 and A1 share a Workshop one.

| | UE4SS from | Mod from | Loads from |
|---|---|---|---|
| A3 | Okaetsu's GitHub release | the archive | `Pal\Binaries\Win64\ue4ss\Mods\` |
| A2 | Steam Workshop | the archive | `Mods\NativeMods\UE4SS\Mods\` |
| A1 | Steam Workshop | a hidden Workshop item | `Mods\NativeMods\UE4SS\Mods\` |

The archive installs three copies, one per layout, so a pass does not say which
one loaded. Delete the two you are not testing first, or the result means
nothing.

A1 needs an upload, but not a public one: the Palworld Mod Uploader creates
items hidden, and you can subscribe to your own hidden item. It is the only
test of the subscription path and of the payload loading *without* an
`enabled.txt`, so a manual copy cannot stand in for it.

Pass: in `UE4SS.log`, which sits next to the UE4SS dll and therefore moves with
the install route --

```
[SharedXPPool] loading
[SharedXPPool] sharing active, checking every 1000 ms
[SharedXPPool] ready -- bound: F11 pause/resume sharing  (debug keys off)
```

Disable a manual UE4SS by renaming `dwmapi.dll` to `dwmapi.dll.bak`, which is
what Okaetsu's release notes suggest. Unsubscribe the Workshop one in Steam.
Never both at once -- two copies load and the game crashes on launch.

### Results, v1.0.0-beta.1, 2026-09-20

All three routes loaded. Two things worth keeping:

**The Workshop route reports itself differently.** A3 and A2 log `Mod
'SharedXPPool' has enabled.txt, starting mod.`; A1 logs `Starting Lua mod
'SharedXPPool'` with no mention of `enabled.txt`. That is Palworld's own Mod
Management enabling it, and it confirms the Workshop payload is right to leave
the file out.

**The world object changes three times a session, then stops.** Twice between
launching the game and the main menu, once on entering a world, and never
again -- measured across two full logs. `pool.lua` leans on that: a change is
only acted on when there is something to forget, so the transitions at startup
are silent. If a future build logs `a different world is loaded` repeatedly
during play, that assumption has broken.

## Phase B -- does it share

Two players, once. **Host a throwaway world for the first run**, not one that
matters: the mod grants XP that cannot be taken back. The mod runs on the host,
so it goes on whoever hosts.

1. Both join, and confirm two players are seen. Below two, every tick is a
   deliberate no-op and nothing is being tested.
2. One player earns XP far away from the other.
3. `paying via AddExpValue_forPlayerParty_Server` appears. That is the first
   payout verifying, and the session is doing real work from here.
4. The player behind climbs and levels up on their own. The player in front
   never moves.
5. F11 -> `sharing PAUSED`, earn XP, nobody is topped up, F11 again.
6. The player behind logs out, the other earns, they come back and are caught
   up within seconds. No login hook is involved; it is the same rule.

Two lines mean an assumption about the game was wrong:

- `has been paid N times without their total moving`, while XP is visibly
  moving in game -> the game applies XP more slowly than assumed. Raise
  `STUCK_AFTER` in `pool.lua`.
- `read ... below the ... seen before`, recurring in ordinary play -> the
  refusal rule is too strict. It no longer lowers a baseline on its own, which
  is deliberate, so a false positive now persists instead of healing.

### Results, v1.0.0-beta.2, 2026-09-20

Two players on a hosted test world, apart. It works, and the XP arrived on the
other machine as well as in the host's log.

`paying via AddExpValue_forPlayerParty_Server` on the first payout, and the
arithmetic matches the rule exactly: 721 behind paid 180, 541 paid 135, 406
paid 101. Pause held through eleven XP earned and paid nobody; resume caught
up. A player who logged out, missed a chunk and rejoined was level again within
seconds, with no login hook involved. Neither `does not go down` nor `without
their total moving` appeared, and the world message fired once, on leaving the
world, which is the beta.2 fix behaving in a game.

One thing to fix, and it is the reason a phase B exists: the tail dribbled. Ten
XP of mining crossed one point per second for ten seconds, because at 0.25
every gap of seven or less rounds down to the minimum payout and the minimum
was 1. Raised to `MIN_STEP`, so a gap worth less than one early-game action
closes in a single tick.
