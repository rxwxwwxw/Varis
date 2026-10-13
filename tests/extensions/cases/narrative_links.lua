-- Passage links [[text->choice]] compile to choices: validated at seal, delivered as `links`.
relation ready(0)
fact ready()
storylet fork()
    when { ready() }
    title "Fork"
    text "Take the [[left road->left]] or [[right]]."
    choice left effect do end end
    choice right effect do end end
end
narrative.seal()
local s = narrative.new(logic.world())
s:seed(1)
local p = s:present()
local links = p.storylets[1].links
assert(#links == 2 and links[1].text == "left road" and links[1].choice == :left)
assert(links[2].text == "right" and links[2].choice == :right and links[2].enabled)
s:choose(links[1].token)
assert(s:turn() == 1)
