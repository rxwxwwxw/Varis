relation value(id, n) key(id)
relation blocked(1)
relation allowed(1)
rule allowed(?id) :- value(?id, ?n), not blocked(?id)
for id = 1, 20 do fact value(id, 0) end
local expected = {}
for id = 1, 20 do expected[id] = 0 end
local snapshots, values, discarded = {}, {}, {}
for step = 1, 100 do
    local id = step % 20 + 1
    local prior = expected[id]
    transaction do
        set value(id, step)
        fact blocked(id)
        assert((query allowed(id))() == nil)
        assert((query value(id, ?n))().n == step)
        transaction do
            adjust value(id) by 1
            rollback
        end
        assert((query value(id, ?n))().n == step)
        local frozen = query value(id, ?n)
        if step % 3 == 0 then
            discarded[#discarded + 1] = frozen
            rollback
        end
        snapshots[#snapshots + 1] = frozen
        values[#values + 1] = step
        retract blocked(id)
        assert((query allowed(id))() ~= nil)
        expected[id] = step
    end
    assert((query value(id, ?n))().n == expected[id])
    assert((query allowed(id))() ~= nil)
end
for index, iterator in ipairs(snapshots) do
    assert(iterator().n == values[index])
    assert(iterator() == nil)
end
for _, iterator in ipairs(discarded) do reject(iterator, "invalid query iterator") end
