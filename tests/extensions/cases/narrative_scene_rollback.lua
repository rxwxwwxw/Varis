scene visit { {kind=:background,tag=:garden}, {kind=:pause} }
relation ready(0)
fact ready()
local s
storylet hub()
    when {ready()}
    title "Hub"
    choice bad effect do
        narrative.play(:visit)
        error("abort scene")
    end end
    choice good effect do
        narrative.play(:visit)
    end end
end
s = narrative.new(logic.world())
s:seed(1)
local p = s:present()
local before = s:save()
reject(function() s:choose(p.storylets[1].choices[1].token) end, "abort scene")
assert(s:save() == before)
s:choose(p.storylets[1].choices[2].token)
local scene = s:present()
assert(scene.scene == :visit and scene.stage.background == :garden and s:turn() == 1)
