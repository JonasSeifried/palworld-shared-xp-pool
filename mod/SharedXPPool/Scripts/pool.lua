-- The shared pool itself: when one player earns XP, give it to everyone.
--
-- Scope is deliberately narrow. This only reaches players who are currently
-- connected, because a player who is offline has no loaded save for the mod to
-- touch. Catching an offline player up is the save editor's job, not this one's.

local config = require("config")
local players = require("players")

local pool = {}

-- The function the game calls when a player's party is awarded XP. Confirm
-- this against a probe run before trusting it; see probe.lua.
local SOURCE = "/Script/Pal.PalExpDatabase:AddExpValue_forPlayerParty_Server"

-- Set while we are handing out mirrored XP, so our own grants do not come back
-- through the hook and mirror themselves forever.
local sharing = false

-- Palworld already awards full XP to every player standing nearby, and we do
-- not know yet whether that means the hook fires once per event or once per
-- recipient. If it is once per recipient, an unguarded mirror multiplies the
-- award by the number of players who happened to be together. Collapsing
-- identical amounts that arrive in the same instant is the cheap defence.
--
-- A probe run settles it: if the log shows exactly one call per kill, set this
-- to 0 and the guard disappears.
local DEDUP_WINDOW = 0.2
local last_amount, last_at = nil, -1

local function is_duplicate(amount)
    if DEDUP_WINDOW <= 0 then return false end
    local now = os.clock()
    if last_amount == amount and (now - last_at) < DEDUP_WINDOW then
        return true
    end
    last_amount, last_at = amount, now
    return false
end

-- We know the parameter names from the binary but not their order or arity, and
-- both can change with a patch. Rather than hard-coding positions, take the
-- first number as the amount and the first object as the earner. If a patch
-- reshuffles the signature this still works, and if it stops working the log
-- says so instead of the mod silently doing nothing.
local function read_event(...)
    local amount, earner

    for i = 1, select("#", ...) do
        local raw = (select(i, ...))
        if raw ~= nil then
            local ok, value = pcall(function() return raw:get() end)
            if not ok then value = raw end

            if amount == nil and type(value) == "number" and value > 0 then
                amount = value
            elseif earner == nil and type(value) ~= "number"
                    and type(value) ~= "boolean" and type(value) ~= "string" then
                -- Duck-type on IsValid rather than checking for userdata: the
                -- wrapper type UE4SS hands us is not something to depend on.
                local ok2, valid = pcall(function() return value:IsValid() end)
                if ok2 and valid then earner = value end
            end
        end
    end

    return amount, earner
end

local function share(amount, earner)
    local connected = players.connected()
    if #connected <= 1 then return end

    local per_player = amount * config.share_rate
    if config.divide_among_players then
        per_player = per_player / #connected
    end

    per_player = math.floor(per_player)
    if per_player <= 0 then return end

    local earner_key = players.key(earner)
    local given = 0

    sharing = true
    for _, character in ipairs(connected) do
        local key = players.key(character)
        if key == nil or key ~= earner_key then
            if players.grant(character, per_player) then
                given = given + 1
            end
        end
    end
    sharing = false

    if config.verbose then
        print(string.format(
            "[SharedXPPool] %d xp earned -> %d xp to %d other player(s)\n",
            amount, per_player, given))
    end
end

function pool.start()
    local ok, err = pcall(function()
        RegisterHook(SOURCE, function(Context, ...)
            if sharing then return end

            local amount, earner = read_event(...)
            if not amount then
                print("[SharedXPPool] hook fired but no amount found in its "
                    .. "arguments -- run with probe_only = true and check the "
                    .. "signature\n")
                return
            end

            if is_duplicate(amount) then return end

            -- Never let a failure in here take the game's XP call down with it.
            local shared, why = pcall(share, amount, earner)
            if not shared then
                sharing = false
                print("[SharedXPPool] share failed: " .. tostring(why) .. "\n")
            end
        end)
    end)

    if ok then
        print("[SharedXPPool] sharing active on " .. SOURCE .. "\n")
    else
        print("[SharedXPPool] could not hook " .. SOURCE .. ": " .. tostring(err) .. "\n")
        print("[SharedXPPool] set probe_only = true in config.lua to find the "
            .. "right function for this build\n")
    end
end

return pool
