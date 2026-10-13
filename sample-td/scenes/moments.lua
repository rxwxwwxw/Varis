-- Moments: the scenes that interrupt a battle (plan §5.1). Each one is named by a trigger in
-- battle/setup.lua; a choice records a decision (`decide`), and battle/sync.lua says what that
-- decision does to the battle that is paused. Trust moves with the procedures at the top of
-- scenes/characters.lua.

-- Night 1, wave_start(1): the teaching beat. Wren runs in and joins.
scene m1_wren {
    {kind=:background, tag=:road},
    {kind=:show, character=:corvin, slot=:right},
    {kind=:say, character=:corvin, text="Watch the road. Not the lamps. The road."},
    {kind=:show, character=:wren, slot=:left},
    {kind=:say, character=:wren, attributes={expression=:worried}, text="They are on the second switchback! I counted. Thirty, maybe more, and they are not even hurrying."},
    {kind=:say, character=:corvin, text="You are the courier. Courier, you are in the wrong place."},
    {kind=:say, character=:wren, attributes={expression=:fierce}, text="I am in the only place I can see them from."},
    {kind=:narration, text="Corvin looks at you. It is your terrace, and your call."},
    {kind=:effect, name=:join_wren},
    {kind=:say, character=:corvin, text="Stay behind the lamps, then. Warden, give her something to do."},
    {kind="return"},
}

-- Night 2, enemy_kind_seen(husk): Ilse and Corvin disagree how to meet armour.
scene m2_husks {
    {kind=:background, tag=:road},
    {kind=:show, character=:ilse, slot=:left},
    {kind=:show, character=:corvin, slot=:right},
    {kind=:say, character=:ilse, text="Those are shells, not bodies. The lamps will burn through them if we give them time."},
    {kind=:say, character=:corvin, attributes={expression=:fierce}, text="We have no time. Hit them where they stop, all lamps at once, and the road holds."},
    {kind=:menu, choices={
        {id=:focus, text="Focus fire, Corvin's way", target=:m2_husks_focus},
        {id=:lamps, text="Let the lamps work, Ilse's way", target=:m2_husks_lamps},
    }},
}
scene m2_husks_focus {
    {kind=:effect, name=:decide, args={what=:focus_fire}},
    {kind=:effect, name=:raise_trust, args={hero=:corvin, delta=1}},
    {kind=:say, character=:corvin, text="Good. Every lamp on one husk, then the next. Ilse, you will have your oil's worth."},
    {kind=:say, character=:ilse, attributes={expression=:worried}, text="I will have a long night of mending, is what I will have."},
    {kind="return"},
}
scene m2_husks_lamps {
    {kind=:effect, name=:decide, args={what=:lamps_work}},
    {kind=:effect, name=:raise_trust, args={hero=:ilse, delta=1}},
    {kind=:say, character=:ilse, text="Thank you. Steady, now. A lamp that is allowed to finish is worth three that are rushed."},
    {kind=:say, character=:corvin, text="If the road breaks, it breaks on your say."},
    {kind="return"},
}

-- Night 2, hero_hp_below(wren, 40): Wren is cut off.
scene m2_wren {
    {kind=:background, tag=:road},
    {kind=:show, character=:corvin, slot=:right},
    {kind=:show, character=:wren, slot=:left},
    {kind=:say, character=:wren, attributes={expression=:worried}, text="I cannot get back! They are between me and the lamps!"},
    {kind=:say, character=:corvin, text="Warden. She is not a lamp and she is not a wall. Say the word."},
    {kind=:menu, choices={
        {id=:cover, text="Corvin, cover her", target=:m2_wren_cover},
        {id=:hold, text="Hold the line", target=:m2_wren_hold},
    }},
}
scene m2_wren_cover {
    {kind=:effect, name=:decide, args={what=:cover_wren}},
    {kind=:effect, name=:raise_trust, args={hero=:wren, delta=1}},
    {kind=:effect, name=:raise_trust, args={hero=:corvin, delta=-1}},
    {kind=:effect, name=:add_bond, args={a=:wren, b=:corvin}},
    {kind=:say, character=:corvin, attributes={expression=:fierce}, text="Moving. If the road breaks I will remember whose idea this was."},
    {kind=:say, character=:wren, text="I will remember it better."},
    {kind="return"},
}
scene m2_wren_hold {
    {kind=:effect, name=:decide, args={what=:hold_the_line}},
    {kind=:effect, name=:set_flag, args={name=:held_the_line}},
    {kind=:say, character=:corvin, text="Hold! Wren, run for the lamps. Run as if the hill were on fire."},
    {kind=:say, character=:wren, attributes={expression=:worried}, text="You are the Warden, and you decided that. I heard you."},
    {kind="return"},
}

-- Night 3, heroes_near(ilse, corvin, 3): forced to cooperate.
scene m3_together {
    {kind=:background, tag=:road},
    {kind=:show, character=:ilse, slot=:left},
    {kind=:show, character=:corvin, slot=:right},
    {kind=:narration, text="The east road and the switchbacks meet at one terrace, and two stubborn people have found themselves standing on it."},
    {kind=:say, character=:corvin, text="Left lamp. Now the right. Ilse, the oil."},
    {kind=:say, character=:ilse, attributes={expression=:fierce}, text="I know where the oil is, Captain. Hold the gap and I will keep your lamps burning."},
    {kind=:narration, text="For one quiet minute they do not argue. Then the husks come, and nobody has time to."},
    {kind=:effect, name=:decide, args={what=:side_by_side}},
    {kind=:effect, name=:add_bond, args={a=:ilse, b=:corvin}},
    {kind=:say, character=:ilse, text="That was not so bad."},
    {kind=:say, character=:corvin, text="It was tolerable."},
    {kind="return"},
}

-- Night 3, leak_count(5): villagers on the Mill road.
scene m3_mill {
    {kind=:background, tag=:mill},
    {kind=:show, character=:corvin, slot=:right},
    {kind=:narration, text="The Dim have reached the Mill road, and the Mill is full of people who thought it was the safe place."},
    {kind=:say, character=:corvin, text="Militia can hold the lane for a quarter of an hour. Or you empty the Mill and let the Dim have the empty building."},
    {kind=:menu, choices={
        {id=:militia, text="Call the militia", target=:m3_mill_militia},
        {id=:evacuate, text="Order the Mill evacuated", target=:m3_mill_evacuate},
    }},
}
scene m3_mill_militia {
    {kind=:effect, name=:decide, args={what=:call_militia}},
    {kind=:say, character=:corvin, text="Pitchforks to the lane. Nobody is a hero tonight; everybody is a wall."},
    {kind="return"},
}
scene m3_mill_evacuate {
    {kind=:effect, name=:decide, args={what=:evacuate_mill}},
    {kind=:effect, name=:set_flag, args={name=:evacuated_mill}},
    {kind=:say, character=:corvin, text="Out. Out, and uphill. We keep the people and lose the grain."},
    {kind="return"},
}

-- Night 3, step(1200): the east light fails; Ilse asks for a minute.
scene m3_east_light {
    {kind=:background, tag=:road},
    {kind=:show, character=:ilse, slot=:left},
    {kind=:say, character=:ilse, attributes={expression=:worried}, text="The east light is guttering. If I do not trim it now it goes out in the middle of the rush. A minute, Warden. One."},
    {kind=:menu, choices={
        {id=:minute, text="Give her the minute", target=:m3_east_minute},
        {id=:notime, text="No time", target=:m3_east_notime},
    }},
}
scene m3_east_minute {
    {kind=:effect, name=:decide, args={what=:give_minute}},
    {kind=:effect, name=:raise_trust, args={hero=:ilse, delta=1}},
    {kind=:say, character=:ilse, text="Thank you. There. Now every lamp near me is mended, and I am not sorry."},
    {kind="return"},
}
scene m3_east_notime {
    {kind=:effect, name=:decide, args={what=:no_time}},
    {kind=:effect, name=:raise_trust, args={hero=:ilse, delta=-1}},
    {kind=:say, character=:ilse, attributes={expression=:fierce}, text="Then it goes out. I will remember that you chose the rush over the lamp."},
    {kind="return"},
}

-- Night 4, wave_start(3): the Maw. The camera pulls out; no choice.
scene m4_maw {
    {kind=:background, tag=:valley},
    {kind=:narration, text="The fog below the last terrace parts like a curtain. Something the size of a barn climbs out of it, slowly, and the lamps nearest it begin to burn the wrong colour."},
    {kind=:show, character=:wren, slot=:left},
    {kind=:say, character=:wren, attributes={expression=:worried}, text="That is not one of them. That is where they come from."},
    {kind=:show, character=:corvin, slot=:right},
    {kind=:say, character=:corvin, text="Then we do not let it reach the Lantern. Everything on it."},
    {kind="return"},
}

-- Night 4, hero_downed(any): who goes to the fallen?
scene m4_fallen {
    {kind=:background, tag=:road},
    {kind=:narration, text="One of them is down on the road, and the Dim are closing around the place."},
    {kind=:menu, choices={
        {id=:rescue, text="Go to the fallen", target=:m4_fallen_rescue},
        {id=:leave, text="Leave them", target=:m4_fallen_leave},
    }},
}
scene m4_fallen_rescue {
    {kind=:effect, name=:decide, args={what=:rescue}},
    {kind=:narration, text="Someone goes. Someone always does. The line behind them thins."},
    {kind="return"},
}
scene m4_fallen_leave {
    {kind=:effect, name=:decide, args={what=:leave_them}},
    {kind=:effect, name=:set_flag, args={name=:left_behind}},
    {kind=:narration, text="You choose the line. Nobody says anything afterwards. That is what it costs."},
    {kind="return"},
}

-- Night 4, structure_destroyed(bellfrey): the bell goes silent.
scene m4_bell {
    {kind=:background, tag=:bellfrey},
    {kind=:show, character=:wren, slot=:left},
    {kind=:narration, text="The Bellfrey has rung every night since the Lantern was lit. It stops. The silence is louder than the bell was."},
    {kind=:say, character=:wren, attributes={expression=:fierce}, text="I can burn the approach. A flare big enough to show them all, and burn them while they look. Or we fall back to the Lantern and make a stand there."},
    {kind=:menu, choices={
        {id=:flare, text="Wren's Flare", target=:m4_bell_flare},
        {id=:rally, text="Rally at the Lantern", target=:m4_bell_rally},
    }},
}
scene m4_bell_flare {
    {kind=:effect, name=:decide, args={what=:flare_valley}},
    {kind=:effect, name=:set_flag, args={name=:valley_seen}},
    {kind=:say, character=:wren, text="Look, then. Look at all of it."},
    {kind="return"},
}
scene m4_bell_rally {
    {kind=:effect, name=:decide, args={what=:rally_lantern}},
    {kind=:say, character=:corvin, text="To me. The Lantern, and nothing else, until it is done."},
    {kind="return"},
}

-- Night 4, leak_count(12): the line breaks.
scene m4_line {
    {kind=:background, tag=:lantern},
    {kind=:narration, text="Twelve have passed the last lamp. The Lantern flickers, and the heat of it is leaving the terrace."},
    {kind=:show, character=:ilse, slot=:left},
    {kind=:say, character=:ilse, attributes={expression=:worried}, text="We can still carry it down. The flame, I mean. Out of the hill. It would live."},
    {kind=:menu, choices={
        {id=:retreat, text="Sound the retreat", target=:m4_line_retreat},
        {id=:stand, text="Stand", target=:m4_line_stand},
    }},
}
scene m4_line_retreat {
    {kind=:effect, name=:decide, args={what=:sound_retreat}},
    {kind=:effect, name=:set_flag, args={name=:retreated}},
    {kind=:say, character=:ilse, text="Carry it down. Carry it slowly. Do not look back at the hill."},
    {kind="return"},
}
scene m4_line_stand {
    {kind=:effect, name=:decide, args={what=:stand}},
    {kind=:effect, name=:raise_trust, args={hero=:ilse, delta=-1}},
    {kind=:effect, name=:raise_trust, args={hero=:corvin, delta=-1}},
    {kind=:effect, name=:raise_trust, args={hero=:wren, delta=-1}},
    {kind=:say, character=:corvin, attributes={expression=:fierce}, text="Then we stand. Every one of us. Hear me, Warden: you asked that."},
    {kind="return"},
}

-- Closing moments: they do not count toward the cap.
scene m4_won {
    {kind=:background, tag=:valley},
    {kind=:narration, text="The Maw folds, and the valley is empty of everything but fog. The fog, for the first time in anyone's memory, is only fog."},
    {kind=:effect, name=:set_flag, args={name=:won_night_4}},
    {kind="return"},
}
scene m4_lost {
    {kind=:background, tag=:lantern},
    {kind=:narration, text="The line breaks. Below, the Lantern gutters, and the valley goes dark."},
    {kind=:effect, name=:set_flag, args={name=:lantern_out}},
    {kind="return"},
}
