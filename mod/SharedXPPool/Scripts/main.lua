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

-- These need a loaded world, which does not exist at mod load time, so they go
-- on keys. Output goes to UE4SS.log.
--
-- Reading and paying are on separate keys deliberately. Paying is the one call
-- left that could take the game down, so it must never fire as a side effect of
-- looking.
local bound = {}

local function bind(key, name, fn)
    if key == nil then
        print("[SharedXPPool] cannot bind " .. name .. ": no such key in this UE4SS build\n")
        return
    end

    local ok, err = pcall(RegisterKeyBind, key, function()
        local ran, why = pcall(fn)
        if not ran then
            print("[SharedXPPool] " .. name .. " failed: " .. tostring(why) .. "\n")
        end
    end)

    if ok then
        bound[#bound + 1] = name
    else
        print("[SharedXPPool] could not bind " .. name .. ": " .. tostring(err) .. "\n")
    end
end

-- F8 pays the first player, F6 the second. Paying somebody else is the only
-- way to watch what the pool's top-up does to *your* side: whether being topped
-- up brings your pal along the way earning it yourself does.
--
-- F10 is left alone; UE4SS's console enabler already uses it.
bind(Key.F6, "F6 test_grant(player 2)", function() probe.test_grant(2) end)
bind(Key.F7, "F7 dump_players", probe.dump_players)
bind(Key.F8, "F8 test_grant(player 1)", function() probe.test_grant(1) end)
bind(Key.F9, "F9 dump_exp_api", probe.dump_exp_api)

-- Report what actually got bound rather than what was meant to be. A key that
-- silently failed to register looks exactly like a key that does nothing when
-- pressed, and one of those is a bug in here.
print("[SharedXPPool] ready -- bound: " .. table.concat(bound, ", ") .. "\n")
