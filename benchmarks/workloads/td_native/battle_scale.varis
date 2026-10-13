-- bench: the native battle at the plan's scales (TOWER_DEFENSE_PLAN.md section 9).
--   varis battle_scale.lua reference   2,000 live enemies, 200 towers, 6 heroes: step cost
--   varis battle_scale.lua stress      10,000 live enemies, 600 towers on 880 x 495 tiles: step cost
--   varis battle_scale.lua flow        the 435,600-tile map: setup, and a flow field per placement
--   varis battle_scale.lua judge       3,600 steps (three minutes) at reference scale, headless
--   varis battle_scale.lua bridge      setup with 200 structures, 20 syncs of 200 modifiers, outcome
-- The wall time of the process is what the gate in targets.toml bounds; the per-measure numbers
-- are printed to stderr and checked against the section 9 budgets with generous headroom.
local scenario = arg and arg[1] or "reference"

local function sectors(width, height)
    local list = {}
    for i = 1, math.ceil(width / 16) * math.ceil(height / 9) do list[i] = i end
    return list
end

-- An open lane along row 1, towers on row 2, `waves` waves of `each` enemies spawning one per step.
local function setup_for(width, height, towers, waves, each, structure_room)
    local s = {
        seed = 3, map_seed = 5, width = width, height = height, wall_density = 0,
        credits = 1000000, max_leaks = 1000000, structure_room = structure_room or 0,
        revealed = sectors(width, height),
        sinks = {{q = width - 2, r = 1}},
        sources = {{q = 1, r = 1, sink = 1}},
        towers = {
            {name = "bolt", cost = 1, range = 3, damage = 1, cooldown = 1, hp = 30, ability = "single"},
            {name = "sling", cost = 0, range = 3, damage = 1, cooldown = 5, hp = 1, ability = "single", buildable = false},
        },
        enemies = {{name = "dimling", hp = 1000000, speed = 64, armour = 0, bounty = 0, structure_damage = 0}},
        waves = {},
        structures = {},
        heroes = {},
    }
    for i = 1, towers do
        s.structures[i] = {id = i, kind = 1, q = 2 + (i - 1) % (width - 4), r = 2 + (i - 1) // (width - 4)}
    end
    for i = 1, waves do
        s.waves[i] = {source = 1, kind = 1, count = each, every = 1, start = 0}
    end
    for i = 1, 6 do
        s.heroes[i] = {id = 9000 + i, kind = 2, q = 10 * i, r = 4, hp = 70, obedience = 100}
    end
    return s
end

local function ms(a, b) return (b - a) * 1000 end

local function steps(h, n)
    local worst = 0
    local t0 = os.clock()
    for _ = 1, n do
        local a = os.clock()
        h:pump(1)
        local d = ms(a, os.clock())
        if d > worst then worst = d end
    end
    return ms(t0, os.clock()) / n, worst
end

local function report(name, value, budget)
    io.stderr:write(string.format("%s %.3f ms (budget %g)\n", name, value, budget))
    assert(value <= budget, name .. " over budget: " .. value)
end

if scenario == "reference" or scenario == "judge" then
    local h, why = battle.new(setup_for(220, 120, 200, 20, 100))
    assert(h, why)
    h:pump(120)
    assert(#h:snapshot().enemies >= 1900, "reference scale not reached")
    if scenario == "reference" then
        local mean, worst = steps(h, 300)
        report("reference step mean", mean, 2)    -- plan budget 1 ms on the M1
        report("reference step worst", worst, 10)
    else
        local t0 = os.clock()
        local state
        local left = 3600
        repeat
            state = h:pump(math.min(left, 500))
            left = 3600 - h:steps() + 120
        until left <= 0 or state ~= "running"
        report("judge 3,600 steps", ms(t0, os.clock()), 2000)
    end
elseif scenario == "stress" then
    local t0 = os.clock()
    local h, why = battle.new(setup_for(880, 495, 600, 100, 100))
    assert(h, why)
    io.stderr:write(string.format("stress setup %.1f ms\n", ms(t0, os.clock())))
    h:pump(110)
    assert(#h:snapshot().enemies >= 9000, "stress scale not reached")
    local mean, worst = steps(h, 100)
    report("stress step mean", mean, 8)          -- plan budget 4 ms on the M1
    report("stress step worst", worst, 30)
elseif scenario == "flow" then
    local t0 = os.clock()
    local h, why = battle.new(setup_for(880, 495, 0, 1, 1000000, 100))
    assert(h, why)
    report("435,600-tile setup", ms(t0, os.clock()), 150)
    -- a placement changes the routes; the next step rebuilds the flow fields, so time both
    h:pump(1)
    local a = os.clock()
    for _ = 1, 20 do h:pump(1) end
    local plain = ms(a, os.clock()) / 20
    a = os.clock()
    for i = 1, 20 do
        assert(h:place(1, 100 + i * 7, 200))
        h:pump(1)
    end
    local with = ms(a, os.clock()) / 20
    report("flow field per placement", with - plain, 12)   -- plan budget 8 ms on the M1
elseif scenario == "bridge" then
    local setup = setup_for(220, 120, 200, 1, 10)
    local a = os.clock()
    local h, why = battle.new(setup)
    assert(h, why)
    report("setup with 200 structures", ms(a, os.clock()), 100)      -- plan budget 50 ms
    local mods = {}
    for i = 1, 200 do mods[i] = {hero = 9001 + i % 6, damage = i % 5} end
    a = os.clock()
    for _ = 1, 20 do h:sync({hero_mods = mods, global = {damage = 10, bounty = 0}}) end
    report("sync of 200 modifiers", ms(a, os.clock()) / 20, 40)      -- plan budget 20 ms
    h:pump(50)
    a = os.clock()
    local o = h:outcome()
    assert(o.result == "running")
    report("outcome", ms(a, os.clock()), 100)                         -- plan budget 50 ms
else
    error("unknown scenario " .. tostring(scenario))
end
