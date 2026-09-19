-- Everybody in the world sits at the same XP total.
--
-- One rule, re-asserted every tick: find the highest total anybody has, and
-- move everyone else toward it. That is the whole mod.
--
-- It replaced a design that tried to share XP *as it was earned* -- watch each
-- player's total, work out what they gained since the last look, top up whoever
-- gained less. That version had to answer a question the game does not expose:
-- when two players both gain inside the same second, was that one kill the game
-- shared with both of them, or two separate kills? The totals look identical
-- either way. Answering it needed a sharing radius nobody could measure
-- reliably, and every rule built on top of it -- baselines, stale readings,
-- rise caps, distance grouping, a catch-up allocator -- existed to prop up that
-- one guess.
--
-- Asking "what should everyone have?" instead of "what did everyone earn?"
-- deletes the question. The save editor has always worked this way.
--
-- What follows from the rule rather than being bolted onto it:
--
--   * Catching up and ongoing sharing are the same operation. There is no login
--     hook and no catch-up mode; somebody who was away is simply below the top
--     when they come back.
--   * It cannot loop. Every payout moves people toward a fixed point, and a
--     tick where everybody is already level pays nothing.
--   * A failed reading costs one tick. Nothing is carried between ticks except
--     a sanity check, so there is no state to corrupt.
--
-- Two things the rule does need, and both are here:
--
--   * A payout that reaches only its recipient. If paying one player raises
--     another, the top moves every time it is approached and the mod chases it
--     forever. AddExpValue_forPlayerParty_Server names its recipients and is
--     verified on the first payout; there is no leaky fallback any more.
--   * A guard against a reading that is too *low*. Under the old differential
--     rule a bad low reading clamped harmlessly to zero. Here it looks like
--     somebody who needs the entire pool. XP never decreases in Palworld, so a
--     reading below that player's previous one is wrong by definition.

local config = require("config")
local players = require("players")

local pool = {}

-- key -> the last total read for that player. Not arithmetic: it exists only to
-- notice a reading that went backwards, and to avoid paying somebody on the
-- very first tick they are seen.
local last_seen = {}

local running = false
local paused = false
local last_unreadable = 0
local refused = false

-- What each connected player has, indexed alongside `connected`.
--
-- A reading is trusted only if that player has been seen before and the number
-- has not gone backwards. An untrusted reading is recorded and otherwise
-- ignored: it neither sets the top nor receives anything.
local function read(connected)
    local totals, trusted = {}, {}
    local unreadable = 0

    for i, character in ipairs(connected) do
        local key = players.key(character)
        local total = key and players.exp(character) or nil
        totals[i] = total

        if not total then
            unreadable = unreadable + 1
        else
            local before = last_seen[key]
            if before == nil then
                -- First sighting. Record it and wait a tick.
                trusted[i] = false
            elseif total < before then
                print(string.format(
                    "[SharedXPPool] %s read %s xp, below the %s seen before --"
                    .. " ignoring it, XP does not go down\n",
                    players.name(character), tostring(total), tostring(before)))
                trusted[i] = false
            else
                trusted[i] = true
            end
            last_seen[key] = total
        end
    end

    return totals, trusted, unreadable
end

local function tick()
    local connected = players.connected()
    if #connected == 0 then return end

    local totals, trusted, unreadable = read(connected)

    -- Somebody we cannot read is left alone rather than guessed at. They are
    -- never lowered, they do not set the top, and the next tick that reads them
    -- brings them up.
    if unreadable > 0 and unreadable ~= last_unreadable then
        print(string.format(
            "[SharedXPPool] %d player(s) unreadable, skipping them until that changes\n",
            unreadable))
    end
    last_unreadable = unreadable

    if config.watch_totals then
        local parts = {}
        for i = 1, #connected do
            parts[#parts + 1] = players.name(connected[i])
                .. " " .. (totals[i] and tostring(totals[i]) or "?")
                .. (trusted[i] and "" or " (new)")
        end
        print("[SharedXPPool] watch  " .. table.concat(parts, "  ") .. "\n")
    end

    if paused then return end

    local rate = config.catch_up_rate or 0
    if rate <= 0 or #connected < 2 then return end

    local top = nil
    for i = 1, #connected do
        if trusted[i] and (not top or totals[i] > top) then top = totals[i] end
    end
    if not top then return end

    -- Refusing beats looping. A payout that reaches bystanders moves the top
    -- every time it is approached, so without a precise one there is nothing
    -- safe to do at all.
    if players.precise_payout() == false then
        if not refused then
            refused = true
            print("[SharedXPPool] the precise payout does not work on this build,"
                .. " so nothing will be shared -- see the README\n")
        end
        return
    end

    local paid, given = 0, 0
    for i = 1, #connected do
        if trusted[i] then
            local gap = top - totals[i]
            if gap > 0 then
                -- A fraction of the gap rather than a fixed amount, because an
                -- amount that is sensible at level 10 (a level costs 1,900 xp)
                -- is a rounding error at level 60 (670,000). The floor of 1 is
                -- what makes it land exactly instead of creeping at the end.
                local owed = math.floor(gap * rate)
                if owed < 1 then owed = 1 end
                if owed > gap then owed = gap end

                if players.grant(connected[i], owed) then
                    paid = paid + 1
                    given = given + owed
                    if config.verbose then
                        print(string.format("[SharedXPPool] %s is %s behind -> paid %s\n",
                            players.name(connected[i]), tostring(gap), tostring(owed)))
                    end
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
-- nothing is differential: resuming just starts levelling people again.
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
    last_seen = {}
    paused = false
    refused = false
    last_unreadable = 0
end

return pool
