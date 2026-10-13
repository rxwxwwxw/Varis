-- Extension regression: symbols_binary
relation value(1)
local names = {"", "a\0b", "a\0c", "\255\128", "query", "a:b"}
for _, name in ipairs(names) do
    local s = symbol(name)
    assert(s == logic.symbol(name) and symbol(s) == s)
    assert(logic.symbolname(s) == name and type(s) == "symbol")
    assert(s ~= name)
    fact value(s) fact value(name)
end
assert(count(query value(?v)) == 12)
local keys = {}
keys[symbol("a\0b")] = 42
assert(keys[logic.symbol("a\0b")] == 42 and keys[symbol("a\0c")] == nil)
reject(function() symbol(1) end, "string expected")
reject(function() logic.symbolname("a") end, "symbol expected")
