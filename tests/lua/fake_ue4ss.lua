-- Just enough of the UE4SS and Palworld API to exercise the mod's logic
-- outside the game. Only the calls the mod actually makes are here; anything
-- else should fail loudly rather than quietly return nil.

local fake = {}

local state

-- The mod tries several ways to reach a character's individual parameter,
-- because which one is reachable from Lua is build-dependent. The fake
-- implements only the second, so the tests exercise the fall-through rather
-- than the happy first guess.
local function make_parameter(player)
    return {
        IsValid = function() return true end,
        GetExp = function() return player._exp end,
        GetLevel = function() return player._level end,
    }
end

function fake.reset(player_names)
    state = {
        players = {},
        grants = {},     -- { character = <fake player>, amount = n }
        hooks = {},
        keybinds = {},   -- key -> handler
        output = {},
        -- When set, a grant raises every player, not just the one standing at
        -- the target point. This is what the game actually does: paying one
        -- player raised the other too, because Palworld shares XP with nearby
        -- players and the exp call is a sphere. It is the behaviour that turned
        -- the first live run into a feedback loop.
        propagate = false,
    }

    for i, name in ipairs(player_names or {}) do
        state.players[i] = fake.add_player(name, 0, 1)
    end

    return state
end

function fake.add_player(name, exp, level)
    local index = #state.players + 1
    local player
    player = {
        _name = name,
        _exp = exp or 0,
        _level = level or 1,
        _index = index,
        IsValid = function() return true end,
        GetAddress = function(self) return 0x1000 + self._index end,
        -- Distinct positions: the real grant resolves a recipient by
        -- overlapping a sphere at a point.
        K2_GetActorLocation = function(self) return { X = self._index * 10000, Y = 0, Z = 0 } end,
        GetCharacterParameterComponent = function(self)
            return { GetIndividualParameter = function() return make_parameter(self) end }
        end,
        GetPlayerState = function(self)
            return {
                IsValid = function() return true end,
                PlayerNamePrivate = { ToString = function() return self._name end },
                PlayerUId = { A = self._index, B = 0, C = 0, D = 0 },
            }
        end,
    }

    if state.players[index] ~= player then
        state.players[index] = player
    end
    return player
end

function fake.state() return state end

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

    -- Granting really moves the number, so the mod's own payouts come back
    -- round on the next reading exactly as they would in game. Without that,
    -- the bookkeeping that stops a payout being mirrored again is untested.
    GiveExpToAroundPlayerCharacter = function(_, _, location, radius, amount, _)
        local target = nil
        for _, p in ipairs(state.players) do
            local at = p:K2_GetActorLocation()
            if at.X == location.X and at.Y == location.Y and at.Z == location.Z then
                target = p
                break
            end
        end
        if not target then
            error("GiveExpToAroundPlayerCharacter: nobody at that location")
        end

        state.grants[#state.grants + 1] = { character = target, amount = amount }

        for _, p in ipairs(state.players) do
            if p == target or state.propagate then
                p._exp = p._exp + amount
            end
        end
    end,
}

-- UEHelpers ships with UE4SS and the mod requires it by name. Standing it up
-- through package.preload means the mod's own require finds it, rather than the
-- test reaching inside the mod to inject anything.
local function install_uehelpers()
    package.loaded["UEHelpers"] = nil
    package.preload["UEHelpers"] = function()
        return {
            GetWorld = function()
                return { IsValid = function() return true end }
            end,
            GetAllPlayers = function()
                local pawns = {}
                for i, p in ipairs(state.players) do pawns[i] = p end
                return pawns
            end,
        }
    end
end

function fake.install()
    install_uehelpers()

    _G.StaticFindObject = function(path)
        if path == "/Script/Pal.Default__PalUtility" then return utility end
        return nil
    end

    _G.FindFirstOf = function(class)
        if class == "World" then return { IsValid = function() return true end } end
        return nil
    end

    _G.FindAllOf = function() return nil end
    _G.RegisterHook = function(path, callback) state.hooks[path] = callback return 1, 2 end
    _G.RegisterKeyBind = function(key, handler) state.keybinds[key] = handler end
    _G.ExecuteWithDelay = function() end
    -- Distinct values, so a test can tell the keys apart rather than watching
    -- them overwrite each other at index 0.
    _G.Key = { F7 = 7, F8 = 8, F9 = 9 }
    _G.print = function(line) state.output[#state.output + 1] = line end
end

return fake
