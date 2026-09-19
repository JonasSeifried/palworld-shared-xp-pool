-- Run: lua tests/lua/test_pool.lua   (from the repo root)

package.path = "tests/lua/?.lua;mod/SharedXPPool/Scripts/?.lua;" .. package.path

local fake = require("fake_ue4ss")
local real_print = print

local passed, failed = 0, 0

local function load_pool(overrides)
    package.loaded["pool"] = nil
    package.loaded["players"] = nil
    package.loaded["config"] = nil
    package.loaded["UEHelpers"] = nil

    local config = require("config")
    for k, v in pairs(overrides or {}) do config[k] = v end
    config.verbose = false

    return require("pool")
end

local function test(name, body)
    fake.install()
    local ok, err = pcall(body)
    if ok then
        passed = passed + 1
        real_print("  ok    " .. name)
    else
        failed = failed + 1
        real_print("  FAIL  " .. name .. "\n          " .. tostring(err))
    end
end

local function assert_equal(actual, expected, what)
    if actual ~= expected then
        error(string.format("%s: expected %s, got %s",
            what, tostring(expected), tostring(actual)), 2)
    end
end

local function exp_by_name(state)
    local out = {}
    for _, p in ipairs(state.players) do out[p._name] = p._exp end
    return out
end

real_print("shared xp pool -- live mod")

test("the first tick only takes a baseline", function()
    local state = fake.reset({ "Jonas", "Keddo" })
    state.players[1]._exp = 5000
    local pool = load_pool()

    pool.tick()

    -- Existing XP is not something they just earned.
    assert_equal(#state.grants, 0, "grant count")
    assert_equal(state.players[2]._exp, 0, "Keddo untouched")
end)

test("xp earned after the baseline is mirrored to everyone else", function()
    local state = fake.reset({ "Jonas", "Keddo", "HenBot" })
    local pool = load_pool()

    pool.tick()
    state.players[1]._exp = state.players[1]._exp + 100
    pool.tick()

    local got = exp_by_name(state)
    assert_equal(got["Keddo"], 100, "Keddo")
    assert_equal(got["HenBot"], 100, "HenBot")
    assert_equal(got["Jonas"], 100, "the earner keeps exactly what they earned")
end)

test("a payout is not mistaken for earnings and mirrored again", function()
    -- The whole design rests on this. Grants really move the number in the
    -- fake, so without the bookkeeping each tick would re-share the last
    -- tick's payout and XP would compound forever.
    local state = fake.reset({ "Jonas", "Keddo", "HenBot" })
    local pool = load_pool()

    pool.tick()
    state.players[1]._exp = state.players[1]._exp + 100
    for _ = 1, 6 do pool.tick() end

    local got = exp_by_name(state)
    assert_equal(got["Jonas"], 100, "Jonas")
    assert_equal(got["Keddo"], 100, "Keddo")
    assert_equal(got["HenBot"], 100, "HenBot")
    assert_equal(#state.grants, 2, "one payout each, once")
end)

test("everyone earning at once settles without compounding", function()
    local state = fake.reset({ "Jonas", "Keddo" })
    local pool = load_pool()

    pool.tick()
    state.players[1]._exp = state.players[1]._exp + 100
    state.players[2]._exp = state.players[2]._exp + 40
    for _ = 1, 6 do pool.tick() end

    local got = exp_by_name(state)
    -- Each earned their own and received the other's.
    assert_equal(got["Jonas"], 140, "Jonas")
    assert_equal(got["Keddo"], 140, "Keddo")
end)

test("divide_among_players splits instead of mirroring", function()
    local state = fake.reset({ "Jonas", "Keddo", "HenBot" })
    local pool = load_pool({ divide_among_players = true })

    pool.tick()
    state.players[1]._exp = state.players[1]._exp + 100
    pool.tick()

    local got = exp_by_name(state)
    -- floor(100/3) = 33 each, so the group gains 66 on top of the earner's
    -- 100 rather than 200.
    assert_equal(got["Keddo"], 33, "Keddo")
    assert_equal(got["HenBot"], 33, "HenBot")
end)

test("a solo player shares with nobody", function()
    local state = fake.reset({ "Jonas" })
    local pool = load_pool()

    pool.tick()
    state.players[1]._exp = state.players[1]._exp + 100
    pool.tick()

    assert_equal(#state.grants, 0, "grant count")
end)

test("someone joining later gets a baseline, not a windfall", function()
    local state = fake.reset({ "Jonas" })
    local pool = load_pool()

    pool.tick()
    state.players[1]._exp = state.players[1]._exp + 100
    pool.tick()

    -- Keddo arrives already carrying XP from elsewhere.
    local keddo = fake.add_player("Keddo", 9999, 20)
    pool.tick()
    assert_equal(#state.grants, 0, "nothing shared on the tick they appear")

    state.players[1]._exp = state.players[1]._exp + 50
    pool.tick()
    assert_equal(keddo._exp, 10049, "Keddo receives only what was earned after they joined")
end)

test("share_rate = 0 turns sharing off", function()
    local state = fake.reset({ "Jonas", "Keddo" })
    local pool = load_pool({ share_rate = 0 })

    pool.tick()
    state.players[1]._exp = state.players[1]._exp + 100
    pool.tick()

    assert_equal(#state.grants, 0, "grant count")
end)

test("xp is found through a fall-back accessor", function()
    -- The fake only implements the second of the four ways to reach a
    -- character's parameter, so this passing means the chain works.
    local state = fake.reset({ "Jonas", "Keddo" })
    load_pool()
    local players = require("players")

    assert_equal(players.exp(state.players[1]), 0, "xp readable")
    assert_equal(players.access_path(),
        "character:GetCharacterParameterComponent():GetIndividualParameter()",
        "accessor in use")
end)

test("a player whose xp cannot be read is skipped, not crashed on", function()
    local state = fake.reset({ "Jonas", "Keddo" })
    local pool = load_pool()
    pool.tick()

    state.players[2].GetCharacterParameterComponent = function() error("gone") end
    state.players[1]._exp = state.players[1]._exp + 100

    pool.tick()  -- must not raise
    assert_equal(state.players[2]._exp, 100, "the unreadable player is still paid")
end)

test("players are tracked by identity, not by list position", function()
    local state = fake.reset({ "Jonas", "Keddo" })
    local pool = load_pool()
    pool.tick()

    state.players[1], state.players[2] = state.players[2], state.players[1]
    state.players[1]._index, state.players[2]._index = 1, 2

    state.players[1]._exp = state.players[1]._exp + 100
    pool.tick()

    local got = exp_by_name(state)
    assert_equal(got["Jonas"], 100, "Jonas")
    assert_equal(got["Keddo"], 100, "Keddo")
end)

test("reading never touches PalUtility", function()
    -- The crash that killed run two came from enumerating through PalUtility:
    -- a CDO call taking FindFirstOf("World") and returning an array of FText.
    -- Nothing on the read path may go near it again. Paying out still may, and
    -- that is deliberately a separate call behind a separate key.
    local state = fake.reset({ "Jonas", "Keddo" })
    local pool = load_pool()
    local players = require("players")

    local reached = false
    local guarded = _G.StaticFindObject
    _G.StaticFindObject = function(path)
        reached = true
        error("StaticFindObject must not be called while reading: " .. tostring(path))
    end

    pool.tick()
    players.connected()
    players.exp(state.players[1])
    players.name(state.players[1])
    players.key(state.players[1])

    _G.StaticFindObject = guarded
    assert_equal(reached, false, "PalUtility was left alone")
end)

test("main binds both probe keys", function()
    -- This is here because F8 once did nothing at all in game: an edit to
    -- main.lua silently failed to apply, the key was never registered, and an
    -- unbound key looks exactly like a working key whose handler does nothing.
    -- Loading main.lua for real is the only way to catch that.
    local state = fake.reset({ "Jonas" })
    package.loaded["probe"] = nil
    package.loaded["players"] = nil
    package.loaded["config"] = nil
    package.loaded["UEHelpers"] = nil

    dofile("mod/SharedXPPool/Scripts/main.lua")

    assert_equal(type(state.keybinds[7]), "function", "F7 bound")
    assert_equal(type(state.keybinds[8]), "function", "F8 bound")

    -- And pressing them must not raise out of the handler.
    state.keybinds[7]()
    state.keybinds[8]()
end)

real_print(string.format("\n%d passed, %d failed", passed, failed))
os.exit(failed == 0 and 0 or 1)
