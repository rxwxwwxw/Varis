-- Boundary coverage for per-instance policies and deterministic priority tiers.
relation actor(1)
fact actor(:a)
fact actor(:b)
deck :default {draw = 10, replacement = true}
deck :side {draw = 1, replacement = false}
storylet cooled(?id)
    when {actor(?id)}
    cooldown 2
    priority 10
    title "Cooled {id}"
    choice go effect do end end
end
storylet once(?id)
    when {actor(?id)}
    repeatable false
    priority 20
    title "Once {id}"
    choice go effect do end end
end
storylet zero()
    when {actor(:a)}
    priority 100
    weight 0
    title "Never drawn"
    choice go effect do end end
end
storylet advance()
    when {actor(:a)}
    priority -10
    title "Advance"
    choice go effect do end end
    choice same_entry effect do narrative.push_deck(:side) narrative.pop_deck() end end
    choice new_entry effect do narrative.replace_deck(:default) end end
end
local session = narrative.new(logic.global)
session:seed(1)
local function find(p, id, value)
    for i = 1, #p.storylets do
        local story = p.storylets[i]
        if story.id == id and story.bindings.id == value then return story end
    end
end
local first = session:present()
assert(#first.storylets == 5 and first.storylets[1].id == :once and first.storylets[5].id == :advance)
local duplicate = session:present()
session:choose(find(first, :cooled, :a).choices[1].token)
assert(session:turn() == 1)
reject(function() session:choose(find(duplicate, :cooled, :a).choices[1].token) end, "STALE_CHOICE")
assert(not find(session:present(), :cooled, :a))
assert(find(session:present(), :cooled, :b))
session:choose(find(session:present(), :once, :a).choices[1].token)
assert(session:turn() == 2 and not find(session:present(), :cooled, :a))
assert(not find(session:present(), :once, :a) and find(session:present(), :once, :b))
session:choose(find(session:present(), :advance).choices[1].token)
assert(session:turn() == 3 and find(session:present(), :cooled, :a))
local old = find(session:present(), :advance).choices[1].token
session:choose(find(session:present(), :advance).choices[2].token)
-- Pushing/popping preserves the underlying deck entry and its valid tokens.
session:choose(old)
local replaced = find(session:present(), :advance).choices[1].token
session:choose(find(session:present(), :advance).choices[3].token)
reject(function() session:choose(replaced) end, "STALE_CHOICE")
assert(session:active_deck() == :default)
