-- PASS: child world inherits rules and facts only as of construction time.
relation edge(2)
relation reach(2)
fact edge(:a, :b)
rule reach(?x, ?y) :- edge(?x, ?y)
rule reach(?x, ?y) :- edge(?x, ?z), reach(?z, ?y)

local child = logic.world()

fact edge(:b, :c)       -- global only
fact child.edge(:b, :d) -- child only

local function check(iterator, expected)
    local count = 0
    for m in iterator do
        assert(expected[m.target], "unexpected reachability result")
        expected[m.target] = nil
        count = count + 1
    end
    assert(count == 2 and next(expected) == nil)
end

check(query reach(:a, ?target), {[:b] = true, [:c] = true})
check(query child.reach(:a, ?target), {[:b] = true, [:d] = true})

retract edge(:a, :b)
local global_count = 0
for _ in query reach(:a, ?target) do global_count = global_count + 1 end
assert(global_count == 0)
check(query child.reach(:a, ?target), {[:b] = true, [:d] = true})
print("PASS 07_world_snapshot_inheritance")
