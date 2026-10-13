-- Milestone 28: terminal sessions (`narrative.finish`, `session:ended`) and narration events
-- delivered with presentations (`events`, `session:events_since`).
relation open(1)
fact open(:x)
relation closed(1)
relation armed(1)
deck :default {draw = 2, replacement = true}
storylet read()
    when { open(:x) }
    title "Read"
    choice page effect do
        narrative.emit(:say, "A page turns.")
        narrative.emit(:say, "Dust falls.")
    end end
    choice leave effect do
        narrative.emit(:say, "You go.")
        fact armed(:x)
        narrative.finish(:left)
    end end
    choice twice effect do
        narrative.finish(:one)
        narrative.finish(:one)
        narrative.finish(:two)
    end end
    choice rewind effect do
        narrative.emit(:say, "never delivered")
        narrative.finish(:other)
        error("changed my mind")
    end end
end
action after_leave()
    when { armed(:x) }
    effect do fact closed(:ran) end
end
narrative.seal()
local s = narrative.new(logic.global)
s:seed(3)
local function choice(p, id)
    local cs = p.storylets[1].choices
    for i = 1, #cs do if cs[i].id == id then return cs[i] end end
end
local p1 = s:present()
assert(#p1.events == 0 and p1.ending == nil)
assert(s:ended() == nil)
-- a failing effect (conflicting endings) emits nothing and finishes nothing
reject(function() s:choose(choice(p1, :twice).token) end, "already finished")
assert(s:ended() == nil and #s:events_since(0) == 0)
reject(function() s:choose(choice(s:present(), :rewind).token) end, "changed my mind")
assert(s:ended() == nil and #s:events_since(0) == 0)
local p2 = s:present()
s:choose(choice(p2, :page).token)
local p3 = s:present()
assert(#p3.events == 2, "events committed since the previous presentation")
assert(p3.events[1].kind == :say and p3.events[1].args[1] == "A page turns." and p3.events[1].sequence == 1)
assert(p3.events[2].sequence == 2 and p3.events[2].turn == 0)
assert(#s:events_since(0) == 2 and #s:events_since(1) == 1 and #s:events_since(2) == 0)
-- re-rendering an existing presentation delivers nothing new and consumes nothing
local again = s:render(p3)
assert(#again.events == 2)
assert(#s:present().events == 0)
-- events committed but not yet presented stay undelivered across a save
s:choose(choice(s:present(), :page).token)
local waiting = narrative.load(s:save(), function()
    local w = logic.world()
    logic (w) do fact open(:x) end
    return w
end)
local resumed = waiting:present()
assert(#resumed.events == 2 and resumed.events[1].sequence == 3)
assert(#s:present().events == 2)
-- finishing: the effect completes, automatic actions stop, the presentation is terminal
s:choose(choice(s:present(), :leave).token)
assert(s:ended() == :left)
assert(count(query closed(:ran)) == 0, "no automatic action after the ending")
local last = s:present()
assert(last.ending == :left and #last.storylets == 0)
assert(#last.events == 1 and last.events[1].args[1] == "You go.")
reject(function() s:choose(choice(p2, :page).token) end, "SESSION_ENDED")
-- the ending and the event cursor survive a save
local text = s:save()
local function factory()
    local w = logic.world()
    logic (w) do fact open(:x) end
    return w
end
local loaded = narrative.load(text, factory)
assert(loaded:ended() == :left)
assert(loaded:present().ending == :left and #loaded:present().events == 0)
assert(#loaded:events_since(0) == 5)
