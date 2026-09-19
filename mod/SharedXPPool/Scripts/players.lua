-- Finding the connected players, reading their XP, and paying one of them.
--
-- Enumeration deliberately uses nothing Palworld-specific. The first attempt
-- went through PalUtility -- StaticFindObject on the CDO, then
-- GetPlayerListDisplayMessages(FindFirstOf("World")) -- and hard-crashed the
-- game the moment it ran. Two likely reasons, both avoided here:
-- FindFirstOf("World") can return a UWorld that is not the one being played,
-- and passing that into a Pal function is undefined; and the call returns an
-- array of FText, which this build of UE4SS has a changelog entry about
-- crashing on.
--
-- UEHelpers walks GameState.PlayerArray to PlayerState.PawnPrivate instead,
-- which is plain Unreal with no text marshalling and a world resolved through
-- the player controller. It ships with UE4SS and is maintained alongside it.

local players = {}

local UEHelpers = nil
do
    local ok, helpers = pcall(require, "UEHelpers")
    if ok then
        UEHelpers = helpers
    else
        print("[SharedXPPool] could not load UEHelpers: " .. tostring(helpers) .. "\n")
    end
end

function players.world()
    if not UEHelpers then return nil end
    local ok, w = pcall(UEHelpers.GetWorld)
    if ok and w and w:IsValid() then return w end
    return nil
end

-- Every player currently connected, as pawns.
function players.connected()
    if not UEHelpers then return {} end

    local ok, pawns = pcall(UEHelpers.GetAllPlayers)
    if not (ok and pawns) then return {} end

    local out = {}
    for _, pawn in ipairs(pawns) do
        if pawn and pawn:IsValid() then
            out[#out + 1] = pawn
        end
    end
    return out
end

-- Reaching a character's individual parameter, which is where XP lives.
--
-- All four names are in the shipping binary, but which one is a reflected
-- UFunction (and so reachable from Lua) is not something the binary says. Try
-- them in order and remember what worked, so a patch that moves the access path
-- costs a different branch rather than a rewrite.
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
    return pcall(function() return parameter:GetExp() end)
end

function players.parameter(character)
    if not (character and character:IsValid()) then return nil end

    if chosen then
        local ok, parameter = pcall(chosen.get, character)
        if ok and usable(parameter) then return parameter end
        chosen = nil  -- it stopped working; look again
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

-- Total XP earned over the character's life, not progress within the level: a
-- save stores 73,865 for a level 21 player whose level began at 68,784. That
-- makes the difference between two readings the amount actually earned.
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

local function player_state(character)
    local ok, state = pcall(function() return character:GetPlayerState() end)
    if ok and state and state:IsValid() then return state end
    ok, state = pcall(function() return character.PlayerState end)
    if ok and state and state:IsValid() then return state end
    return nil
end

-- A stable identity. The player's UId survives a reconnect and is not reused,
-- unlike an object address.
function players.key(character)
    if not (character and character:IsValid()) then return nil end

    local state = player_state(character)
    if state then
        local ok, text = pcall(function()
            local uid = state.PlayerUId
            -- The four words come back as signed integers, so a high bit set
            -- prints as FFFFFFFFD0686E06 rather than D0686E06. Mask to 32 bits
            -- to get the form the save files use.
            local function word(v) return (v or 0) & 0xFFFFFFFF end
            return string.format("%08X-%08X-%08X-%08X",
                word(uid.A), word(uid.B), word(uid.C), word(uid.D))
        end)
        if ok and text then return text end
    end

    local addressed, address = pcall(function() return character:GetAddress() end)
    if addressed and address then return tostring(address) end
    return nil
end

function players.name(character)
    if not (character and character:IsValid()) then return "?" end

    local state = player_state(character)
    if state then
        local ok, n = pcall(function() return state.PlayerNamePrivate:ToString() end)
        if ok and n then return n end
    end
    return "?"
end

-- Grant XP by calling the game's own exp-giving function at the recipient's
-- feet, with a radius small enough to reach nobody else. Going through the game
-- means level-ups, UI and replication happen normally; writing the Exp field
-- directly would skip all of that.
--
-- This is the one Palworld-specific call left, and it is the one that has not
-- been proven safe on this build. probe.test_grant puts it behind its own key
-- so that if it crashes, it crashes on its own and says so.
--
-- The radius is not zero because the call is a sphere overlap and the player's
-- own capsule has to fall inside it.
local GRANT_RADIUS = 50.0

function players.grant(character, amount)
    if not (character and character:IsValid()) then return false end
    if not amount or amount <= 0 then return false end

    local w = players.world()
    if not w then return false end

    local utility = StaticFindObject("/Script/Pal.Default__PalUtility")
    if not (utility and utility:IsValid()) then return false end

    local ok, location = pcall(function() return character:K2_GetActorLocation() end)
    if not (ok and location) then return false end

    return pcall(function()
        utility:GiveExpToAroundPlayerCharacter(w, location, GRANT_RADIUS, amount, true)
    end)
end

return players
