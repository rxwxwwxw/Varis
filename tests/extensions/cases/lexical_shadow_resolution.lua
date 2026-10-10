-- Extension regression: lexical_shadow_resolution
relation p(1) fact p(:global)
local before = query p(?x)
do
    local relation p(1) fact p(:outer)
    local outer = function() return query p(?x) end
    do
        local relation p(1) fact p(:inner)
        assert((query p(?x))().x == :inner)
        assert(outer()().x == :outer)
    end
    assert((query p(?x))().x == :outer)
end
assert(before().x == :global and (query p(?x))().x == :global)
