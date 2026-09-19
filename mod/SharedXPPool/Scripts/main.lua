-- Shared XP Pool -- live mod for Palworld via UE4SS.
--
-- Install on the host only. Palworld decides XP server-side, so the host
-- decides it for everyone and joining clients need nothing installed.

local config = require("config")
local probe = require("probe")

print("[SharedXPPool] loading\n")

if config.probe_only then
    print("[SharedXPPool] DISCOVERY MODE -- observing only, no XP will be shared\n")
    probe.start()
else
    require("pool").start()
end

-- The player dump needs a loaded world, which does not exist at mod load time,
-- so it goes on a key. F7 in game, output to UE4SS.log.
RegisterKeyBind(Key.F7, function()
    local ok, err = pcall(probe.dump_players)
    if not ok then
        print("[SharedXPPool] dump_players failed: " .. tostring(err) .. "\n")
    end
end)

print("[SharedXPPool] ready -- press F7 in game to dump what the mod can see\n")
