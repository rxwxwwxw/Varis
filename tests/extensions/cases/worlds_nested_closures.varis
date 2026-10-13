-- Extension regression: worlds_nested_closures
local a, b = logic.emptyworld(), logic.emptyworld()
local fa, fb
logic (a) do
    relation p(1) fact p(1)
    fa = function() return query p(?x) end
    logic (b) do
        relation p(1) fact p(2)
        fb = function() return query p(?x) end
    end
    assert((query p(?x))().x == 1)
end
assert(fa()().x == 1 and fb()().x == 2)
local child = logic.world(a)
fact a.p(3) retract child.p(1) fact child.p(4)
assert(count(query a.p(?x)) == 2 and (query child.p(?x))().x == 4)
