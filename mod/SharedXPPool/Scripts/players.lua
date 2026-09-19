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

-- Straight-line distance between two characters, in Unreal units, or nil if
-- either position cannot be read. Used to tell players the game has already
-- shared XP between from players who are too far apart for that.
function players.distance(a, b)
    local ok, d = pcall(function()
        local pa, pb = a:K2_GetActorLocation(), b:K2_GetActorLocation()
        local dx, dy, dz = pa.X - pb.X, pa.Y - pb.Y, pa.Z - pb.Z
        return math.sqrt(dx * dx + dy * dy + dz * dz)
    end)
    if ok then return d end
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

-- Paying a player.
--
-- Through the game's own function rather than by writing the Exp field, so
-- level-ups, the UI and replication happen normally:
--
--   AddExpValue_forPlayerParty_Server(ExpValue: Int64,
--                                     GiftPlayerList: Array of PalPlayerCharacter,
--                                     isCallDelegate: Bool)
--
-- Named recipients, no radius, nothing for the game to forward to bystanders.
-- That is a correctness requirement, not a preference: the pool moves everybody
-- toward the highest total, so a payout that also raises a bystander moves the
-- top every time it is approached. The sphere-based alternative leaks by
-- design and is not used; if this call fails, the mod shares nothing.

local database = nil
-- nil until the list-based call has been tried, then true or false for good.
local precise_works = nil

local function exp_database()
    if database and database:IsValid() then return database end
    local ok, found = pcall(FindFirstOf, "PalExpDatabase")
    if ok and found and found:IsValid() then
        database = found
        return database
    end
    return nil
end

local function grant_by_list(character, amount)
    local db = exp_database()
    if not db then return false end

    -- On the first attempt, check the XP actually moved. A call that raises is
    -- easy to notice; one that quietly does nothing would leave the pool
    -- believing it had paid everybody, forever.
    local verify = (precise_works == nil)
    local before = verify and players.exp(character) or nil

    local ok = pcall(function()
        db:AddExpValue_forPlayerParty_Server(amount, { character }, true)
    end)
    if not ok then return false end

    if verify then
        local after = players.exp(character)
        if not (before and after and after > before) then return false end
    end

    return true
end

function players.grant(character, amount)
    if not (character and character:IsValid()) then return false end
    if not amount or amount <= 0 then return false end
    if precise_works == false then return false end

    local first = (precise_works == nil)
    if grant_by_list(character, amount) then
        if first then
            precise_works = true
            print("[SharedXPPool] paying via AddExpValue_forPlayerParty_Server"
                .. " -- named recipients, nothing forwarded to bystanders\n")
        end
        return true
    end

    if first then
        precise_works = false
        print("[SharedXPPool] AddExpValue_forPlayerParty_Server does not work on this"
            .. " build, and there is no safe fallback -- a payout that reaches"
            .. " bystanders would make the pool chase a moving target\n")
    end
    return false
end

-- Which route is in use: true, false, or nil before anything has been paid.
function players.precise_payout()
    return precise_works
end

return players
