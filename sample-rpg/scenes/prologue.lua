-- The opening: the cart road, your name, and Aunt Odile at the gate. The name travels from the
-- scene's input beat into the world through an effect beat.

procedure set_name(?name)
    effect do
        set player_name(:player, name)
    end
end

scene prologue {
    {kind=:background, tag=:road},
    {kind=:audio, channel=:music, tag=:title_theme},
    {kind=:narration, text="The cart driver lets you down at the edge of Hollowbrook and does not wait for thanks. Ten days until Midsummer. Ten days until the Trials."},
    {kind=:narration, text="A letter in your pocket says there is a bed for you at your aunt's house, and that the town is short of hands. It does not say what the Trials are for. Everyone you meet will assume you know."},
    {kind=:input, ["local"]="visitor", text="The gatekeeper squints at you. \"Name?\""},
    {kind=:effect, name=:set_name, locals={name="visitor"}},
    {kind=:background, tag=:house},
    {kind=:show, character=:odile, slot=:right, attributes={expression=:happy}},
    {kind=:say, character=:odile, id="prologue.odile1", text="{visitor}! Look at the size of you. Come in, come in. The kettle has been on since breakfast."},
    {kind=:say, character=:odile, attributes={expression=:neutral}, id="prologue.odile2", text="You will want to know about the Trials. Three contests on Midsummer night: strength, wits and charm. The guilds sponsor whoever impresses them. Enter, and you will need the fee, and you will need to be good."},
    {kind=:menu, choices={
        {id=:eager, text="\"I'll win it.\"", target=:prologue_eager},
        {id=:wary, text="\"What's the catch?\"", target=:prologue_wary},
        {id=:tired, text="\"Can I sit down first?\"", target=:prologue_tired},
    }},
}
scene prologue_eager {
    {kind=:say, character=:odile, attributes={expression=:happy}, id="prologue.eager", text="That is the spirit. Your mother said the same at your age. Sit; eat; then we will look at what kind of person you have grown into."},
    {kind=:jump, target=:prologue_end},
}
scene prologue_wary {
    {kind=:say, character=:odile, attributes={expression=:worried}, id="prologue.wary", text="The catch is that everyone wants it. Be kind to the people who help you. Hollowbrook remembers."},
    {kind=:jump, target=:prologue_end},
}
scene prologue_tired {
    {kind=:say, character=:odile, attributes={expression=:happy}, id="prologue.tired", text="Sit. Of course sit. There will be time to be tested. Tonight, be a person."},
    {kind=:jump, target=:prologue_end},
}
scene prologue_end {
    {kind=:hide, character=:odile},
    {kind=:show, character=:player, slot=:left},
    {kind=:narration, text="Before the summer begins, you take a moment to decide who you are."},
    {kind=:jump, target=:hub},
}

-- Creation outcomes are looks: the player's own sprite changes with the outfit chosen.
scene look_casual {
    {kind=:show, character=:player, slot=:left, attributes={outfit=:casual, expression=:happy}},
    {kind="return"}
}
scene look_sporty {
    {kind=:show, character=:player, slot=:left, attributes={outfit=:sporty, expression=:happy}},
    {kind="return"}
}
scene look_scholarly {
    {kind=:show, character=:player, slot=:left, attributes={outfit=:scholarly, expression=:happy}},
    {kind="return"}
}

scene begin_summer {
    {kind=:background, tag=:house},
    {kind=:hide, character=:player},
    {kind=:show, character=:odile, slot=:right, attributes={expression=:happy}},
    {kind=:say, character=:odile, id="begin.odile", text="Breakfast is on the table, and the town is waking up. Go and see what it needs of you."},
    {kind=:audio, channel=:music, tag=:day_theme},
    {kind="return"},
}
