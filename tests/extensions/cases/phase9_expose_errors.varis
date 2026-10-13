-- `expose` must name a variable the query binds, and not repeat a parameter.
relation room(1)
fact room(:a)
local function problem(source)
    local chunk, message = load(source)
    assert(chunk == nil, "expected a compile error")
    return message
end
local m = problem([[
storylet bad(?room)
    when { room(?room) }
    expose ?nothing
    title "x"
    choice go effect do end end
end
]])
assert(string.find(m, "not bound", 1, true), m)
m = problem([[
storylet bad(?room)
    when { room(?room) }
    expose ?room
    title "x"
    choice go effect do end end
end
]])
assert(string.find(m, "repeats a parameter", 1, true), m)
