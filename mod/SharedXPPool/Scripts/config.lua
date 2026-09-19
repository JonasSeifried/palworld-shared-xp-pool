local config = {}

-- Discovery mode. Observes and logs, changes nothing.
--
-- Off, because the probe runs answered everything they were for. Reading works:
-- F7 enumerated the player and read level 3 / 399 xp through
-- GetCharacterParameterComponent():GetIndividualParameter(). Paying works: 145
-- consecutive F8 presses each moved the total by exactly 1, with no failures,
-- and the game levelled the player up on its own at 400 xp -- which is where
-- data/exp_table.json says level 4 begins.
--
-- Turn it back on after a game patch, or if XP stops moving and you need to
-- find out which half broke. It arms the probe keys on its own, so
-- config.debug_keys below does not also have to be set.
config.probe_only = false

-- How often to check. XP is not high-frequency, and each check is a handful of
-- reads over the connected players, so a second is unnoticeable either way.
config.poll_interval_ms = 1000

-- Each connected player receives this fraction of any XP another player earns.
--   1.0  every player gets the full amount (default)
--   0.0  sharing off
config.share_rate = 1.0

-- Split instead of mirror: an earned amount X is divided across all connected
-- players, so each gets X / N and the group's total XP per kill is unchanged.
--
-- Off by default, and the reasoning matters. Palworld already gives every
-- nearby player the full amount -- a group playing together is not splitting
-- anything. Mirroring is that same rule with the distance limit removed, so a
-- group that splits up progresses exactly like a group that sticks together.
-- Turning this on makes the whole group progress at one solo player's rate,
-- which is slower than vanilla, not equal to it.
config.divide_among_players = false

-- Close gaps that already exist, instead of only keeping everyone level.
--
-- Without this the pool equalises how fast people gain, not how much they have:
-- a player four levels behind on the day the mod goes in stays four levels
-- behind forever, because everyone is topped up to the same rise every tick.
--
-- With it, the same budget -- the best earner's rise, times the number of
-- players -- goes to the lowest totals first instead of to each player's own
-- shortfall. Somebody far behind is simply the deepest valley and the water
-- reaches them first, so there is no ratio to pick and nobody is ever lowered.
--
-- Nobody is raised above the player in front either, and that cap is what makes
-- it safe to leave on: once everyone is level there is nowhere to put the money
-- and it is simply not paid, so a group already sharing evenly gains exactly
-- what it does today. The extra XP exists only while there is a gap to close.
config.catch_up = true

-- Bind the probe keys (F6/F7/F8/F9) when the mod is live.
--
-- Off, and that is not tidiness. F6 and F8 inject XP into the world, and F9
-- walks reflected function parameters -- the thing that hard-crashed the game
-- during discovery. On the host's keyboard during a real session a stray
-- function key is a live-world event, not a debugging convenience.
--
-- Discovery mode turns them on regardless, since it is nothing but those keys.
config.debug_keys = false

-- Key that pauses and resumes sharing, by name in UE4SS's Key table.
--
-- The point is to be able to stop the mod mid-session without alt-tabbing out
-- to edit files. While paused it keeps reading everyone and moving the
-- baselines along, so resuming does not pay out a backlog of everything earned
-- while it was off.
--
-- F10 is out; UE4SS's console enabler uses it. Set to nil to bind nothing.
config.pause_key = "F11"

-- Ignore a rise larger than this, and take it as a new baseline instead.
--
-- Not a balance knob -- it is a filter for readings that cannot be real. A
-- whole level costs about 35k xp at level 30 and 1.1M at level 65, so no
-- single second of play approaches ten million. A garbage int64 read, or a
-- baseline gone stale behind a gap in readings, comfortably exceeds it.
--
-- Treating such a rise as earnings would inject it into every other player at
-- once, which is the one mistake the pause key cannot undo. 0 disables.
config.max_rise_per_tick = 10000000

-- Log every share to UE4SS.log.
config.verbose = true

return config
