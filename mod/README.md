# Shared XP Pool -- live mod

The v1 mod: XP is shared as it is earned, instead of being reconciled after the
fact by the save editor.

**Status: live, and it has shared real XP between two players.** It also looped
the first time, paying out once a second forever with nobody playing. The cause
and the fix are below. The fix is not yet confirmed in game.

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
recipient's feet, so level-ups, UI and replication happen normally.

Keeping the mod from reacting to its own payouts is the hard part, and the
first attempt at it was wrong. See the two-player run below.

## What the second probe run found

Pressing F7 hard-crashed the game, before a single line of the dump reached the
log. That puts it inside player enumeration, which was the first thing to run.

The likely causes were both in one line:
`GetPlayerListDisplayMessages(FindFirstOf("World"))` on the `PalUtility` CDO.
`FindFirstOf("World")` can return a `UWorld` that is not the one being played,
and passing that into a Pal function is undefined; and the call returns an array
of `FText`, which this UE4SS build has a changelog entry about crashing on.

Enumeration now goes through `UEHelpers.GetAllPlayers`, which walks
`GameState.PlayerArray` to `PlayerState.PawnPrivate` -- plain Unreal, no text
marshalling, and a world resolved through the player controller. It ships with
UE4SS and is maintained alongside it. Nothing on the read path touches
`PalUtility` any more, and a test fails if it ever does again.

## What the third run found

Both halves work.

**Reading.** F7 enumerated the player and read level 3 / 399 XP, through the
*second* of the four accessors -- `GetCharacterParameterComponent()` then
`GetIndividualParameter()`. The first guess was wrong, which is why the chain
exists.

**Paying.** 145 consecutive F8 presses each moved the total by exactly 1, with
no failures and no drift. The game levelled the player to 4 on its own when the
total passed 400, which is exactly where `data/exp_table.json` says level 4
begins -- so paying through `GiveExpToAroundPlayerCharacter` does the whole job,
level-up included, and the curve table picked up a third independent
confirmation for free.

Those 145 calls also came straight back through the `GiveExpToAroundPlayerCharacter`
hook the probe had registered. Under the old hook-based design that would have
been a feedback loop to defend against. Watching totals instead means it is
simply not a question.

## What the first two-player run found

It worked, and then it looped.

The working part: XP moved between the two players, and not only from kills.
One player discovering a fast travel altar was picked up and shared like
anything else -- through a code path the probe never hooked and I never
identified. That is the total-watching design earning its keep.

The loop: with nobody playing, the log filled with one payout per second at a
constant amount, forever.

```
18:12:44  Tondoa earned 10 xp -> shared to 1 player(s)
18:12:45  Tondoa earned 10 xp -> shared to 1 player(s)
18:12:46  Tondoa earned 10 xp -> shared to 1 player(s)
```

**Paying one player raised the other too.** Either the 50-unit sphere reached
them, or -- more likely -- Palworld's own nearby-player sharing propagated the
payout. The mod credited only the intended recipient, so the other player's rise
looked like earnings, which it mirrored, which raised the first player again.

The mistake was assuming a grant lands on exactly one player. It does not, and
no radius makes that reliably true, because the game may forward it regardless.
Two rules now make the feedback path impossible:

**Top up to the best rise, never add to it.** Palworld already gives full XP to
players standing together, so if both rose 10 this tick the game has already
done the sharing and there is nothing to do. The target is the largest rise
anyone saw; only players below it get the difference. Summing instead would
double every shared kill -- and it is what let the loop grow.

**Re-read everyone after paying.** Whatever the payout touched, and whoever it
reached, is absorbed into the new baseline instead of being counted as earnings
next tick. Without this the recipient's gain reads as *their* earning, making the
original earner the one who is behind, and the two trade payments back and forth
forever -- no propagation required, purely the mod's own accounting.

Both rules have a test that fails when the rule is removed. I checked by
removing each one.

A consequence worth knowing: a player whose XP cannot be read is now skipped
rather than paid. Without a reading there is no way to know what they already
gained, and guessing high is precisely what caused the loop. Falling behind is
recoverable -- that is what the save editor is for.

## Testing it with two people

The keys stay bound when the mod is live, and F8 doubles as the two-player test.

With both players connected, press **F8 once**. It grants 1 XP to the first
player, which the pool sees as a rise nobody else matched, so the other player
gains 1 XP within a second. `UE4SS.log` will say so:

```
[SharedXPPool] best rise 1 xp -> topped up 1 player(s) by 1 xp total
```

That beats grinding kills to find out whether sharing works.

**Then stop and watch the log for ten seconds.** One line is correct; a line
every second is the loop, and it means the fix did not hold.

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

Every tick, whoever gained the most sets the mark, and everybody else is brought
up to it. Nobody is ever pulled down, and nobody is pushed past the best earner.

That is not a multiplier. Palworld already gives full XP to every player
standing nearby, so a group playing together shares nothing today -- and the
top-up rule correctly does nothing in that case, because they all rose together.
What it removes is the distance limit, so a group that splits up progresses like
a group that sticks together. Nobody falls behind for going off to do their own
thing.

`config.divide_among_players` targets the average rise instead of the best. The
group then gains roughly what one player earned rather than matching the best
earner, which is slower than vanilla rather than equal to it. It is the honest
reading of "as if it was one player", but it is off by default.

## The payout still leaks, and the replacement is known

`GiveExpToAroundPlayerCharacter` takes a `Center` and a `Radius`, and Palworld's
own nearby-player sharing forwards what lands there. Measured: standing
together, paying one player 1 XP gave the payer 2 and the other 1; standing
apart, exactly 1 each. So the leak is the game's sharing, not the radius, and no
radius setting fixes it.

Mostly this cancels out. If two players are close enough for a payout to leak,
they are close enough that a kill already raised both -- their rises match and
the top-up never fires. It only bites for XP the game does *not* share, like
crafting, done standing next to someone.

The fix is to stop using a sphere. `F9` found:

```
AddExpValue_forPlayerParty_Server
    1. ExpValue: Int64Property
    2. GiftPlayerList: ArrayProperty
    3. isCallDelegate: BoolProperty
```

An explicit list of players and no radius at all. What remains is confirming
what belongs in the list and finding a live `UPalExpDatabase` to call it on --
both of which `F9` now reports.

A warning for anyone extending the probe: reading a parameter's name and class
is safe, but `GetInner`, `GetPropertyClass` and `GetStruct` each read a field
that exists only on their own property type. Called on anything else they read a
wrong offset and kill the process, and `pcall` does not catch it. Asking every
parameter for all three crashed the game on the first one. A test now fails if
the code does that again.

## Not yet: closing a gap that already exists

The top-up equalises how fast people gain, not how much they have. Everyone
moves in lockstep from wherever they started, so a player who was four levels
behind on the day the mod went in stays four levels behind.

Until that changes, the fix is the save editor. `sharedxp apply` converges
everyone to the mean once, between sessions, and after that the live mod keeps
them level. Run it before the first session on an existing world.

When it is worth doing live -- mainly for someone joining an established world
with a fresh character -- the shape is already clear, and it costs nothing in
balance:

Each tick the mod injects a known amount of XP: the sum of `best - rise` across
everyone behind. Keep that budget exactly as it is, but distribute it by who is
furthest behind *in total XP* rather than giving each player precisely their own
shortfall. The player who is ahead on totals receives less than their rate
shortfall, the one furthest behind receives more, and the sum injected is
unchanged. Gaps close on their own, nobody is ever lowered, and the group gains
not one point more than it does today.

Deliberately not built yet. The loop fix above is confirmed in tests but not in
game, and adding a second way to inject XP before the first one is proven means
the next surprise has two possible causes instead of one.

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

Sixteen tests against a stubbed UE4SS. The fake models what the game actually
does, which is the part that matters: a payout really moves the number, and in
`propagate` mode it moves *everyone's*, the way paying one player raised the
other in game.

Four of them are the ones worth having:

- a single earning settles after one payout and stays settled
- a payout that leaks onto the earner does not start a loop
- players the game already paid are not paid again
- nothing on the read path calls `StaticFindObject`

Each was checked by breaking the code it defends and watching it go red. The
first one only exists because removing the re-read broke nothing in the suite --
the rule looked unnecessary until there was a test that could tell.

`pytest` runs the suite too, and skips if Lua is not installed.
