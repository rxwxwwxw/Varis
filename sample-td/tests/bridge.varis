-- The bridge refuses a bad setup, names the field, and leaves the world byte-identical; a battle
-- can be abandoned (the snapshot comes back exactly); no save is possible during a battle.
--
--   bin/varis sample-td/tests/bridge.lua        (from the repository root)

package.path = "sample-td/?.lua;" .. package.path
local G = require("game")

local function fresh()
    local s = G.new_session(1)
    G.settle(s)
    assert(G.choose(s, "go_up", "go"))
    return s
end

-- Each fixture breaks one thing in the setup; the refusal names the field and nothing changes.
local fixtures = {
    {name = "an unknown tower kind", field = "structures.kind", tweak = function(t)
        t.structures[#t.structures + 1] = {id = 77, kind = 99, q = 20, r = 5}
    end},
    {name = "a tile off the map", field = "structures", tweak = function(t)
        t.structures[#t.structures + 1] = {id = 77, kind = 1, q = 500, r = 5}
    end},
    {name = "a missing sink", field = "sinks", tweak = function(t) t.sinks = {} end},
    {name = "a moment naming an unknown scene", field = "moments.scene", tweak = function(t)
        -- built at run time so that `varis check` does not see (and report) the bad name
        t.moments[#t.moments + 1] = {id = 99, trigger = "step", arg = 5, scene = "no_such_" .. "scene"}
    end},
    {name = "a duplicate moment id", field = "moments.id", tweak = function(t)
        t.moments[#t.moments + 1] = {id = t.moments[1].id, trigger = "step", arg = 5, scene = "m1_wren"}
    end},
    {name = "a source that cannot reach its sink", field = "sources", tweak = function(t)
        local src = t.sources[1]
        for dq = -1, 1 do
            for dr = -1, 1 do
                t.edits[#t.edits + 1] = {q = src.q + dq, r = src.r + dr, wall = true}
            end
        end
        t.edits[#t.edits + 1] = {q = src.q, r = src.r, wall = false}
    end},
    {name = "a wave naming no enemy kind", field = "waves.kind", tweak = function(t)
        t.waves[1].kind = 42
    end},
}
for _, f in ipairs(fixtures) do
    local s = fresh()
    local before = s:save()
    local night, problem = G.start_battle(s, f.tweak)
    assert(night == nil, f.name .. " was accepted")
    assert(tostring(problem):find(f.field, 1, true), f.name .. ": field not named in '" .. tostring(problem) .. "'")
    assert(s:save() == before, f.name .. ": the world changed")
    assert(not G.battle_active(), f.name .. ": the host thinks a battle is running")
end
print("bridge: " .. #fixtures .. " bad setups refused, world unchanged")

-- Abandon: the snapshot taken at the start returns byte for byte, moments' writes undone.
local s = fresh()
local night = assert(G.start_battle(s))
local start = night.snapshot
assert(G.battle_active())
-- a battle in progress cannot be saved, in any phase
local ok, err = pcall(G.save, s)
assert(not ok and tostring(err):find("battle is in progress"), tostring(err))
night.handle:place(1, 44, 22)
assert(night.handle:pump(100) == "moment", "night 1 has its moment at the first wave")
G.play_moment(night)                     -- the scene writes a flag and a fact
assert(G.has_flag(s, :wren_joined))
ok, err = pcall(G.save, s)               -- ... even inside a moment's aftermath
assert(not ok and tostring(err):find("battle is in progress"), tostring(err))
local restored = G.abandon(night)
assert(not G.battle_active())
assert(restored:save() == start, "abandon did not restore the snapshot")
assert(not G.has_flag(restored, :wren_joined), "the moment's write survived the abandon")
assert(G.phase(restored) == "build" and G.battle_request(restored).night == 1,
    "Continue starts the battle again: the request is still there")
assert(type(G.save(restored)) == "string")
print("bridge: abandon restores the world exactly; no save during a battle")
print("checks passed")
