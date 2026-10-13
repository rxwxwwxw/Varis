-- Battle setups for Lanternfall: the map of the terraces, and the table the battle bridge reads
-- (TOWER_DEFENSE_PLAN.md §5.2). Indices are 1-based, as in Lua. The map is the same every night;
-- what changes is how much of it the fog has given back and what the story has written on it.
--
--   The Lantern burns at the top left. The Dim climbs from the valley by four terraces, each
--   cut off from the next by a cliff row with one gap, so the road switches back and forth.
--   From the third night a second road comes down from the east to the Mill.

local kinds = require("battle.kinds")
local waves = require("battle.waves")

local M = {}

M.WIDTH, M.HEIGHT = 96, 54
M.LANTERN = {q = 6, r = 3}
M.MILL = {q = 72, r = 10}
M.BELLFREY = {q = 9, r = 3}
M.MILL_HOUSE = {q = 73, r = 9}
M.HERO_ID = {ilse = 9001, corvin = 9002, wren = 9003}

-- Fog sectors are 16 x 9 tiles, six across. A k x k block from the top left is what the warden
-- has seen after night k-2: 48 x 27, 64 x 36, 80 x 45, 96 x 54.
function M.sectors(k)
    local list = {}
    for row = 0, k - 1 do
        for col = 0, k - 1 do
            list[#list + 1] = row * 6 + col + 1
        end
    end
    return list
end

local CLIFFS = {
    {r = 13, from = 38, to = 46},   -- the gap to the Lantern terrace
    {r = 27, from = 2,  to = 10},   -- the gap on the left
    {r = 41, from = 38, to = 46},
}

-- The designed walls: cliffs with gaps, boulders that make lanes, and the sealed east road.
function M.edits()
    local list = {}
    for _, c in ipairs(CLIFFS) do
        for q = 0, M.WIDTH - 1 do
            if q < c.from or q > c.to then list[#list + 1] = {q = q, r = c.r, wall = true} end
        end
    end
    -- the Lantern's gate: a ring of walls three tiles out, one gap at (9, 3) where the Bellfrey
    -- stands. While the bell stands the Dim must break it to reach the flame.
    for dq = -3, 3 do
        for dr = -3, 3 do
            if math.max(math.abs(dq), math.abs(dr), math.abs(dq + dr)) == 3 then
                local q, r = M.LANTERN.q + dq, M.LANTERN.r + dr
                if q >= 0 and r >= 0 and not (q == M.BELLFREY.q and r == M.BELLFREY.r) then
                    list[#list + 1] = {q = q, r = r, wall = true}
                end
            end
        end
    end
    for band = 0, 3 do
        local r0 = band * 14
        for _, q in ipairs({16, 28, 52, 66}) do
            for r = r0 + 4, r0 + 8 do
                if q < 70 or r > 12 then list[#list + 1] = {q = q, r = r, wall = true} end
            end
        end
    end
    -- the east road: a sealed region with a three-wide corridor from (78, 3) to the Mill (72, 10)
    for r = 0, 12 do
        for q = 69, 79 do
            local corridor = (q >= 71 and q <= 78 and r >= 2 and r <= 4)
                or (q >= 71 and q <= 73 and r >= 5 and r <= 10)
            list[#list + 1] = {q = q, r = r, wall = not corridor}
        end
    end
    return list
end

-- Night n's source on the road below the terraces: the bottom right of what is revealed.
local function road_source(night)
    local k = math.min(night + 2, 5)
    return {q = 16 * k - 2, r = 9 * k - 2}
end

-- Heroes start on the Lantern terrace, away from the road's end.
local START = {ilse = {q = 10, r = 1}, corvin = {q = 16, r = 1}, wren = {q = 22, r = 1}}
M.START = START

local MOMENTS = {
    [1] = {
        {trigger = "wave_start", arg = 1, scene = "m1_wren"},
    },
    [2] = {
        {trigger = "enemy_kind_seen", arg = 3, scene = "m2_husks", needs = {"ilse", "corvin"}},
        {trigger = "hero_hp_below", hero = "wren", arg2 = 40, scene = "m2_wren", needs = {"wren"}},
    },
    [3] = {
        {trigger = "heroes_near", hero = "ilse", hero2 = "corvin", arg3 = 3, scene = "m3_together", needs = {"ilse", "corvin"}},
        {trigger = "leak_count", arg = 5, scene = "m3_mill"},
        {trigger = "step", arg = 1200, scene = "m3_east_light", needs = {"ilse"}},
    },
    [4] = {
        {trigger = "wave_start", arg = 3, scene = "m4_maw"},
        {trigger = "hero_downed", arg = 0, scene = "m4_fallen"},
        {trigger = "structure_destroyed", arg = 1, scene = "m4_bell"},
        {trigger = "leak_count", arg = 12, scene = "m4_line"},
        {trigger = "battle_won", scene = "m4_won"},
        {trigger = "battle_lost", scene = "m4_lost"},
    },
}

-- Night n from the facts the world gave the host (see game.lua `battle_setup`):
--   data.credits, data.structures, data.heroes, data.edits, data.revealed, data.next_id
function M.night(n, data)
    local source = road_source(n)
    local edits = M.edits()
    for _, e in ipairs(data.edits or {}) do edits[#edits + 1] = e end
    local k = math.min(n + 2, 5)
    local setup = {
        seed = 7000 + n, map_seed = 11, width = M.WIDTH, height = M.HEIGHT,
        wall_density = 0, terrace_rows = 14, attack_every = 10,
        credits = data.credits, max_leaks = ({10, 6, 8, 14})[n],
        moment_cap = n, structure_room = 40,
        first_structure_id = data.next_id,
        edits = edits,
        revealed = data.revealed or M.sectors(k),
        sinks = {{q = M.LANTERN.q, r = M.LANTERN.r}},
        sources = {{q = source.q, r = source.r, sink = 1}},
        towers = kinds.towers,
        enemies = kinds.enemies,
        structures = data.structures or {},
        heroes = data.heroes or {},
        waves = {},
        moments = {},
    }
    if n >= 3 then
        setup.sinks[2] = {q = M.MILL.q, r = M.MILL.r}
        setup.sources[2] = {q = 78, r = 3, sink = 2}
    end
    for _, w in ipairs(waves[n] or {}) do
        setup.waves[#setup.waves + 1] = {source = w.source, kind = w.kind, count = w.count, every = w.every, start = w.start}
    end
    if n == 4 then setup.moment_cap = 4 end
    -- a moment is listed only when the heroes it needs are on the road
    local here, standing = {}, {}
    for _, h in ipairs(setup.heroes) do here[h.id] = true end
    for _, st in ipairs(setup.structures) do standing[st.id] = true end
    local id = 0
    for _, m in ipairs(MOMENTS[n] or {}) do
        local ok = true
        if m.trigger == "structure_destroyed" and not standing[m.arg] then ok = false end
        for _, who in ipairs(m.needs or {}) do
            if not here[M.HERO_ID[who]] then ok = false end
        end
        if ok then
            id = id + 1
            local arg = m.arg
            if m.hero then arg = M.HERO_ID[m.hero] end
            local arg2 = m.arg2
            if m.hero2 then arg2 = M.HERO_ID[m.hero2] end
            setup.moments[#setup.moments + 1] = {
                id = id, trigger = m.trigger, arg = arg, arg2 = arg2, arg3 = m.arg3, scene = m.scene,
            }
        end
    end
    return setup
end

return M
