-- session:idle() is the host's "collect now" between turns; it reports whether it collected
-- and leaves the session untouched.
relation coins(1)
fact coins(0)
deck :default {draw = 1, replacement = true}
storylet market()
    when { coins(?c) }
    title "Market"
    choice earn effect do fact coins(5) end end
end
narrative.seal()
local s = narrative.new(logic.global)
s:seed(7)
s:present()
assert(type(s:idle()) == "boolean")
local junk = {}
for i = 1, 200000 do junk[i] = { i, tostring(i) } end
junk = nil
assert(s:idle() == true)
assert(s:idle() == false)
assert(s:turn() == 0)
