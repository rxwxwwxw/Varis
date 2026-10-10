-- PASS: stratified negation, retraction, and derived-tuple invalidation.
relation room(1)
relation blocked(1)
relation available(1)

fact room(:a)
fact room(:b)
fact blocked(:a)

rule available(?r) :- room(?r), not blocked(?r)

local function check(a, b)
    local seen = {}
    local n = 0
    for m in query available(?room) do
        assert(not seen[m.room])
        seen[m.room] = true
        n = n + 1
    end
    assert(n == (a and 1 or 0) + (b and 1 or 0))
    assert(not not seen[:a] == not not a)
    assert(not not seen[:b] == not not b)
end

check(false, true)
retract blocked(:a)
check(true, true)
fact blocked(:b)
check(true, false)
retract blocked(:b)
check(true, true)

-- A base tuple can be retracted while the same tuple remains derivable.
fact available(:a)
retract available(:a)
check(true, true)
print("PASS 03_stratified_negation_and_retraction")
