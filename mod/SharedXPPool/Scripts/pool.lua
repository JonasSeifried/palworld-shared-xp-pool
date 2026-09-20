-- Everybody in the world sits at the same XP total.
--
-- Every tick: read everyone, find the highest total, move the rest toward it.
-- Catching up a returning player and sharing during play are the same
-- operation, and a tick where everybody is level does nothing at all.
--
-- Three things the rule depends on, all enforced below:
--
--   * the payout must reach only its recipient, or the top moves every time it
--     is approached and the mod chases it forever
--   * a reading outside what the game can produce is a bad read, not somebody
--     owed the entire pool and not a new top for everybody to chase
--   * a payout has to be seen landing, or the pool pays the same gap forever
--
-- The design this replaced, and why, is in the README.

local config = require("config")
local players = require("players")

local pool = {}

-- No real player is anywhere near this. The datamined curve puts level 100 at
-- 382 million, and this build's CharacterMaxLevel reads 80, which is 46
-- million; a total in the billions is a marshalling artefact, not somebody who
-- has been playing.
--
-- It is the half the "XP does not go down" rule was missing, and the worse
-- half: a bad reading that is too small costs one player one payout, while a
-- bad reading that is too large is taken as the top, everybody is paid up to
-- it, and by the next tick that invented XP is real and nothing can take it
-- back.
local MAX_CREDIBLE_EXP = 1000000000

-- Ticks of a reading being refused before saying it is not going away, and
-- ticks of paying somebody without their total moving before giving up on
-- them. Both are small; both only need to outlast one bad instant.
local PERSISTENT_REFUSALS, STUCK_AFTER = 5, 3

-- key -> last total accepted. A sanity check, not arithmetic.
local last_seen = {}

-- key -> consecutive readings refused, for saying so once rather than each tick.
local refusals = {}

-- key -> { at = the total they were on when we paid them, misses = ticks since
-- that has not moved }. Cleared the moment it does move.
local landing = {}

local running, paused, refused = false, false, false
local last_unreadable = 0
local world = nil

-- Everything above is true of one loaded world and nothing else.
local function forget()
    last_seen, refusals, landing = {}, {}, {}
    refused, last_unreadable = false, 0
end

-- Whether anything is being remembered about the world that was loaded.
-- Nothing is in the menu or through a load screen, which is exactly when the
-- world object changes most.
local function remembering()
    return next(last_seen) ~= nil
        or next(refusals) ~= nil
        or next(landing) ~= nil
end

-- The Lua state outlives a loaded world: going to the main menu and loading a
-- different save leaves every baseline describing somewhere else, and the same
-- player legitimately back at a lower total. Without this they would be
-- refused for the rest of the session under the rule below.
local function world_changed()
    local id = players.world_id()
    if id == nil or id == world then return false end

    local changed = world ~= nil
    world = id
    return changed
end

-- A refused reading does not become the new baseline, and that is the whole
-- point of keeping one. If a bad reading could lower it, the same bad reading
-- is believed one tick later and the player is paid the entire pool on top of
-- the XP they actually have. Nothing lowers a baseline while a world is
-- loaded: refusing to pay somebody is recoverable, inventing XP in a live
-- world is not.
local function refuse(character, key, why)
    local n = (refusals[key] or 0) + 1
    refusals[key] = n

    if n == 1 then
        print(string.format("[SharedXPPool] %s %s -- ignoring it\n",
            players.name(character), why))
    elseif n == PERSISTENT_REFUSALS then
        print(string.format(
            "[SharedXPPool] %s has now been refused %d times running and is being"
            .. " left out. If you loaded a different world without restarting the"
            .. " game, restart it\n",
            players.name(character), n))
    end
end

-- One entry per connected player: { key, character, total, trusted }.
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
        elseif total > MAX_CREDIBLE_EXP then
            refuse(character, key, string.format(
                "read %s xp, past anything the game can produce", tostring(total)))
        elseif last_seen[key] and total < last_seen[key] then
            refuse(character, key, string.format(
                "read %s xp, below the %s seen before -- XP does not go down",
                tostring(total), tostring(last_seen[key])))
        else
            -- Not on the first sighting: the number may still be settling.
            trusted = last_seen[key] ~= nil
            last_seen[key] = total
            refusals[key] = nil
        end

        seen[#seen + 1] = {
            key = key, character = character, total = total, trusted = trusted,
        }
    end

    return seen, unreadable
end

-- Did the last tick's payouts land?
--
-- players.grant checks the first payout of a session and no others, which
-- leaves the rest of it unwatched: a call that stops moving XP -- a recipient
-- the game will not take past CharacterMaxLevel, a patch that turns the
-- function into a no-op that does not raise -- would have the pool paying the
-- same gap every second forever, logging it every time, and changing nothing.
--
-- This costs no extra reads, because the next tick reads everybody anyway.
local function check_landing(seen)
    for _, p in ipairs(seen) do
        local watch = landing[p.key]
        if watch and p.trusted then
            if p.total > watch.at then
                landing[p.key] = nil
            else
                watch.misses = watch.misses + 1
                if watch.misses == STUCK_AFTER then
                    print(string.format(
                        "[SharedXPPool] %s has been paid %d times without their total"
                        .. " moving -- not paying them again until it does\n",
                        players.name(p.character), watch.misses))
                end
            end
        end
    end
end

local function stuck(key)
    local watch = landing[key]
    return watch ~= nil and watch.misses >= STUCK_AFTER
end

-- Keep the total they were on when the first unlanded payout went out, so a
-- run of payouts is judged against where it started rather than each other.
local function watch_landing(p)
    if not landing[p.key] then
        landing[p.key] = { at = p.total, misses = 0 }
    end
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
    -- Before the early return below, because a world can be swapped while
    -- nobody is connected -- which is in fact the usual way to do it.
    --
    -- A change on its own means nothing. Measured in game: the world object
    -- changes twice between launching the game and the main menu, and once
    -- more on entering a world, and then stays put for the rest of the
    -- session. Only a change with something to throw away is worth acting on,
    -- and saying "forgetting everything" three times before a single player
    -- has been read is both alarming and untrue.
    if world_changed() and remembering() then
        forget()
        print("[SharedXPPool] a different world is loaded -- forgetting"
            .. " everything read in the last one\n")
    end

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

    -- After the pause check: nothing is being paid while paused, so a payout
    -- still waiting to be seen landing should not run out of patience there.
    check_landing(seen)

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
        local gap = (p.trusted and not stuck(p.key)) and (top - p.total) or 0
        if gap > 0 then
            local owed = step(gap, rate)
            if players.grant(p.character, owed) then
                watch_landing(p)
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
