-- The docks: work, patience, and the broken bridge that three kinds of person can mend.

storylet unload()
    when { at(:player, :docks), free_time() }
    cooldown 2
    title "Unload the herring boat"
    text [[The boat-master is a woman with arms like rope and a voice like a gate. "Crates," she says. "Fast."]]

    choice haul
        require { quality(:player, :stamina, ?st), ?st >= 3 }
        because "You are too tired for that. Sleep, eat, or sit down for a while."
        title "Carry crates"
        effect do
            local bonus = (query bonus(:strength, ?n))()
            local gain = 3 + (bonus and bonus.n or 0)
            local v_strength = quality.get(:player, :strength)
            set quality(:player, :strength, math.min(100, v_strength + gain))
            local c = quality.get(:player, :coins)
            set quality(:player, :coins, math.min(200, c + 8))
            local s = quality.get(:player, :stamina)
            set quality(:player, :stamina, math.max(0, s - 3))
            adjust quality(:world, :slot) by 1
            narrative.play(:r_unload)
        end
    end
end

scene r_unload {
    {kind=:narration, text="Sixty crates, two buckets of ice and a long afternoon. You are paid in coins and a smell you will carry for a week."},
    {kind="return"}
}

storylet fish()
    when { at(:player, :docks), free_time() }
    cooldown 2
    title "Fish off the end of the pier"
    text [[A rod leans against a bollard where somebody forgot it. The river is the colour of tea.]]

    choice cast
        title "Sit and wait"
        effect do
            local bonus = (query bonus(:grit, ?n))()
            local gain = 2 + (bonus and bonus.n or 0)
            local v_grit = quality.get(:player, :grit)
            set quality(:player, :grit, math.min(100, v_grit + gain))
            local v_wits = quality.get(:player, :wits)
            set quality(:player, :wits, math.min(100, v_wits + 1))
            local c = quality.get(:player, :coins)
            set quality(:player, :coins, math.min(200, c + 2))
            local s = quality.get(:player, :stamina)
            set quality(:player, :stamina, math.min(10, s + 1))
            adjust quality(:world, :slot) by 1
            narrative.play(:r_fish)
        end
    end
end

scene r_fish {
    {kind=:narration, text="You catch nothing for two hours, then something small and furious. The patience gets into your bones, and with it a kind of calm that has not been there in days."},
    {kind="return"}
}

storylet bridge()
    when { at(:player, :docks), free_time(), broken(:docks, :quarry) }
    priority 40
    title "The broken bridge"
    text [[The old bridge to the quarry has a gap in the middle the width of a cart. A crowd of sensible people has gathered to agree that something should be done.]]

    choice engineer
        require { quality(:player, :wits, ?w), ?w >= 45, quality(:player, :strength, ?s), ?s >= 40 }
        because "You can see what the bridge needs, or you can lift it, but not both yet."
        title "Plan and haul a new span"
        effect do
            retract broken(:docks, :quarry)
            retract broken(:quarry, :docks)
            fact flag(:bridge_fixed)
            narrative.schedule(:town_talk, narrative.sequence(:bridge), 2)
            local v_wits = quality.get(:player, :wits)
            set quality(:player, :wits, math.min(100, v_wits + 2))
            local v_strength = quality.get(:player, :strength)
            set quality(:player, :strength, math.min(100, v_strength + 2))
            local f = quality.get(:player, :fame)
            set quality(:player, :fame, math.min(10, f + 2))
            adjust quality(:world, :slot) by 1
            narrative.play(:r_bridge_engineer)
            narrative.defer(function() Achievements.unlock("Mended the bridge") end)
        end
    end

    choice rally
        require { quality(:player, :charm, ?c), ?c >= 55 }
        because "They are listening, politely. But they are not yet listening to you."
        title "Rally the town to mend it"
        effect do
            retract broken(:docks, :quarry)
            retract broken(:quarry, :docks)
            fact flag(:bridge_fixed)
            narrative.schedule(:town_talk, narrative.sequence(:bridge), 2)
            local v_charm = quality.get(:player, :charm)
            set quality(:player, :charm, math.min(100, v_charm + 3))
            local t_tilly = quality.get(:tilly, :trust)
            set quality(:tilly, :trust, math.min(5, t_tilly + 1))
            local t_mara = quality.get(:mara, :trust)
            set quality(:mara, :trust, math.min(5, t_mara + 1))
            local f = quality.get(:player, :fame)
            set quality(:player, :fame, math.min(10, f + 2))
            adjust quality(:world, :slot) by 1
            narrative.play(:r_bridge_rally)
            narrative.defer(function() Achievements.unlock("Mended the bridge") end)
        end
    end

    choice pay
        require { quality(:player, :coins, ?c), ?c >= 15 }
        because "Carpenters cost fifteen coins and do not take promises."
        title "Hire the carpenters"
        effect do
            retract broken(:docks, :quarry)
            retract broken(:quarry, :docks)
            fact flag(:bridge_fixed)
            narrative.schedule(:town_talk, narrative.sequence(:bridge), 2)
            local c = quality.get(:player, :coins)
            set quality(:player, :coins, math.max(0, c - 15))
            local f = quality.get(:player, :fame)
            set quality(:player, :fame, math.min(10, f + 1))
            adjust quality(:world, :slot) by 1
            narrative.play(:r_bridge_pay)
        end
    end
end

scene r_bridge_engineer {
    {kind=:narration, text="A day of drawing in the dust, then of timber and rope and a great deal of swearing. When the last plank is pegged, the whole dockside walks across it, one by one, in a kind of ceremony."},
    {kind="return"}
}

scene r_bridge_rally {
    {kind=:narration, text="You stand on a crate and say what everyone is thinking. By evening there are forty people and a cart of planks. The bridge is mended before the sun goes down and you have somehow become its mother."},
    {kind="return"}
}

scene r_bridge_pay {
    {kind=:narration, text="The carpenters take your coins and do it in a morning. It is a perfectly good bridge. It is not a story anyone will tell."},
    {kind="return"}
}

storylet boatman()
    when { at(:player, :docks), flag(:banner_stolen), not clue(:boat_crate) }
    priority 10
    title "The ferryman"
    text [[The ferryman smokes a clay pipe and watches everyone come and go. He has seen more of Hollowbrook than the constable.]]

    choice ask
        require { quality(:player, :charm, ?c), ?c >= 25 }
        because "He nods at you, says nothing, and goes back to his pipe."
        title "Ask about the early boat"
        effect do
            fact clue(:boat_crate)
            narrative.play(:r_boatman)
        end
    end
end

scene r_boatman {
    {kind=:say, character=:tilly, attributes={expression=:neutral}, text="Lad with a long bundle took the first crossing to the quarry road. Said he was delivering linen. Linen does not clink like brass poles."},
    {kind=:narration, text="The ferryman shrugs when you thank him, as if he had said nothing at all."},
    {kind="return"}
}
