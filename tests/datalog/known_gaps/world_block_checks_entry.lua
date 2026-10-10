-- KNOWN-GAP: was accepted by a world block
-- Spec §11.7: the world expression "must produce a world".  dlua only
-- checks this lazily, when the block contains a declarative statement that
-- needs the world, so `logic (5) do end` is silently accepted.
local ok, err = pcall(function()
    logic (5) do
        local unused = 1
    end
end)
assert(not ok, "a non-world expression was accepted by a world block")
assert(string.find(tostring(err), "world", 1, true), tostring(err))
print("GAP CLOSED")
