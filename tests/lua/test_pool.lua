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

    assert_equal(#state.grants, 0, "grant count")
    assert_equal(state.players[2]._exp, 0, "Keddo untouched")
end)

test("a player who earned nothing is topped up to the one who did", function()
    local state = fake.reset({ "Jonas", "Keddo", "HenBot" })
    local pool = load_pool()

    pool.tick()
    state.players[1]._exp = state.players[1]._exp + 100
    pool.tick()

    local got = exp_by_name(state)
    assert_equal(got["Keddo"], 100, "Keddo")
    assert_equal(got["HenBot"], 100, "HenBot")
    assert_equal(got["Jonas"], 100, "the earner gains only what they earned")
end)

test("players the game already paid are not paid again", function()
    -- This is the bug that made the first live run loop. Palworld gives full XP
    -- to players standing near each other, so both rise on their own. Treating
    -- the second player's rise as something to match would double every kill,
    -- and paying them would raise the first player again, and so on forever.
    local state = fake.reset({ "Jonas", "Keddo" })
    local pool = load_pool()

    pool.tick()
    state.players[1]._exp = state.players[1]._exp + 10
    state.players[2]._exp = state.players[2]._exp + 10
    pool.tick()

    assert_equal(#state.grants, 0, "nothing to do -- the game already shared it")
    local got = exp_by_name(state)
    assert_equal(got["Jonas"], 10, "Jonas")
    assert_equal(got["Keddo"], 10, "Keddo")
end)

test("a payout that leaks onto the earner does not start a loop", function()
    -- In game, paying one player raised the other too. The mod cannot control
    -- where the game's exp call lands, so it must be safe when a payout lands
    -- everywhere. What it must never do is keep paying forever.
    local state = fake.reset({ "Jonas", "Keddo" })
    state.propagate = true
    local pool = load_pool()

    pool.tick()
    state.players[1]._exp = state.players[1]._exp + 100

    pool.tick()
    local after_first = #state.grants

    for _ = 1, 20 do pool.tick() end

    assert_equal(#state.grants, after_first, "no further payouts after it settled")

    local settled = exp_by_name(state)
    for _ = 1, 5 do pool.tick() end
    local still = exp_by_name(state)
    assert_equal(still["Jonas"], settled["Jonas"], "Jonas stopped moving")
    assert_equal(still["Keddo"], settled["Keddo"], "Keddo stopped moving")
end)

test("a single earning settles after one payout and stays settled", function()
    -- Without absorbing our own payout into the baseline, the next tick reads
    -- it as the recipient earning, which makes the original earner the one who
    -- is behind -- and the two of them trade payments back and forth, growing
    -- each time. No propagation needed for that; it is purely our own
    -- accounting.
    local state = fake.reset({ "Jonas", "Keddo" })
    local pool = load_pool()

    pool.tick()
    state.players[1]._exp = state.players[1]._exp + 100
    pool.tick()

    assert_equal(#state.grants, 1, "one payout")

    for _ = 1, 20 do pool.tick() end

    assert_equal(#state.grants, 1, "and no more, ever")
    local got = exp_by_name(state)
    assert_equal(got["Jonas"], 100, "Jonas")
    assert_equal(got["Keddo"], 100, "Keddo")
end)

test("an idle world pays nobody", function()
    local state = fake.reset({ "Jonas", "Keddo" })
    state.propagate = true
    local pool = load_pool()

    for _ = 1, 30 do pool.tick() end

    assert_equal(#state.grants, 0, "grant count")
end)

test("the biggest earner sets the target, not the sum", function()
    local state = fake.reset({ "Jonas", "Keddo", "HenBot" })
    local pool = load_pool()

    pool.tick()
    state.players[1]._exp = state.players[1]._exp + 100
    state.players[2]._exp = state.players[2]._exp + 40
    pool.tick()

    local got = exp_by_name(state)
    -- Everyone ends the tick up by 100, the best rise. Summing would have made
    -- it 140 each and inflated a shared kill.
    assert_equal(got["Jonas"], 100, "Jonas")
    assert_equal(got["Keddo"], 100, "Keddo")
    assert_equal(got["HenBot"], 100, "HenBot")
end)

test("divide_among_players targets the average instead", function()
    local state = fake.reset({ "Jonas", "Keddo", "HenBot" })
    local pool = load_pool({ divide_among_players = true })

    pool.tick()
    state.players[1]._exp = state.players[1]._exp + 90
    pool.tick()

    local got = exp_by_name(state)
    -- floor(90/3) = 30 each for the two who earned nothing; the earner keeps
    -- their 90 rather than being pulled down to it.
    assert_equal(got["Jonas"], 90, "Jonas")
    assert_equal(got["Keddo"], 30, "Keddo")
    assert_equal(got["HenBot"], 30, "HenBot")
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

    local keddo = fake.add_player("Keddo", 9999, 20)
    pool.tick()
    assert_equal(#state.grants, 0, "nothing paid on the tick they appear")

    state.players[1]._exp = state.players[1]._exp + 50
    pool.tick()
    assert_equal(keddo._exp, 10049, "only what was earned after they joined")
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
    -- character's parameter -- which is the one the real game used too.
    local state = fake.reset({ "Jonas", "Keddo" })
    load_pool()
    local players = require("players")

    assert_equal(players.exp(state.players[1]), 0, "xp readable")
    assert_equal(players.access_path(),
        "character:GetCharacterParameterComponent():GetIndividualParameter()",
        "accessor in use")
end)

test("a player whose xp cannot be read is skipped, not guessed at", function()
    -- Deliberately not paid. Without a reading there is no way to know what
    -- they already gained, so any payment is a guess -- and guessing high is
    -- what turned the first live run into a loop. Falling behind is
    -- recoverable; the save editor tops them up between sessions.
    local state = fake.reset({ "Jonas", "Keddo", "HenBot" })
    local pool = load_pool()
    pool.tick()

    state.players[2].GetCharacterParameterComponent = function() error("gone") end
    state.players[1]._exp = state.players[1]._exp + 100

    pool.tick()  -- must not raise

    assert_equal(state.players[2]._exp, 0, "the unreadable player is left alone")
    assert_equal(state.players[3]._exp, 100, "everyone else is still topped up")

    local warned = false
    for _, line in ipairs(state.output) do
        if line:find("unreadable") then warned = true end
    end
    assert_equal(warned, true, "and it says so rather than failing silently")
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
    package.loaded["pool"] = nil
    package.loaded["UEHelpers"] = nil

    dofile("mod/SharedXPPool/Scripts/main.lua")

    assert_equal(type(state.keybinds[7]), "function", "F7 bound")
    assert_equal(type(state.keybinds[8]), "function", "F8 bound")

    state.keybinds[7]()
    state.keybinds[8]()
end)

real_print(string.format("\n%d passed, %d failed", passed, failed))
os.exit(failed == 0 and 0 or 1)
