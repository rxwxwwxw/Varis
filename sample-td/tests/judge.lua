-- The silent judge (SAMPLE_TD_PLAN.md §6.5): a raid on a copy chips a tower and shows nothing; the
-- forecast on another copy records what would fall and changes no structure. Both are
-- deterministic and neither touches the world apart from the forecast's facts.
--
--   bin/varis sample-td/tests/judge.lua        (from the repository root)

package.path = "sample-td/?.lua;" .. package.path
local G = require("game")
local bot = require("tools.bot")

local function night_two()
    local s = G.new_session(1)
    G.settle(s)
    assert(G.choose(s, "go_up", "go"))
    G.run_night(s, {build = bot.builder({towers = 3}), every = 10})
    assert(G.choose(s, "report", "rest"))
    assert(G.choose(s, "go_up", "go"))
    return s
end

local function structure_rows(s)
    local rows = {}
    logic (s:world()) do
        for r in query structure(?id, ?k, ?q, ?r, ?l, ?h) do
            rows[#rows + 1] = string.format("%d:%d:%d:%d:%d:%d", r.id, r.k, r.q, r.r, r.l, r.h)
        end
    end
    table.sort(rows)
    return table.concat(rows, ";")
end

-- The raid: nothing is shown and the world is byte-identical; a tower starts the night chipped.
local s = night_two()
local night = assert(G.start_battle(s))
local before = {}
for _, u in pairs(night.handle:snapshot().units) do before[u.id] = u.hp end
local world_before = s:save()
local result = G.judge(night)
assert(s:save() == world_before, "the raid wrote to the world")
local chipped = 0
for _, u in pairs(night.handle:snapshot().units) do
    if before[u.id] and u.hp < before[u.id] then chipped = chipped + 1 end
end
assert(chipped == result.chipped, "chipped " .. chipped .. " vs reported " .. result.chipped)
assert(chipped <= 1, "the raid chips the thinnest tower, not all of them")

-- deterministic: the same night judged again chips the same tower by the same amount
local s2 = night_two()
local night2 = assert(G.start_battle(s2))
G.judge(night2)
local a, b = night.handle:snapshot().units, night2.handle:snapshot().units
for i = 1, #a do assert(a[i].hp == b[i].hp, "the judge is not deterministic at unit " .. i) end
assert(night.handle:digest() == night2.handle:digest())

-- the forecast: facts only, no structure changes; replaced by the next forecast
local rows = structure_rows(s)
local f1 = G.forecast(s, 2)
assert(structure_rows(s) == rows, "the forecast changed a structure")
local weak = 0
logic (s:world()) do for _ in query weak(?x) do weak = weak + 1 end end
assert(weak == f1.weak, "weak facts " .. weak .. " vs " .. f1.weak)
local f2 = G.forecast(s, 2)
assert(f2.weak == f1.weak and f2.leaks == f1.leaks, "the forecast is not deterministic")
weak = 0
logic (s:world()) do for _ in query weak(?x) do weak = weak + 1 end end
assert(weak == f2.weak, "a forecast replaces the previous one")
print("judge: raid chipped " .. chipped .. ", forecast " .. f1.weak .. " weak, " .. f1.leaks .. " leaks")
print("checks passed")
