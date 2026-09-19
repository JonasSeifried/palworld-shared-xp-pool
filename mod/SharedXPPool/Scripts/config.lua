local config = {}

-- Discovery mode. Hooks every candidate XP function, logs what fires and with
-- which arguments, and changes nothing. The function names below are read out
-- of the shipping binary so we know they exist, but that does not tell us which
-- one the game actually calls, nor whether UE4SS can hook it. Only a real run
-- answers that.
--
-- Leave this on until UE4SS.log shows a hook firing when you earn XP, then turn
-- it off. Turn it back on after a game patch to re-confirm.
config.probe_only = true

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
