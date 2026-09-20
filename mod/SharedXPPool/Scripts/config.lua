local config = {}

-- ---------------------------------------------------------------------------
-- Settings
-- ---------------------------------------------------------------------------

-- How fast somebody behind catches up, as a fraction of the gap each tick.
--
--   0.25  a quarter of the remaining distance every second (default)
--   1.0   instantly, in one tick
--   0     sharing off
--
-- A fraction rather than a fixed number of XP, because a fixed number that is
-- sensible at level 10 -- where a level costs 1,900 xp -- is a rounding error
-- at level 60, where it costs 670,000. A fraction needs no units and cannot be
-- wrong at one end of the game or the other.
--
-- At 0.25 a gap of two million is essentially gone in half a minute, and a gap
-- worth less than one kill closes in a single tick -- payouts have a floor, so
-- the tail does not trickle a point at a time. Lower it if you would rather
-- catch up visibly over a few seconds than arrive all at once -- it is also
-- what spreads out the level-up popups, and the XP that reaches your pals
-- along the way.
config.catch_up_rate = 0.25

-- Key that pauses and resumes sharing, by name in UE4SS's Key table.
--
-- For stopping the mod mid-session without alt-tabbing out to edit files.
-- Nothing accumulates while it is paused. F10 is out; UE4SS's console enabler
-- uses it. Set to nil to bind nothing.
config.pause_key = "F11"

-- Log every payout. Off gives one summary line per tick instead of one per
-- player, which matters while a large gap is closing.
config.verbose = true

-- How often to check. Nothing is measured across ticks, so this is only how
-- quickly somebody is brought level, not an accuracy setting.
config.poll_interval_ms = 1000













-- ---------------------------------------------------------------------------
-- Debugging
--
-- None of the rest is needed to play. Everything below is off, and two of them
-- change the world when they are not.
-- ---------------------------------------------------------------------------

-- Log everybody's total once a tick, whether or not anything is paid.
--
-- For watching what the game does rather than what the mod does. Pause sharing
-- first, or the mod's own payouts are in the readings.
config.watch_totals = false

-- Bind the probe keys (F6/F7/F8/F9).
--
-- Off, and that is not tidiness. F6 and F8 inject XP into the world, and F9
-- walks reflected function parameters -- the thing that hard-crashed the game
-- during discovery. On the host's keyboard during a real session a stray
-- function key is a live-world event, not a debugging convenience.
--
--   F7  read and report every connected player
--   F8  pay player 1 the amount below;  F6  the same for player 2
--   F9  dump the exp API's function signatures
config.debug_keys = false

-- How much XP those test payouts hand over.
--
-- 1 is right for "did the payout land, and on whom". It is useless for checking
-- what the recipient's pal gets, because a pal takes roughly a fifth and a
-- fifth of 1 rounds to nothing. Set it to a few hundred for that.
config.test_grant_amount = 1

-- Discovery mode. Observes and logs, shares nothing.
--
-- Off, because the probe runs answered what they were for. Reading works: F7
-- enumerated the player and read their level and XP through
-- GetCharacterParameterComponent():GetIndividualParameter(). Paying works:
-- consecutive F8 presses each moved the total by exactly the amount asked for,
-- and the game levelled the player up on its own at the right threshold.
--
-- Turn it back on after a game patch, or if XP stops moving and you need to
-- find out which half broke. It arms the probe keys on its own, so debug_keys
-- does not also have to be set.
config.probe_only = false

return config
