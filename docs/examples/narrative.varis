-- Varis reference example: deterministic choice, quality, events, and save/load.
local function make_world()
    local w = logic.emptyworld()
    logic (w) do
        relation location(entity, room) key(entity)
        relation road(2)
        set location(:player, :hall)
        fact road(:hall, :library)
    end
    quality.initialize(:player, :coins, w)
    return w
end

quality.define(:coins, { initial = 10, minimum = 0, label = "Coins" })
narrative.name(:library, "the Library")
storylet travel(?from, ?to)
    when { location(:player, ?from), road(?from, ?to) }
    repeatable false
    title "Walk to {to}"
    text "{#variant 3}A quiet corridor.{#variant 1}An empty corridor.{/variant}"
    choice proceed
        title "Continue"
        effect do
            set location(:player, to)
            quality.add(:player, :coins, -1)
            narrative.emit(:travelled, from, to)
        end
    end
end

-- A sticky exit remains visible alongside the sampled storylet.
storylet leave(?room)
    when { location(:player, ?room) }
    sticky true
    order 100
    title "Stay in {room}"
    choice stay
        effect do end
    end
end

local session = narrative.new(make_world())
session:seed(42)
local presentation = session:present()
assert(#presentation.storylets == 2)
assert(presentation.storylets[2].id == :leave)
assert(presentation.storylets[2].choices[1].title == "")
assert(presentation.storylets[1].title == "Walk to the Library")
local token = presentation.storylets[1].choices[1].token
session:choose(token)
assert(session:turn() == 1)
assert(quality.get(:player, :coins, session:world()) == 9)
assert(not pcall(function() session:choose(token) end))
logic (session:world()) do
    local event = (query narrative_event(?sequence, ?turn, :travelled, ?args))()
    assert(event.sequence == 1 and event.turn == 0)
    assert(#event.args == 2 and event.args[2] == :library)
end
local saved = session:save()
local restored = narrative.load(saved, make_world)
assert(restored:turn() == session:turn())
assert(quality.get(:player, :coins, restored:world()) == 9)
assert(restored:save() == saved)
print("narrative: ok")
