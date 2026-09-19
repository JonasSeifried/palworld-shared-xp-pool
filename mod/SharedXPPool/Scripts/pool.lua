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
-- **A reading after a gap is a baseline, not a rise.** When a player cannot be
-- read for a while -- a pawn swap, a loading screen, an accessor that stopped
-- working -- their stored total goes stale, and the next good reading would
-- otherwise look like everything they earned in between arriving at once. That
-- number becomes the best rise and is paid to everybody. So a player who was
-- missed is rebaselined on their next reading rather than counted, the same way
-- somebody who just joined is.
--
-- On top of those three, config.catch_up decides where a tick's budget goes.
-- The budget is the same either way -- the best rise times the number of
-- players -- but paying each player their own shortfall preserves whatever gap
-- people started with, while filling the lowest totals first closes it. Capped
-- so nobody passes the player in front, which is what makes the second one
-- switch itself off when everybody is already level.
--
-- Between them the rules make a feedback loop structurally impossible.
-- Sharing can only ever level players up to the best earner, never past them,
-- and a tick where everyone is already level produces no payment at all.
--
-- Scope: only players currently connected. Someone offline has no loaded save
-- to reach, and catching them up is the save editor's job.

local config = require("config")
local players = require("players")

local pool = {}

-- key -> { exp = <last total we saw>, stale = <true if we missed a reading> }
local watched = {}

local running = false
local paused = false
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
                -- A reading that landed clears the gap: from here the stored
                -- total is current again.
                state.stale = nil
            else
                watched[key] = { exp = total }
            end
        end
    end
end

-- Who gets the budget, when catching up is on.
--
-- Raise the lowest total first until it meets the next lowest, then raise both
-- together, and so on -- filling valleys rather than handing each player their
-- own shortfall. That is what closes a gap instead of preserving it, and it is
-- also the level weighting: somebody four levels down is simply the deepest
-- valley, so the water reaches them first. No ratio to pick.
--
-- The water level never rises above `ceiling`, the highest total anybody has.
-- Nobody overtakes the player in front, and once everyone is level there is
-- nowhere left to put the money -- which is exactly how the extra XP switches
-- itself off when there is no gap to close.
--
-- Returns index -> amount, over the entries given.
local function water_fill(entries, budget, ceiling)
    table.sort(entries, function(a, b) return a.total < b.total end)

    local n = #entries
    local level = entries[1].total
    local remaining = budget

    for i = 1, n do
        local next_level = (i < n) and entries[i + 1].total or ceiling
        if next_level > ceiling then next_level = ceiling end

        if next_level > level then
            -- Raising the i players at or below the line costs this much.
            local cost = i * (next_level - level)
            if remaining >= cost then
                remaining = remaining - cost
                level = next_level
            else
                local step = remaining // i
                level = level + step
                remaining = remaining - step * i
                break
            end
        end
    end

    local allocation = {}
    for _, entry in ipairs(entries) do
        local owed = level - entry.total
        allocation[entry.index] = owed > 0 and owed or 0
    end

    -- XP is whole numbers, so a budget that does not divide evenly leaves a few
    -- units over. Dropping them every second adds up, so they go to the lowest
    -- totals -- one each, in order, which is all that can be left.
    for _, entry in ipairs(entries) do
        if remaining <= 0 then break end
        if entry.total + allocation[entry.index] < ceiling then
            allocation[entry.index] = allocation[entry.index] + 1
            remaining = remaining - 1
        end
    end

    return allocation
end

local function tick()
    local connected = players.connected()
    if #connected == 0 then return end

    local keys = {}
    for i, character in ipairs(connected) do
        keys[i] = players.key(character)
    end

    local totals = read_totals(connected, keys)

    -- Paused still reads and still moves the baselines forward, so resuming
    -- does not pay out everything earned while it was off.
    if paused then
        rebaseline(connected, keys, totals)
        return
    end

    -- How much each player gained since the last look. A player we have not
    -- seen before gets a baseline and sits this tick out: their existing XP is
    -- not something they just earned.
    local rises = {}
    local best, sum, counted, unreadable = 0, 0, 0, 0
    local cap = config.max_rise_per_tick or 0

    for i = 1, #connected do
        local key, total = keys[i], totals[i]
        if key and total then
            local state = watched[key]
            -- A stale entry is one we failed to read at least once since it was
            -- written. The difference from it spans that gap rather than this
            -- tick, so it is not earnings. rebaseline below takes the reading.
            if state and not state.stale then
                local rise = total - state.exp
                if rise < 0 then rise = 0 end  -- a fresh character, or a reset
                if cap > 0 and rise > cap then
                    -- %s, not %d: this is the branch for a number that is
                    -- not what it should be, and %d raises on a non-integer.
                    print(string.format(
                        "[SharedXPPool] ignoring an impossible rise of %s xp from %s"
                        .. " -- taking it as a new baseline instead\n",
                        tostring(rise), players.name(connected[i])))
                else
                    rises[i] = rise
                    if rise > best then best = rise end
                    sum = sum + rise
                    counted = counted + 1
                end
            end
        else
            unreadable = unreadable + 1
            -- Mark what we missed, so the reading that follows the gap is not
            -- mistaken for a tick's earnings.
            if key and watched[key] then watched[key].stale = true end
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

    -- What to pay whom. Both routes hand out the same budget, and differ only
    -- in where it goes: to each player's own rate shortfall, which keeps an
    -- existing gap exactly as it was, or to the lowest totals first, which
    -- closes it.
    local owings = {}

    if config.catch_up then
        local entries, ceiling, budget = {}, nil, 0

        for i = 1, #connected do
            if keys[i] and totals[i] then
                entries[#entries + 1] = { index = i, total = totals[i] }
                if not ceiling or totals[i] > ceiling then ceiling = totals[i] end
            end
            local rise = rises[i]
            if rise and rise < target then budget = budget + (target - rise) end
        end

        -- Note what this budget is: summed over everybody, target - rise is
        -- exactly (players * target) - (what the game already gave out). So the
        -- XP in the world after this tick is the best rise times the number of
        -- players, no matter who ends up holding it -- the same total vanilla
        -- would produce with everyone standing together. Catching up moves it
        -- around; it never makes more of it.
        if #entries > 0 and budget > 0 then
            owings = water_fill(entries, budget, ceiling)
        end
    else
        for i = 1, #connected do
            local rise = rises[i]
            if rise and rise < target then
                owings[i] = target - rise
            end
        end
    end

    local paid, given = 0, 0
    for i = 1, #connected do
        local owed = owings[i]
        if owed and owed > 0 then
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

-- Pausing stops payouts, not the loop: it keeps reading so the baselines stay
-- current. Returns the new state, which the key handler reports.
function pool.set_paused(value)
    paused = value and true or false
    print(paused
        and "[SharedXPPool] sharing PAUSED -- still watching, paying nobody\n"
        or "[SharedXPPool] sharing RESUMED\n")
    return paused
end

function pool.toggle_paused()
    return pool.set_paused(not paused)
end

function pool.is_paused()
    return paused
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
    paused = false
end

return pool
