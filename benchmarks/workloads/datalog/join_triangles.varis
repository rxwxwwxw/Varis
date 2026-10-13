-- bench: three-way join counting triangles in a deterministic pseudo-random graph
local w = logic.emptyworld()
local seed = 7
local function rnd(n) seed = (seed * 1103515245 + 12345) % 2147483648; return (seed // 65536) % n + 1 end
local function count(it) local n = 0 for _ in it do n = n + 1 end return n end
logic (w) do
    relation edge(2)
    local seen = {}
    for _ = 1, 2500 do
        local a, b = rnd(150), rnd(150)
        if a < b and not seen[a * 1000 + b] then seen[a * 1000 + b] = true; fact edge(a, b) end
    end
    local n = count(query { edge(?a, ?b), edge(?b, ?c), edge(?a, ?c) })
    assert(n > 0)
end
