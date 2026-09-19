-- Just enough of the UE4SS and Palworld API to exercise the mod's logic
-- outside the game. Only the calls the mod actually makes are here; anything
-- else should fail loudly rather than quietly return nil.

local fake = {}

local state

function fake.reset(player_names)
    state = {
        players = {},
        grants = {},     -- { character = <fake player>, amount = n }
        -- When set, every grant re-enters the XP hook, the way it would if
        -- GiveExpToAroundPlayerCharacter routes back through the same server
        -- function we hooked.
        reentrant = false,
        hooks = {},      -- hook path -> callback
        output = {},
    }

    for i, name in ipairs(player_names or {}) do
        state.players[i] = {
            _name = name,
            _address = 0x1000 + i,
            IsValid = function() return true end,
            GetAddress = function(self) return self._address end,
            -- Distinct positions, because the real grant resolves a recipient
            -- by overlapping a sphere at a point.
            K2_GetActorLocation = function() return { X = i * 10000, Y = 0, Z = 0 } end,
            GetPalPlayerController = function(self)
                return {
                    PlayerState = {
                        PlayerNamePrivate = {
                            ToString = function() return self._name end,
                        },
                    },
                }
            end,
        }
    end

    return state
end

function fake.state() return state end

-- A parameter as the mod sees it: wrapped, with :get() to unwrap.
function fake.param(value)
    return { get = function() return value end }
end

local utility = {
    IsValid = function() return true end,

    GetPlayerListDisplayMessages = function(_, _)
        local list = {}
        for i, p in ipairs(state.players) do
            list[i] = { get = function() return { ToString = function() return p._name end } end }
        end
        return list
    end,

    GetPlayerCharacterByPlayerIndex = function(_, _, index)
        return state.players[index + 1]
    end,

    GiveExpToAroundPlayerCharacter = function(_, _, location, radius, amount, _)
        -- The real call is a sphere overlap, so resolve who is standing at that
        -- point rather than trusting the caller to have picked correctly.
        for _, p in ipairs(state.players) do
            local at = p:K2_GetActorLocation()
            if at.X == location.X and at.Y == location.Y and at.Z == location.Z then
                state.grants[#state.grants + 1] = { character = p, amount = amount }
                if state.reentrant then
                    -- A different amount, so only the re-entrancy guard can
                    -- stop this -- the duplicate filter will not.
                    fake.fire_raw(p, amount + 1)
                end
                return
            end
        end
        error("GiveExpToAroundPlayerCharacter: nobody at that location")
    end,
}

-- Re-fire the XP hook from inside a grant. Split out so the fake utility can
-- reach it without depending on which path the test registered.
function fake.fire_raw(earner, amount)
    for _, callback in pairs(state.hooks) do
        callback(nil, fake.param(earner), fake.param(amount))
    end
end

function fake.install()
    _G.StaticFindObject = function(path)
        if path == "/Script/Pal.Default__PalUtility" then return utility end
        return nil
    end

    _G.FindFirstOf = function(class)
        if class == "World" then return { IsValid = function() return true end } end
        return nil
    end

    _G.FindAllOf = function() return nil end

    _G.RegisterHook = function(path, callback)
        state.hooks[path] = callback
        return 1, 2
    end

    _G.RegisterKeyBind = function() end
    _G.Key = { F7 = 0 }

    _G.print = function(line) state.output[#state.output + 1] = line end
end

-- Fire a hook the way the game would, wrapping every argument.
function fake.fire(path, ...)
    local callback = state.hooks[path]
    if not callback then error("no hook registered at " .. path) end

    local wrapped = {}
    for i = 1, select("#", ...) do
        wrapped[i] = fake.param((select(i, ...)))
    end
    callback(nil, table.unpack(wrapped, 1, select("#", ...)))
end

return fake
