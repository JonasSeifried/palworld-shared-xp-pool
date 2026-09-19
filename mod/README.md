# Shared XP Pool -- live mod

The v1 mod: XP is shared as it is earned, instead of being reconciled after the
fact by the save editor.

**Status: discovery mode.** The code is written and tested against a stubbed
UE4SS, but it has never run inside Palworld. The first in-game run is a
read-only probe whose job is to tell us which XP function the game really calls.
Nothing shares XP until that comes back.

## Install

On the **host's** machine only. Every XP function involved is marked `_Server`
in the game's own naming, so the host decides XP for everybody and clients need
nothing installed. In your setup that means Keddo's PC, not yours.

```powershell
.\tools\install_ue4ss.ps1 -Dev
.\tools\link_mod.ps1
```

`install_ue4ss.ps1` fetches [Okaetsu's Palworld fork of
UE4SS](https://github.com/Okaetsu/RE-UE4SS/releases/latest). Stock RE-UE4SS does
not work -- Palworld made engine edits in 0.4.1.5 and needs this build. Do not
also subscribe to the Steam Workshop copy of UE4SS; two copies load at once and
the game crashes on launch.

`link_mod.ps1` junctions `mod/SharedXPPool` into the game's mods folder, so
edits here take effect in place. UE4SS hot reload is on, so most changes do not
even need a restart.

Both scripts default to `D:\SteamLibrary\steamapps\common\Palworld`; pass
`-GameDir` for anywhere else.

## The first run

`config.probe_only` starts at `true`. Launch the game, load a world, kill
something, then read:

```
<game>\Pal\Binaries\Win64\ue4ss\UE4SS.log
```

Three things need answering, and none of them can be settled from outside the
game:

1. **Which function fires.** The probe hooks ten candidates. Their names and
   parameter names come out of the FName table in `Palworld-Win64-Shipping.exe`,
   so they exist in this build -- but existing is not the same as being on the
   path a kill actually takes, and UE4SS cannot hook every UFunction.
2. **Whether the amount is per player or per party.** It decides whether
   mirroring is correct or doubles everyone's XP.
3. **Whether one kill fires the hook once, or once per nearby player.** If it is
   once per player, an unguarded mirror multiplies the award by however many
   people happened to be standing together. `pool.lua` currently collapses
   identical amounts arriving within 200 ms to defend against that; if the log
   shows one call per kill, set `DEDUP_WINDOW` to `0` and drop the guard.

Press **F7** in game to dump the players the mod can see. If that list is empty,
player enumeration is what broke, not the hooks.

Then set `probe_only = false` and play.

## What it does

When one player earns XP, every other connected player gets the same amount.

That is not a multiplier. Palworld already gives full XP to every player
standing nearby -- a group playing together shares nothing today. This removes
the distance limit, so a group that splits up progresses like a group that
sticks together. Nobody falls behind for going off to do their own thing.

`config.divide_among_players` switches to giving each player `X / N` instead.
That makes the whole group progress at one solo player's rate, which is slower
than vanilla rather than equal to it. It is there because it is the honest
reading of "as if it was one player", but it is off by default.

## Scope

**Connected players only.** A player who is offline has no loaded save for the
mod to reach. Catching them up on return is the save editor's job -- run
`sharedxp apply` between sessions.

**Pals are not touched**, same as v0.

**The tech tree is not shared.** The reasoning is in the [root
README](../README.md); in short, a shared XP pool already puts everyone on the
same technology point income, so each player builds their own tree at exactly a
solo player's rate. Sharing the tree here would finally be cheap to do neutrally
-- one shared point balance, charged by the game -- but that is a v2 decision,
not something to fold into the first working version.

## Layout

| | |
|---|---|
| `Scripts/config.lua` | every knob, with the reasoning next to it |
| `Scripts/probe.lua` | discovery: hooks the candidates and logs them |
| `Scripts/pool.lua` | the sharing itself |
| `Scripts/players.lua` | finding players, and paying one of them |

`players.lua` goes through `PalUtility` rather than `FindAllOf("PalPlayerState")`
on purpose: `FindAllOf` returns nothing at all on some builds, and it fails
silently, so every loop over it matches nobody and the mod looks simply broken.

## Testing

```
lua tests/lua/test_pool.lua
```

Ten tests covering the mirror, the split, the earner exclusion, the duplicate
filter and the re-entrancy guard, against a stubbed UE4SS. `pytest` runs them
too, and skips if Lua is not installed.

The re-entrancy test earns its keep: the fake re-enters the XP hook from inside
every payout, the way the game would if its exp call routes back through the
function we hooked. Remove the guard and that test does not fail, it hangs.
