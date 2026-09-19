-- Shared XP Pool -- live mod for Palworld via UE4SS.
--
-- Install on the host only. Palworld decides XP server-side, so the host
-- decides it for everyone and joining clients need nothing installed.

local config = require("config")
local probe = require("probe")

print("[SharedXPPool] loading\n")

local pool = nil

if config.probe_only then
    print("[SharedXPPool] DISCOVERY MODE -- observing only, no XP will be shared\n")
    probe.start()
else
    pool = require("pool")
    pool.start()
end

-- These need a loaded world, which does not exist at mod load time, so they go
-- on keys. Output goes to UE4SS.log.
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

-- The one key a live session gets, and the reason it exists: stopping the mod
-- without alt-tabbing out of the game to edit files. It only reads and writes a
-- flag, so it cannot itself be the thing that breaks.
--
-- Reading and paying are on separate keys deliberately. Paying is the one call
-- left that could take the game down, so it must never fire as a side effect of
-- looking.
if pool and config.pause_key then
    bind(Key[config.pause_key],
        config.pause_key .. " pause/resume sharing",
        pool.toggle_paused)
end

-- The rest inject XP (F6, F8) or walk reflected function parameters (F9), which
-- is what hard-crashed the game during discovery. In a live session a stray
-- function key would be a world event rather than a debugging convenience, so
-- they are bound only when asked for -- and always in discovery mode, which is
-- nothing but these keys.
--
-- F8 pays the first player, F6 the second. Paying somebody else is the only
-- way to watch what the pool's top-up does to *your* side: whether being topped
-- up brings your pal along the way earning it yourself does.
--
-- F10 is left alone; UE4SS's console enabler already uses it.
if config.debug_keys or config.probe_only then
    bind(Key.F6, "F6 test_grant(player 2)", function() probe.test_grant(2) end)
    bind(Key.F7, "F7 dump_players", probe.dump_players)
    bind(Key.F8, "F8 test_grant(player 1)", function() probe.test_grant(1) end)
    bind(Key.F9, "F9 dump_exp_api", probe.dump_exp_api)
end

-- Report what actually got bound rather than what was meant to be. A key that
-- silently failed to register looks exactly like a key that does nothing when
-- pressed, and one of those is a bug in here.
print("[SharedXPPool] ready -- bound: "
    .. (#bound > 0 and table.concat(bound, ", ") or "nothing")
    .. (config.debug_keys and "" or "  (debug keys off)") .. "\n")
