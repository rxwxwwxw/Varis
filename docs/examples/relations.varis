-- Varis reference example: closure, snapshots, nil bindings, and worlds.
fact edge(:a, :b)
fact edge(:b, :c)
rule path(?x, ?y) :- edge(?x, ?y)
rule path(?x, ?y) :- edge(?x, ?z), path(?z, ?y)

local old = query path(:a, ?destination)
fact edge(:c, :d)
local seen = {}
for row in old do seen[row.destination] = true end
assert(seen[:b] and seen[:c] and not seen[:d])

local function reachable_from(start)
    local relation reached(1)
    rule reached(?x) :- path(start, ?x)
    return query reached(?destination)
end
local count = 0
for row in reachable_from(:a) do count = count + 1 end
assert(count == 3)

fact optional(nil)
local row = (query optional(?value))()
assert(row.value == nil)
assert(logic.hasbinding(row, "value"))
assert(not logic.hasbinding(row, "missing"))
assert(logic.binding(row, "value") == nil)

local child = logic.world()
retract edge(:c, :d)
assert((query child.path(:a, :d))() ~= nil)
assert((query path(:a, :d))() == nil)
-- Queries can join snapshots of independent worlds; rules cannot.
assert((query { child.path(:a, ?target), path(:a, ?target) })() ~= nil)
print("relations: ok")
