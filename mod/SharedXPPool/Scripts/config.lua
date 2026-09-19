local config = {}

-- Discovery mode. Observes and logs, changes nothing.
--
-- The first probe run already answered the big question: a kill goes through
-- PalExpDatabase:AddExp_EnemyDeath, whose only argument is a PalDeadInfo, so
-- the XP amount is computed inside the game and never appears in the
-- arguments. That is why the mod now watches each player's XP total instead of
-- hooking the award. See pool.lua.
--
-- What is still unconfirmed is whether the mod can enumerate players and read
-- their XP at all. Press F7 in game: if the dump shows the right names and the
-- right XP numbers, sharing will work, because it uses exactly that code.
config.probe_only = true

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
