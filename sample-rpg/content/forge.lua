-- Mara Voss's forge: strength, a test of it, and what she teaches those who pass.

storylet bellows()
    when { at(:player, :forge), free_time() }
    cooldown 1
    title "Work Mara's bellows"
    text [[Mara jerks her chin at the great leather lungs of the forge. "Pump," she says. "Even. Not like a goose."]]

    choice pump
        require { quality(:player, :stamina, ?st), ?st >= 2 }
        because "You are too tired for that. Sleep, eat, or sit down for a while."
        title "Pump until she tells you to stop"
        effect do
            local s = quality.get(:player, :strength)
            local bonus = (query bonus(:strength, ?n))()
            local gain = 4 + (bonus and bonus.n or 0)
            local v_strength = quality.get(:player, :strength)
            set quality(:player, :strength, math.min(100, v_strength + gain))
            local c = quality.get(:player, :coins)
            set quality(:player, :coins, math.min(200, c + 2))
            local s = quality.get(:player, :stamina)
            set quality(:player, :stamina, math.max(0, s - 2))
            adjust quality(:world, :slot) by 1
            if s < 35 then
                narrative.play(:r_bellows_1)
            else
                narrative.play(:r_bellows_2)
            end
        end
    end
end

scene r_bellows_1 {
    {kind=:narration, text="Your arms burn by the tenth minute and weep by the thirtieth. Mara says \"Even,\" four times, and by the end it is almost true."},
    {kind="return"}
}

scene r_bellows_2 {
    {kind=:narration, text="You find the rhythm and the fire answers it, a long white breath. Mara nods at the flames, which is how she nods at you."},
    {kind="return"}
}

storylet anvil()
    when { at(:player, :forge), free_time(), not flag(:anvil_lifted) }
    title "The anvil"
    text [[In the corner stands a small anvil with a rope handle on its horn. Apprentices are measured by it. Mara does not mention it, which is how you know it matters.]]

    choice lift
        require { quality(:player, :strength, ?s), ?s >= 50 }
        because "The anvil does not so much as rock. It would take someone stronger."
        title "Lift it to your chest"
        effect do
            fact flag(:anvil_lifted)
            fact heard(:mara, :deed)
            local v_strength = quality.get(:player, :strength)
            set quality(:player, :strength, math.min(100, v_strength + 2))
            local t_mara = quality.get(:mara, :trust)
            set quality(:mara, :trust, math.min(5, t_mara + 2))
            local f = quality.get(:player, :fame)
            set quality(:player, :fame, math.min(10, f + 1))
            adjust quality(:world, :slot) by 1
            narrative.play(:r_anvil_lift)
            narrative.defer(function() Achievements.unlock("Lifted Mara's anvil") end)
        end
    end

    choice strain
        when { quality(:player, :strength, ?s), ?s < 50 }
        title "Heave anyway"
        effect do
            local s = quality.get(:player, :stamina)
            set quality(:player, :stamina, math.max(0, s - 3))
            local v_grit = quality.get(:player, :grit)
            set quality(:player, :grit, math.min(100, v_grit + 1))
            adjust quality(:world, :slot) by 1
            narrative.play(:r_anvil_strain)
        end
    end
end

scene r_anvil_lift {
    {kind=:narration, text="It comes up grudgingly, then all at once, and you stand in the forge with a hundredweight of iron against your chest and your heart going like a hammer."},
    {kind=:narration, text="Mara looks at the anvil, then at you, then at the anvil. \"Put it down gently,\" she says. \"It has been through enough.\""},
    {kind="return"}
}

scene r_anvil_strain {
    {kind=:narration, text="The anvil moves a hand's breadth and thinks better of it. You sit down very suddenly. Somewhere, a smith is not laughing."},
    {kind="return"}
}

storylet mentor()
    when { at(:player, :forge), free_time(), flag(:anvil_lifted), quality(:mara, :trust, ?t), ?t >= 2, not technique(:leverage) }
    priority 30
    title "Mara offers to teach you"
    text [[Mara wipes her hands on her apron. "You lift like someone who is going to hurt herself," she says. "Stand there."]]

    choice learn
        title "Learn the trick of leverage"
        effect do
            fact technique(:leverage)
            local v_strength = quality.get(:player, :strength)
            set quality(:player, :strength, math.min(100, v_strength + 4))
            local s = quality.get(:player, :stamina)
            set quality(:player, :stamina, math.max(0, s - 1))
            adjust quality(:world, :slot) by 1
            narrative.play(:r_mentor)
        end
    end
end

scene r_mentor {
    {kind=:say, character=:mara, attributes={expression=:neutral}, text="Strength is a fraction of the work. A bar, a block and a good place to stand: that is the rest."},
    {kind=:say, character=:mara, attributes={expression=:happy}, text="Again. Feet under you. Good. Now you are only half as stupid as you were an hour ago."},
    {kind="return"}
}

storylet lock()
    when { at(:player, :forge), free_time(), not flag(:lock_fixed) }
    title "A cracked lock"
    text [[A strongbox sits open on the bench, its lock a puzzle of broken wards. "Customer's," says Mara. "I do iron, not fiddly."]]

    choice mend
        require { quality(:player, :wits, ?w), ?w >= 35 }
        because "You turn the wards over and cannot tell which are meant to be broken."
        title "Mend the lock"
        effect do
            fact flag(:lock_fixed)
            local v_wits = quality.get(:player, :wits)
            set quality(:player, :wits, math.min(100, v_wits + 2))
            local t_mara = quality.get(:mara, :trust)
            set quality(:mara, :trust, math.min(5, t_mara + 1))
            local c = quality.get(:player, :coins)
            set quality(:player, :coins, math.min(200, c + 8))
            adjust quality(:world, :slot) by 1
            narrative.play(:r_lock_fixed)
        end
    end

    choice bodge
        when { quality(:player, :wits, ?w), ?w < 35 }
        title "Do your best"
        effect do
            local t_mara = quality.get(:mara, :trust)
            set quality(:mara, :trust, math.max(-5, t_mara - 1))
            local v_wits = quality.get(:player, :wits)
            set quality(:player, :wits, math.min(100, v_wits + 1))
            adjust quality(:world, :slot) by 1
            narrative.play(:r_lock_bodged)
        end
    end
end

scene r_lock_fixed {
    {kind=:narration, text="The trick is to listen to the lock rather than to your hands. Three small clicks, and the box opens as if embarrassed."},
    {kind=:narration, text="Mara pays you eight coins and says only, \"Not bad.\" You take it for a speech."},
    {kind="return"}
}

scene r_lock_bodged {
    {kind=:narration, text="Something snaps. It was either the right ward or the wrong one. Mara looks at the lock for a long time and then at you."},
    {kind="return"}
}

storylet mara_clue()
    when { at(:player, :forge), flag(:banner_stolen), not clue(:purple_dye), quality(:mara, :trust, ?t), ?t >= 1 }
    priority 10
    title "Ask Mara about the banner"
    text [[Mara's forge has a view of half the square, and she has never in her life looked at anything she did not mean to.]]

    choice ask
        title "Ask what she saw"
        effect do
            fact clue(:purple_dye)
            narrative.play(:r_mara_clue)
        end
    end
end

scene r_mara_clue {
    {kind=:say, character=:mara, attributes={expression=:neutral}, text="Somebody carried a bundle out of the square before dawn. Rough sacking. Hands stained purple to the wrist, the kind of purple dyers cannot get off in a week."},
    {kind=:say, character=:mara, attributes={expression=:worried}, text="I did not stop him. I assumed it was laundry. Tell Hask I said so, and tell him I am sorry."},
    {kind="return"}
}
