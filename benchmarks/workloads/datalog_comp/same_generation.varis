-- Paired Datalog benchmark: same generation on binary tree of depth 5 (63 nodes)
local w = logic.emptyworld()
local function count(it) local n = 0 for _ in it do n = n + 1 end return n end
logic (w) do
    relation node(1)
    relation parent(2)
    for i = 1, 63 do
        fact node(i)
        if i > 1 then fact parent(i // 2, i) end
    end
    rule sg(?x, ?x) :- node(?x)
    rule sg(?x, ?y) :- parent(?p, ?x), sg(?p, ?q), parent(?q, ?y)
    local total = count(query sg(?x, ?y))
    print(total)
end
