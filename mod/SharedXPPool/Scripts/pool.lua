-- The shared pool: nobody falls behind the best earner.
--
-- This watches each player's XP total and reacts to it changing, rather than
-- hooking whatever function awarded it. Palworld computes XP inside the game --
-- a kill arrives as AddExp_EnemyDeath carrying a PalDeadInfo and no amount --
-- so the award is not readable from a hook. The difference between two
-- readings is, and it covers every source at once: kills, crafting, building,
-- capture bonuses, and anything a future patch adds.
--
-- Two rules follow from what the game actually does, both learned the hard way.
--
-- **Top up to the best rise, do not add to it.** Palworld already gives full XP
-- to players standing near each other. If two players both rose 10 this tick,
-- the game has already shared it and there is nothing to do; paying them 10
-- more would double a kill. So the target is the largest rise anyone saw, and
-- only players below it get the difference.
--
-- **Rebaseline after paying.** A payout does not land on one player. Granting
-- to one raised the other too -- Palworld's own nearby sharing propagates it,
-- and the exp call is a sphere in the first place. Crediting only the intended
-- recipient left the other's rise looking earned, which mirrored it, forever:
-- a steady 10 xp per second per player with nobody playing. So after paying,
-- read everyone again and take that as the new baseline. Whatever the payout
-- touched, and whoever it reached, is absorbed rather than counted as
-- earnings.
--
-- Between them the two rules make a feedback loop structurally impossible.
-- Sharing can only ever level players up to the best earner, never past them,
-- and a tick where everyone is already level produces no payment at all.
--
-- Scope: only players currently connected. Someone offline has no loaded save
-- to reach, and catching them up is the save editor's job.

local config = require("config")
local players = require("players")

local pool = {}

-- key -> { exp = <last total we saw> }
local watched = {}

local running = false
local last_unreadable = 0

local function read_totals(connected, keys)
    local totals = {}
    for i, character in ipairs(connected) do
        if keys[i] then
            totals[i] = players.exp(character)
        end
    end
    return totals
end

local function rebaseline(connected, keys, totals)
    for i = 1, #connected do
        local key, total = keys[i], totals[i]
        if key and total then
            local state = watched[key]
            if state then
                state.exp = total
            else
                watched[key] = { exp = total }
            end
        end
    end
end

local function tick()
    local connected = players.connected()
    if #connected == 0 then return end

    local keys = {}
    for i, character in ipairs(connected) do
        keys[i] = players.key(character)
    end

    local totals = read_totals(connected, keys)

    -- How much each player gained since the last look. A player we have not
    -- seen before gets a baseline and sits this tick out: their existing XP is
    -- not something they just earned.
    local rises = {}
    local best, sum, counted, unreadable = 0, 0, 0, 0

    for i = 1, #connected do
        local key, total = keys[i], totals[i]
        if key and total then
            local state = watched[key]
            if state then
                local rise = total - state.exp
                if rise < 0 then rise = 0 end  -- a fresh character, or a reset
                rises[i] = rise
                if rise > best then best = rise end
                sum = sum + rise
                counted = counted + 1
            end
        else
            unreadable = unreadable + 1
        end
    end

    -- A player we cannot read gets nothing, rather than the full target. We do
    -- not know what they already gained, so paying them would be a guess -- and
    -- guessing high is exactly what turned the first live run into a loop.
    -- Falling behind is recoverable; the save editor tops them up later.
    if unreadable > 0 and unreadable ~= last_unreadable then
        print(string.format(
            "[SharedXPPool] %d player(s) unreadable, skipping them until that changes\n",
            unreadable))
    end
    last_unreadable = unreadable

    if #connected < 2 or best <= 0 or counted == 0 then
        rebaseline(connected, keys, totals)
        return
    end

    -- Everyone should end this tick having gained as much as the best earner.
    local target = best * config.share_rate
    if config.divide_among_players then
        target = (sum * config.share_rate) / counted
    end
    target = math.floor(target)

    local paid, given = 0, 0
    for i = 1, #connected do
        local rise = rises[i]
        if rise and rise < target then
            local owed = target - rise
            if players.grant(connected[i], owed) then
                paid = paid + 1
                given = given + owed
            end
        end
    end

    if paid > 0 then
        -- Read again rather than assuming where the XP landed.
        local after = read_totals(connected, keys)
        for i = 1, #connected do
            if after[i] then totals[i] = after[i] end
        end

        if config.verbose then
            print(string.format(
                "[SharedXPPool] best rise %d xp -> topped up %d player(s) by %d xp total\n",
                best, paid, given))
        end
    end

    rebaseline(connected, keys, totals)
end

local function schedule()
    ExecuteWithDelay(config.poll_interval_ms, function()
        if not running then return end

        -- Never let a bad tick kill the loop; a mod that stops silently is
        -- worse than one that logs and carries on.
        local ok, err = pcall(tick)
        if not ok then
            print("[SharedXPPool] tick failed: " .. tostring(err) .. "\n")
        end

        schedule()
    end)
end

function pool.start()
    running = true
    schedule()
    print(string.format("[SharedXPPool] sharing active, checking every %d ms\n",
        config.poll_interval_ms))
end

-- Exposed for the tests, which drive ticks directly instead of waiting.
pool.tick = tick

function pool.reset()
    watched = {}
end

return pool
