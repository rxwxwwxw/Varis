-- The four endings (plan §6), each with a line per hero by the trust earned (three bands) and by
-- what became of them. The host does not select among them: the storylet `report` reads the rule
-- `ending/1` and plays the scene.

scene ending_kept {
    {kind=:background, tag=:lantern},
    {kind=:narration, text="The Lantern keeps. By midmorning the fog has gone back below the last terrace, and the village is up on its roofs, mending, and shouting at each other about nothing."},
    {kind=:narration, text="{#if query dead(:ilse)}Ilse's place at the table is hers.{#else}{#if query trust_high(:ilse)}Ilse has the lamps trimmed before dawn and never once asks you to hurry.{#else}{#if query trust_mid(:ilse)}Ilse nods at the lamps. \"They will hold. Mostly.\"{#else}Ilse keeps her tools in her apron and her opinions to herself.{/if}{/if}{/if}"},
    {kind=:narration, text="{#if query dead(:corvin)}Corvin's road is still on the map in his hand.{#else}{#if query trust_high(:corvin)}Corvin walks the road with you to the gate, the way a captain walks with his own.{#else}{#if query trust_mid(:corvin)}Corvin salutes, short and dry. It is the most he gives anyone.{#else}Corvin says the road was his, and goes home without waiting for you.{/if}{/if}{/if}"},
    {kind=:narration, text="{#if query dead(:wren)}Somebody else carries the messages now.{#else}{#if query trust_high(:wren)}Wren has already named the next dawn's first runner after herself.{#else}{#if query trust_mid(:wren)}Wren waves from the switchbacks and shouts the news before anyone asks.{#else}Wren keeps her distance, though she still runs the messages.{/if}{/if}{/if}"},
    {kind=:effect, name=:set_flag, args={name=:ended}},
    {kind=:ended},
}

scene ending_cost {
    {kind=:background, tag=:lantern},
    {kind=:narration, text="The Lantern keeps, at a cost. The terraces are burned and broken, and the fog is only fog now, but the places at the table are not all filled."},
    {kind=:narration, text="{#if query dead(:ilse)}Somebody has hung Ilse's can of oil over the lamp store door.{/if}{#if query dead(:corvin)}The road is Corvin's. They have named it.{/if}{#if query dead(:wren)}Nobody runs the messages on the switchbacks any more. It is very quiet.{/if}{#if query bell_ruined()}The Bellfrey's bell is a piece of the museum already.{/if}"},
    {kind=:narration, text="You stand on the wall and the village stands with you. It is not quite nothing."},
    {kind=:effect, name=:set_flag, args={name=:ended}},
    {kind=:ended},
}

scene ending_withdrawal {
    {kind=:background, tag=:lantern},
    {kind=:narration, text="You sounded the retreat, and they carried the flame down the hill in a lantern. The Lantern stands empty at the top of Marrow Hill. For the first time in a hundred years, there is nothing on the terraces to defend."},
    {kind=:narration, text="Ilse carries the oil and Corvin carries the road. Wren runs ahead, as ever, and does not look back."},
    {kind=:effect, name=:set_flag, args={name=:ended}},
    {kind=:ended},
}

scene ending_dimmed {
    {kind=:background, tag=:valley},
    {kind=:narration, text="The Lantern goes out. In the fog, something notices, and begins at last to climb."},
    {kind=:narration, text="Marrow Hill is dark. In the morning the village is not there, and the fog is a little thicker, and more patient."},
    {kind=:effect, name=:set_flag, args={name=:ended}},
    {kind=:ended},
}
