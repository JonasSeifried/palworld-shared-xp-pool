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
-- find out which half broke. F7 and F8 stay bound either way.
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

-- Log every share to UE4SS.log.
config.verbose = true

return config
