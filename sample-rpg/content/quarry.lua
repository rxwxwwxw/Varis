-- The old quarry: reachable only once the bridge is mended. A cache, a rival and the stars.

storylet climb()
    when { at(:player, :quarry), free_time(), not has(:cache_ring) }
    priority 30
    title "The north wall"
    text [[A rusted ring is set in the north wall, forty feet up, where the stone is as smooth as a table. The map had an X exactly there.]]

    choice climb
        require { quality(:player, :strength, ?s), ?s >= 50, quality(:player, :grit, ?g), ?g >= 35, quality(:player, :stamina, ?st), ?st >= 3 }
        because "You get ten feet up and know, with the perfect clarity of a falling person, that you will not get further."
        title "Climb for the ring"
        effect do
            fact has(:cache_ring)
            local v_strength = quality.get(:player, :strength)
            set quality(:player, :strength, math.min(100, v_strength + 3))
            local v_grit = quality.get(:player, :grit)
            set quality(:player, :grit, math.min(100, v_grit + 3))
            local c = quality.get(:player, :coins)
            set quality(:player, :coins, math.min(200, c + 25))
            local f = quality.get(:player, :fame)
            set quality(:player, :fame, math.min(10, f + 1))
            local s = quality.get(:player, :stamina)
            set quality(:player, :stamina, math.max(0, s - 3))
            adjust quality(:world, :slot) by 1
            narrative.play(:r_climb)
            narrative.defer(function() Achievements.unlock("The quarry cache") end)
        end
    end

    choice fall
        when { quality(:player, :strength, ?s), quality(:player, :grit, ?g), where(?s < 50 or ?g < 35) }
        title "Try it anyway"
        effect do
            local s = quality.get(:player, :stamina)
            set quality(:player, :stamina, math.max(0, s - 4))
            local v_grit = quality.get(:player, :grit)
            set quality(:player, :grit, math.min(100, v_grit + 1))
            adjust quality(:world, :slot) by 1
            narrative.play(:r_climb_fall)
        end
    end
end

scene r_climb {
    {kind=:narration, text="Hand over hand, with your fingertips as the only argument. At the top the ring comes away with a pull, and behind it is a hollow with a leather purse and twenty-five coins of a currency that has since changed its face."},
    {kind="return"}
}

scene r_climb_fall {
    {kind=:narration, text="You slide from ten feet, and land in a heap of shale and indignity. The wall is unharmed."},
    {kind="return"}
}

storylet race()
    when { at(:player, :quarry), free_time() }
    cooldown 4
    title "Dane's challenge"
    text [[Dane Whitlock is stretching on the lip of the quarry like a man who has done this before in front of mirrors. "Rim to the old crane and back," he says. "Loser carries the other's pack."]]

    choice sprint
        require { quality(:player, :grit, ?g), ?g >= 45, quality(:player, :stamina, ?s), ?s >= 2 }
        because "You do not have the lungs for the loop, and he does."
        title "Take the bet"
        effect do
            local v_grit = quality.get(:player, :grit)
            set quality(:player, :grit, math.min(100, v_grit + 2))
            local t_dane = quality.get(:dane, :trust)
            set quality(:dane, :trust, math.min(5, t_dane + 1))
            local f = quality.get(:player, :fame)
            set quality(:player, :fame, math.min(10, f + 1))
            local s = quality.get(:player, :stamina)
            set quality(:player, :stamina, math.max(0, s - 2))
            adjust quality(:world, :slot) by 1
            narrative.play(:r_race_win)
        end
    end

    choice jog
        when { quality(:player, :grit, ?g), ?g < 45 }
        title "Run it anyway"
        effect do
            local v_grit = quality.get(:player, :grit)
            set quality(:player, :grit, math.min(100, v_grit + 2))
            local t_dane = quality.get(:dane, :trust)
            set quality(:dane, :trust, math.max(-5, t_dane - 1))
            local s = quality.get(:player, :stamina)
            set quality(:player, :stamina, math.max(0, s - 2))
            adjust quality(:world, :slot) by 1
            narrative.play(:r_race_lose)
        end
    end
end

scene r_race_win {
    {kind=:narration, text="You run the way you did as a child: without thinking of the end. At the crane you are a stride ahead. At the rim you are two."},
    {kind=:say, character=:dane, attributes={expression=:worried}, text="Huh. You can really run. I had you down as the book-and-ribbon sort. Don't tell anyone I said that."},
    {kind="return"}
}

scene r_race_lose {
    {kind=:narration, text="Dane is a crack of speed at the first bend and a spot on the horizon by the second. You arrive to find him sitting on your pack."},
    {kind=:say, character=:dane, attributes={expression=:happy}, text="Good effort. Truly. Carry mine, would you?"},
    {kind="return"}
}

storylet stargaze()
    when { at(:player, :quarry), evening(), free_time() }
    cooldown 3
    title "The stars from the quarry floor"
    text [[The walls shut out the town. Above you, the sky is a ceiling full of the same few stories.]]

    choice watch
        title "Lie back and watch"
        effect do
            local v_wits = quality.get(:player, :wits)
            set quality(:player, :wits, math.min(100, v_wits + 1))
            local v_charm = quality.get(:player, :charm)
            set quality(:player, :charm, math.min(100, v_charm + 1))
            local s = quality.get(:player, :stamina)
            set quality(:player, :stamina, math.min(10, s + 2))
            adjust quality(:world, :slot) by 1
            narrative.play(:r_stars)
        end
    end
end

scene r_stars {
    {kind=:narration, text="The quarry holds the dark like a bowl. You count satellites that are not there yet and the names of things you have never been told. You leave a little lighter."},
    {kind="return"}
}

storylet quarry_train()
    when { at(:player, :quarry), free_time() }
    cooldown 2
    title "Run the quarry steps"
    text [[There are two hundred and eleven steps cut into the east wall, and nobody has ever thanked them.]]

    choice run
        require { quality(:player, :stamina, ?st), ?st >= 2 }
        because "You are too tired for that. Sleep, eat, or sit down for a while."
        title "Run them all"
        effect do
            local bonus = (query bonus(:grit, ?n))()
            local gain = 3 + (bonus and bonus.n or 0)
            local v_grit = quality.get(:player, :grit)
            set quality(:player, :grit, math.min(100, v_grit + gain))
            local s = quality.get(:player, :stamina)
            set quality(:player, :stamina, math.max(0, s - 2))
            adjust quality(:world, :slot) by 1
            narrative.play(:r_steps)
        end
    end
end

scene r_steps {
    {kind=:narration, text="On the second hundred, your thoughts run out. On the two hundred and eleventh you stand over the whole town and feel exactly as tall as you need to be."},
    {kind="return"}
}
