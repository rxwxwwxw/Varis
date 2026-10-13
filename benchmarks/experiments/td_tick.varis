-- Tower-defense tick spike (TOWER_DEFENSE_PLAN.md, stage TD0 starting point).
-- Not part of `tools/suite bench`; it is the reproducible source of the numbers in
-- TOWER_DEFENSE_PLAN.md section 1.
--
--   bin/varis benchmarks/experiments/td_tick.lua tick ENEMIES TOWERS [RANGE] [sort]
--   bin/varis benchmarks/experiments/td_tick.lua facts COUNT
--
--   tick   One simulation step on an open hex field (100 x 60 tiles, flow field to one sink):
--          move every enemy one tile, pick one target per tower (nearest the sink, ties to the
--          lowest id), sum the damage per enemy, apply it, all in one transaction. Prints the
--          milliseconds per phase and in total (CPU, median of 10 steps). `sort` orders the
--          moves by enemy id before applying them: it is not needed here (a `set` per distinct
--          key commutes) and costs about three times the writes themselves.
--   facts  Cost of holding COUNT keyed tuples of a map-like relation: load time, heap, the first
--          query (which builds the index) and a write after the load.
--
-- Everything is integers. Rule heads cannot compute (manual 4.4), so geometry is materialised:
-- the flow field (`flow`, `route_dist`) is computed once on the host side and each tower's
-- footprint (`covers`) when it is placed. Query results are unordered (manual 4.8), so code
-- whose effect depends on order (id allocation, random draws) must sort first; this one does not.
local MODE = arg[1] or "tick"

local function ms(since) return (os.clock() - since) * 1000 end

if MODE == "facts" then
    local K = tonumber(arg[2]) or 100000
    local w = logic.emptyworld()
    logic (w) do relation flow(tile, nxt) key(tile) end
    local t0 = os.clock()
    logic (w) do for i = 1, K do set flow(i, i + 1) end end
    local load = ms(t0)
    collectgarbage()
    local heap = collectgarbage("count") / 1024
    local t1 = os.clock()
    logic (w) do for _ in query flow(1234, ?n) do end end
    local first = ms(t1)
    local t2 = os.clock()
    logic (w) do set flow(5, 99) end
    print(string.format("%d keyed facts: load %.0f ms (%.2f us/fact), heap %.1f MB, first query %.2f ms, "
        .. "one set afterwards %.3f ms", K, load, load * 1000 / K, heap, first, ms(t2)))
    return
end

local W, H = 100, 60
local NE = tonumber(arg[2]) or 1000
local NT = tonumber(arg[3]) or 120
local RANGE = tonumber(arg[4]) or 3
local SORT = arg[5] == "sort"

-- Packed axial hex id: one integer per tile, so a tile is a single join key.
local function id(q, r) return (q + 1000) * 4096 + (r + 1000) end
local dirs = { {1,0}, {1,-1}, {0,-1}, {-1,0}, {-1,1}, {0,1} }
local function inside(q, r) return q >= 0 and q < W and r >= 0 and r < H end

-- Breadth-first flow field towards the sink in the far corner (host side, once).
local sink = id(W - 1, H - 1)
local dist, flow = { [sink] = 0 }, {}
local queue, head = { { W - 1, H - 1 } }, 1
while head <= #queue do
    local q, r = queue[head][1], queue[head][2]; head = head + 1
    for _, d in ipairs(dirs) do
        local nq, nr = q + d[1], r + d[2]
        if inside(nq, nr) and not dist[id(nq, nr)] then
            dist[id(nq, nr)] = dist[id(q, r)] + 1
            flow[id(nq, nr)] = id(q, r)
            queue[#queue + 1] = { nq, nr }
        end
    end
end

local w = logic.emptyworld()
logic (w) do
    relation flow(tile, nxt) key(tile)
    relation route_dist(tile, d) key(tile)
    relation enemy_at(id, tile) key(id)
    relation enemy_hp(id, hp) key(id)
    relation tower_at(id, tile) key(id)
    relation tower_dmg(id, dmg) key(id)
    relation covers(tower, tile)
    relation cooldown(tower, t) key(tower)

    -- The enemy nearest the sink among those in range; ties go to the lowest enemy id.
    rule best(?t, ?d) :- tower_at(?t, ?_), cooldown(?t, 0),
        ?d = min { ?x : covers(?t, ?tile), enemy_at(?_, ?tile), route_dist(?tile, ?x) }
    rule pick(?t, ?e) :- best(?t, ?d),
        ?e = min { ?id : covers(?t, ?tile), enemy_at(?id, ?tile), route_dist(?tile, ?d) }
    rule incoming(?e, ?d) :- enemy_hp(?e, ?_), ?d = sum { ?x : pick(?t, ?e), tower_dmg(?t, ?x) }
end

logic (w) do
    for tile, nxt in pairs(flow) do set flow(tile, nxt) end
    for tile, d in pairs(dist) do set route_dist(tile, d) end
    for i = 1, NE do
        set enemy_at(i, id((i * 7) % 20, (i * 11) % H))
        set enemy_hp(i, 1000000)
    end
    for j = 1, NT do
        local cq, cr = 25 + (j * 13) % 60, (j * 17) % H
        fact tower_at(j, id(cq, cr))
        set cooldown(j, 0)
        set tower_dmg(j, 3)
        -- hex disc of radius RANGE around the tower
        for dq = -RANGE, RANGE do
            for dr = math.max(-RANGE, -dq - RANGE), math.min(RANGE, -dq + RANGE) do
                if inside(cq + dq, cr + dr) then fact covers(j, id(cq + dq, cr + dr)) end
            end
        end
    end
end

local STEPS = 10
local samples = { {}, {}, {}, {} }
for _ = 1, STEPS do
    logic (w) do
        transaction (w) do
            local t = os.clock()
            local moves = {}
            for r in query { enemy_at(?e, ?tile), flow(?tile, ?n) } do moves[#moves + 1] = r end
            samples[1][#samples[1] + 1] = ms(t); t = os.clock()
            if SORT then table.sort(moves, function(a, b) return a.e < b.e end) end
            for _, r in ipairs(moves) do set enemy_at(r.e, r.n) end
            samples[2][#samples[2] + 1] = ms(t); t = os.clock()
            local hits = {}
            for r in query incoming(?e, ?d) do if r.d > 0 then hits[#hits + 1] = r end end
            samples[3][#samples[3] + 1] = ms(t); t = os.clock()
            for _, r in ipairs(hits) do adjust enemy_hp(r.e) by -r.d end
            samples[4][#samples[4] + 1] = ms(t)
        end
    end
end
local function median(list) table.sort(list); return list[(#list + 1) // 2] end
local m = { median(samples[1]), median(samples[2]), median(samples[3]), median(samples[4]) }
print(string.format("enemies=%d towers=%d range=%d: move-query %.2f, apply-moves %.2f, "
    .. "target+damage-query %.2f, apply-damage %.2f, total %.2f ms/step",
    NE, NT, RANGE, m[1], m[2], m[3], m[4], m[1] + m[2] + m[3] + m[4]))
