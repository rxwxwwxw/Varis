-- Bounded integrated scheduler, save/restore and recorded-input replay.
quality.define(:coins, {initial=0, minimum=0, maximum=1000})
deck :default {draw=2, replacement=true}
narrative.on(:delivery, function(world, kind, args)
    logic (world) do fact delivered(args[1]) end
end)
action startup_a()
    when {actor(:a)} phase :pre priority 100 once_per :game
    effect do narrative.emit(:startup_a) end
end
action startup_b()
    when {actor(:a)} phase :pre priority 100 once_per :game
    effect do narrative.emit(:startup_b) end
end
action chapter()
    when {actor(:a)} phase :pre priority 10 once_per :chapter
    effect do narrative.emit(:chapter) end
end
action settle()
    when {counter(:auto, ?n), ?n < 3} phase :pre once_per :always
    effect do adjust counter(:auto) by 1 end
end
action after()
    when {actor(:a)} phase :post
    effect do narrative.emit(:after) end
end
storylet step(?id)
    when {actor(?id)} title "Step {id}"
    choice go effect do
        transaction do
            quality.add(id, :coins, 500)
            narrative.emit(:discarded)
            rollback
        end
        quality.add(id, :coins, 1)
        narrative.emit(:step, id, nil)
        narrative.schedule(:delivery, narrative.sequence(id), 1)
    end end
end
local function make_world(reverse)
    local world = logic.emptyworld()
    logic (world) do
        relation actor(1)
        relation counter(id, n) key(id)
        relation delivered(1)
        if reverse then fact actor(:b) fact actor(:a)
        else fact actor(:a) fact actor(:b) end
        fact counter(:auto, 0)
    end
    quality.initialize(:a, :coins, world)
    quality.initialize(:b, :coins, world)
    return world
end
narrative.seal()
local left = narrative.new(make_world(false))
local right = narrative.new(make_world(true))
left:seed(1234) right:seed(1234)
left:set_period(:chapter, 1) right:set_period(:chapter, 1)
for turn = 1, 60 do
    if turn == 20 then
        left:set_period(:chapter, 2) right:set_period(:chapter, 2)
    elseif turn == 40 then
        -- Revisiting a prior period does not repeat its once-per action.
        left:set_period(:chapter, 1) right:set_period(:chapter, 1)
    end
    local a, b = left:present(), right:present()
    assert(#a.storylets == 2 and #b.storylets == 2)
    for i = 1, 2 do assert(a.storylets[i].instance_key == b.storylets[i].instance_key) end
    local i = turn % 2 + 1
    left:choose(a.storylets[i].choices[1].token)
    right:choose(b.storylets[i].choices[1].token)
    assert(left:turn() == turn and right:turn() == turn)
    if turn % 10 == 0 then
        local saved = left:save()
        local restored = narrative.load(saved, function() return make_world(true) end)
        assert(saved == restored:save())
        left = restored
    end
end
local world = left:world()
logic (world) do
    assert((query counter(:auto, ?n))().n == 3)
    assert((query narrative_event(1, 0, :startup_a, ?args))() ~= nil)
    assert((query narrative_event(2, 0, :startup_b, ?args))() ~= nil)
    assert(count(query narrative_event(?seq, ?turn, :chapter, ?args)) == 2)
    assert(count(query narrative_event(?seq, ?turn, :after, ?args)) == 60)
    assert(count(query narrative_event(?seq, ?turn, :delivery, ?args)) == 60)
    assert(count(query narrative_event(?seq, ?turn, :discarded, ?args)) == 0)
end
assert(quality.get(:a, :coins, world) + quality.get(:b, :coins, world) == 60)
local replay = narrative.new(make_world(true))
local log = left:replay_log()
local presentation
for i = 1, #log.inputs do
    local command = log.inputs[i]
    if command.kind == :seed then replay:seed(command.value)
    elseif command.kind == :period then replay:set_period(command.value[1], command.value[2])
    elseif command.kind == :present then
        presentation = replay:present()
        assert(#presentation.storylets == #command.value)
        for j = 1, #command.value do assert(presentation.storylets[j].instance_key == command.value[j]) end
    elseif command.kind == :choose then
        local token
        for j = 1, #presentation.storylets do
            local story = presentation.storylets[j]
            if story.instance_key == command.value[1] then
                for k = 1, #story.choices do
                    if story.choices[k].instance_key == command.value[2] then token = story.choices[k].token end
                end
            end
        end
        assert(token ~= nil)
        replay:choose(token)
    else error("unexpected replay input") end
end
assert(replay:turn() == 60)
for i = 1, 10 do
    local a, b = left:present(), replay:present()
    for j = 1, 2 do assert(a.storylets[j].instance_key == b.storylets[j].instance_key) end
end
assert(quality.get(:a, :coins, replay:world()) == quality.get(:a, :coins, world))
assert(quality.get(:b, :coins, replay:world()) == quality.get(:b, :coins, world))
