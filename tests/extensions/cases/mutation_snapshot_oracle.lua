-- A deterministic model checks repeated mutations and delayed snapshots.
relation present(1) relation banned(1) relation allowed(1)
rule allowed(?x) :- present(?x), not banned(?x)
local model, bans, snapshots, sizes = {}, {}, {}, {}
local state = 17
for step = 1, 250 do
    state = (state * 109 + 89) % 65536
    local x = state % 32
    local op = (state // 32) % 4
    if op == 0 then fact present(x) model[x] = true
    elseif op == 1 then retract present(x) model[x] = nil
    elseif op == 2 then fact banned(x) bans[x] = true
    else retract banned(x) bans[x] = nil end
    local wanted = 0
    for v in pairs(model) do if not bans[v] then wanted = wanted + 1 end end
    local seen, actual = {}, 0
    for row in query allowed(?x) do
        assert(model[row.x] and not bans[row.x] and not seen[row.x])
        seen[row.x] = true actual = actual + 1
    end
    assert(actual == wanted)
    if step % 5 == 0 then
        snapshots[#snapshots + 1] = query allowed(?x)
        sizes[#sizes + 1] = wanted
    end
end
for i, q in ipairs(snapshots) do
    assert(count(q) == sizes[i], "old snapshot changed after later mutation")
end
