-- Finding the connected players, reading their XP, and paying one of them.
--
-- Enumeration goes through PalUtility rather than FindAllOf("PalPlayerState"),
-- which returns nothing at all on some builds. It fails silently, so every loop
-- over it matches nobody and the mod looks simply broken.

local players = {}

local PalUtility = nil

local function utility()
    if PalUtility and PalUtility:IsValid() then return PalUtility end
    PalUtility = StaticFindObject("/Script/Pal.Default__PalUtility")
    if PalUtility and PalUtility:IsValid() then return PalUtility end
    return nil
end

local function world()
    local w = FindFirstOf("World")
    if w and w:IsValid() then return w end
    return nil
end

players.utility = utility
players.world = world

-- Every player currently connected, as PalPlayerCharacter actors.
function players.connected()
    local out = {}
    local w, u = world(), utility()
    if not (w and u) then return out end

    local list = u:GetPlayerListDisplayMessages(w)
    if not list then return out end

    for i = 1, #list do
        local pc = u:GetPlayerCharacterByPlayerIndex(w, i - 1)
        if pc and pc:IsValid() then
            out[#out + 1] = pc
        end
    end
    return out
end

-- Reaching a character's individual parameter, which is where XP lives.
--
-- All four of these names are in the shipping binary, but which one is a
-- reflected UFunction (and so reachable from Lua) is not something the binary
-- says. Try them in order and remember the one that worked, so a game patch
-- that moves the access path costs a different branch rather than a rewrite.
local ACCESSORS = {
    {
        name = "character:GetIndividualCharacterParameter()",
        get = function(c) return c:GetIndividualCharacterParameter() end,
    },
    {
        name = "character:GetCharacterParameterComponent():GetIndividualParameter()",
        get = function(c) return c:GetCharacterParameterComponent():GetIndividualParameter() end,
    },
    {
        name = "character.CharacterParameterComponent.IndividualParameter",
        get = function(c) return c.CharacterParameterComponent.IndividualParameter end,
    },
    {
        name = "character.IndividualParameter",
        get = function(c) return c.IndividualParameter end,
    },
}

local chosen = nil

local function usable(parameter)
    if not parameter then return false end
    local ok, valid = pcall(function() return parameter:IsValid() end)
    if not (ok and valid) then return false end
    local reads = pcall(function() return parameter:GetExp() end)
    return reads
end

function players.parameter(character)
    if not (character and character:IsValid()) then return nil end

    if chosen then
        local ok, parameter = pcall(chosen.get, character)
        if ok and usable(parameter) then return parameter end
        chosen = nil  -- it stopped working; fall through and look again
    end

    for _, accessor in ipairs(ACCESSORS) do
        local ok, parameter = pcall(accessor.get, character)
        if ok and usable(parameter) then
            chosen = accessor
            return parameter
        end
    end
    return nil
end

-- Which accessor is in use, for the probe to report. nil until one is found.
function players.access_path()
    return chosen and chosen.name or nil
end

local function number(value)
    if type(value) == "number" then return value end
    local ok, inner = pcall(function() return value:get() end)
    if ok and type(inner) == "number" then return inner end
    return nil
end

-- Total XP earned over the character's life, not progress within the level:
-- a save stores 73,865 for a level 21 player whose level began at 68,784. That
-- makes differences between two readings the amount actually earned.
function players.exp(character)
    local parameter = players.parameter(character)
    if not parameter then return nil end
    local ok, value = pcall(function() return parameter:GetExp() end)
    if not ok then return nil end
    return number(value)
end

function players.level(character)
    local parameter = players.parameter(character)
    if not parameter then return nil end
    local ok, value = pcall(function() return parameter:GetLevel() end)
    if not ok then return nil end
    return number(value)
end

-- A stable identity. The player's UId survives reconnects and is not reused,
-- unlike an object address.
function players.key(character)
    if not (character and character:IsValid()) then return nil end

    local ok, uid = pcall(function()
        return character:GetPalPlayerController().PlayerState.PlayerUId
    end)
    if ok and uid then
        local formatted, text = pcall(function()
            return string.format("%08X-%08X-%08X-%08X",
                uid.A or 0, uid.B or 0, uid.C or 0, uid.D or 0)
        end)
        if formatted and text then return text end
    end

    local addressed, address = pcall(function() return character:GetAddress() end)
    if addressed and address then return tostring(address) end
    return nil
end

function players.name(character)
    if not (character and character:IsValid()) then return "?" end
    local ok, n = pcall(function()
        return character:GetPalPlayerController().PlayerState.PlayerNamePrivate:ToString()
    end)
    if ok and n then return n end
    return "?"
end

-- Grant XP to one player by calling the game's own exp-giving function at that
-- player's feet, with a radius small enough to reach nobody else. Going through
-- the game means level-ups, UI and replication happen the way they normally do;
-- writing the Exp field directly would skip all of that.
--
-- The radius is not zero because the call is a sphere overlap and the player's
-- own capsule has to fall inside it.
local GRANT_RADIUS = 50.0

function players.grant(character, amount)
    if not (character and character:IsValid()) then return false end
    if not amount or amount <= 0 then return false end

    local w, u = world(), utility()
    if not (w and u) then return false end

    local ok, location = pcall(function() return character:K2_GetActorLocation() end)
    if not (ok and location) then return false end

    local granted = pcall(function()
        u:GiveExpToAroundPlayerCharacter(w, location, GRANT_RADIUS, amount, true)
    end)
    return granted
end

return players
