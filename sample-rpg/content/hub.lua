-- The hub: where you are, the roads out of it, and the end of the day.

storylet look(?place)
    when { at(:player, ?place), flag(:started) }
    sticky true
    order -50
    title "{place}"
    text [[{#select place}{#case house}The kitchen smells of bread and woodsmoke. Aunt Odile's cat watches you from the warm end of the table.{#case square}The square is a cobbled bowl of noise: carts, pigeons, shouted prices. A lamp-post carries a half-peeled poster for the Trials.{#case market}Awnings in every colour lean over the stalls. A fishmonger and a cheese seller are halfway through a feud that has outlived both their fathers.{#case forge}Heat rolls out of the open doors. Mara Voss does not look up from the glowing bar on her anvil.{#case archive}Dust lies in the slats of light. Archivist Pell sits among towers of ledgers like a king of a very quiet country.{#case tavern}The Gilded Heron is half full and wholly loud. Someone is tuning a fiddle with more hope than skill.{#case docks}Gulls argue over a crate of herring. Beyond the last pier, a broken bridge stands over the river like a sentence that lost its end.{#case quarry}White stone climbs on every side. Your footsteps ring back from the cut walls.{#case green}Bunting snaps in the wind. The Festival Green is a ring of lanterns, trestle tables and nervous people.{#default}Hollowbrook.{/select}
{#if query evening()}The light has gone long and gold.{#else}The day is still young enough to spend.{/if}
{#if query nearly_solved()}You have the feeling of a puzzle that is nearly solved.{/if}]]

    choice breathe
        require { quality(:player, :stamina, ?s), ?s < 10 }
        because "You are not tired; there is nothing to recover."
        title "Take a breath on a bench"
        effect do
            adjust quality(:player, :stamina) by 1
        end
    end
end

storylet walk(?from, ?to)
    when { at(:player, ?from), open_road(?from, ?to), flag(:started) }
    sticky true
    order 10
    title "Go to {to}"
    text ""

    choice go
        title "Go"
        effect do
            set at(:player, to)
            -- The stage scene of the destination: a symbol built from the place's name.
            narrative.play(logic.symbol("stage_" .. logic.symbolname(to)))
            narrative.emit(:moved, from, to)
        end
    end
end

-- A way you can see but not take.
storylet barred(?from, ?to)
    when { at(:player, ?from), road(?from, ?to), broken(?from, ?to), flag(:started) }
    sticky true
    order 20
    title "The way to {to} is closed"
    text ""

    choice wait
        require { not broken(?from, ?to) }
        because "{#select to}{#case quarry}The bridge is out. It will have to be mended before anyone crosses it.{#case green}The Green is roped off until the eve of the festival.{#default}The way is closed.{/select}"
        title "Try it anyway"
        effect do
        end
    end
end

storylet sleep(?day)
    when { at(:player, :house), quality(:world, :day, ?day), ?day <= 9, flag(:started) }
    sticky true
    order 60
    title "Go to bed"
    text ""

    choice sleep
        title "Sleep until morning"
        effect do
            adjust quality(:world, :day) by 1
            set quality(:world, :slot, 1)
            set quality(:player, :stamina, 10)
            if day == 9 then
                retract broken(:square, :green)
                retract broken(:green, :square)
            end
            narrative.emit(:new_day, day + 1)
            narrative.play(logic.symbol("dawn_" .. (day + 1)))
        end
    end
end

storylet to_trials()
    when { trials_time(), flag(:started) }
    sticky true
    priority 1000
    order -200
    title "The bell rings: the Trials begin"
    text [[The bell on the Festival Green rings three times. Everyone in Hollowbrook turns the same way at once.]]

    choice go
        title "Walk to the Green"
        effect do
            set at(:player, :green)
            if (query flag(:entered))() then
                narrative.replace_deck(:trials)
                narrative.play(:trials_open)
            else
                narrative.replace_deck(:ending)
                narrative.play(:trials_watch)
            end
        end
    end
end

-- The mornings. One short scene per day, so no day opens the same way twice.
scene dawn_2 {
    {kind=:narration, text="Day two. Odile has left a note on the table: bread in the cloth, trouble in the square, do not be late for either."},
    {kind="return"}
}
scene dawn_3 {
    {kind=:narration, text="Day three. A cart of apples tipped over in the lane before dawn. The whole street smells like cider and apology."},
    {kind="return"}
}
scene dawn_4 {
    {kind=:narration, text="Day four. Your muscles remember yesterday in detail. The cat sits on your chest and pronounces judgment."},
    {kind="return"}
}
scene dawn_5 {
    {kind=:narration, text="Day five. Halfway. Posters for the Trials have multiplied overnight, each one slightly crueller than the last."},
    {kind="return"}
}
scene dawn_6 {
    {kind=:narration, text="Day six. A grey morning, and a rumour already on every doorstep. Nobody will say what it is."},
    {kind="return"}
}
scene dawn_7 {
    {kind=:narration, text="Day seven. Rain on the roof, soft as a drum brush. The river has risen and the docks smell of old wood."},
    {kind="return"}
}
scene dawn_8 {
    {kind=:narration, text="Day eight. The whole town has started rehearsing in public. A man is reciting a speech to a goat."},
    {kind="return"}
}
scene dawn_9 {
    {kind=:narration, text="Day nine. The last full day. Someone has hung lanterns along the road to the Green, and for the first time the Trials feel less like a threat than a promise."},
    {kind="return"}
}
scene dawn_10 {
    {kind=:narration, text="Midsummer. The sun comes up like it has been rehearsing too. By evening the whole of Hollowbrook will be on the Green, and so will you."},
    {kind="return"}
}
