# Shared XP Pool -- live mod

The v1 mod: XP is shared as it is earned, instead of being reconciled after the
fact by the save editor.

**Status: discovery mode, one probe run done.** That run settled the design
question and changed it. Sharing is written and unit-tested but still switched
off; one more run decides whether it can be turned on.

## What the first probe run found

Ten candidate XP functions were hooked. Eight registered.
`AddExp_ToCharacter_ByExpCalcType` and `PalIndividualCharacterParameter:AddExp`
exist in the binary as C++ symbols but are not reflected UFunctions, so UE4SS
cannot reach them.

Killing pals fired exactly one of the eight: `AddExp_EnemyDeath`. Its only
argument is a `PalDeadInfo` of `{LastDamage, LastAttacker, selfActor}` -- **no
amount and no player**. The XP is computed inside the game from the thing that
died.

So the original plan, reading the award out of a hook's arguments, cannot work.
Rebuilding the game's XP formula from the dead pal would mean getting it right
for kills, and then again for crafting, building, capturing and expeditions,
each through a different entry point. Every one of those is a chance to silently
pay out the wrong number.

## What it does instead

It watches each player's XP total and reacts to it changing.

`Exp` is cumulative over a character's life, not progress within the current
level -- a level 21 player's save reads 73,865 where the level began at 68,784.
So the difference between two readings is exactly what the game decided that
player earned, whatever they did to earn it and whichever function awarded it.

That makes the mod source-agnostic. Kills, crafting, building, capture bonuses
and anything added in a future patch all look the same.

Payouts go through the game's own `GiveExpToAroundPlayerCharacter` at the
recipient's feet, so level-ups, UI and replication happen normally. Each payout
is recorded and discounted from that player's next reading -- otherwise the mod
would see its own gift as earnings and mirror it again, forever.

## The next run decides it

Press **F7** in game. The dump uses exactly the code the sharing uses, so it
either prints the right names and the right XP, or it names the part that broke.

**One player is enough.** What F7 answers -- can the mod enumerate players, and
can it read their XP -- does not need anybody else. Only watching XP actually
move between two people does, and that comes after.

If the numbers match what the game shows you, set `probe_only = false` in
`Scripts/config.lua` and play.

## Install

On the **host's** machine only. Palworld decides XP server-side, so the host
decides it for everyone and joining clients need nothing installed. In your
setup that means Keddo's PC.

```powershell
.\tools\install_ue4ss.ps1 -Dev
.\tools\link_mod.ps1
```

`install_ue4ss.ps1` fetches [Okaetsu's Palworld fork of
UE4SS](https://github.com/Okaetsu/RE-UE4SS/releases/latest). Stock RE-UE4SS does
not work -- Palworld made engine edits in 0.4.1.5 and needs this build. Do not
also subscribe to the Steam Workshop copy; two copies load at once and the game
crashes on launch.

`link_mod.ps1` junctions `mod/SharedXPPool` into the game's mods folder, so
edits here take effect in place. UE4SS hot reload is on, so most changes do not
need a restart.

Both default to `D:\SteamLibrary\steamapps\common\Palworld`; pass `-GameDir` for
anywhere else. Logs go to `<game>\Pal\Binaries\Win64\ue4ss\UE4SS.log`.

## Balance

When one player earns XP, every other connected player gets the same amount.

That is not a multiplier. Palworld already gives full XP to every player
standing nearby, so a group playing together shares nothing today. This removes
the distance limit, so a group that splits up progresses like a group that
sticks together. Nobody falls behind for going off to do their own thing.

`config.divide_among_players` switches to `X / N` each instead. That makes the
whole group progress at one solo player's rate, which is slower than vanilla
rather than equal to it. It is the honest reading of "as if it was one player",
but it is off by default.

## Scope

**Connected players only.** A player who is offline has no loaded save to reach.
Catching them up on return is the save editor's job -- run `sharedxp apply`
between sessions.

**Pals are not touched**, same as v0.

**The tech tree is not shared.** Reasoning in the [root README](../README.md);
in short, a shared XP pool already puts everyone on the same technology point
income. Sharing the tree is a v2 decision.

## Layout

| | |
|---|---|
| `Scripts/config.lua` | every knob, with the reasoning next to it |
| `Scripts/pool.lua` | watching totals and sharing the difference |
| `Scripts/players.lua` | finding players, reading their XP, paying them |
| `Scripts/probe.lua` | discovery: the hooks, and the F7 dump |

`players.lua` goes through `PalUtility` rather than
`FindAllOf("PalPlayerState")`, which returns nothing at all on some builds --
and fails silently, so every loop over it matches nobody and the mod looks
simply broken. It also tries four different ways to reach a character's
individual parameter, because which one is reachable from Lua is
build-dependent, and remembers the one that worked.

## Testing

```
lua tests/lua/test_pool.lua
```

Eleven tests against a stubbed UE4SS: the baseline tick, mirroring, splitting,
late joiners, unreadable players, identity tracking, and the accessor
fall-through.

Two of them are the ones that matter. Grants really move the number in the fake,
so a payout comes back round on the next reading exactly as it would in game --
without the bookkeeping that discounts it, XP compounds forever and those two
tests fail. `pytest` runs the suite too, and skips if Lua is not installed.
