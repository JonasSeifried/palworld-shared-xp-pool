-- Everybody in the world sits at the same XP total.
--
-- Every tick: read everyone, find the highest total, move the rest toward it.
-- Catching up a returning player and sharing during play are the same
-- operation, and a tick where everybody is level does nothing at all.
--
-- Two things the rule depends on, both enforced below:
--
--   * the payout must reach only its recipient, or the top moves every time it
--     is approached and the mod chases it forever
--   * a reading below that player's previous one is a bad read, not somebody
--     owed the entire pool
--
-- The design this replaced, and why, is in the README.

local config = require("config")
local players = require("players")

local pool = {}

-- key -> last total read. A sanity check, not arithmetic.
local last_seen = {}

local running, paused, refused = false, false, false
local last_unreadable = 0

-- One entry per connected player: { character, total, trusted }.
--
-- `total` is nil when they cannot be read. Untrusted entries are recorded and
-- otherwise ignored -- they neither set the top nor receive anything.
local function read(connected)
    local seen, unreadable = {}, 0

    for _, character in ipairs(connected) do
        local key = players.key(character)
        local total = key and players.exp(character) or nil
        local trusted = false

        if not total then
            unreadable = unreadable + 1
        elseif last_seen[key] and total < last_seen[key] then
            print(string.format(
                "[SharedXPPool] %s read %s xp, below the %s seen before --"
                .. " ignoring it, XP does not go down\n",
                players.name(character), tostring(total), tostring(last_seen[key])))
        else
            -- Not on the first sighting: the number may still be settling.
            trusted = last_seen[key] ~= nil
        end

        if total then last_seen[key] = total end
        seen[#seen + 1] = { character = character, total = total, trusted = trusted }
    end

    return seen, unreadable
end

local function highest(seen)
    local top = nil
    for _, p in ipairs(seen) do
        if p.trusted and (not top or p.total > top) then top = p.total end
    end
    return top
end

-- A fraction of the gap, because a fixed amount that suits level 10 is a
-- rounding error at level 60. Never below 1, or the last few points creep
-- forever; never above the gap, or a rate over 1 overshoots the top.
local function step(gap, rate)
    local owed = math.floor(gap * rate)
    if owed < 1 then owed = 1 end
    if owed > gap then owed = gap end
    return owed
end

local function report(seen)
    local parts = {}
    for _, p in ipairs(seen) do
        parts[#parts + 1] = players.name(p.character)
            .. " " .. (p.total and tostring(p.total) or "?")
            .. (p.trusted and "" or " (new)")
    end
    print("[SharedXPPool] watch  " .. table.concat(parts, "  ") .. "\n")
end

local function tick()
    local connected = players.connected()
    if #connected == 0 then return end

    local seen, unreadable = read(connected)

    -- Somebody unreadable is left alone rather than guessed at. The next tick
    -- that reads them brings them up.
    if unreadable > 0 and unreadable ~= last_unreadable then
        print(string.format(
            "[SharedXPPool] %d player(s) unreadable, skipping them until that changes\n",
            unreadable))
    end
    last_unreadable = unreadable

    if config.watch_totals then report(seen) end
    if paused then return end

    local rate = config.catch_up_rate or 0
    if rate <= 0 or #connected < 2 then return end

    local top = highest(seen)
    if not top then return end

    -- Refusing beats looping: without a precise payout there is nothing safe to
    -- do, because a payout that reaches bystanders moves the top.
    if players.precise_payout() == false then
        if not refused then
            refused = true
            print("[SharedXPPool] the precise payout does not work on this build,"
                .. " so nothing will be shared -- see the README\n")
        end
        return
    end

    local paid, given = 0, 0
    for _, p in ipairs(seen) do
        local gap = p.trusted and (top - p.total) or 0
        if gap > 0 then
            local owed = step(gap, rate)
            if players.grant(p.character, owed) then
                paid, given = paid + 1, given + owed
                if config.verbose then
                    print(string.format("[SharedXPPool] %s is %s behind -> paid %s\n",
                        players.name(p.character), tostring(gap), tostring(owed)))
                end
            end
        end
    end

    if paid > 0 and not config.verbose then
        print(string.format("[SharedXPPool] levelled up %d player(s) by %s xp\n",
            paid, tostring(given)))
    end
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

-- Pausing stops payouts, not reading. Nothing accumulates while paused, because
-- nothing is differential.
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

return pool
