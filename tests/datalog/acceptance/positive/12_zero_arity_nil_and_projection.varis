-- PASS: zero-arity relations, nil/false/zero tuples, anonymous-variable projection.
relation ready(0)
relation absent(0)
relation payload(2)
fact ready()
fact payload(:a, nil)
fact payload(:a, false)
fact payload(:a, 0)

local ready_count = 0
for binding in query ready() do
    assert(binding ~= nil)
    ready_count = ready_count + 1
end
assert(ready_count == 1)

local absent_count = 0
for _ in query absent() do absent_count = absent_count + 1 end
assert(absent_count == 0)

local nil_count, false_count, zero_count = 0, 0, 0
for binding in query payload(:a, ?value) do
    assert(logic.hasbinding(binding, "value"))
    local v = logic.binding(binding, "value")
    if v == nil then
        nil_count = nil_count + 1
    elseif v == false then
        false_count = false_count + 1
    elseif v == 0 then
        zero_count = zero_count + 1
    else
        error("unexpected payload value")
    end
end
assert(nil_count == 1 and false_count == 1 and zero_count == 1)

-- Anonymous variable is omitted from the result; projection deduplicates :a.
local projected = 0
for binding in query payload(?key, ?_) do
    assert(binding.key == :a)
    projected = projected + 1
end
assert(projected == 1)
print("PASS 12_zero_arity_nil_and_projection")
