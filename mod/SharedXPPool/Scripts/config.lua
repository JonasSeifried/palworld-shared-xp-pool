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
-- behind forever, because everyone is topped up by the same amount every tick.
--
-- With it, that same amount goes to the lowest totals first instead of to each
-- player's own shortfall. Somebody far behind is simply the deepest valley and
-- the water reaches them first, so there is no ratio to pick.
--
-- It does not create a single point more XP. The budget is unchanged either
-- way: summed over everybody, (best rise - your rise) is exactly the best rise
-- times the number of players, less what the game already handed out. So a tick
-- puts the same total in the world as vanilla does for a group standing
-- together, and this only decides who holds it.
--
-- Nobody is lowered and nobody is raised above the player in front, so a group
-- already level behaves exactly as it does with this off.
--
-- The limit worth knowing: a gap does not close while only the player in front
-- is earning, because every point they gain is a point they created. It closes
-- as soon as the people behind are playing at all.
config.catch_up = true

-- How far apart two players have to be before the game stops sharing XP between
-- them, in Unreal units. nil leaves this off.
--
-- This is the one thing the pool cannot work out from XP totals alone. When two
-- players both gain in the same second, it has to decide whether that was one
-- kill the game shared with both of them, or two separate kills. Top up to the
-- larger and two separate kills collapse into one; add them together and every
-- shared kill counts twice. Distance is what tells them apart: an award has a
-- radius, so players outside it cannot have received each other's.
--
-- Off until it has been measured on your build, because the two ways of being
-- wrong are not equal. Too large, and players who really were apart get treated
-- as together -- the pool under-shares, which is what it does today anyway. Too
-- small, and players who were sharing get counted twice, which invents XP.
--
-- config.watch_rises below is how to measure it: it prints who gained what and
-- how far apart everyone was, so a session of ordinary play shows the distance
-- at which one player's kill stops moving the other player's total.
config.share_radius = nil

-- Log every player's gain and the distance between them, once per tick.
--
-- For answering the question above, and for anything else where what matters is
-- what the game did rather than what the pool did. Pause with the pause key
-- while measuring, or the pool's own payouts appear in the readings.
config.watch_rises = false

-- Palworld's own tuning constants, written once when a world is loaded.
--
-- These live on BP_PalGameSetting_C and are ordinary numbers. Writing them
-- works: MapObjectDistributeExpRange, the distance over which XP from
-- destroying a map object is shared, went from 1000 to 1000000 in game and read
-- back changed. Widening it makes the game share that XP itself.
--
--   config.game_settings = { MapObjectDistributeExpRange = 1000000.0 }
--
-- Empty anyway, and the reasoning is in the README. In short: it covers map
-- objects and nothing else, so it makes behaviour depend on how the XP was
-- earned -- which is the thing watching totals exists to avoid. It also
-- overlaps share_radius rather than complementing it; setting both double-counts
-- map object XP, and the mod says so at startup. And a 10 km radius on a 4 km
-- map is a world-wide query per harvest, of unmeasured cost.
--
-- Kept because it is how any future finding of this kind gets applied, and the
-- fallback if distance grouping turns out not to work.
--
-- Every write is read back and reported, and a name this build does not have is
-- skipped with a line saying so. F9 lists what exists. Nothing persists: the
-- object is transient and rebuilt from Blueprint defaults each launch.
config.game_settings = {}

-- How much XP the F6 and F8 test payouts hand over.
--
-- 1 is right for "did the payout land, and on whom". It is useless for checking
-- what the recipient's pal gets, because a pal takes roughly a fifth and a fifth
-- of 1 rounds to nothing. Set this to a few hundred, press the key, and compare
-- the pal's gain against the player's.
config.test_grant_amount = 1

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
