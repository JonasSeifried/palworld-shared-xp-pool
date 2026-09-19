-- Writing Palworld's own numbers, rather than working around them.
--
-- BP_PalGameSetting_C carries the game's tuning constants as plain scalar
-- properties, and they can be written. MapObjectDistributeExpRange, for one, is
-- the distance over which XP from destroying a map object is shared -- 1000
-- units by default, which is about ten metres.
--
-- That matters because the pool spends most of its effort inferring what the
-- game did. Widening the game's own sharing instead means it hands every award
-- to everybody itself, with the right amounts and the right pal XP, and there is
-- nothing left to infer. Where a setting exists for a kind of XP, changing it
-- beats guessing at it.
--
-- Nothing is written unless config.game_settings asks for it, and every write
-- is read back and reported, because a write that silently does nothing would
-- leave the pool trusting a radius that never changed.

local config = require("config")

local settings = {}

local done = false

-- Only scalars. Writing a struct or an array through a name is how the probe
-- killed the game during discovery.
local function readable(object, name)
    local ok, value = pcall(function() return object[name] end)
    if ok and (type(value) == "number" or type(value) == "boolean") then
        return value
    end
    return nil
end

-- Returns true once there is nothing left to do, so the caller can stop asking.
function settings.apply()
    if done then return true end

    local wanted = config.game_settings
    if not wanted or next(wanted) == nil then
        done = true
        return true
    end

    -- No world yet means no live settings object; try again next tick.
    local found, object = pcall(FindFirstOf, "PalGameSetting")
    if not (found and object) then return false end
    local checked, valid = pcall(function() return object:IsValid() end)
    if not (checked and valid) then return false end

    for name, value in pairs(wanted) do
        local before = readable(object, name)
        if before == nil then
            print("[SharedXPPool] " .. name
                .. ": no such setting on this build, or not a plain number\n")
        else
            pcall(function() object[name] = value end)
            local after = readable(object, name)
            if after == value then
                print(string.format("[SharedXPPool] %s: %s -> %s\n",
                    name, tostring(before), tostring(after)))
            else
                print(string.format(
                    "[SharedXPPool] %s: tried to set %s but it reads %s -- not applied\n",
                    name, tostring(value), tostring(after)))
            end
        end
    end

    done = true
    return true
end

function settings.reset()
    done = false
end

return settings
