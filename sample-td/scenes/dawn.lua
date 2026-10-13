-- The mornings. One scene per night, and each reads the world: what stands, who is hurt, what
-- was decided. They play as the first thing after "Rest until dusk".

scene dawn_2 {
    {kind=:background, tag=:terraces},
    {kind=:narration, text="Morning on the second terrace. {#if query flag(:wren_joined)}Wren is asleep on the roof of the lamp store, one boot off, with her tally of the Dim on her arm in charcoal.{#else}Nobody has seen the courier since the road went quiet.{/if}"},
    {kind=:narration, text="{#if query any_ruin()}There are ruins where there were lamps, and Ilse is already walking among them with her can.{#else}Every lamp is where it was left. That has not happened before.{/if}"},
    {kind=:narration, text="{#if query any_injured()}The infirmary has a visitor's chair and a patient who will not stay in the bed.{/if}"},
    {kind="return"},
}

scene dawn_3 {
    {kind=:background, tag=:terraces},
    {kind=:narration, text="Morning on the third. {#if query decided(:focus_fire)}Corvin has painted a mark on the wall for every husk his road took, and has run out of wall.{/if}{#if query decided(:lamps_work)}Ilse has hung a husk's shell over the lamp store as a sign.{/if}"},
    {kind=:narration, text="{#if query decided(:cover_wren)}Wren has taken to walking half a step behind Corvin. He has stopped pretending not to notice.{/if}{#if query decided(:hold_the_line)}Wren does not meet your eye, and runs the messages faster than anyone needs.{/if}"},
    {kind=:narration, text="The east road is open. Beyond the Mill, the fog has drawn back by a terrace overnight."},
    {kind="return"},
}

scene dawn_4 {
    {kind=:background, tag=:terraces},
    {kind=:narration, text="Morning on the last day. {#if query decided(:evacuate_mill)}The Mill is empty and the grain with it; the village has been eating thin soup and not complaining.{/if}{#if query decided(:call_militia)}The militia is on the Mill road with their forks, and they are proud and tired and a little drunk.{/if}"},
    {kind=:narration, text="{#if query decided(:side_by_side)}Ilse and Corvin are sharing a table. They have not yet started to talk, but the table is shared.{/if}{#if query decided(:give_minute)}Ilse's east lamp is the brightest on the hill and she has told everyone.{/if}{#if query decided(:no_time)}The east lamp is dark. Ilse has not mentioned it, and that is how you know.{/if}"},
    {kind=:narration, text="The fog has thinned to a rope below the last terrace. Something in it is looking up."},
    {kind="return"},
}
