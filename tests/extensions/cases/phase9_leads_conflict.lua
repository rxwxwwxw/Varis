-- `leads` with an effect that also navigates decks is refused, and the whole choice rolls back;
-- an unknown deck or a non-symbol is a content error at sealing.
relation open(1)
fact open(:x)
relation log(1)
deck :default {draw = 1, replacement = true}
deck :cellar {draw = 1, replacement = true}
storylet door()
    when { open(:x) }
    title "Door"
    choice both
        leads :cellar
        title "Both"
        effect do fact log(:ran); narrative.push_deck(:cellar) end
    end
end
narrative.seal()
local s = narrative.new(logic.global)
s:seed(1)
local p = s:present()
reject(function() s:choose(p.storylets[1].choices[1].token) end, "navigates decks")
assert(s:active_deck() == :default and count(query log(:ran)) == 0 and s:turn() == 0)
