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

-- Pay one player 1 XP and measure who actually received it.
--
-- Paying one player raised the other in the first two-player run, and the
-- amount is not the question -- who it reaches is. If only the recipient moves,
-- the payout is precise. If everyone moves, the distance between them says
-- whether it is the game's nearby-player sharing forwarding it (in which case
-- standing apart will stop it, and the mod's normal top-up never fires when
-- players are together anyway) or something that ignores distance entirely (in
-- which case this function is the wrong one to grant with).
--
-- Run it once standing next to each other, once far apart. The difference is
-- the answer.
function probe.test_grant(which)
    local players = require("players")

    which = which or 1

    log("---- grant test (player " .. which .. ") ----")

    local list = players.connected()
    if #list < which then
        log("STOP -- there is no player " .. which .. "; only " .. #list .. " connected.")
        return
    end

    local before = {}
    for i, character in ipairs(list) do
        before[i] = players.exp(character)
    end

    local target = list[which]

    log("paying " .. players.name(target) .. " 1 xp")
    local ok = players.grant(target, 1)
    log("call returned: " .. tostring(ok)
        .. "  (route: " .. tostring(players.precise_payout()) .. ")")

    local moved = 0
    for i, character in ipairs(list) do
        local after = players.exp(character)
        local delta = (after and before[i]) and (after - before[i]) or nil
        local away = (i == which) and 0 or players.distance(character, target)

        -- "%+s" is not a thing: the + flag is for numbers, and string.format
        -- raises on it. Build the signed text by hand so a nil delta is still
        -- printable.
        local change = delta and string.format("%+d", delta) or "?"

        log(string.format("  %-16s %s -> %s  (%s xp)  %s",
            players.name(character),
            tostring(before[i]), tostring(after),
            change,
            i == which and "<- the one being paid"
                or ("distance " .. (away and string.format("%.0f", away) or "?"))))

        if delta and delta > 0 then moved = moved + 1 end
    end

    if moved == 0 then
        log("PROBLEM -- nobody gained anything.")
    elseif moved == 1 then
        log("OK -- the payout reached only its target.")
    else
        log("LEAK -- the payout reached " .. moved .. " players. Note the "
            .. "distances above, then run this again standing far apart.")
    end

    -- Everything above is the direct payout. The pool has not run yet -- it
    -- ticks on its own schedule -- so the interesting part, whether a player
    -- topped up by the pool brings their pal along, has not happened. Look
    -- again once it has, measuring from the same baseline.
    local config = require("config")
    ExecuteWithDelay(config.poll_interval_ms + 500, function()
        local ok, err = pcall(function()
            log("---- after the pool ticked ----")
            for i, character in ipairs(list) do
                local now = players.exp(character)
                local total = (now and before[i]) and (now - before[i]) or nil
                log(string.format("  %-16s %s xp in total",
                    players.name(character),
                    total and string.format("%+d", total) or "?"))
            end
        end)
        if not ok then
            log("follow-up reading failed: " .. tostring(err))
        end
    end)
end

local function name_of(object)
    local ok, n = pcall(function() return object:GetFName():ToString() end)
    if ok and n then return n end
    return nil
end

-- Property kinds whose value is a plain scalar and safe to read. Anything else
-- is left alone: asking a struct or an array for its contents is the territory
-- that killed the game during discovery.
local SCALARS = {
    FloatProperty = true,
    DoubleProperty = true,
    IntProperty = true,
    Int8Property = true,
    Int64Property = true,
    UInt32Property = true,
    ByteProperty = true,
    BoolProperty = true,
}

local RANGE_HINTS = { "radius", "range", "distance", "dist", "near", "share" }

local function looks_like_a_range(name)
    local lowered = name:lower()
    for _, hint in ipairs(RANGE_HINTS) do
        if lowered:find(hint, 1, true) then return true end
    end
    return false
end

-- Is the distance Palworld shares XP over something we can just write to?
--
-- Worth knowing before building anything that works around it. If the radius is
-- reachable, setting it huge makes the game share every award with everybody
-- itself -- right amounts, right pal XP, right level-ups -- and the pool stops
-- having to infer from totals whether two players who both gained were near
-- each other. Most of this mod would become unnecessary.
--
-- The kill path gives no hope of intercepting it: run one found that kills fire
-- AddExp_EnemyDeath and not GiveExpToAroundPlayerCharacter, so the sharing
-- happens inside native code with no reflected radius to change. A property on
-- a live object is the remaining possibility, and BP_PalExpDatabase_C is a
-- Blueprint, so it may well expose one.
function probe.dump_share_radius()
    local CANDIDATES = {
        "PalExpDatabase",
        "PalGameSetting",
        "PalGameWorldSettings",
        "PalWorldSettings",
        "PalGameStateInGame",
    }

    log("---- looking for a share radius we can set ----")

    for _, class in ipairs(CANDIDATES) do
        local found, object = pcall(FindFirstOf, class)
        local live = false
        if found and object then
            local ok, valid = pcall(function() return object:IsValid() end)
            live = ok and valid
        end

        if not live then
            log(class .. ": not present")
        else
            local named, full = pcall(function() return object:GetFullName() end)
            log(class .. ": " .. ((named and full) or "found, but it will not name itself"))

            local seen, hits = 0, 0
            local walked = pcall(function()
                object:GetClass():ForEachProperty(function(property)
                    seen = seen + 1
                    local name = name_of(property) or "?"
                    local kind = name_of(property:GetClass()) or "?"
                    local interesting = looks_like_a_range(name)

                    if interesting or SCALARS[kind] then
                        local text = "not read"
                        if SCALARS[kind] then
                            local read, value = pcall(function() return object[name] end)
                            if read then text = tostring(value) end
                        end
                        log(string.format("    %s%s: %s = %s",
                            interesting and "*** " or "", name, kind, text))
                        if interesting then hits = hits + 1 end
                    end
                end)
            end)

            if not walked then
                log("    -- stopped reading properties after " .. seen)
            elseif seen == 0 then
                log("    (no properties reported)")
            end
            log(string.format("    %s propert(ies), %s of them look like a range",
                tostring(seen), tostring(hits)))
        end
    end

    log("Anything marked *** is worth trying: set it large and see whether a kill"
        .. " reaches a player standing far away.")
end

-- What a parameter is made of, beyond its outer kind. An ArrayProperty on its
-- own says nothing about what belongs in the array, and that is exactly what
-- has to be right to pay one player instead of a sphere full of them.
--
-- Every accessor here is gated on the property's class, and that is not
-- tidiness. GetInner, GetPropertyClass and GetStruct each read a field that
-- only exists on their own property type; called on anything else they read a
-- wrong offset and take the process down. The first version asked every
-- property for all three and killed the game on the first parameter it saw.
-- pcall does not help -- an access violation is not a Lua error.
local function detail(property)
    local kind = name_of(property:GetClass())
    if not kind then return "" end

    if kind == "ArrayProperty" then
        local ok, inner = pcall(function() return property:GetInner() end)
        if not (ok and inner) then return "  (array of ?)" end

        local inner_kind = name_of(inner:GetClass()) or "?"
        local target = nil
        if inner_kind == "ObjectProperty" or inner_kind == "ClassProperty" then
            local okc, class = pcall(function() return inner:GetPropertyClass() end)
            if okc and class then target = name_of(class) end
        elseif inner_kind == "StructProperty" then
            local oks, struct = pcall(function() return inner:GetStruct() end)
            if oks and struct then target = name_of(struct) end
        end

        return "  (of " .. inner_kind .. (target and (" -> " .. target) or "") .. ")"
    end

    if kind == "ObjectProperty" or kind == "ClassProperty" then
        local ok, class = pcall(function() return property:GetPropertyClass() end)
        if ok and class then return "  (-> " .. (name_of(class) or "?") .. ")" end
        return ""
    end

    if kind == "StructProperty" then
        local ok, struct = pcall(function() return property:GetStruct() end)
        if ok and struct then return "  {" .. (name_of(struct) or "?") .. "}" end
        return ""
    end

    return ""
end

-- What the exp-granting functions actually take.
--
-- Reading a parameter's name and class is safe. Reading what is *inside* it is
-- not, unless the accessor matches the property type -- see detail() above,
-- which learned that the hard way. Each parameter is logged as it is read
-- rather than at the end, so if something here does take the game down again,
-- the log stops on the parameter that did it.
--
-- The first pass already found the shape worth having:
-- AddExpValue_forPlayerParty_Server(ExpValue: Int64, GiftPlayerList: Array,
-- isCallDelegate: Bool) takes an explicit list of players and no radius at all,
-- which is the leak-free payout this mod needs. What it did not say is what
-- belongs in that list -- player characters, player states or something else --
-- and passing the wrong type to a native function is how the game crashes. So
-- ask, rather than guess.
function probe.dump_exp_api()
    local FUNCTIONS = {
        "/Script/Pal.PalExpDatabase:AddExpValue_forPlayerParty_Server",
        "/Script/Pal.PalExpDatabase:DistributionExpValue_forPlayerParty_Server",
        "/Script/Pal.PalExpDatabase:AddExp_forPlayerParty_ByExpCalcType",
        "/Script/Pal.PalUtility:GiveExpToAroundPlayerCharacter",
        "/Script/Pal.PalUtility:GiveExpToAroundCharacter",
    }

    log("---- exp api ----")

    for _, path in ipairs(FUNCTIONS) do
        local found, fn = pcall(StaticFindObject, path)
        if not (found and fn and fn:IsValid()) then
            log(path .. "  -- not found")
        else
            log(path)

            local count = 0
            local ok = pcall(function()
                fn:ForEachProperty(function(property)
                    count = count + 1
                    local name = name_of(property) or "?"
                    local kind = name_of(property:GetClass()) or "?"

                    -- Name and kind first, on their own line, before anything
                    -- reaches inside the property.
                    log("    " .. count .. ". " .. name .. ": " .. kind)
                    local inside = detail(property)
                    if inside ~= "" then
                        log("       " .. inside:gsub("^%s+", ""))
                    end
                end)
            end)

            if not ok then
                log("    -- stopped reading parameters after " .. count)
            elseif count == 0 then
                log("    (no parameters reported)")
            end
        end
    end

    -- Calling AddExpValue_forPlayerParty_Server needs a live UPalExpDatabase to
    -- call it on, not the class default. Find out now whether one is reachable,
    -- while it costs nothing.
    log("looking for a live PalExpDatabase to call:")
    for _, how in ipairs({ "PalExpDatabase", "PalExpDatabaseBase" }) do
        local ok, found = pcall(FindFirstOf, how)
        local description = "nothing"
        if ok and found then
            local valid = pcall(function() return found:IsValid() end)
            if valid then
                local named, full = pcall(function() return found:GetFullName() end)
                description = (named and full) or "found, but it will not name itself"
            end
        end
        log(string.format("  FindFirstOf(%q) -> %s", how, description))
    end

    probe.dump_share_radius()
end

return probe
