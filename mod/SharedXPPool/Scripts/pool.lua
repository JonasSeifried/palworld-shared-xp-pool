-- The shared pool: when one player earns XP, give it to everyone else.
--
-- This watches each player's total XP and reacts to it changing, rather than
-- hooking whatever function awarded it. That is a deliberate choice, and the
-- probe run is why.
--
-- Palworld awards XP through several entry points on UPalExpDatabase, and a
-- kill goes through AddExp_EnemyDeath, whose only argument is a PalDeadInfo of
-- {LastDamage, LastAttacker, selfActor}. The amount is computed inside, and
-- never appears in the arguments. Crafting and building come in through
-- different functions again. Hooking each one would mean deriving the game's
-- own XP formula from the dead pal, correctly, for every source -- and getting
-- it wrong would silently pay out the wrong number.
--
-- Watching the total sidesteps all of it. Whatever the game decided a player
-- earned, and for whatever reason, the difference between two readings is
-- exactly that amount.
--
-- Scope is deliberately narrow: only players who are currently connected. A
-- player who is offline has no loaded save for the mod to reach, and catching
-- them up is the save editor's job.

local config = require("config")
local players = require("players")

local pool = {}

-- Per player: the last total we saw, and how much of any future rise is XP we
-- handed out ourselves rather than XP they earned.
local watched = {}

local running = false

local function share(earner_key, amount, connected, keys)
    local per_player = amount * config.share_rate
    if config.divide_among_players then
        per_player = per_player / #connected
    end
    per_player = math.floor(per_player)
    if per_player <= 0 then return 0 end

    local recipients = 0

    for i, character in ipairs(connected) do
        if keys[i] ~= earner_key then
            if players.grant(character, per_player) then
                -- Remember what we gave, so the next reading does not mistake
                -- our own payout for XP they earned and mirror it again.
                local state = watched[keys[i]]
                if state then
                    state.owed = state.owed + per_player
                end
                recipients = recipients + 1
            end
        end
    end

    return recipients
end

local function tick()
    local connected = players.connected()
    if #connected == 0 then return end

    local keys = {}
    for i, character in ipairs(connected) do
        keys[i] = players.key(character)
    end

    -- Read everyone first. Sharing as we go would let one player's payout land
    -- before we had read the next player's total, which then looks earned.
    local earned = {}
    for i, character in ipairs(connected) do
        local key = keys[i]
        local total = key and players.exp(character)

        if total then
            local state = watched[key]
            if not state then
                -- First sight. Establish a baseline and share nothing: their
                -- existing XP is not something they just earned.
                watched[key] = { exp = total, owed = 0 }
            else
                local rise = total - state.exp
                state.exp = total

                if rise > 0 then
                    -- Discount our own payouts first.
                    local ours = math.min(rise, state.owed)
                    state.owed = state.owed - ours
                    local really_earned = rise - ours

                    if really_earned > 0 then
                        earned[#earned + 1] = { key = key, amount = really_earned, index = i }
                    end
                end
            end
        end
    end

    if #connected < 2 then return end

    for _, event in ipairs(earned) do
        local recipients = share(event.key, event.amount, connected, keys)
        if config.verbose and recipients > 0 then
            print(string.format("[SharedXPPool] %s earned %d xp -> shared to %d player(s)\n",
                players.name(connected[event.index]), event.amount, recipients))
        end
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
