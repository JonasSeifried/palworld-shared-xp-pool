-- Discovery: what can the mod actually see and do in this build.
--
-- The first run settled the XP path. Of ten candidate functions, eight were
-- hookable; AddExp_ToCharacter_ByExpCalcType and
-- PalIndividualCharacterParameter:AddExp exist in the binary as C++ symbols but
-- are not reflected UFunctions, so UE4SS cannot reach them. Killing things
-- fired exactly one of the eight -- AddExp_EnemyDeath -- with a single
-- PalDeadInfo argument carrying no amount and no player.
--
-- That ruled out reading the award from a hook, which is why the mod watches
-- XP totals instead. The hooks below are kept because they still answer a
-- useful question: which functions crafting, building and capturing go through.
-- Nothing in the mod depends on the answer any more.
--
-- The dump is now the important half. It exercises the exact code the sharing
-- uses, so a dump showing the right names and the right XP is proof the mod
-- works -- and one player is enough to see it.

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
        local str, s = pcall(function() return value:ToString() end)
        if str and s then return s end
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
        local ok, err = pcall(function()
            RegisterHook(path, function(Context, ...)
                local parts = {}
                for i = 1, select("#", ...) do
                    parts[#parts + 1] = describe((select(i, ...)))
                end
                print("[SharedXPPool/probe] " .. path .. "(" .. table.concat(parts, ", ") .. ")\n")
                if not seen[path] then
                    seen[path] = true
                    print("[SharedXPPool/probe] FIRST CALL: " .. path .. "\n")
                end
            end)
        end)

        if ok then
            hooked = hooked + 1
        else
            missing[#missing + 1] = path
        end
    end

    print("[SharedXPPool/probe] hooked " .. hooked .. "/" .. #CANDIDATES .. "\n")
    for _, m in ipairs(missing) do
        print("[SharedXPPool/probe] NOT HOOKABLE: " .. m .. "\n")
    end
    print("[SharedXPPool/probe] press F7 in game -- that is the test that matters\n")
end

-- What the mod can see. Every line here comes from the same functions the
-- sharing uses, so this either works or names the thing that broke.
function probe.dump_players()
    local players = require("players")
    local list = players.connected()

    print("[SharedXPPool/probe] ---- player dump ----\n")
    print("[SharedXPPool/probe] " .. #list .. " connected player(s)\n")

    if #list == 0 then
        print("[SharedXPPool/probe] none found. Either no world is loaded, or "
            .. "PalUtility player enumeration changed. Sharing cannot work "
            .. "until this lists somebody.\n")
        return
    end

    local readable = 0
    for i, character in ipairs(list) do
        local exp = players.exp(character)
        local level = players.level(character)
        if exp then readable = readable + 1 end

        print(string.format("[SharedXPPool/probe]   %d. %-16s level=%-6s xp=%-10s key=%s\n",
            i,
            players.name(character),
            tostring(level),
            tostring(exp),
            tostring(players.key(character))))
    end

    local path = players.access_path()
    if path then
        print("[SharedXPPool/probe] xp read via " .. path .. "\n")
    end

    if readable == #list then
        print("[SharedXPPool/probe] OK -- every player's xp is readable. Check the "
            .. "numbers against what the game shows you, then set probe_only = "
            .. "false in config.lua.\n")
    else
        print("[SharedXPPool/probe] PROBLEM -- xp unreadable for "
            .. (#list - readable) .. " of " .. #list .. " player(s). None of the "
            .. "known ways to reach the individual parameter worked.\n")
    end
end

return probe
