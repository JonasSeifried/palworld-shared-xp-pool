# Testing this alone

You do not need other players for most of it. Tiers 1-4 cover the save editor in
`save-editor/`; tier 5 covers the mod in `mod/`.

## Tier 1 - pool math (no game, no save files)

`save-editor/src/sharedxp/pool.py` is pure functions over plain dataclasses.
Every rule that matters lives here: averaging, the never-de-level clamp, edge
cases.

    cd save-editor && python -m pytest -q

This is where most bugs are, and it runs in milliseconds.

## Tier 2 - synthetic saves (no game)

Decode a real save to JSON, clone the player record into as many fake players as
you like with whatever XP spread you want, re-encode, run the tool against it.

This exercises the save read/write path and lets you simulate a 10-player server
from a single-player save. Round-trip assertions (decode -> encode -> decode
gives back an identical structure) catch corruption before it ever reaches the
game.

## Tier 3 - real game, one account

The only thing tiers 1 and 2 cannot tell you: *does the game accept the values we
wrote*. You need exactly one player for this.

1. Back up the save.
2. Note your level and XP in game, then quit fully (the game writes on exit).
3. Run the tool.
4. Load the save and confirm the level, the XP bar, and that nothing is corrupt.

## Tier 4 - two real accounts

Only validates that two players converge, which tiers 1-2 already prove at the
data layer. Nice-to-have, not a blocker for v0. A single 20-minute session with
one other person covers it.

## Tier 5 - the live mod

`lua mod/tests/test_pool.lua` runs the mod's logic against a stubbed UE4SS: no
game, no Palworld, no second player. It covers the rule, the reading guards and
the refusal to share through a payout that would reach bystanders.

What it cannot cover is whether the game still accepts the calls. That takes one
account and about two minutes: set `config.debug_keys = true`, then F7 to read
your own level and XP and check them against the game, and F8 to pay yourself
and watch the total move. Sharing itself needs a second player, since the mod
does nothing at all with one.
