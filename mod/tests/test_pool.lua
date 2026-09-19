-- Run: lua mod/tests/test_pool.lua   (from the repo root)

package.path = "mod/tests/?.lua;mod/SharedXPPool/Scripts/?.lua;" .. package.path

local fake = require("fake_ue4ss")
local real_print = print

local passed, failed = 0, 0

local MODULES = { "probe", "players", "config", "pool", "UEHelpers" }

local function forget()
    for _, name in ipairs(MODULES) do package.loaded[name] = nil end
end

local function load_pool(overrides)
    forget()
    local config = require("config")
    for k, v in pairs(overrides or {}) do config[k] = v end
    config.verbose = false
    return require("pool")
end

-- main.lua decides what to bind from the config, so the key tests have to load
-- it for real rather than reach into it. Requiring config first and editing it
-- means main's own require finds the edited one.
local function load_main(overrides)
    forget()
    local config = require("config")
    for k, v in pairs(overrides or {}) do config[k] = v end
    dofile("mod/SharedXPPool/Scripts/main.lua")
    return config
end

local function said(state, text)
    for _, line in ipairs(state.output) do
        if line:find(text, 1, true) then return true end
    end
    return false
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

local function totals(state)
    local out = {}
    for _, p in ipairs(state.players) do out[p._name] = p._exp end
    return out
end

local function spread(state)
    local low, high
    for _, p in ipairs(state.players) do
        if not low or p._exp < low then low = p._exp end
        if not high or p._exp > high then high = p._exp end
    end
    return high - low
end

-- Two ticks of nothing happening: the first sighting of each player, then a
-- tick where they are trusted. Most tests want to start from there.
local function settle(pool)
    pool.tick()
    pool.tick()
end

real_print("shared xp pool -- live mod")

-- ---------------------------------------------------------------- the rule

test("everybody is brought up to the highest total", function()
    local state = fake.reset({ "P1", "P2", "P3" })
    state.players[1]._exp, state.players[2]._exp, state.players[3]._exp = 0, 500, 1000
    local pool = load_pool({ catch_up_rate = 1.0 })

    pool.tick()   -- first sighting, nobody trusted yet
    assert_equal(#state.grants, 0, "nothing on the tick they are first seen")

    pool.tick()

    local got = totals(state)
    assert_equal(got["P1"], 1000, "P1")
    assert_equal(got["P2"], 1000, "P2")
    assert_equal(got["P3"], 1000, "the one in front is untouched")
end)

test("a world where everybody is level pays nothing", function()
    local state = fake.reset({ "P1", "P2" })
    state.players[1]._exp, state.players[2]._exp = 1000, 1000
    local pool = load_pool()

    for _ = 1, 30 do pool.tick() end

    assert_equal(#state.grants, 0, "grant count")
end)

test("it settles after one gap and stays settled", function()
    -- The property that makes the rule safe to leave running: it is a fixed
    -- point, so a tick with nothing to do genuinely does nothing.
    local state = fake.reset({ "P1", "P2" })
    state.players[2]._exp = 1000
    local pool = load_pool({ catch_up_rate = 1.0 })
    settle(pool)

    assert_equal(spread(state), 0, "levelled")
    local after_settling = #state.grants

    for _ = 1, 50 do pool.tick() end
    assert_equal(#state.grants, after_settling, "and no further payouts, ever")
end)

test("nobody is ever lowered", function()
    local state = fake.reset({ "Ahead", "Behind" })
    state.players[1]._exp, state.players[2]._exp = 9999, 0
    local pool = load_pool({ catch_up_rate = 1.0 })
    settle(pool)

    assert_equal(state.players[1]._exp, 9999, "the leader keeps what they had")
    assert_equal(state.players[2]._exp, 9999, "and the other is brought to it")
end)

test("a solo player is left alone", function()
    local state = fake.reset({ "P1" })
    local pool = load_pool({ catch_up_rate = 1.0 })

    state.players[1]._exp = 500
    for _ = 1, 10 do pool.tick() end

    assert_equal(#state.grants, 0, "grant count")
    assert_equal(state.players[1]._exp, 500, "untouched")
end)

test("earning while level with everyone pulls the others along", function()
    -- The ordinary case in a session: two people together, one kills something,
    -- the other is brought up to them on the next tick.
    local state = fake.reset({ "P1", "P2" })
    local pool = load_pool({ catch_up_rate = 1.0 })
    settle(pool)

    state.players[1]._exp = state.players[1]._exp + 120
    pool.tick()

    assert_equal(state.players[2]._exp, 120, "P2 caught up")
    assert_equal(state.players[1]._exp, 120, "P1 gained only what they earned")
end)

-- ------------------------------------------------------------ catch_up_rate

test("catch_up_rate closes a fraction of the gap and lands exactly", function()
    local state = fake.reset({ "Behind", "Ahead" })
    state.players[2]._exp = 1000
    local pool = load_pool({ catch_up_rate = 0.25 })
    settle(pool)

    -- A quarter of 1000 on the first paying tick.
    assert_equal(state.players[1]._exp, 250, "a quarter of the gap")

    -- The last few points would round to zero, so the floor of 1 is what makes
    -- it converge rather than creep.
    for _ = 1, 200 do pool.tick() end
    assert_equal(state.players[1]._exp, 1000, "lands exactly on the top")
end)

test("a catch_up_rate above 1 cannot overshoot the top", function()
    -- Nothing stops somebody typing 2.0 in the config. Overshooting would put
    -- the player who was behind in front, and then everybody chases them.
    local state = fake.reset({ "Behind", "Ahead" })
    state.players[2]._exp = 1000
    local pool = load_pool({ catch_up_rate = 2.0 })
    settle(pool)

    assert_equal(state.players[1]._exp, 1000, "levelled, not overshot")
    assert_equal(state.players[2]._exp, 1000, "and the top did not move")
end)

test("catch_up_rate = 0 turns sharing off", function()
    local state = fake.reset({ "P1", "P2" })
    state.players[2]._exp = 1000
    local pool = load_pool({ catch_up_rate = 0 })

    for _ = 1, 10 do pool.tick() end

    assert_equal(#state.grants, 0, "grant count")
    assert_equal(state.players[1]._exp, 0, "untouched")
end)

test("a huge gap closes in a sensible number of ticks", function()
    -- Joining a world two million XP ahead. At a quarter of the gap a second
    -- this should be over in well under a minute, not a slow crawl.
    local state = fake.reset({ "Newcomer", "Veteran" })
    state.players[2]._exp = 2000000
    local pool = load_pool({ catch_up_rate = 0.25 })
    settle(pool)

    for _ = 1, 58 do pool.tick() end
    assert_equal(spread(state), 0, "level within a minute of ticks")
end)

-- --------------------------------------------------------------- the guards

test("a player is not paid on the first tick they are seen", function()
    -- A reading taken before a player's save data has settled would look like
    -- somebody who needs the entire pool.
    local state = fake.reset({ "P1" })
    state.players[1]._exp = 5000
    local pool = load_pool({ catch_up_rate = 1.0 })
    settle(pool)

    local joiner = fake.add_player("Joiner", 0, 1)
    pool.tick()
    assert_equal(joiner._exp, 0, "nothing on the tick they appear")

    pool.tick()
    assert_equal(joiner._exp, 5000, "brought up on the next one")
end)

test("a player seen for the first time does not set the top either", function()
    -- Stronger than "is not paid yet": an unconfirmed reading must not drag
    -- everybody else up to it. Somebody joining a world reads before their save
    -- has necessarily settled, and the whole world follows the highest number.
    local state = fake.reset({ "P1", "P2" })
    state.players[1]._exp, state.players[2]._exp = 1000, 1000
    local pool = load_pool({ catch_up_rate = 1.0 })
    settle(pool)

    fake.add_player("Joiner", 50000, 20)
    pool.tick()

    assert_equal(state.players[1]._exp, 1000, "P1 was not pulled up by an unconfirmed reading")
    assert_equal(state.players[2]._exp, 1000, "nor P2")

    pool.tick()
    assert_equal(state.players[1]._exp, 50000, "and follows it once it is confirmed")
end)

test("a reading that goes backwards is ignored", function()
    -- XP does not decrease in Palworld, so a smaller number is a bad read --
    -- and under this rule a bad low read looks like somebody owed everything.
    local state = fake.reset({ "P1", "P2" })
    state.players[1]._exp, state.players[2]._exp = 1000, 1000
    local pool = load_pool({ catch_up_rate = 1.0 })
    settle(pool)

    state.players[1]._exp = 5          -- the bad reading
    pool.tick()

    assert_equal(#state.grants, 0, "nobody was paid on it")
    assert_equal(said(state, "XP does not go down"), true, "and it said so")
end)

test("a bad reading is still refused the second time it is read", function()
    -- The dangerous shape is a bad reading that persists for more than one
    -- tick -- a pawn reading 0 while its save data is still being applied. If
    -- refusing it also lowered the baseline, the same 0 would be trusted one
    -- tick later and the player paid the whole pool on top of what they have.
    local state = fake.reset({ "P1", "P2" })
    state.players[1]._exp, state.players[2]._exp = 1000, 1000
    local pool = load_pool({ catch_up_rate = 1.0 })
    settle(pool)

    state.players[1]._exp = 5
    pool.tick()
    pool.tick()

    assert_equal(#state.grants, 0, "not on the first bad reading, and not on the second")
    assert_equal(state.players[1]._exp, 5, "so no XP was invented")
end)

test("a refusal that will not go away says what to do about it", function()
    local state = fake.reset({ "P1", "P2" })
    state.players[1]._exp, state.players[2]._exp = 1000, 1000
    local pool = load_pool({ catch_up_rate = 1.0 })
    settle(pool)

    state.players[1]._exp = 5
    for _ = 1, 6 do pool.tick() end

    assert_equal(#state.grants, 0, "still nobody paid")
    assert_equal(said(state, "restart it"), true, "and the log says how to clear it")
end)

test("a reading past anything the game can produce is refused", function()
    -- The low guard has always been there; this is the other half. A bogus
    -- high reading is the worse one, because it becomes the top, everybody is
    -- paid up to it, and by the next tick that invented XP is real.
    local state = fake.reset({ "P1", "P2" })
    state.players[1]._exp, state.players[2]._exp = 1000, 1000
    local pool = load_pool({ catch_up_rate = 1.0 })
    settle(pool)

    state.players[2]._exp = 18446744073709551615    -- a signed Int64 read as unsigned
    pool.tick()

    assert_equal(state.players[1]._exp, 1000, "nobody chased it")
    assert_equal(said(state, "past anything the game can produce"), true, "and it said so")
end)

test("a payout that cannot be read back does not switch sharing off", function()
    -- One unreadable instant right after the session's first payout -- a
    -- level-up, a respawn -- used to latch the precise route off for the whole
    -- session and blame the build for it, while the XP it had just paid sat in
    -- the player's total.
    local state = fake.reset({ "P1", "P2" })
    state.players[1]._exp, state.players[2]._exp = 1000, 1000
    local pool = load_pool({ catch_up_rate = 0.25 })
    settle(pool)

    state.players[2]._exp = 101000
    local p1, fired = state.players[1], false
    p1.IsValid = function()
        if #state.grants > 0 and not fired then fired = true return false end
        return true
    end
    pool.tick()
    p1.IsValid = function() return true end

    assert_equal(said(state, "does not work on this build"), false, "the build was not blamed")
    for _ = 1, 60 do pool.tick() end
    assert_equal(state.players[1]._exp, 101000, "and sharing carried on to the top")
end)

-- A route that worked and then stopped moving XP: a recipient the game will
-- not take past the level cap, or a patched-out function. players.grant checks
-- the first payout of a session and no others, so these start from a payout
-- that did land -- which is exactly the session where nothing is watching.
local function stalled(rate)
    local state = fake.reset({ "P1", "P2" })
    state.players[2]._exp = 1000
    local pool = load_pool({ catch_up_rate = rate })
    settle(pool)
    pool.tick()                 -- one real payout, verified, route known good
    state.grants_land = false
    return state, pool, #state.grants
end

test("paying somebody whose total never moves stops", function()
    local state, pool, before = stalled(0.25)

    for _ = 1, 20 do pool.tick() end

    assert_equal(#state.grants - before <= 4, true,
        "it gave up after a few rather than paying every tick forever ("
        .. (#state.grants - before) .. ")")
    assert_equal(said(state, "not paying them again until it does"), true, "and said so")
end)

test("a payout landing again clears the giving-up", function()
    local state, pool = stalled(0.25)
    for _ = 1, 10 do pool.tick() end

    state.grants_land = true
    state.players[1]._exp = state.players[1]._exp + 1   -- they earn a little on their own
    for _ = 1, 60 do pool.tick() end

    assert_equal(state.players[1]._exp, 1000, "paying resumed once the total moved")
end)

test("loading a different world forgets the old baselines", function()
    -- The Lua state outlives a loaded world. Going to the menu and loading
    -- another save leaves every baseline describing somewhere else, and the
    -- same players legitimately back at lower totals -- which the rule above
    -- would otherwise refuse for the rest of the session.
    local state = fake.reset({ "P1", "P2" })
    state.players[1]._exp, state.players[2]._exp = 500000, 500000
    local pool = load_pool({ catch_up_rate = 1.0 })
    settle(pool)

    state.world_id = 0x9001
    state.players[1]._exp, state.players[2]._exp = 100, 900
    settle(pool)

    assert_equal(said(state, "a different world is loaded"), true, "the swap was noticed")
    assert_equal(state.players[1]._exp, 900, "and the new world's own top is shared")
end)

test("a player who cannot be read is skipped, not guessed at", function()
    local state = fake.reset({ "P1", "P2", "P3" })
    state.players[3]._exp = 800
    local pool = load_pool({ catch_up_rate = 1.0 })
    settle(pool)

    state.players[2].GetCharacterParameterComponent = function() error("gone") end
    state.players[3]._exp = 1600
    pool.tick()

    assert_equal(state.players[1]._exp, 1600, "everyone readable is still levelled")
    assert_equal(said(state, "unreadable"), true, "and it says so")
end)

test("an unreadable player does not set the top", function()
    local state = fake.reset({ "P1", "P2" })
    state.players[1]._exp, state.players[2]._exp = 100, 999999
    local pool = load_pool({ catch_up_rate = 1.0 })
    pool.tick()

    state.players[2].GetCharacterParameterComponent = function() error("gone") end
    pool.tick()

    assert_equal(state.players[1]._exp, 100, "nothing was paid toward a total we cannot see")
end)

test("nothing is shared if the precise payout does not work", function()
    -- A payout that reaches bystanders moves the top every time it is
    -- approached. There is no safe fallback, so the honest move is to stop.
    local state = fake.reset({ "P1", "P2" })
    state.players[2]._exp = 1000
    state.precise_available = false
    local pool = load_pool({ catch_up_rate = 1.0 })

    for _ = 1, 10 do pool.tick() end

    assert_equal(state.players[1]._exp, 0, "nobody was paid")
    assert_equal(state.sphere_calls, 0, "and the leaky call was not reached for")
    assert_equal(said(state, "no safe fallback"), true, "the route failure is reported")
    assert_equal(said(state, "nothing will be shared"), true, "and so is the consequence")
end)

test("payouts name their recipient instead of using a sphere", function()
    local state = fake.reset({ "P1", "P2" })
    state.players[2]._exp = 1000
    local pool = load_pool({ catch_up_rate = 1.0 })
    settle(pool)

    assert_equal(state.sphere_calls, 0, "the radius call was not used")
    assert_equal(state.players[1]._exp, 1000, "P1 was paid")
end)

test("reading never touches PalUtility", function()
    -- The crash that killed the second probe run came from enumerating through
    -- PalUtility: a CDO call taking FindFirstOf("World") and returning an array
    -- of FText. Nothing on the read path may go near it again.
    local state = fake.reset({ "P1", "P2" })
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

test("players are tracked by identity, not by list position", function()
    -- Enumeration order is not promised to be stable. Keyed by position, the
    -- swap below would read slot two as having dropped from 1000 to 0, call it
    -- a bad reading, and never pay P1 anything.
    local state = fake.reset({ "P1", "P2" })
    state.players[2]._exp = 1000
    local pool = load_pool({ catch_up_rate = 1.0 })
    pool.tick()

    state.players[1], state.players[2] = state.players[2], state.players[1]
    pool.tick()

    local got = totals(state)
    assert_equal(got["P1"], 1000, "P1 was still recognised, and paid")
    assert_equal(got["P2"], 1000, "P2")
    assert_equal(said(state, "XP does not go down"), false,
        "and the reorder was not mistaken for a reading going backwards")
end)

-- ------------------------------------------------------------------ reading

test("xp is found through a fall-back accessor", function()
    -- The fake implements only the second of the four ways to reach a
    -- character's parameter, which is the one the real game used too.
    local state = fake.reset({ "P1", "P2" })
    load_pool()
    local players = require("players")

    assert_equal(players.exp(state.players[1]), 0, "xp readable")
    assert_equal(players.access_path(),
        "character:GetCharacterParameterComponent():GetIndividualParameter()",
        "accessor in use")
end)

test("player keys use the same form as the save files", function()
    -- The UId words come back signed, and "%08X" widens a negative one to
    -- sixteen digits: Keddo's key logged as FFFFFFFFD0686E06 where his save
    -- file is named D0686E06.
    local state = fake.reset({ "Keddo" })
    load_pool()
    local players = require("players")

    state.players[1].GetPlayerState = function()
        return {
            IsValid = function() return true end,
            PlayerNamePrivate = { ToString = function() return "Keddo" end },
            PlayerUId = { A = 0xD0686E06 - 0x100000000, B = 0, C = 0, D = 0 },
        }
    end

    assert_equal(players.key(state.players[1]),
        "D0686E06-00000000-00000000-00000000", "key")
end)

-- -------------------------------------------------------------- pause, watch

test("the pause key stops payouts", function()
    local state = fake.reset({ "P1", "P2" })
    state.players[2]._exp = 1000
    load_main({ catch_up_rate = 1.0 })
    local pool = require("pool")

    state.keybinds[11]()
    assert_equal(pool.is_paused(), true, "paused")

    for _ = 1, 10 do pool.tick() end
    assert_equal(#state.grants, 0, "nobody paid while paused")

    state.keybinds[11]()
    assert_equal(pool.is_paused(), false, "resumed")

    pool.tick()
    assert_equal(state.players[1]._exp, 1000, "and levelling resumes at once")
end)

test("watching still works while sharing is paused", function()
    local state = fake.reset({ "P1", "P2" })
    state.players[1]._exp = 42
    local pool = load_pool({ watch_totals = true })
    pool.set_paused(true)
    pool.tick()

    assert_equal(said(state, "P1 42"), true, "totals reported")
    assert_equal(#state.grants, 0, "and still paying nobody")
end)

-- --------------------------------------------------------------------- keys

test("a live session binds nothing that injects xp", function()
    -- F6 and F8 pay out and F9 walks reflected function parameters, which is
    -- what hard-crashed the game twice during discovery.
    local state = fake.reset({ "P1", "P2" })
    load_main()

    assert_equal(state.keybinds[6], nil, "F6 unbound")
    assert_equal(state.keybinds[7], nil, "F7 unbound")
    assert_equal(state.keybinds[8], nil, "F8 unbound")
    assert_equal(state.keybinds[9], nil, "F9 unbound")
    assert_equal(type(state.keybinds[11]), "function", "the pause key is bound")
end)

test("a live session does not even load the debug code", function()
    -- probe.lua is a third of the mod and none of it runs unless a key is
    -- bound to it. Loading it anyway is a third of the parse cost for nothing.
    fake.reset({ "P1", "P2" })
    load_main()
    assert_equal(package.loaded["probe"], nil, "probe was never required")

    load_main({ debug_keys = true })
    assert_equal(type(package.loaded["probe"]), "table", "and is there when asked for")
end)

test("discovery mode arms the probe keys without being asked", function()
    local state = fake.reset({ "P1" })
    load_main({ probe_only = true, debug_keys = false })

    assert_equal(type(state.keybinds[7]), "function", "F7 bound")
    assert_equal(state.keybinds[11], nil, "and nothing to pause, so no pause key")
end)

test("discovery mode does not claim the debug keys are off", function()
    -- The point of the ready line is to report what actually got bound rather
    -- than what was meant to be, and it listed four XP-injecting keys followed
    -- by "(debug keys off)".
    local state = fake.reset({ "P1" })
    load_main({ probe_only = true, debug_keys = false })

    assert_equal(said(state, "debug keys off"), false,
        "not while F6 and F8 are bound and pay players")
end)

test("main binds every probe key", function()
    -- This is here because F8 once did nothing at all in game: an edit to
    -- main.lua silently failed to apply, the key was never registered, and an
    -- unbound key looks exactly like a working key whose handler does nothing.
    local state = fake.reset({ "P1", "P2" })
    load_main({ debug_keys = true })

    assert_equal(type(state.keybinds[6]), "function", "F6 bound")
    assert_equal(type(state.keybinds[7]), "function", "F7 bound")
    assert_equal(type(state.keybinds[8]), "function", "F8 bound")
    assert_equal(type(state.keybinds[9]), "function", "F9 bound")

    state.keybinds[6]()
    state.keybinds[7]()
    state.keybinds[8]()
    state.keybinds[9]()
    fake.run_delayed()

    -- Every handler is wrapped so a fault cannot take the game down, which also
    -- means a broken one looks like a working one from in game. F8 once died on
    -- a "%+s" format halfway through, after the payout had already happened,
    -- and a test like this passed anyway. So check the log, not just that
    -- nothing raised.
    for _, line in ipairs(state.output) do
        if line:find("failed:") then error("a key handler faulted: " .. line, 2) end
    end
end)

test("the shipped config arms nothing that changes a world on its own", function()
    -- Every one of these has been left switched on after a testing session at
    -- least once, and two of them shipped that way. A config is easy to edit
    -- and easy to forget, so the defaults get their own test rather than
    -- relying on whoever ran the tests last having tidied up.
    fake.reset({})
    package.loaded["config"] = nil
    local config = require("config")

    assert_equal(config.debug_keys, false, "debug_keys")
    assert_equal(config.watch_totals, false, "watch_totals")
    assert_equal(config.probe_only, false, "probe_only")
    assert_equal(config.test_grant_amount, 1, "test_grant_amount")
end)

-- -------------------------------------------------------------------- probe

test("reading a parameter never uses the wrong accessor for its kind", function()
    -- F9 killed the game outright by asking every parameter for GetInner,
    -- GetPropertyClass and GetStruct. Those read a field that only exists on
    -- their own property type; anywhere else they read a wrong offset and the
    -- process dies. pcall does not catch that, so the code has to check the
    -- kind first.
    local state = fake.reset({ "P1" })
    forget()

    require("probe").dump_exp_api()

    assert_equal(state.unsafe_property_access, false, "accessor use")

    local found = false
    for _, line in ipairs(state.output) do
        if line:find("PalPlayerCharacter") then found = true end
    end
    assert_equal(found, true, "the array's element class was reported")
end)

test("no format string uses a numeric flag on %s", function()
    -- "%+s" raised in game and silently returned "1" here: Lua tightened format
    -- validation after 5.4.2, and UE4SS ships a newer one than this suite runs
    -- on. So the running test could not catch it and a static check has to.
    -- Only "-" and a width are legal on %s and %q.
    local files = { "config", "main", "players", "pool", "probe" }

    for _, name in ipairs(files) do
        local path = "mod/SharedXPPool/Scripts/" .. name .. ".lua"
        local handle = assert(io.open(path, "r"))
        local source = handle:read("a")
        handle:close()

        for line in source:gmatch("[^\n]+") do
            -- Skip whole-line comments: the note explaining this rule quotes
            -- the very thing it forbids.
            if not line:match("^%s*%-%-") then
                local bad = line:match("%%[+ #0][-%d%.]*[sq]")
                if bad then
                    error(path .. " uses " .. bad .. ", which raises on UE4SS's Lua"
                        .. " -- in: " .. line:gsub("^%s+", ""), 2)
                end
            end
        end
    end
end)

real_print(string.format("\n%d passed, %d failed", passed, failed))
os.exit(failed == 0 and 0 or 1)
