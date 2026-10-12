-- A scene `effect` beat runs a named procedure in its own transaction, with scene locals and
-- literal arguments, so input and menu choices reach the world.
quality.define(:str, {initial = 10, minimum = 0, maximum = 20, label = "Strength"})
procedure set_name(?name)
    effect do
        set player_name(:player, name)
    end
end
procedure grow(?amount)
    effect do
        adjust quality(:player, :str) by amount
        narrative.emit(:grew, amount)
    end
end
character mira { name = "Mira", attributes = {expression = {:quiet}}, defaults = {expression = :quiet} }
scene intro {
    {kind=:input, ["local"]="visitor", text="Name?"},
    {kind=:effect, name=:set_name, locals={name="visitor"}},
    {kind=:effect, name=:grow, args={amount=5}},
    {kind=:say, character=:mira, id="intro.hi", text="Hello, {visitor}."},
    {kind=:menu, choices={{id=:strong, text="Strong", target=:strong}, {id=:weak, text="Weak", target=:weak}}},
}
scene strong {
    {kind=:effect, name=:grow, args={amount=10}},   -- 10 + 5 + 10 > 20: the whole advance fails
    {kind=:ended},
}
scene weak {
    {kind=:effect, name=:grow, args={amount=1}},
    {kind=:ended},
}
local function factory()
    local w = logic.emptyworld()
    logic (w) do relation player_name(who, name) key(who) end
    return w
end
local w = factory()
quality.initialize(:player, :str, w)
local s = narrative.new(w)
s:seed(1)
s:play(:intro)
local p = s:present()
s:advance(p.token, "Rowan")
assert(quality.get(:player, :str, w) == 15)
local named
logic (w) do named = (query player_name(:player, ?n))() end
assert(named.n == "Rowan")
p = s:present()
assert(p.beats[1].text == "Hello, Rowan.")
-- Save and load mid-scene, after effects.
local loaded = narrative.load(s:save(), factory)
assert(loaded:save() == s:save())
-- The failing branch leaves position, world and token untouched.
s:advance(s:present().token)
assert(s:present().beats[1].kind == :menu)
p = s:present()
reject(function() s:advance(p.token, :strong) end, "")
assert(quality.get(:player, :str, w) == 15)
assert(s:present().beats[1].kind == :menu)
s:advance(s:present().token, :weak)
assert(quality.get(:player, :str, w) == 16)
print("scene effect passed")
