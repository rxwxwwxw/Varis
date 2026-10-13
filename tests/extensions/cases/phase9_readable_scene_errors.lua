-- Readable scenes reject likely mistakes at parse time with a message that says what to write.
local function rejects(source, needle)
    local chunk, message = load(source)
    assert(chunk == nil, "accepted: " .. source)
    assert(message:find(needle, 1, true), message)
end
rejects("scene a() say mira \"hi\" end", "needs an id")
rejects("scene a() narrate id x \"one\" narrate id x \"two\" end", "duplicate line id 'x'")
rejects("scene a() input v \"Name?\" end", "needs an id")
rejects("scene a() frobnicate end", "unknown scene statement 'frobnicate'")
rejects("scene a(x) end", "takes no parameters")
rejects("scene a() if mood then end end", "compares a local with a value")
rejects("scene a() menu end end", "at least one")
rejects("scene a() show mira :left end", "'at' expected")
rejects("scene a() effect using x end end", "'do' expected")
rejects("scene a() input v id q \"?\" with colour = 1 end", "not accepted here")

-- An ordering over a local of another kind is a runtime error that keeps the position.
character mira { name = "Mira" }
scene cmp()
    set level = "high"
    if level > 3 then
        narrate id big "big"
    end
    narrate id done "done"
end
local s = narrative.new(logic.emptyworld())
local ok, message = pcall(function() s:play(:cmp) end)
assert(not ok and tostring(message):find("another kind", 1, true), tostring(message))
print("readable scene error checks passed")
