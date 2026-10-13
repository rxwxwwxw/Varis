-- Milestone 28: `expose ?name` shows a matched value to templates and effects without making
-- it part of the instance identity.
relation room(1)
relation lamp(2)
relation seen(2)
fact room(:cellar)
fact room(:attic)
fact lamp(:cellar, :oil)
fact lamp(:attic, :gas)
deck :default {draw = 4, replacement = true}
storylet visit(?room)
    when { room(?room), lamp(?room, ?kind) }
    expose ?kind
    title "Visit the {room}"
    text "A {kind} lamp burns."
    choice look
        title "Look at the {kind} lamp"
        effect do fact seen(room, kind) end
    end
end
narrative.seal()
local s = narrative.new(logic.global)
s:seed(5)
local p = s:present()
assert(#p.storylets == 2)
for i = 1, #p.storylets do
    local st = p.storylets[i]
    assert(st.bindings.kind == nil, "exposed values are not instance bindings")
    if st.bindings.room == :cellar then
        assert(st.text == "A oil lamp burns.", st.text)
        assert(st.choices[1].title == "Look at the oil lamp")
    end
end
local cellar
for i = 1, #p.storylets do if p.storylets[i].bindings.room == :cellar then cellar = p.storylets[i] end end
-- the instance key does not mention the exposed value
assert(not string.find(cellar.instance_key, "oil", 1, true))
s:choose(cellar.choices[1].token)
assert(count(query seen(:cellar, :oil)) == 1)
-- choosing revalidates exposed values: a lamp swapped between present and choose is stale
local again = s:present()
local attic
for i = 1, #again.storylets do if again.storylets[i].bindings.room == :attic then attic = again.storylets[i] end end
retract lamp(:attic, :gas)
fact lamp(:attic, :torch)
reject(function() s:choose(attic.choices[1].token) end, "STALE_CHOICE")
-- two different values for one instance is an author-facing error
fact lamp(:attic, :candle)
reject(function() s:present() end, "AMBIGUOUS_EXPOSE")
