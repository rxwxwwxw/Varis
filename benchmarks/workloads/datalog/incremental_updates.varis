-- bench: repeated fact insertion / retraction with re-query (invalidation and recomputation)
local w = logic.emptyworld()
local function count(it) local n = 0 for _ in it do n = n + 1 end return n end
logic (w) do
    relation edge(2)
    for i = 1, 40 do fact edge(i, i + 1) end
    rule path(?x, ?y) :- edge(?x, ?y)
    rule path(?x, ?y) :- edge(?x, ?z), path(?z, ?y)
    local total = 0
    for k = 1, 25 do
        retract edge(k, k + 1)
        total = total + count(query path(1, ?t))
        fact edge(k, k + 1)
    end
    assert(count(query path(1, ?t)) == 40)
    assert(total > 0)
end
