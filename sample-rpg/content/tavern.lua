-- The Gilded Heron: the stage, the arm-wrestling table, and what people say over both.

storylet openmic()
    when { at(:player, :tavern), free_time() }
    cooldown 3
    title "Open mic at the Heron"
    text [[A stool, a stub of candle and a crowd that has already forgiven you in advance. Tilly waves you up.]]

    choice perform
        require { quality(:player, :charm, ?c), ?c >= 40, quality(:player, :stamina, ?s), ?s >= 1 }
        because "You get to the stool and a cough comes out. Tilly winces for you."
        title "Take the stage"
        effect do
            fact heard(:tilly, :deed)
            fact flag(:sang)
            local v_charm = quality.get(:player, :charm)
            set quality(:player, :charm, math.min(100, v_charm + 4))
            local c = quality.get(:player, :coins)
            set quality(:player, :coins, math.min(200, c + 8))
            local t_tilly = quality.get(:tilly, :trust)
            set quality(:tilly, :trust, math.min(5, t_tilly + 1))
            local f = quality.get(:player, :fame)
            set quality(:player, :fame, math.min(10, f + 1))
            local s = quality.get(:player, :stamina)
            set quality(:player, :stamina, math.max(0, s - 1))
            adjust quality(:world, :slot) by 1
            narrative.play(:r_openmic_win)
        end
    end

    choice stumble
        when { quality(:player, :charm, ?c), ?c < 40 }
        title "Try a verse"
        effect do
            local v_charm = quality.get(:player, :charm)
            set quality(:player, :charm, math.min(100, v_charm + 2))
            adjust quality(:world, :slot) by 1
            narrative.play(:r_openmic_stumble)
        end
    end
end

scene r_openmic_win {
    {kind=:narration, text="You tell a story about a goose and a bishop. By the end, grown men are wiping their eyes, and the fiddler has started playing under you without being asked."},
    {kind="return"}
}

scene r_openmic_stumble {
    {kind=:narration, text="You forget the second verse, then the first. A kind drunk finishes it for you and everyone claps. It is the nicest humiliation of your life."},
    {kind="return"}
}

storylet armwrestle()
    when { at(:player, :tavern), free_time() }
    cooldown 3
    title "The arm-wrestling table"
    text [[A dockhand the size of a doorframe is taking on all comers, loudly, for a copper a go.]]

    choice win
        require { quality(:player, :strength, ?s), ?s >= 55, quality(:player, :stamina, ?t), ?t >= 2 }
        because "Dockhands do not lose to people who have not been lifting things."
        title "Take the table"
        effect do
            fact heard(:tilly, :deed)
            local v_strength = quality.get(:player, :strength)
            set quality(:player, :strength, math.min(100, v_strength + 2))
            local v_grit = quality.get(:player, :grit)
            set quality(:player, :grit, math.min(100, v_grit + 1))
            local c = quality.get(:player, :coins)
            set quality(:player, :coins, math.min(200, c + 10))
            local f = quality.get(:player, :fame)
            set quality(:player, :fame, math.min(10, f + 1))
            local s = quality.get(:player, :stamina)
            set quality(:player, :stamina, math.max(0, s - 2))
            adjust quality(:world, :slot) by 1
            narrative.play(:r_arm_win)
        end
    end

    choice lose
        when { quality(:player, :strength, ?s), ?s < 55 }
        title "Have a go anyway"
        effect do
            local c = quality.get(:player, :coins)
            set quality(:player, :coins, math.max(0, c - 3))
            local v_grit = quality.get(:player, :grit)
            set quality(:player, :grit, math.min(100, v_grit + 2))
            local s = quality.get(:player, :stamina)
            set quality(:player, :stamina, math.max(0, s - 2))
            adjust quality(:world, :slot) by 1
            narrative.play(:r_arm_lose)
        end
    end
end

scene r_arm_win {
    {kind=:narration, text="It is a long ten seconds. Your whole arm turns to light, and then his knuckles touch the wood and the room erupts. He buys you a drink and calls you \"boss\" for the rest of the night."},
    {kind="return"}
}

scene r_arm_lose {
    {kind=:narration, text="He pins you in a heartbeat, and apologises in the way large men do: by buying you something and not looking at your face."},
    {kind="return"}
}

storylet eavesdrop()
    when { at(:player, :tavern), free_time() }
    cooldown 2
    title "Listen to the tables"
    text [[The Gilded Heron is a pot of low conversations, and you have a seat by the stove.]]

    choice listen
        title "Pretend to read a menu"
        effect do
            fact heard(:tilly, :overheard)
            local v_wits = quality.get(:player, :wits)
            set quality(:player, :wits, math.min(100, v_wits + 1))
            local v_charm = quality.get(:player, :charm)
            set quality(:player, :charm, math.min(100, v_charm + 1))
            adjust quality(:world, :slot) by 1
            narrative.play(:r_eavesdrop)
        end
    end
end

scene r_eavesdrop {
    {kind=:narration, text="A carter complains about bridge tolls. A tailor's wife complains about her husband's apprentices. A girl in the corner is learning the fiddle from a book. You leave with a head full of a town."},
    {kind="return"}
}

storylet tilly_clue()
    when { at(:player, :tavern), flag(:banner_stolen), not clue(:tilly_saw), quality(:tilly, :trust, ?t), ?t >= 1 }
    priority 10
    title "Ask Tilly about the night before"
    text [[Tilly keeps the one window in the square that stays lit all night.]]

    choice ask
        title "Ask what she saw from the window"
        effect do
            fact clue(:tilly_saw)
            narrative.play(:r_tilly_clue)
        end
    end
end

scene r_tilly_clue {
    {kind=:say, character=:tilly, attributes={expression=:neutral}, text="A lad came out of the square at three, carrying something long. Young. Quick. A cousin of someone, I would swear: he had the Whitlock walk."},
    {kind=:say, character=:tilly, attributes={expression=:worried}, text="I did not know it mattered. Tell the constable. And if it is who I think it is, tell him I am sorry too."},
    {kind="return"}
}
