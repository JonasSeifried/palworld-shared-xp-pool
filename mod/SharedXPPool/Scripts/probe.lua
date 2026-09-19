-- Discovery. Hooks every plausible XP function and logs what actually fires.
--
-- The names below were read out of the FName table in
-- Palworld-Win64-Shipping.exe (build 25246127), together with their parameter
-- names, which is how we know they are reflected UFunctions and not plain C++.
-- What the binary cannot tell us is which of them the game calls when a player
-- earns XP, whether the amount passed is per-player or per-party, and whether
-- UE4SS can hook it at all. Play for two minutes with this on and the log
-- answers all three.

local probe = {}

local CANDIDATES = {
    -- UPalExpDatabase. The whole XP system funnels through this object; the
    -- _Server pair is almost certainly the choke point we want.
    "/Script/Pal.PalExpDatabase:AddExpValue_forPlayerParty_Server",
    "/Script/Pal.PalExpDatabase:DistributionExpValue_forPlayerParty_Server",
    "/Script/Pal.PalExpDatabase:AddExp_forPlayerParty_ByExpCalcType",
    "/Script/Pal.PalExpDatabase:AddExp_ToCharacter_ByExpCalcType",
    "/Script/Pal.PalExpDatabase:AddExp_EnemyDeath",
    "/Script/Pal.PalExpDatabase:AddExp_forBaseCamp",
    "/Script/Pal.PalExpDatabase:AddExp_forPlayerParty_TowerBoss",

    -- UPalUtility. GiveExpToAroundPlayerCharacter is the radius-based grant.
    -- If the game itself routes through this, the entire mod collapses into
    -- overwriting one float, because vanilla XP sharing already does what we
    -- want -- just not far enough.
    "/Script/Pal.PalUtility:GiveExpToAroundPlayerCharacter",
    "/Script/Pal.PalUtility:GiveExpToAroundCharacter",

    -- The per-character end of the chain.
    "/Script/Pal.PalIndividualCharacterParameter:AddExp",
}

-- Parameters arrive wrapped, and the wrapper throws for types it cannot
-- marshal, so every read is behind a pcall.
local function describe(value)
    if value == nil then return "nil" end

    local ok, inner = pcall(function() return value:get() end)
    if ok then value = inner end

    local t = type(value)
    if t == "number" or t == "boolean" or t == "string" then
        return tostring(value)
    end
    if t == "userdata" then
        local named, name = pcall(function() return value:GetFullName() end)
        if named and name then return name end
        local str, s = pcall(function() return value:ToString() end)
        if str and s then return s end
        return "<userdata>"
    end
    return "<" .. t .. ">"
end

local seen = {}

local function log_call(path, ...)
    local parts = {}
    for i = 1, select("#", ...) do
        parts[#parts + 1] = describe((select(i, ...)))
    end

    local line = "[SharedXPPool/probe] " .. path .. "(" .. table.concat(parts, ", ") .. ")"
    print(line .. "\n")

    if not seen[path] then
        seen[path] = true
        print("[SharedXPPool/probe] FIRST CALL: " .. path .. "\n")
    end
end

function probe.start()
    local hooked, missing = 0, {}

    for _, path in ipairs(CANDIDATES) do
        -- One unhookable name raises, and an uncaught raise here would skip
        -- every remaining RegisterHook in the loop -- so each gets its own
        -- pcall rather than wrapping the loop.
        local ok, err = pcall(function()
            RegisterHook(path, function(Context, ...)
                log_call(path, ...)
            end)
        end)

        if ok then
            hooked = hooked + 1
        else
            missing[#missing + 1] = path .. "  --  " .. tostring(err)
        end
    end

    print("[SharedXPPool/probe] hooked " .. hooked .. "/" .. #CANDIDATES .. " candidates\n")
    for _, m in ipairs(missing) do
        print("[SharedXPPool/probe] NOT HOOKABLE: " .. m .. "\n")
    end
    print("[SharedXPPool/probe] now go earn some XP and watch this log\n")
end

-- Dump what the game thinks the players are. Bound to a key in main.lua so it
-- can be triggered in-game rather than only at load, when no world exists yet.
function probe.dump_players()
    local players = require("players")
    local list = players.connected()

    print("[SharedXPPool/probe] " .. #list .. " connected player(s)\n")
    for i, pc in ipairs(list) do
        print(string.format("[SharedXPPool/probe]   %d. %s  key=%s\n",
            i, players.name(pc), tostring(players.key(pc))))
    end

    if #list == 0 then
        print("[SharedXPPool/probe] none found -- either not in a world yet, or "
            .. "PalUtility enumeration changed and needs revisiting\n")
    end
end

return probe
