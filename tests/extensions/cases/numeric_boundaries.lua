-- Extension regression: numeric_boundaries
relation number(1)
local values = {9007199254740992, 9007199254740993, 9007199254740992.0,
                9223372036854775807, -9223372036854775807 - 1,
                9223372036854775808.0, -9223372036854775808.0, 0, -0.0, 1, 1.0}
for _, v in ipairs(values) do fact number(v) end
assert(count(query number(?v)) == 7, "numeric equality lost precision or hashing disagrees")
assert(count(query number(9007199254740993)) == 1)
assert(count(query number(9223372036854775807)) == 1)
retract number(9007199254740992.0)
assert(count(query number(9007199254740993)) == 1)
assert(count(query number(?v)) == 6)
