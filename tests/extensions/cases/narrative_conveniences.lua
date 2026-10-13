-- Twine-class conveniences: visited / last_chosen, pass-through metadata, rich-text spans,
-- and validated text input.
relation ready(0)
fact ready()
storylet shop()
    when { ready() }
    title "Shop"
    choice browse effect do
        assert(narrative.visited(:shop) == 0 or narrative.visited(:shop) >= 1)
    end end
end
character guide { name="Guide", tag=:guide }
scene askname {
    {kind=:input, ["local"]="who", text="Name?", default="Rowan", min_length=2, max_length=5},
    {kind=:input, ["local"]="age", text="Age?", min=1, max=120},
    {kind=:say, character=:guide, id="hi", text="Hi {who}."},
    {kind=:ended},
}
narrative.meta(:shop, {icon="cart", tags={"trade", "daily"}})
narrative.meta(:shop, :browse, {shortcut="b"})
reject(function() narrative.meta(:shop, {icon="again"}) end, "duplicate narrative.meta")
narrative.seal()
reject(function() narrative.meta(:other, {x=1}) end, "sealed")
local s = narrative.new(logic.global)
s:seed(1)
s:set_undo_limit(2)
-- metadata passes through and does not enter the save
local p = s:present()
assert(p.storylets[1].meta.icon == "cart" and p.storylets[1].meta.tags[2] == "daily")
assert(p.storylets[1].choices[1].meta.shortcut == "b")
-- visited / last_chosen
assert(s:visited(:shop) == 0 and s:last_chosen(:shop) == nil)
s:choose(p.storylets[1].choices[1].token)
assert(s:visited(:shop) == 1 and s:last_chosen(:shop) == 1)
p = s:present()
s:choose(p.storylets[1].choices[1].token)
assert(s:visited(:shop) == 2 and s:last_chosen(:shop) == 2)
local copy = narrative.load(s:save(), function() return logic.world() end)
assert(copy:visited(:shop) == 2 and copy:last_chosen(:shop) == 2, "derived from saved data")
s:undo()
assert(s:visited(:shop) == 1)
reject(function() narrative.visited(:shop) end, "active transactional effect")
-- spans
local spans = narrative.spans("Say **hello** to *her*, see [the map](map-1).\nBye \\*")
assert(spans[1].text == "Say " and not spans[1].strong)
assert(spans[2].text == "hello" and spans[2].strong == true)
assert(spans[4].text == "her" and spans[4].emphasis == true)
local linked
for _, span in ipairs(spans) do if span.link then linked = span end end
assert(linked and linked.text == "the map" and linked.link == "map-1")
local broke = false
for _, span in ipairs(spans) do if span["break"] then broke = true end end
assert(broke and spans[#spans].text == "Bye *")
local stray = narrative.spans("2 * 3 and [x")
assert(#stray == 1 and stray[1].text == "2 * 3 and [x", "unpartnered markers stay text")
assert(narrative.spans("**a *b* c**")[2].emphasis == true)
assert(narrative.escape_markup("a*b[c]") == "a\\*b\\[c\\]")
assert(narrative.spans(narrative.escape_markup("*not*"))[1].text == "*not*")
-- text input: default, length and number bounds
s:play(:askname)
local beat = s:present()
assert(beat.beats[1].default == "Rowan")
local before = s:save()
reject(function() s:advance(beat.token, "A") end, "at least 2")
reject(function() s:advance(beat.token, "Alexandra") end, "at most 5")
assert(s:save() == before, "invalid input changes nothing")
s:advance(beat.token)                       -- nil takes the default
beat = s:present()
reject(function() s:advance(beat.token, 0) end, "between")
reject(function() s:advance(beat.token, "x") end, "a number is required")
reject(function() s:advance(beat.token) end, "a value is required")
s:advance(beat.token, 30)
beat = s:present()
assert(beat.beats[1].text == "Hi Rowan.")
