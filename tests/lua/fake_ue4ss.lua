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
        -- Set by make_property when a type-specific accessor is used on the
        -- wrong property kind, which in game is a crash rather than an error.
        unsafe_property_access = false,
        -- Whether the list-based payout can be reached at all, so a test can
        -- force the radius fallback.
        precise_available = true,
        sphere_calls = 0,
        delayed = {},
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

-- Run whatever ExecuteWithDelay has queued so far, once each.
function fake.run_delayed()
    local queued = state.delayed
    state.delayed = {}
    for _, callback in ipairs(queued) do callback() end
    return #queued
end

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

        state.sphere_calls = state.sphere_calls + 1
        state.grants[#state.grants + 1] = { character = target, amount = amount }

        for _, p in ipairs(state.players) do
            if p == target or state.propagate then
                p._exp = p._exp + amount
            end
        end
    end,
}

-- The list-based payout: it names its recipients, so nothing is forwarded to
-- bystanders even when the game would otherwise share.
local exp_database = {
    IsValid = function() return true end,
    GetFullName = function() return "BP_PalExpDatabase_C /Engine/Transient.fake" end,
    AddExpValue_forPlayerParty_Server = function(_, amount, gift_list, _)
        for _, character in ipairs(gift_list) do
            character._exp = character._exp + amount
            state.grants[#state.grants + 1] = { character = character, amount = amount }
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

-- A reflected property, with the accessors that only exist on its own kind.
--
-- In game, calling GetInner on a non-array (or GetStruct on a non-struct) reads
-- a wrong offset and kills the process -- it is not a catchable error, and it
-- did kill it once. Here a mismatched call is recorded and raised, so a test
-- can assert it never happened even though the code under test wraps these in
-- pcall.
local function named(text)
    return { GetFName = function() return { ToString = function() return text end } end }
end

local function make_property(name, kind, extras)
    extras = extras or {}
    local property = named(name)
    property.GetClass = function() return named(kind) end

    local function only_for(allowed, accessor, value)
        return function()
            local permitted = false
            for _, k in ipairs(allowed) do
                if k == kind then permitted = true end
            end
            if not permitted then
                state.unsafe_property_access =
                    accessor .. " on a " .. kind .. " would crash the game"
                error(state.unsafe_property_access)
            end
            return value
        end
    end

    property.GetInner = only_for({ "ArrayProperty" }, "GetInner", extras.inner)
    property.GetPropertyClass = only_for({ "ObjectProperty", "ClassProperty" },
        "GetPropertyClass", extras.class)
    property.GetStruct = only_for({ "StructProperty" }, "GetStruct", extras.struct)

    return property
end

local EXP_FUNCTIONS = {
    ["/Script/Pal.PalExpDatabase:AddExpValue_forPlayerParty_Server"] = {
        make_property("ExpValue", "Int64Property"),
        make_property("GiftPlayerList", "ArrayProperty", {
            inner = make_property("Item", "ObjectProperty",
                { class = named("PalPlayerCharacter") }),
        }),
        make_property("isCallDelegate", "BoolProperty"),
    },
    ["/Script/Pal.PalUtility:GiveExpToAroundPlayerCharacter"] = {
        make_property("WorldContextObject", "ObjectProperty",
            { class = named("Object") }),
        make_property("Center", "StructProperty", { struct = named("Vector") }),
        make_property("Radius", "FloatProperty"),
        make_property("Exp", "FloatProperty"),
        make_property("bCallDelegate", "BoolProperty"),
    },
}

function fake.install()
    install_uehelpers()

    _G.StaticFindObject = function(path)
        if path == "/Script/Pal.Default__PalUtility" then return utility end

        local properties = EXP_FUNCTIONS[path]
        if properties then
            return {
                IsValid = function() return true end,
                GetFullName = function() return "Function " .. path end,
                ForEachProperty = function(_, visit)
                    for _, property in ipairs(properties) do visit(property) end
                end,
            }
        end
        return nil
    end

    _G.FindFirstOf = function(class)
        if class == "World" then return { IsValid = function() return true end } end
        if class == "PalExpDatabase" and state.precise_available then
            return exp_database
        end
        return nil
    end

    _G.FindAllOf = function() return nil end
    _G.RegisterHook = function(path, callback) state.hooks[path] = callback return 1, 2 end
    _G.RegisterKeyBind = function(key, handler) state.keybinds[key] = handler end
    -- Queue rather than run. Running immediately would send the pool's
    -- self-rescheduling loop straight into a stack overflow, and never running
    -- would leave the probe's delayed reading untested. fake.run_delayed drains
    -- what is queued at that moment, so a callback that queues another one does
    -- not loop.
    _G.ExecuteWithDelay = function(_, callback)
        state.delayed[#state.delayed + 1] = callback
    end
    -- Distinct values, so a test can tell the keys apart rather than watching
    -- them overwrite each other at index 0.
    _G.Key = { F6 = 6, F7 = 7, F8 = 8, F9 = 9 }
    _G.print = function(line) state.output[#state.output + 1] = line end
end

return fake
