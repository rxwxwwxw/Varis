-- Spec §2.1-2.2, §15.2: symbols are interned, immutable values distinct from strings.
--
-- How to read: every `expect(label, got, want)` asserts got == want and prints
-- "label<TAB>got". The expected output file is just those lines in order.
-- The final section is the benchmark: N dynamically built names that collapse
-- onto K distinct symbols, so exactly K table keys must exist afterwards.
local SCALE = (arg and arg[1]) or "small"
local P = ({
    small = { names = 12,     distinct = 4 },
    large = { names = 300000, distinct = 1000 },
})[SCALE] or error("unknown scale: " .. tostring(SCALE))

local function expect(label, got, want)
    assert(got == want, label .. ": got " .. tostring(got) .. ", want " .. tostring(want))
    print(label, got)
end
local function rejects(label, fn, fragment)
    local ok, err = pcall(fn)
    assert(not ok, label .. ": expected an error")
    assert(string.find(tostring(err), fragment, 1, true),
           label .. ": wrong error: " .. tostring(err))
    print(label, "error")
end

-- Literals with the same name are the same value; different names differ.
local a, b, c = :node1, :node1, :node2
expect("same name equal", a == b, true)
expect("different name unequal", a ~= c, true)
expect("type", type(a), "symbol")

-- Symbols and strings never compare equal, in either direction.
expect("symbol vs string", :lava == "lava", false)
expect("string vs symbol", "lava" == :lava, false)

-- symbol() and logic.symbol() build the same interned value as the literal.
expect("symbol() equals literal", symbol("lava") == :lava, true)
expect("logic.symbol() equals literal", logic.symbol("lava") == :lava, true)
expect("symbol(symbol) is identity", symbol(:lava) == :lava, true)
expect("symbolname", logic.symbolname(:lava), "lava")

-- tostring: plain identifiers print as :name, anything else is quoted.
expect("tostring identifier", tostring(:lava), ":lava")
expect("tostring quoted", tostring(symbol("two words")), ':"two words"')

-- Dynamic names may contain bytes no literal could: empty, NUL, high bytes.
local odd = { "", "a\0b", "a\0c", "\255\128" }
for i, name in ipairs(odd) do
    expect("binary name " .. i .. " round trip", logic.symbolname(symbol(name)) == name, true)
end
expect("NUL names differ after NUL", symbol("a\0b") ~= symbol("a\0c"), true)

-- Symbols are usable as table keys; a string with the same text is another key.
local t = { [:red] = 1, red = 2 }
expect("key :red", t[:red], 1)
expect("key 'red'", t.red, 2)

-- Only equality is defined. Ordering raises an error.
rejects("symbol < symbol", function() return :a < :b end, "attempt to compare")
rejects("symbol(1)", function() return symbol(1) end, "string expected")
rejects("symbolname(string)", function() return logic.symbolname("a") end, "symbol expected")

-- `:` keeps its other Lua meanings next to symbol literals.
local obj = { n = 7 }
function obj:get() return self.n end
local method = :get
expect("method call", obj:get(), 7)
expect("symbol named like the method", logic.symbolname(method), "get")
do
    local i = 0
    ::again::
    i = i + 1
    if i < 3 then goto again end
    expect("label and goto", i, 3)
end

-- Benchmark: N names, K distinct symbols.  Name i maps to symbol (i mod K).
local counts, distinct = {}, 0
for i = 1, P.names do
    local s = symbol("sym" .. (i % P.distinct))
    if counts[s] == nil then distinct = distinct + 1; counts[s] = 0 end
    counts[s] = counts[s] + 1
end
expect("distinct symbols", distinct, P.distinct)
expect("uses of :sym0", counts[:sym0], P.names // P.distinct)
