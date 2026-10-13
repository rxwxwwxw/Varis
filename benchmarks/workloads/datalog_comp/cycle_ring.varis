-- Paired Datalog benchmark: cycle termination on a 30-node ring
local w = logic.emptyworld()
local N = 30
local function count(it) local n = 0 for _ in it do n = n + 1 end return n end
logic (w) do
    relation edge(2)
    for i = 1, N - 1 do fact edge(i, i + 1) end
    fact edge(N, 1)
    rule path(?x, ?y) :- edge(?x, ?y)
    rule path(?x, ?y) :- edge(?x, ?z), path(?z, ?y)
    local total = count(query path(?a, ?b))
    print(total)
end
