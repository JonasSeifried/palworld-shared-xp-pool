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

-- main.lua decides what to bind from the config, so the key tests have to load
-- it for real rather than reach into it. Requiring config first and editing it
-- means main's own require finds the edited one.
local function load_main(overrides)
    for _, name in ipairs({ "probe", "players", "config", "pool", "UEHelpers" }) do
        package.loaded[name] = nil
    end

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

    -- Keddo is 9,800 ahead, so catching up pays him nothing and hands the whole
    -- budget to Jonas. What matters here is its size: 50, Keddo's shortfall
    -- against the rise, and nothing resembling Keddo's 9,999.
    assert_equal(keddo._exp, 9999, "the player in front is not paid")
    assert_equal(state.players[1]._exp, 200, "and the budget came from the 50 earned")
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

test("a live session binds nothing that injects xp", function()
    -- F6 and F8 pay out and F9 walks reflected function parameters, which is
    -- what hard-crashed the game twice during discovery. On the host's keyboard
    -- mid-session a stray function key would be a world event, so the default
    -- config must not leave them armed.
    local state = fake.reset({ "Jonas", "Keddo" })
    load_main()

    assert_equal(state.keybinds[6], nil, "F6 unbound")
    assert_equal(state.keybinds[7], nil, "F7 unbound")
    assert_equal(state.keybinds[8], nil, "F8 unbound")
    assert_equal(state.keybinds[9], nil, "F9 unbound")
    assert_equal(type(state.keybinds[11]), "function", "the pause key is bound")
end)

test("discovery mode arms the probe keys without being asked", function()
    -- It is nothing but those keys; a discovery run with none of them bound
    -- would observe nothing at all.
    local state = fake.reset({ "Jonas" })
    load_main({ probe_only = true, debug_keys = false })

    assert_equal(type(state.keybinds[7]), "function", "F7 bound")
    assert_equal(state.keybinds[11], nil, "and nothing to pause, so no pause key")
end)

test("main binds every probe key", function()
    -- This is here because F8 once did nothing at all in game: an edit to
    -- main.lua silently failed to apply, the key was never registered, and an
    -- unbound key looks exactly like a working key whose handler does nothing.
    -- Loading main.lua for real is the only way to catch that.
    local state = fake.reset({ "Jonas", "Keddo" })
    load_main({ debug_keys = true })

    assert_equal(type(state.keybinds[6]), "function", "F6 bound")
    assert_equal(type(state.keybinds[7]), "function", "F7 bound")
    assert_equal(type(state.keybinds[8]), "function", "F8 bound")
    assert_equal(type(state.keybinds[9]), "function", "F9 bound")

    state.keybinds[6]()
    state.keybinds[7]()
    state.keybinds[8]()
    state.keybinds[9]()

    -- The grant test schedules a second reading for after the pool ticks;
    -- that callback has to survive too.
    fake.run_delayed()

    -- Every handler is wrapped so a fault cannot take the game down, which
    -- also means a broken one looks like a working one from in game. F8 once
    -- died on a "%+s" format halfway through, after the payout had already
    -- happened, and this test passed anyway. So check the log, not just that
    -- nothing raised.
    for _, line in ipairs(state.output) do
        if line:find("failed:") then
            error("a key handler faulted: " .. line, 2)
        end
    end
end)

test("payouts name their recipient instead of using a sphere", function()
    local state = fake.reset({ "Jonas", "Keddo" })
    local pool = load_pool()

    pool.tick()
    state.players[1]._exp = state.players[1]._exp + 100
    pool.tick()

    assert_equal(state.sphere_calls, 0, "the radius call was not used")
    assert_equal(state.players[2]._exp, 100, "Keddo was paid")
end)

test("a named payout does not leak, even where the sphere would", function()
    -- propagate is what the game does to anything landing in a sphere: paying
    -- one player raised the other. Naming recipients removes the sphere, so
    -- there is nothing to forward.
    local state = fake.reset({ "Jonas", "Keddo" })
    state.propagate = true
    local pool = load_pool()

    pool.tick()
    state.players[1]._exp = state.players[1]._exp + 100
    pool.tick()

    local got = exp_by_name(state)
    assert_equal(got["Jonas"], 100, "the payer gained only what they earned")
    assert_equal(got["Keddo"], 100, "and the other exactly matched them")
end)

test("the radius call is used when the named one is unreachable", function()
    local state = fake.reset({ "Jonas", "Keddo" })
    state.precise_available = false
    local pool = load_pool()

    pool.tick()
    state.players[1]._exp = state.players[1]._exp + 100
    pool.tick()

    assert_equal(state.sphere_calls, 1, "fell back to the radius call")
    assert_equal(state.players[2]._exp, 100, "Keddo was still paid")

    local said = false
    for _, line in ipairs(state.output) do
        if line:find("falling back") then said = true end
    end
    assert_equal(said, true, "and it said so")
end)

test("a named payout that silently does nothing falls back", function()
    -- A call that raises is easy to notice. One that quietly succeeds without
    -- moving any XP would leave the pool believing it had paid everyone,
    -- forever, and nobody would ever receive anything.
    local state = fake.reset({ "Jonas", "Keddo" })
    local pool = load_pool()
    local players = require("players")

    local db = FindFirstOf("PalExpDatabase")
    db.AddExpValue_forPlayerParty_Server = function() end  -- accepts, does nothing

    pool.tick()
    state.players[1]._exp = state.players[1]._exp + 100
    pool.tick()

    assert_equal(players.precise_payout(), false, "the named route was rejected")
    assert_equal(state.sphere_calls, 1, "and the radius call covered it")
    assert_equal(state.players[2]._exp, 100, "Keddo was paid either way")
end)

test("reading a parameter never uses the wrong accessor for its kind", function()
    -- F9 killed the game outright by asking every parameter for GetInner,
    -- GetPropertyClass and GetStruct. Those read a field that only exists on
    -- their own property type; anywhere else they read a wrong offset and the
    -- process dies. pcall does not catch that, so the code has to check the
    -- kind first.
    local state = fake.reset({ "Jonas" })
    package.loaded["probe"] = nil
    package.loaded["players"] = nil
    package.loaded["config"] = nil

    local probe = require("probe")
    probe.dump_exp_api()

    assert_equal(state.unsafe_property_access, false, "accessor use")

    -- And it still reported what the list holds, which is the whole point.
    local found = false
    for _, line in ipairs(state.output) do
        if line:find("PalPlayerCharacter") then found = true end
    end
    assert_equal(found, true, "the array's element class was reported")
end)

test("no format string uses a numeric flag on %s", function()
    -- "%+s" raised in game and silently returned "1" here: Lua tightened
    -- format validation after 5.4.2, and UE4SS ships a newer one than this
    -- suite runs on. So the running test could not catch it and a static check
    -- has to. Only "-" and a width are legal on %s and %q.
    local files = {
        "config", "main", "players", "pool", "probe",
    }

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

test("the pause key stops payouts, and resuming pays no backlog", function()
    -- The point of the key is being able to stop the mod mid-session without
    -- alt-tabbing out to edit files. Resuming must not then hand everybody
    -- everything that was earned while it was off -- that would be a far bigger
    -- injection than anything it does running.
    local state = fake.reset({ "Jonas", "Keddo" })
    load_main()
    local pool = require("pool")

    state.keybinds[11]()
    assert_equal(pool.is_paused(), true, "paused")

    pool.tick()
    state.players[1]._exp = state.players[1]._exp + 100
    pool.tick()

    assert_equal(#state.grants, 0, "nobody paid while paused")
    assert_equal(state.players[2]._exp, 0, "Keddo untouched")

    state.keybinds[11]()
    assert_equal(pool.is_paused(), false, "resumed")

    pool.tick()
    assert_equal(#state.grants, 0, "and the 100 earned while paused is not a backlog")

    state.players[1]._exp = state.players[1]._exp + 50
    pool.tick()

    -- 50 is what Jonas earned since resuming. Had the backlog counted, the rise
    -- would have read 150 and Keddo would be sitting at 150.
    assert_equal(state.players[2]._exp, 50, "sharing picks up from where it resumed")
end)

test("a reading after a gap is a baseline, not a windfall", function()
    -- A player who cannot be read for a while leaves a stale stored total, and
    -- the next good reading spans the whole gap. Counted as a tick's earnings
    -- that becomes the best rise and is paid to everybody at once -- the one
    -- mistake the pause key cannot undo.
    local state = fake.reset({ "Jonas", "Keddo", "HenBot" })
    local pool = load_pool()
    pool.tick()

    local reachable = state.players[2].GetCharacterParameterComponent
    state.players[2].GetCharacterParameterComponent = function() error("gone") end
    pool.tick()

    -- Whatever happened to him while he was out of reach.
    state.players[2]._exp = 50000
    state.players[2].GetCharacterParameterComponent = reachable
    pool.tick()

    assert_equal(#state.grants, 0, "nothing paid on the reading that closes the gap")
    assert_equal(state.players[1]._exp, 0, "Jonas")
    assert_equal(state.players[3]._exp, 0, "HenBot")

    -- And it is a baseline, not a blacklist: the next real earning shares.
    state.players[2]._exp = state.players[2]._exp + 10
    pool.tick()
    assert_equal(state.players[1]._exp, 10, "Jonas shares normally again")
end)

test("an impossible rise is ignored rather than shared", function()
    -- The backstop for a reading that cannot be real -- a garbage int64, or a
    -- baseline stale in some way the gap rule does not see. A whole level costs
    -- about 35k xp at level 30, so nothing a second of play produces comes near
    -- the cap.
    local state = fake.reset({ "Jonas", "Keddo" })
    local pool = load_pool({ max_rise_per_tick = 10000 })
    pool.tick()

    state.players[1]._exp = 999999999
    pool.tick()

    assert_equal(#state.grants, 0, "nobody was paid it")
    assert_equal(state.players[2]._exp, 0, "Keddo untouched")
    assert_equal(said(state, "impossible rise"), true, "and it said so")

    state.players[1]._exp = state.players[1]._exp + 100
    pool.tick()
    assert_equal(state.players[2]._exp, 100, "the baseline moved on, so sharing resumes")
end)

local function spread(state)
    local low, high = nil, nil
    for _, p in ipairs(state.players) do
        if not low or p._exp < low then low = p._exp end
        if not high or p._exp > high then high = p._exp end
    end
    return high - low
end

test("catching up sends the budget to whoever is furthest behind", function()
    -- Three players a long way apart. Whoever earns, the same 40 is created on
    -- top of it -- 20 of shortfall each for the two who did not earn -- and the
    -- old rule would hand them 20 apiece, preserving both gaps exactly. Instead
    -- all of it goes to the deepest valley.
    local state = fake.reset({ "P1", "P2", "P3" })
    state.players[1]._exp, state.players[2]._exp, state.players[3]._exp = 1000, 5000, 12000
    local pool = load_pool()
    pool.tick()

    state.players[3]._exp = state.players[3]._exp + 20
    pool.tick()

    assert_equal(state.players[1]._exp, 1040, "P1 takes the whole budget")
    assert_equal(state.players[2]._exp, 5000, "P2 waits until P1 reaches him")
    assert_equal(state.players[3]._exp, 12020, "the earner keeps only what he earned")

    local created = 0
    for _, p in ipairs(state.players) do created = created + p._exp end
    assert_equal(created, 1000 + 5000 + 12000 + 60,
        "20 earned by one of three players put 60 in the world, which is vanilla")
end)

test("the pool never creates more than the rise times the players", function()
    -- The invariant, over a long mixed run rather than a single tick. Somebody
    -- different earns 20 each tick, and the world gains exactly 60 every time
    -- however lopsided the totals are.
    local state = fake.reset({ "P1", "P2", "P3" })
    state.players[1]._exp, state.players[2]._exp, state.players[3]._exp = 1000, 5000, 12000
    local pool = load_pool()
    pool.tick()

    local function total()
        local sum = 0
        for _, p in ipairs(state.players) do sum = sum + p._exp end
        return sum
    end

    local before = total()
    for i = 1, 300 do
        local who = (i % 3) + 1
        state.players[who]._exp = state.players[who]._exp + 20
        pool.tick()
    end

    assert_equal(total() - before, 300 * 60, "60 a tick, never more")
end)

test("nobody is ever raised above the player in front", function()
    -- A budget larger than the room for it. Slow is 100 ahead when Fast earns
    -- 200, so 200 of budget meets 100 of headroom; the rest goes unpaid rather
    -- than carrying Slow past Fast to 300.
    local state = fake.reset({ "Slow", "Fast" })
    state.players[1]._exp, state.players[2]._exp = 100, 0
    local pool = load_pool()
    pool.tick()

    state.players[2]._exp = state.players[2]._exp + 200
    pool.tick()

    assert_equal(state.players[1]._exp, 200, "filled exactly level, not to 300")
    assert_equal(state.players[2]._exp, 200, "and the earner is untouched")
end)

test("a gap closes when the people behind are playing too", function()
    local state = fake.reset({ "P1", "P2", "P3" })
    state.players[1]._exp, state.players[2]._exp, state.players[3]._exp = 1000, 5000, 12000
    local pool = load_pool()
    pool.tick()

    for i = 1, 3000 do
        local who = (i % 3) + 1
        state.players[who]._exp = state.players[who]._exp + 20
        pool.tick()
    end

    assert_equal(spread(state), 0, "everyone converged")

    for i = 1, 30 do
        local who = (i % 3) + 1
        state.players[who]._exp = state.players[who]._exp + 20
        pool.tick()
    end
    assert_equal(spread(state), 0, "and stays converged")
end)

test("only the player in front earning keeps the gap as it was", function()
    -- The honest limit of a fixed budget, stated deliberately rather than
    -- discovered later. Every point the leader gains is a point they created,
    -- so nobody can gain faster than them. P1 still catches P2, and the pair
    -- then track P3 at his own rate forever.
    local state = fake.reset({ "P1", "P2", "P3" })
    state.players[1]._exp, state.players[2]._exp, state.players[3]._exp = 1000, 5000, 12000
    local pool = load_pool()
    pool.tick()

    for _ = 1, 2000 do
        state.players[3]._exp = state.players[3]._exp + 20
        pool.tick()
    end

    assert_equal(state.players[1]._exp, state.players[2]._exp, "P1 caught P2")
    assert_equal(state.players[3]._exp > state.players[1]._exp, true,
        "but neither of them closed on P3")
end)

test("two players close a gap as well", function()
    -- Which the design recorded in the README could not do at any player count.
    local state = fake.reset({ "Behind", "Ahead" })
    state.players[1]._exp, state.players[2]._exp = 0, 1000
    local pool = load_pool()
    pool.tick()

    state.players[1]._exp = state.players[1]._exp + 20
    pool.tick()

    assert_equal(state.players[1]._exp, 40, "the earner behind keeps the budget as well")
    assert_equal(state.players[2]._exp, 1000, "and the one in front gains nothing")
    assert_equal(spread(state), 960, "so the gap closed by 40")
end)

test("catch_up off keeps the old allocation exactly", function()
    local state = fake.reset({ "Behind", "Ahead" })
    state.players[1]._exp, state.players[2]._exp = 0, 1000
    local pool = load_pool({ catch_up = false })
    pool.tick()

    state.players[1]._exp = state.players[1]._exp + 20
    pool.tick()

    assert_equal(state.players[1]._exp, 20, "the earner gets only what they earned")
    assert_equal(state.players[2]._exp, 1020, "and the player in front is topped up too")
    assert_equal(spread(state), 1000, "so the gap is exactly as it was")
end)

real_print(string.format("\n%d passed, %d failed", passed, failed))
os.exit(failed == 0 and 0 or 1)
