# Shared XP Pool -- live mod

The v1 mod: XP is shared as it is earned, instead of being reconciled after the
fact by the save editor.

**Status: working.** Two players, XP shared in both directions, no leak and no
loop, confirmed in game.

```
paying Keddo 1 xp
  Tondoa  1533 -> 1533  (+0 xp)  distance 828
  Keddo   1280 -> 1281  (+1 xp)  <- the one being paid
---- after the pool ticked ----
  Tondoa  +1 xp in total
  Keddo   +1 xp in total
```

Nothing leaked onto Tondoa at 828 units or at 6116, the top-up reached him a
second later, and his active pal gained the XP with him -- so being topped up by
the pool carries the party exactly as earning it yourself does. That was the last
open question about how it behaves.

Three faults were found along the way and all three are fixed: it crashed the
game on player enumeration, it looped paying out once a second forever, and its
payouts leaked onto nearby players. Each has a test that fails if the fix is
removed.

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

Payouts go through the game's own exp functions rather than writing the `Exp`
field, so level-ups, UI and replication happen normally. Which function took two
tries; see "the payout names its recipient" below.

Keeping the mod from reacting to its own payouts is the hard part, and the first
attempt at that was wrong too. See the two-player run.

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

Set `config.debug_keys = true` first -- these keys inject XP, and a live session
does not bind them. Hot reload picks the change up without a restart.

**F8** pays the first player 1 XP, **F6** the second. Each reports who actually
received it, then reads everyone again once the pool has ticked -- the direct
payout and the shared top-up are a second apart, so one reading only ever shows
half of it.

Pay the *other* player, not yourself: paying yourself reaches your own party
either way, so it cannot tell you whether being topped up by the pool brings your
pals along. Paying them and watching your own side can.

**Then stop and watch the log for ten seconds.** One payout is correct; a line
every second is the loop returning.

## Running it live

Three things exist only because a live world is not a test world.

**Nothing that injects XP is bound.** `config.debug_keys` is off, so F6, F8 and
F9 are not registered at all. F6 and F8 pay out, and F9 walks reflected function
parameters -- the call that hard-crashed the game twice during discovery. A
stray function key mid-session should not be able to do any of that. Discovery
mode arms them regardless, since it is nothing but those keys.

**One key stays bound: pause.** `config.pause_key`, F11 by default. It stops
payouts without stopping the loop -- the mod keeps reading everyone and moving
the baselines along, so resuming does not then hand out everything earned while
it was off. It is how to stop the mod without alt-tabbing out to edit files, and
it touches nothing but a flag, so it cannot itself be what breaks.

**A rise that cannot be real is taken as a baseline, not shared.** Two ways that
happens. A player who cannot be read for a while leaves a stale stored total,
and the next good reading spans the whole gap rather than one tick; that player
is rebaselined on the reading that closes the gap, the same as somebody who just
joined. And `config.max_rise_per_tick` (10,000,000) catches anything else, a
garbage int64 read most likely -- a whole level costs about 35k XP at level 30
and 1.1M at level 65, so no second of play comes near it.

That last one is the case the pause key cannot help with: by the time anyone
notices, the XP is already in everybody's character. Hence a rule rather than a
reflex.

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

Every tick, whoever gained the most sets the mark, and the world ends the tick
holding that rise times the number of players -- exactly what vanilla produces
for a group standing together. Nobody is ever pulled down, and nobody is ever
raised above the player in front.

All the pool decides is who holds it. When everyone is level that means bringing
each player up to the best earner. When somebody is behind, it goes to them
first -- see below.

That is not a multiplier. Palworld already gives full XP to every player
standing nearby, so a group playing together shares nothing today -- and the
top-up rule correctly does nothing in that case, because they all rose together.
What it adds is that nobody falls behind the best earner for going off to do
their own thing.

It is not yet true that a group which splits up progresses like a group that
sticks together. See the next section for why, and what it would take.

`config.divide_among_players` targets the average rise instead of the best. The
group then gains roughly what one player earned rather than matching the best
earner, which is slower than vanilla rather than equal to it. It is the honest
reading of "as if it was one player", but it is off by default.

## The payout names its recipient

`GiveExpToAroundPlayerCharacter` takes a `Center` and a `Radius`, and Palworld's
own nearby-player sharing forwards whatever lands there. Measured: standing
together, paying one player 1 XP gave the payer 2 and the other 1; standing
apart, exactly 1 each. The sphere size is not the problem, so no radius setting
fixes it. The only answer is not to use a sphere.

`F9` found one that does not:

```
AddExpValue_forPlayerParty_Server
    1. ExpValue: Int64Property
    2. GiftPlayerList: ArrayProperty  (of ObjectProperty -> PalPlayerCharacter)
    3. isCallDelegate: BoolProperty
```

Named recipients, no centre, no radius, nothing for the game to forward. The
list holds `PalPlayerCharacter`, which is exactly what player enumeration
already returns, and a live `BP_PalExpDatabase_C` is reachable through
`FindFirstOf("PalExpDatabase")`.

The radius call stays as a fallback, since it is proven to work on this build
and a leaky payout beats none. The first payout of a session verifies the named
route actually moved the XP before committing to it -- a call that raises is
easy to notice, but one that quietly does nothing would leave the pool believing
it had paid everybody, forever.

A warning for anyone extending the probe: reading a parameter's name and class
is safe, but `GetInner`, `GetPropertyClass` and `GetStruct` each read a field
that exists only on their own property type. Called on anything else they read a
wrong offset and kill the process, and `pcall` does not catch it. Asking every
parameter for all three crashed the game on the first one. A test now fails if
the code does that again.

## The one thing totals cannot tell you

Two players both gain inside the same second. Either the game gave one kill to
both of them, or they each killed something of their own. In the totals those are
identical, and they call for opposite responses: a shared kill means do nothing,
two kills mean give each player the other's as well.

The pool takes the smaller answer, because under-sharing is recoverable and
inventing XP is not. The cost is real:

```
two players, kills worth 20 and 30 in the same second

  standing together    +50 each   the game shared both, and the pool leaves it
  far apart            +30 each   should be +50; the smaller kill is lost
  far apart, equal     +20 each   should be +40; the pool does nothing at all
```

The last line is the ordinary case -- two people grinding in different places at
similar rates -- and it is why the mod does not really pool XP yet.

**`config.share_radius`** settles it, because an award has a radius and players
outside it cannot have received each other's. Players closer than the radius
count once; players further apart add up. It is off until measured, since the
two ways of being wrong are not equal: too large behaves like today, too small
invents XP.

**`config.watch_rises`** is how to measure it. Once a tick it logs who gained
what, and how far apart everyone was:

```
[SharedXPPool] watch  Tondoa +20  Keddo +0  |  Tondoa-Keddo 18300
```

Pause sharing first with the pause key, or the pool's own payouts turn up in the
readings. An evening of ordinary play then shows the distance at which one
player's kill stops moving the other player's total.

**Better still, if it turns out to exist:** widen Palworld's own radius instead
of working around it. Then the game hands every award to everybody itself, with
the right amounts, the right pal XP and the right level-ups, and none of the
above is needed -- there is never a tick where one player gained and another did
not, so there is nothing left to infer.

The kill path offers no way in: kills fire `AddExp_EnemyDeath` and not
`GiveExpToAroundPlayerCharacter`, so the sharing happens inside native code with
no reflected radius to intercept. A property on a live object is the remaining
possibility, and `BP_PalExpDatabase_C` is a Blueprint, so it may well expose one.
**F9** now hunts for one and marks anything plausible with `***`. Worth pressing
before relying on `share_radius` at all.

## Closing a gap that already exists

Topping everyone up to the best rise equalises how fast people gain, not how
much they have. On its own it moves everybody in lockstep from wherever they
started, so a player four levels behind on the day the mod goes in stays four
levels behind. `config.catch_up` fixes that, and it is on.

**It costs nothing.** The budget is not touched -- summed over everybody,
`best rise - your rise` is exactly the best rise times the number of players,
less what the game already handed out. A tick therefore puts the same XP in the
world with catching up on as with it off, and as vanilla puts there for a group
standing together. The only change is where it lands.

**It lands on the lowest totals first.** Not on each player's own shortfall --
the water fills the deepest valley until it reaches the next one, then both rise
together. Somebody four levels down is the deepest valley, so they are served
first and there is no ratio to tune.

Three players at 1,000, 5,000 and 12,000 XP, and 20 earned:

```
catch_up off   P1 +20, P2 +20, P3 +20    60 created, both gaps preserved exactly
catch_up on    P1 +40, P2 +0,  P3 +20    60 created, P1 closes on both
```

Whoever of the three earns the 20, the other 40 goes to P1, because P1 is
furthest behind. Once P1 is level with P2 the two of them share it, and so on.

**Nobody is raised above the player in front.** Filling valleys cannot lift
anyone over somebody who was above them -- it levels them and stops. The ceiling
on top of that is where the furthest-ahead player would have finished under the
flat rule, so the whole budget always has somewhere to go. An earlier version
capped at the highest *total* instead, which left no room above the leader on a
tick where everybody was owed something, and quietly dropped the difference.

**The limit, stated deliberately:** a gap does not close while only the player
in front is earning. Every point they gain is a point they created, so nobody
can gain faster than them on a fixed budget -- the players behind keep pace and
no more. As soon as the people behind are playing at all, it closes. In tests a
spread of 11,000 XP across three players taking turns earning closes to exactly
zero and then holds.

`config.divide_among_players` is unaffected; the budget is its own either way and
only the allocation changes.

The save editor is still worth one run before the first session -- `sharedxp
apply --mode max` converges everyone at once rather than over several evenings --
but it is no longer the only way to close a gap.

## What pals get

Measured solo in game, 2026-09-19, with sharing paused so the readings are
Palworld's own:

```
crafting a pal sphere    player +5    active pal +1
killing a pal            player +12   active pal +2
```

So a pal gets roughly a fifth of what the player gets, and -- the useful part --
the fraction looks the same whether the XP came from crafting or from a kill. A
uniform ratio means the mod does not have to care where XP came from, which is
the same reason watching totals works at all.

What is confirmed, from the two-player run: a player topped up by the pool has
their active pal gain alongside them, exactly as a player who earned it does.
What is **not** confirmed is the fraction -- whether
`AddExpValue_forPlayerParty_Server` hands the party the same fifth the game
does, or something else.

That is measurable alone. `config.test_grant_amount` sets how much F6 and F8 pay
out; the default of 1 is useless here, because a fifth of 1 rounds to nothing.
Set it to a few hundred, press F8, and compare the pal's gain against the
player's. If it is a fifth, the mod is faithful to vanilla and there is nothing
to do.

## Scope

**Connected players only.** A player who is offline has no loaded save to reach.
Catching them up on return is the save editor's job -- run `sharedxp apply`
between sessions.

**Pals are not written to directly**, same as v0 -- but they are not untouched,
because the payout goes through a function whose name ends in `forPlayerParty`
and the party comes along. See below.

**The tech tree is not shared.** Reasoning in the [root README](../README.md);
in short, a shared XP pool already puts everyone on the same technology point
income. Sharing the tree is a v2 decision.

## Layout

| | |
|---|---|
| `Scripts/config.lua` | every knob, with the reasoning next to it |
| `Scripts/pool.lua` | watching totals and sharing the difference |
| `Scripts/players.lua` | finding players, reading their XP, paying them |
| `Scripts/probe.lua` | discovery: the hooks, the F7 dump, the F9 radius hunt |

`players.lua` enumerates through `UEHelpers.GetAllPlayers`. Not
`FindAllOf("PalPlayerState")`, which returns nothing at all on some builds --
and fails silently, so every loop over it matches nobody and the mod looks
simply broken; and not `PalUtility`, which is what crashed run two. It tries
four different ways to reach a character's individual parameter, because which
one is reachable from Lua is build-dependent, and remembers the one that
worked.

## Testing

```
lua tests/lua/test_pool.lua
```

Forty-two tests against a stubbed UE4SS. The fake models what the game actually
does, which is the part that matters: a payout really moves the number, and in
`propagate` mode it moves *everyone's*, the way paying one player raised the
other in game.

The ones worth having:

- a single earning settles after one payout and stays settled
- a payout that leaks onto the earner does not start a loop
- players the game already paid are not paid again
- nothing on the read path calls `StaticFindObject`
- a reading taken after a gap is a baseline, not a windfall
- an impossible rise is ignored rather than shared
- pausing stops payouts, and resuming pays no backlog
- a live session binds nothing that injects XP
- the budget goes to whoever is furthest behind
- the pool never creates more than the rise times the players
- nobody is ever raised above the player in front
- a gap closes when the people behind are playing too
- players too far apart to have shared add their gains together
- players close enough to have shared are still counted once
- a distance that cannot be read merges rather than splits

Each was checked by breaking the code it defends and watching it go red. The
first one only exists because removing the re-read broke nothing in the suite --
the rule looked unnecessary until there was a test that could tell.

`pytest` runs the suite too, and skips if Lua is not installed.
