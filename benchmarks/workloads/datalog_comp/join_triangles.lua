-- Paired Datalog benchmark: triangle counting in deterministic pseudo-random graph
local w = logic.emptyworld()
local function count(it) local n = 0 for _ in it do n = n + 1 end return n end
logic (w) do
    relation edge(2)
    for line in io.lines("benchmarks/workloads/datalog_comp/join_triangles_edge.facts") do
        local a, b = line:match("(%d+)%s+(%d+)")
        fact edge(tonumber(a), tonumber(b))
    end
    local total = count(query { edge(?a, ?b), edge(?b, ?c), edge(?a, ?c) })
    print(total)
end
