-- Milestone 28: handlers and deferred callbacks default to the session's world.
relation open(1)
relation heard(1)
relation told(1)
quality.define(:mood, {initial = 1})
local w = logic.world()
logic (w) do fact open(:x) end
deck :default {draw = 1, replacement = true}
narrative.on(:ping, function(world, kind, args)
    fact heard(args[1])               -- unqualified: the session's world, not logic.global
    quality.initialize(:room, :mood)  -- likewise
end)
storylet start()
    when { open(:x) }
    title "Start"
    choice go effect do
        narrative.schedule(:ping, narrative.sequence(:hello), 0)
        narrative.defer(function()
            fact told(:later)
            assert(exists { told(:later) })
        end)
    end end
end
narrative.seal()
local s = narrative.new(w)
s:seed(1)
local p = s:present()
s:choose(p.storylets[1].choices[1].token)
assert(count(query w.heard(:hello)) == 1, "handler wrote to the session world")
assert(count(query heard(:hello)) == 0, "not to logic.global")
assert(count(query w.told(:later)) == 1, "deferred callback wrote to the session world")
assert(count(query told(:later)) == 0, "not to logic.global")
assert(quality.get(:room, :mood, w) == 1)
assert(quality.get(:room, :mood) == nil)
