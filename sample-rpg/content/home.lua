-- Aunt Odile's house: chores, books, dinner, and one story she tells only to people she trusts.

storylet chores()
    when { at(:player, :house), free_time() }
    cooldown 2
    title "Help Aunt Odile with the chores"
    text [[A list in Odile's slanting hand is pinned to the door: wood, water, the east fence, the hens.{#if query trait(:family, :farm)} You could do all of it in your sleep.{/if}]]

    choice work
        require { quality(:player, :stamina, ?st), ?st >= 2 }
        because "You are too tired for that. Sleep, eat, or sit down for a while."
        title "Work through the list"
        effect do
            local bonus = (query bonus(:strength, ?n))()
            local gain = 3 + (bonus and bonus.n or 0)
            local v_strength = quality.get(:player, :strength)
            set quality(:player, :strength, math.min(100, v_strength + gain))
            local t_odile = quality.get(:odile, :trust)
            set quality(:odile, :trust, math.min(5, t_odile + 1))
            local c = quality.get(:player, :coins)
            set quality(:player, :coins, math.min(200, c + 3))
            local s = quality.get(:player, :stamina)
            set quality(:player, :stamina, math.max(0, s - 2))
            adjust quality(:world, :slot) by 1
            narrative.play(:r_chores)
        end
    end
end

scene r_chores {
    {kind=:narration, text="Wood split, water hauled, the east fence propped with a plank you will have to apologise to later. Odile inspects it all and gives you three coins and a look you decide to treat as pride."},
    {kind="return"}
}

storylet read_books()
    when { at(:player, :house), free_time() }
    cooldown 1
    title "Read your father's books"
    text [[A shelf over the bed holds the books he left you. The spines are cracked in the places he loved.]]

    choice read
        require { quality(:player, :stamina, ?st), ?st >= 1 }
        because "You are too tired for that. Sleep, eat, or sit down for a while."
        title "Read until the candle gutters"
        effect do
            local w = quality.get(:player, :wits)
            local bonus = (query bonus(:wits, ?n))()
            local gain = 3 + (bonus and bonus.n or 0)
            local v_wits = quality.get(:player, :wits)
            set quality(:player, :wits, math.min(100, v_wits + gain))
            local s = quality.get(:player, :stamina)
            set quality(:player, :stamina, math.max(0, s - 1))
            adjust quality(:world, :slot) by 1
            if w < 35 then
                narrative.play(:r_books_1)
            elseif w < 55 then
                narrative.play(:r_books_2)
            else
                narrative.play(:r_books_3)
            end
        end
    end
end

scene r_books_1 {
    {kind=:narration, text="You read about tides and tithes and the correct use of a comma. Some of it even stays. Most of what stays is the comma."},
    {kind="return"}
}

scene r_books_2 {
    {kind=:narration, text="A treatise on weights and measures turns out to be a love letter to precision. You begin to notice how often the market's scales are lying."},
    {kind="return"}
}

scene r_books_3 {
    {kind=:narration, text="You find your father's own margin notes, argued in pencil with a dead author. By the third page you have joined the argument, and you are winning."},
    {kind="return"}
}

storylet cook()
    when { at(:player, :house), free_time(), evening() }
    cooldown 3
    title "Cook dinner for the house"
    text [[Odile is dozing in her chair. The pantry has onions, a heel of cheese and an ambition.]]

    choice cook
        title "Make something worth eating"
        effect do
            local v_charm = quality.get(:player, :charm)
            set quality(:player, :charm, math.min(100, v_charm + 2))
            local t_odile = quality.get(:odile, :trust)
            set quality(:odile, :trust, math.min(5, t_odile + 1))
            local s = quality.get(:player, :stamina)
            set quality(:player, :stamina, math.min(10, s + 2))
            adjust quality(:world, :slot) by 1
            narrative.play(:r_cook)
        end
    end
end

scene r_cook {
    {kind=:narration, text="The onions are a triumph. The cheese is a compromise. Odile eats two helpings and says nothing, which from her is a song."},
    {kind="return"}
}

storylet odile_story()
    when { at(:player, :house), evening(), quality(:odile, :trust, ?t), ?t >= 3, not has(:spectacles) }
    priority 20
    sticky true
    title "Odile has something to tell you"
    text [[Odile puts down her knitting and looks at you for a long moment. "There is something of your father's that I kept," she says.]]

    choice listen
        title "Sit with her and listen"
        effect do
            fact has(:spectacles)
            local v_wits = quality.get(:player, :wits)
            set quality(:player, :wits, math.min(100, v_wits + 2))
            local f = quality.get(:player, :fame)
            set quality(:player, :fame, math.min(10, f + 1))
            adjust quality(:world, :slot) by 1
            narrative.play(:r_odile_story)
            narrative.defer(function() Achievements.unlock("Odile's confidence") end)
        end
    end
end

scene r_odile_story {
    {kind=:say, character=:odile, attributes={expression=:worried}, text="He left Hollowbrook the summer of his own Trials. He did not win, and he never said why. He sent these back, wrapped in a note I never answered."},
    {kind=:say, character=:odile, attributes={expression=:happy}, text="Spectacles. Nothing grand. But he wrote that clear sight was the whole of cleverness. I think he meant you."},
    {kind="return"}
}
