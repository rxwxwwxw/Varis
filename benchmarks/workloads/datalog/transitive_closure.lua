-- bench: recursive transitive closure (left+right recursion) over a 90-node chain, fresh world per run
local w = logic.emptyworld()
local N = 90
local function count(it) local n = 0 for _ in it do n = n + 1 end return n end
logic (w) do
    relation edge(2)
    for i = 1, N - 1 do fact edge(i, i + 1) end
    rule right(?x, ?y) :- edge(?x, ?y)
    rule right(?x, ?y) :- edge(?x, ?z), right(?z, ?y)
    assert(count(query right(?a, ?b)) == N * (N - 1) // 2)
    assert(count(query right(1, ?t)) == N - 1)
end
