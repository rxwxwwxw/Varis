-- Paired Datalog benchmark: transitive closure over a 50-node chain
local w = logic.emptyworld()
local N = 50
local function count(it) local n = 0 for _ in it do n = n + 1 end return n end
logic (w) do
    relation edge(2)
    for i = 1, N - 1 do fact edge(i, i + 1) end
    rule right(?x, ?y) :- edge(?x, ?y)
    rule right(?x, ?y) :- edge(?x, ?z), right(?z, ?y)
    local total = count(query right(?a, ?b))
    print(total)
end
