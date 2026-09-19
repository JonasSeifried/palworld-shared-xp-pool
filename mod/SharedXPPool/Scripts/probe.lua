-- Discovery: what can the mod actually see and do in this build.
--
-- Run one settled the XP path. Of ten candidate functions eight were hookable;
-- AddExp_ToCharacter_ByExpCalcType and PalIndividualCharacterParameter:AddExp
-- exist as C++ symbols but are not reflected UFunctions. Killing pals fired
-- exactly one of the eight, AddExp_EnemyDeath, whose only argument is a
-- PalDeadInfo of {LastDamage, LastAttacker, selfActor} -- no amount, no player.
-- That is why the mod watches XP totals instead of reading awards from hooks.
--
-- Run two crashed the game outright, inside player enumeration, before a single
-- line was printed. Enumeration no longer touches PalUtility or FText.
--
-- Everything below logs before it acts rather than after. A native crash cannot
-- be caught by pcall, so the only way to learn where one happened is for the
-- last line in the log to be the thing that was about to run.

local probe = {}

local CANDIDATES = {
    "/Script/Pal.PalExpDatabase:AddExp_EnemyDeath",          -- confirmed: kills
    "/Script/Pal.PalExpDatabase:AddExpValue_forPlayerParty_Server",
    "/Script/Pal.PalExpDatabase:DistributionExpValue_forPlayerParty_Server",
    "/Script/Pal.PalExpDatabase:AddExp_forPlayerParty_ByExpCalcType",
    "/Script/Pal.PalExpDatabase:AddExp_forBaseCamp",
    "/Script/Pal.PalExpDatabase:AddExp_forPlayerParty_TowerBoss",
    "/Script/Pal.PalUtility:GiveExpToAroundPlayerCharacter",
    "/Script/Pal.PalUtility:GiveExpToAroundCharacter",
}

local function log(line)
    print("[SharedXPPool/probe] " .. line .. "\n")
end

-- Arguments arrive wrapped, and the wrapper throws for types it cannot
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
        return "<userdata>"
    end
    return "<" .. t .. ">"
end

local seen = {}

function probe.start()
    local hooked, missing = 0, {}

    for _, path in ipairs(CANDIDATES) do
        -- One unhookable name raises, and an uncaught raise would skip every
        -- remaining RegisterHook in the loop, so each gets its own pcall.
        local ok = pcall(function()
            RegisterHook(path, function(Context, ...)
                local parts = {}
                for i = 1, select("#", ...) do
                    parts[#parts + 1] = describe((select(i, ...)))
                end
                log(path .. "(" .. table.concat(parts, ", ") .. ")")
                if not seen[path] then
                    seen[path] = true
                    log("FIRST CALL: " .. path)
                end
            end)
        end)

        if ok then hooked = hooked + 1 else missing[#missing + 1] = path end
    end

    log("hooked " .. hooked .. "/" .. #CANDIDATES)
    for _, m in ipairs(missing) do log("NOT HOOKABLE: " .. m) end
end

-- What the mod can see. Every line comes from the same functions the sharing
-- uses, so this either works or names the thing that broke.
function probe.dump_players()
    local players = require("players")

    log("---- player dump ----")

    log("step 1: resolving the world")
    local world = players.world()
    log("step 1 ok: world = " .. tostring(world ~= nil))
    if not world then
        log("STOP -- no world. Nothing else can work until this does.")
        return
    end

    log("step 2: enumerating players")
    local list = players.connected()
    log("step 2 ok: " .. #list .. " player(s)")

    if #list == 0 then
        log("STOP -- nobody found. Either no world is loaded yet, or "
            .. "GameState.PlayerArray is not populated on this build.")
        return
    end

    local readable = 0
    for i, character in ipairs(list) do
        log("step 3." .. i .. ": reading player " .. i)

        local name = players.name(character)
        local key = players.key(character)
        local exp = players.exp(character)
        local level = players.level(character)
        if exp then readable = readable + 1 end

        log(string.format("  %d. %-16s level=%-6s xp=%-10s key=%s",
            i, name, tostring(level), tostring(exp), tostring(key)))
    end

    local path = players.access_path()
    if path then log("xp read via " .. path) end

    if readable == #list then
        log("OK -- every player's xp is readable. Check the numbers against what "
            .. "the game shows you, then press F8 to test the payout.")
    else
        log("PROBLEM -- xp unreadable for " .. (#list - readable) .. " of "
            .. #list .. " player(s). None of the known ways to reach the "
            .. "individual parameter worked.")
    end
end

-- Granting is the one Palworld-specific call the mod still makes, and the only
-- one not yet proven safe here. It gets its own key so that if it crashes, it
-- crashes alone and the log says which line did it.
function probe.test_grant()
    local players = require("players")

    log("---- grant test ----")

    local list = players.connected()
    if #list == 0 then
        log("STOP -- no players to pay.")
        return
    end

    local target = list[1]
    local before = players.exp(target)
    log("before: " .. players.name(target) .. " has " .. tostring(before) .. " xp")

    log("about to call PalUtility:GiveExpToAroundPlayerCharacter with 1 xp")
    local ok = players.grant(target, 1)
    log("call returned: " .. tostring(ok))

    local after = players.exp(target)
    log("after: " .. tostring(after) .. " xp")

    if before and after and after > before then
        log("OK -- payout works. Set probe_only = false in config.lua.")
    else
        log("PROBLEM -- xp did not move. The call may need a different world, "
            .. "radius or argument order.")
    end
end

return probe
