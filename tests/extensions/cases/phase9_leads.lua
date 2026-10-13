-- Milestone 28: `leads :deck` on a choice pushes the destination after the authored effect, in
-- the same transaction; `narrative.return_deck()` goes back.
relation open(1)
fact open(:x)
relation log(1)
deck :default {draw = 1, replacement = true}
deck :cellar {draw = 1, replacement = true}
storylet door()
    when { open(:x) }
    title "Door"
    choice down
        leads :cellar
        title "Go down"
        effect do fact log(:went) end
    end
end
storylet room()
    when { open(:x) }
    deck :cellar
    title "Cellar"
    choice up effect do narrative.return_deck() end end
end
narrative.seal()
local s = narrative.new(logic.global)
s:seed(1)
local p = s:present()
s:choose(p.storylets[1].choices[1].token)
assert(s:active_deck() == :cellar)
assert(count(query log(:went)) == 1)
local q = s:present()
assert(q.storylets[1].id == :room and q.deck == :cellar)
s:choose(q.storylets[1].choices[1].token)
assert(s:active_deck() == :default)
reject(function() narrative.return_deck() end, "effect")
