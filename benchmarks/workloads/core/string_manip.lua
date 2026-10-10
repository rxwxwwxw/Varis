-- bench: 100k substring + concatenation operations
local s = "abcdefghijklmnopqrstuvwxyz"
for i = 1, 100000 do s = string.sub(s, 2) .. "a" end
assert(s == string.rep("a", 26))
