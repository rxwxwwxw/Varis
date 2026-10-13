-- A scripted player for Lanternfall: builds along the route, uses hero abilities when the Dim
-- are near, and takes hub and moment choices from a fixed style. It is the engine's integration
-- test (SAMPLE_TD_PLAN.md §7): golden digests, the branch matrix and the novice test all use it.
--
--   local bot = require("tools.bot")
--   bot.play(seed, style)    -- a whole game; returns the final session and a report

local G = require("game")

local M = {}

local function name_of(v) return logic.symbolname(v) end

-- Tower kinds by position in battle/kinds.lua.
local BOLT, CHIME, HOAR, ARC, BEACON = 1, 2, 3, 4, 5

-- The order the builder cycles through; nights unlock kinds as the plan says.
local function palette(night)
    local list = {BOLT, BOLT, CHIME, BOLT}
    if night >= 2 then list = {BOLT, CHIME, HOAR, BOLT, CHIME} end
    if night >= 3 then list = {BOLT, ARC, HOAR, CHIME, BOLT, ARC} end
    if night >= 4 then list = {ARC, BOLT, HOAR, ARC, CHIME, BEACON, BOLT} end
    return list
end

local KIND_COST = {10, 22, 18, 34, 28}

local function distance(q1, r1, q2, r2)
    local dq, dr = q2 - q1, r2 - r1
    return (math.abs(dq) + math.abs(dr) + math.abs(dq + dr)) // 2
end

-- Places towers where they see the most of the route: candidates are the open tiles within two
-- of a route tile; each is scored by the route tiles in range that are not yet covered. As many
-- as the credits allow, spread by the score's decay. `opts.towers` caps the count; `opts.reserve`
-- keeps credits back; `opts.front` moves heroes onto the road near the Lantern to fight.
function M.builder(opts)
    opts = opts or {}
    return function(night)
        local h = night.handle
        local snap = h:snapshot()
        local credits = snap.credits - (opts.reserve or 0)
        local limit = opts.towers or 100
        local kinds = palette(night.night)
        local used = {}
        for _, u in pairs(snap.units) do used[u.q .. "," .. u.r] = true end
        local routes, on_route, covered = {}, {}, {}
        for source = 1, #night.setup.sources do
            local route = h:route(source)
            if route and (not opts.only_route or opts.only_route == source) then
                routes[#routes + 1] = route
                for _, t in ipairs(route) do on_route[t.q .. "," .. t.r] = true end
            end
        end
        if opts.sell_all then
            for _, u in pairs(snap.units) do
                if not u.hero and u.alive and u.id ~= 1 and u.id ~= 2 then h:sell(u.id) end
            end
            snap = h:snapshot()
            credits = snap.credits - (opts.reserve or 0)
        end
        local placed = 0
        -- each route (front) gets an equal share of the credits, so the east road is not starved
        local share = credits / math.max(1, #routes)
        for _, route in ipairs(routes) do
            local budget = share
            local candidates, seen = {}, {}
            for i = 1, #route, 2 do
                local t = route[i]
                for dq = -2, 2 do
                    for dr = -2, 2 do
                        if distance(0, 0, dq, dr) <= 2 then
                            local q, r = t.q + dq, t.r + dr
                            local key = q .. "," .. r
                            if not seen[key] and not on_route[key] and not used[key] then
                                seen[key] = true
                                local info = h:tile(q, r)
                                if info and not info.wall and info.revealed and not info.unit then
                                    candidates[#candidates + 1] = {q = q, r = r}
                                end
                            end
                        end
                    end
                end
            end
            local function score(c)
                local total = 0
                for _, t in ipairs(route) do
                    if distance(c.q, c.r, t.q, t.r) <= 3 then
                        total = total + 1 / (1 + (covered[t.q .. "," .. t.r] or 0))
                    end
                end
                return total
            end
            while placed < limit and budget >= 10 and #candidates > 0 do
                local best, best_score, best_i = nil, 0, nil
                for i, c in ipairs(candidates) do
                    local sc = score(c)
                    if sc > best_score then best, best_score, best_i = c, sc, i end
                end
                if not best then break end
                local kind = kinds[(placed % #kinds) + 1]
                if budget < KIND_COST[kind] then kind = BOLT end
                if budget < KIND_COST[kind] then break end
                local ok = h:place(kind, best.q, best.r)
                table.remove(candidates, best_i)
                if ok then
                    budget = budget - KIND_COST[kind]
                    placed = placed + 1
                    for _, t in ipairs(route) do
                        if distance(best.q, best.r, t.q, t.r) <= 3 then
                            local key = t.q .. "," .. t.r
                            covered[key] = (covered[key] or 0) + 1
                        end
                    end
                end
            end
        end
        if opts.front then
            -- heroes stand on the road near the Lantern, where they can be hurt, spread out
            local route = routes[1]
            local f = opts.front_at or 0
            local g = opts.front_gap or 6
            local at = {#route - 12 - f, #route - 12 - g - f, #route - 12 - 2 * g - f}
            local i = 0
            for _, u in pairs(snap.units) do
                if u.hero then
                    i = i + 1
                    local t = route[math.max(1, at[i] or at[1])]
                    h:move_hero(u.id, t.q, t.r)
                end
            end
        end
        return placed
    end
end

-- Hero abilities: used when an enemy is within four tiles of the hero and the ability is ready.
function M.actor()
    return function(night, snap)
        for _, u in pairs(snap.units) do
            if u.hero and u.alive and u.ability_cd == 0 then
                for _, e in pairs(snap.enemies) do
                    if distance(u.q, u.r, e.q, e.r) <= 4 then
                        night.handle:use_ability(u.id, e.q, e.r)
                        break
                    end
                end
            end
        end
    end
end

-- Menu answers by style: a table from scene name to choice id; anything else takes the first.
M.STYLES = {
    ilse   = {m2_husks = :lamps, m2_wren = :cover, m3_mill = :militia, m3_east_light = :minute, m4_fallen = :rescue, m4_bell = :rally, m4_line = :stand},
    corvin = {m2_husks = :focus, m2_wren = :hold, m3_mill = :evacuate, m3_east_light = :notime, m4_fallen = :leave, m4_bell = :flare, m4_line = :retreat},
}

function M.chooser(style)
    local answers = M.STYLES[style] or {}
    return function(scene, choices)
        local want = answers[scene]
        for _, c in ipairs(choices) do
            if c.id == want then return c.id end
        end
        return choices[1].id
    end
end

-- The dusk: talk to everyone who is there (Ilse and Wren's kindness; Corvin's road), rebuild,
-- and go up. The talk choices follow the style so trust differs between styles.
local function dusk(s, style)
    local favourite = style == "ilse" and "let_her" or "back_her"
    G.choose(s, "talk_ilse", "let_her")
    G.choose(s, "talk_corvin", "road")
    G.choose(s, "talk_wren", "valley")
    for _, who in ipairs {:ilse, :corvin, :wren} do
        G.choose(s, "infirmary", "sit", {hero = who})
        G.choose(s, "remembrance", "light", {hero = who})
    end
    G.choose(s, "overlook", "look")
    for id = 1, 40 do
        if not G.choose(s, "rebuild", "mend", {id = id}) then break end
    end
end

-- A whole game. Returns the final session and a report of what happened each night.
function M.play(seed, style, opts)
    opts = opts or {}
    local s = G.new_session(seed)
    G.settle(s)
    local report = {nights = {}}
    for n = 1, 4 do
        dusk(s, style or "ilse")
        assert(G.choose(s, "go_up", "go"), "no way up at night " .. n)
        local outcome, night = G.run_night(s, {
            build = M.builder(opts.by_night and opts.by_night[n] or opts),
            choose = M.chooser(style or "ilse"),
            act = M.actor(),
            every = 10,
        })
        report.nights[n] = {result = outcome.result, kills = outcome.kills, leaks = outcome.leaks,
            steps = outcome.steps, digest = outcome.digest}
        if G.is_over(s) then break end
        -- dawn: bridge and scree decisions, then rest
        G.choose(s, "cut_bridge", "cut")
        G.choose(s, "clear_scree", "clear")
        assert(G.choose(s, "report", "rest"), "no dawn report at night " .. n)
        if G.is_over(s) or G.phase(s) == "over" then break end
    end
    report.ending = G.ending(s)
    return s, report
end

return M
