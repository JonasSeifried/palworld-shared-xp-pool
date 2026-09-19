-- Shared XP Pool -- live mod for Palworld via UE4SS.
--
-- Install on the host only. Every XP function this mod touches is marked
-- _Server in the game's own naming, so the host decides XP for everyone and
-- clients need nothing installed.

local config = require("config")
local probe = require("probe")

print("[SharedXPPool] loading\n")

if config.probe_only then
    print("[SharedXPPool] DISCOVERY MODE -- observing only, no XP will be shared\n")
    probe.start()
else
    require("pool").start()
end

-- Hooking at load time is too early for anything that needs a world, so the
-- player dump is on a key instead. F7 in game, output goes to UE4SS.log.
RegisterKeyBind(Key.F7, function()
    local ok, err = pcall(probe.dump_players)
    if not ok then
        print("[SharedXPPool] dump_players failed: " .. tostring(err) .. "\n")
    end
end)

print("[SharedXPPool] ready -- F7 dumps the connected players\n")
