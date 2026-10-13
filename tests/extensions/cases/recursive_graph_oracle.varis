-- Extension regression: recursive_graph_oracle
-- Deterministic generated graphs; Floyd-Warshall is independent of rule evaluation.
for trial = 1, 6 do
    local w = logic.emptyworld()
    local n = 12 + trial
    local expected = {}
    for i = 1, n do expected[i] = {} end
    logic (w) do
        relation edge(2) relation reach(2)
        for i = 1, n do
            for j = 1, n do
                if (i * 37 + j * 19 + trial * 11) % 17 < 2 then
                    fact edge(i, j) fact edge(i, j)
                    expected[i][j] = true
                end
            end
        end
        rule reach(?x, ?y) :- edge(?x, ?y)
        rule reach(?x, ?y) :- reach(?x, ?z), edge(?z, ?y)
        for k = 1, n do for i = 1, n do for j = 1, n do
            if expected[i][k] and expected[k][j] then expected[i][j] = true end
        end end end
        local seen, total = {}, 0
        for row in query reach(?x, ?y) do
            assert(expected[row.x][row.y], "unexpected closure tuple")
            local key = row.x * (n + 1) + row.y
            assert(not seen[key], "duplicate closure tuple")
            seen[key] = true total = total + 1
        end
        local wanted = 0
        for i = 1, n do for j = 1, n do
            if expected[i][j] then wanted = wanted + 1 end
        end end
        assert(total == wanted, "missing closure tuple")
    end
end
