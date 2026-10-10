-- bench: stratified negation: reachable / unreachable partition of a layered graph
local w = logic.emptyworld()
local function count(it) local n = 0 for _ in it do n = n + 1 end return n end
logic (w) do
    relation node(1)
    relation edge(2)
    for i = 1, 150 do fact node(i) end
    for i = 1, 100 do fact edge(i, i + 1) end
    for i = 102, 149 do fact edge(i, i + 1) end
    fact root(1)
    rule reach(?x) :- root(?x)
    rule reach(?y) :- reach(?x), edge(?x, ?y)
    rule unreachable(?x) :- node(?x), not reach(?x)
    assert(count(query reach(?x)) == 101)
    assert(count(query unreachable(?x)) == 49)
end
