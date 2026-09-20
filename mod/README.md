# Shared XP Pool

**Everyone in your world stays at the same level.**

Go off and do your own thing -- mine, build, hunt, explore -- and nobody falls
behind. Come back after a week away and you are level with everyone else.
Somebody joining your world for the first time starts where you are, not at
level 1.

It does not invent XP. The world progresses at the pace of whoever is doing
best, and everybody shares that pace. Playing side by side still works exactly
like vanilla; the mod's job is making sure that *splitting up* costs nobody
their progress.

## What it does not do

**It will not level you faster than the best player among you.** Two of you
killing things in different places does not add up -- you both end up wherever
the better of you got to. Standing together in vanilla already gives you both
kills, so playing together is still the quickest way to play. The mod removes
the penalty for not doing that; it is not a multiplier.

**Your pals come along.** XP is paid through the game's own party grant, so a
pal gains roughly a fifth of what its owner does -- the same way it would if the
owner had earned it. The mod does not choose that fraction and cannot turn it
off: Palworld has no player-only XP call.

**Nobody is ever lowered.** If you are the one in front, nothing happens to you.

## Install

On the **host's** machine only. Palworld decides XP server-side, so the host
decides it for everyone and joining clients need nothing installed.

**Playing it:** take `SharedXPPool-<version>.zip` from a
[release](../../../releases) and extract it over the Palworld folder -- the one
with `Pal\` in it. It carries the mod once for each folder a UE4SS build reads
mods from, so it works whether UE4SS came from the Steam Workshop or from
Okaetsu's GitHub release; only the one your build uses ever loads.
[`INSTALL.txt`](INSTALL.txt) is the same instructions, and ships inside the
zip.

**Working on it:** the two scripts below instead, which junction this folder
into the game so edits take effect in place.

```powershell
.\tools\install_ue4ss.ps1 -Dev
.\tools\link_mod.ps1
```

`link_mod.ps1` makes the game's mod folder a junction into this one, so run
`.\tools\unlink_mod.ps1` before installing a release archive over the game --
extracting it while the junction is there writes straight through it and
overwrites the working tree.

`install_ue4ss.ps1` fetches [Okaetsu's Palworld fork of
UE4SS](https://github.com/Okaetsu/RE-UE4SS/releases/latest). Stock RE-UE4SS does
not work -- Palworld made engine edits in 0.4.1.5 and needs this build. Do not
also subscribe to the Steam Workshop copy; two copies load at once and the game
crashes on launch.

`link_mod.ps1` junctions `mod/SharedXPPool` into the game's mods folder, so
edits here take effect in place. Both default to
`D:\SteamLibrary\steamapps\common\Palworld`; pass `-GameDir` for anywhere else.
Logs go to `<game>\Pal\Binaries\Win64\ue4ss\UE4SS.log`, and a working start looks
like:

```
[SharedXPPool] loading
[SharedXPPool] sharing active, checking every 1000 ms
[SharedXPPool] ready -- bound: F11 pause/resume sharing  (debug keys off)
```

## Settings

Everything lives in [`Scripts/config.lua`](SharedXPPool/Scripts/config.lua), with
the reasoning next to each one. The only one most people would touch:

```lua
config.catch_up_rate = 0.25   -- a quarter of the gap each second; 1.0 is instant, 0 is off
```

A fraction rather than an amount of XP, because a number that is sensible at
level 10 -- where a level costs 1,900 XP -- is a rounding error at level 60,
where it costs 670,000.

**F11 pauses and resumes sharing**, so you can stop the mod mid-session without
alt-tabbing out to edit files. Nothing accumulates while it is paused.

## How it works

One rule, re-asserted every second: **read everybody's XP total, find the
highest, move everyone else toward it.**

That is the whole thing. Catching a returning player up and sharing during play
are the same operation, so there is no login hook and no catch-up mode. It
cannot loop, because every payout moves people toward a fixed point and a tick
where everybody is level pays nothing. A failed reading costs one tick, because
nothing is carried between ticks.

Three things the rule needs:

**A payout that reaches only its recipient.** `AddExpValue_forPlayerParty_Server`
names its recipients, and the first payout of a session is verified to have
actually moved the XP. If it ever fails, the mod shares nothing and says so --
the alternative call is a sphere that reaches bystanders, which would move the
top every time it was approached and make the mod chase it forever. A payout
whose result cannot be *read back* is not the same thing as one that failed, and
is not treated as one: it is checked again next time.

**A guard against a reading the game could not have produced.** XP never
decreases in Palworld, so a reading below that player's previous one is wrong by
definition; and no real total is in the billions, so one that is has been
mangled on its way out of the engine. Both are refused, and a refused reading
never becomes the new baseline -- otherwise the same bad reading is believed one
tick later and the player is paid the whole pool on top of what they already
have. Nobody is paid on the first tick they are seen, either, in case the number
is still settling. Baselines belong to the loaded world and are dropped when a
different one is loaded.

**Evidence that payouts are landing.** After paying somebody, the next reading
has to show their total moving. Three payouts without it -- a recipient the game
will not take past the level cap, a patched-out function -- and they are left
alone until it does move, rather than being paid the same gap every second for
the rest of the session.

Payouts go through the game's own XP function rather than writing the `Exp`
field, so level-ups, the UI and replication happen normally. The mod never sets
a level -- it adds XP and the game does the rest.

## Testing

```
lua mod/tests/test_pool.lua
```

Thirty-eight tests against a stubbed UE4SS, which is the whole suite -- no game
and no second player needed. The ones worth having:

- everybody is brought up to the highest total, and nobody is lowered
- it settles after one gap and stays settled
- a bad reading is refused the *second* time it is read as well as the first
- a reading past anything the game can produce is refused
- a player is not paid on the first tick they are seen, and does not set the top
- an unreadable player is skipped, and does not set the top
- a payout that cannot be read back does not switch sharing off for the session
- paying somebody whose total never moves stops, and resumes when it moves
- loading a different world forgets the last one's baselines
- nothing is shared if the precise payout does not work
- nothing on the read path calls `StaticFindObject`
- the shipped config arms nothing that changes a world on its own

Each was checked by breaking the code it defends and watching it go red.

To test in game, set `config.debug_keys = true` -- these keys are not bound in a
normal session because two of them inject XP and one of them walks reflected
function parameters, which hard-crashed the game twice during discovery.

| key | |
|---|---|
| **F7** | read and report every connected player |
| **F8** / **F6** | pay player 1 / player 2 `config.test_grant_amount` XP |
| **F9** | dump the exp API's function signatures |

`config.watch_totals = true` logs everybody's total once a second whether or not
anything is paid. Pause first, or the mod's own payouts are in the readings.

## Layout

| | |
|---|---|
| `Scripts/config.lua` | every knob, with the reasoning next to it |
| `Scripts/pool.lua` | the rule |
| `Scripts/players.lua` | finding players, reading their XP, paying them |
| `Scripts/probe.lua` | discovery: the hooks, the F7 dump, the F9 signatures |
| `INSTALL.txt` | what ships in the zip, for somebody who has only the zip |
| `nexus-description.bbcode` | the Nexus page, kept here so it is reviewed like the rest |
| `steam-workshop-description.bbcode` | the Steam Workshop page, in Steam's BBCode dialect |
| `PUBLISHING.md` | cutting a release, and what to fill in on each site |
| `thumbnail-512.png` | the Steam Workshop thumbnail -- type only, since it is shown at about a hundred pixels |
| `banner-1280x720.png` | the Nexus page image |
| `TESTING.md` | what a release has to be tried on before it goes out |

`probe.lua` is a third of the mod's code and none of it runs in a normal
session, so it is not loaded unless `debug_keys` or `probe_only` is set. Of the
701 lines of code here, 233 are that file; the mod proper is 468, of which 217
is reaching into Palworld through UE4SS reflection and 192 is the rule itself.

`players.lua` enumerates through `UEHelpers.GetAllPlayers`. Not
`FindAllOf("PalPlayerState")`, which returns nothing at all on some builds --
and fails silently, so every loop over it matches nobody and the mod looks
simply broken; and not `PalUtility`, which crashed the game outright. It tries
four different ways to reach a character's individual parameter, because which
one is reachable from Lua is build-dependent, and remembers the one that worked.

## What was tried first, and why it is gone

Worth reading before extending this, because most of the appealing ideas here
are ones that were already followed to the end.

**Hooking the XP award.** Ten candidate functions, eight hookable. Killing pals
fires exactly one of them, `AddExp_EnemyDeath`, whose only argument is a
`PalDeadInfo` of `{LastDamage, LastAttacker, selfActor}` -- **no amount and no
player**. The XP is computed inside the game from the thing that died, so the
award cannot be read from a hook. Rebuilding the formula would mean getting it
right for kills, then again for crafting, building, capturing and expeditions.

**Sharing XP as it is earned.** The design this replaced: remember each player's
total, work out what they gained since the last look, top up whoever gained
less. It survived three in-game runs and grew a loop fix, a leak fix, a
stale-reading rule, a rise cap and a catch-up allocator -- all of it propping up
one unanswerable question. When two players both gain inside the same second,
was that one kill the game shared with both of them, or two separate kills? The
totals are identical either way, and the answer decides whether to match the
larger or add them together. It needed a sharing radius nobody could measure
reliably. Asking what everyone *should have* instead deletes the question.

**Widening Palworld's own sharing radius.** `BP_PalGameSetting_C` holds 680
tuning constants as writable numbers, and writing them works --
`MapObjectDistributeExpRange` went from 1000 to 1000000 in game and read back
changed. But it is the only *distance* among them: everything else XP-flavoured
is an amount or a multiplier, and kill and capture XP are distributed in native
code with nothing exposed. So it would have covered mining and chopping and
nothing else, making behaviour depend on how the XP was earned -- the exact
fragility the current rule avoids.

**Pal XP is not a fixed fraction in vanilla.** Measured: crafting gave the
player 5 and the pal 1, a kill gave 12 and 2, a capture gave 39 and 2.
`OtomoExp_LevelDifferenceMap` and `OtomoExp_HigherPlayerLevel` say why -- it is
keyed on the gap between pal and player level. The party grant the mod uses pays
a flat fifth, so a topped-up player's pals gain at the generous end of vanilla's
range rather than matching it exactly.

Two numbers from that dump worth keeping: `CharacterMaxLevel` reads **80** on
this build, where `data/exp_table.json` runs to 100; and `MaxPlayerNum` reads
**4** on a hosted world.

**A warning for anyone extending the probe.** Reading a parameter's name and
class is safe, but `GetInner`, `GetPropertyClass` and `GetStruct` each read a
field that exists only on their own property type. Called on anything else they
read a wrong offset and kill the process, and `pcall` does not catch it. Asking
every parameter for all three crashed the game on the first one. A test fails if
the code does that again.

Also: `%+s` is not a format. The `+` flag is for numbers, and UE4SS ships a
newer Lua than this test suite runs on, so it raises in game and passes here. A
static check over the sources catches it now.
