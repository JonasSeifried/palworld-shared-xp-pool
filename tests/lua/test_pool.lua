-- Run: lua tests/lua/test_pool.lua   (from the repo root)

package.path = "tests/lua/?.lua;mod/SharedXPPool/Scripts/?.lua;" .. package.path

local fake = require("fake_ue4ss")
local real_print = print

local SOURCE = "/Script/Pal.PalExpDatabase:AddExpValue_forPlayerParty_Server"

local passed, failed = 0, 0

-- Load pool.lua fresh each time so config changes take effect and the module's
-- dedup timestamps do not leak between cases.
local function load_pool(overrides)
    package.loaded["pool"] = nil
    package.loaded["players"] = nil
    package.loaded["config"] = nil

    local config = require("config")
    for k, v in pairs(overrides or {}) do config[k] = v end
    config.verbose = false

    local pool = require("pool")
    pool.start()
    return pool
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

local function grants_by_name(state)
    local out = {}
    for _, g in ipairs(state.grants) do
        out[g.character._name] = (out[g.character._name] or 0) + g.amount
    end
    return out
end

local function assert_equal(actual, expected, what)
    if actual ~= expected then
        error(string.format("%s: expected %s, got %s",
            what, tostring(expected), tostring(actual)), 2)
    end
end

real_print("shared xp pool -- live mod")

test("an earner's xp is mirrored to everyone else at full value", function()
    local state = fake.reset({ "Jonas", "Keddo", "HenBot" })
    load_pool()

    fake.fire(SOURCE, state.players[1], 100)

    local got = grants_by_name(state)
    assert_equal(#state.grants, 2, "grant count")
    assert_equal(got["Keddo"], 100, "Keddo")
    assert_equal(got["HenBot"], 100, "HenBot")
    assert_equal(got["Jonas"], nil, "the earner is not paid twice")
end)

test("divide_among_players splits instead of mirroring", function()
    local state = fake.reset({ "Jonas", "Keddo", "HenBot" })
    load_pool({ divide_among_players = true })

    fake.fire(SOURCE, state.players[1], 100)

    local got = grants_by_name(state)
    -- floor(100/3) = 33, so the group gains 66 on top of the earner's own 100
    -- rather than 200.
    assert_equal(got["Keddo"], 33, "Keddo")
    assert_equal(got["HenBot"], 33, "HenBot")
end)

test("a solo player shares with nobody", function()
    local state = fake.reset({ "Jonas" })
    load_pool()

    fake.fire(SOURCE, state.players[1], 100)

    assert_equal(#state.grants, 0, "grant count")
end)

test("the same amount twice in an instant counts once", function()
    local state = fake.reset({ "Jonas", "Keddo" })
    load_pool()

    fake.fire(SOURCE, state.players[1], 100)
    fake.fire(SOURCE, state.players[1], 100)

    assert_equal(#state.grants, 1, "grant count")
end)

test("different amounts in an instant both count", function()
    local state = fake.reset({ "Jonas", "Keddo" })
    load_pool()

    fake.fire(SOURCE, state.players[1], 100)
    fake.fire(SOURCE, state.players[1], 250)

    assert_equal(#state.grants, 2, "grant count")
end)

test("our own grants do not feed back into the hook", function()
    local state = fake.reset({ "Jonas", "Keddo", "HenBot" })
    load_pool()

    -- Every payout now re-enters the hook, which is what happens if the game's
    -- own exp call routes back through the server function we hooked. Without
    -- the guard this does not terminate.
    state.reentrant = true

    fake.fire(SOURCE, state.players[1], 100)

    assert_equal(#state.grants, 2, "only the outer event paid out")
end)

test("argument order does not matter", function()
    local state = fake.reset({ "Jonas", "Keddo" })
    load_pool()

    -- Amount first, earner second -- the reverse of what we expect.
    fake.fire(SOURCE, 100, state.players[1])

    local got = grants_by_name(state)
    assert_equal(got["Keddo"], 100, "Keddo")
    assert_equal(got["Jonas"], nil, "the earner is still recognised")
end)

test("extra arguments are ignored", function()
    local state = fake.reset({ "Jonas", "Keddo" })
    load_pool()

    fake.fire(SOURCE, state.players[1], 100, true, "Craft")

    assert_equal(#state.grants, 1, "grant count")
    assert_equal(state.grants[1].amount, 100, "amount")
end)

test("a hook with no amount in it is reported, not silently dropped", function()
    local state = fake.reset({ "Jonas", "Keddo" })
    load_pool()

    fake.fire(SOURCE, state.players[1], true)

    assert_equal(#state.grants, 0, "grant count")
    local complained = false
    for _, line in ipairs(state.output) do
        if line:find("no amount found") then complained = true end
    end
    assert_equal(complained, true, "the log explains why nothing happened")
end)

test("share_rate = 0 turns sharing off", function()
    local state = fake.reset({ "Jonas", "Keddo" })
    load_pool({ share_rate = 0 })

    fake.fire(SOURCE, state.players[1], 100)

    assert_equal(#state.grants, 0, "grant count")
end)

real_print(string.format("\n%d passed, %d failed", passed, failed))
os.exit(failed == 0 and 0 or 1)
