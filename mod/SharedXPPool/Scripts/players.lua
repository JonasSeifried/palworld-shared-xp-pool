-- Finding the connected players, and granting XP to one of them.
--
-- Both are done through PalUtility rather than the obvious UE4SS route.
-- FindAllOf("PalPlayerState") returns nothing at all on some Palworld builds --
-- it fails silently, so every loop over it matches nobody and the mod looks
-- like it simply does not work. PalUtility's own enumeration is what the game
-- uses and it has held up across patches.

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

-- A stable identity for a player character, used to tell recipients apart.
function players.key(character)
    if not (character and character:IsValid()) then return nil end
    local ok, addr = pcall(function() return character:GetAddress() end)
    if ok and addr then return tostring(addr) end
    return tostring(character)
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
-- player's feet with a radius small enough to reach nobody else. Going through
-- the game means level-ups, UI and replication all happen the way they normally
-- do; writing the Exp field directly would skip all of that.
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
