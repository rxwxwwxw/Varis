-- The archive: Pell, a ledger of riddles, and a shelf that is not for everyone.

storylet catalog()
    when { at(:player, :archive), free_time() }
    cooldown 2
    title "Catalogue the new arrivals"
    text [[Pell has a crate of unsorted pamphlets and the expression of a man who has been looking at it for a week.]]

    choice sort
        require { quality(:player, :stamina, ?st), ?st >= 1 }
        because "You are too tired for that. Sleep, eat, or sit down for a while."
        title "Sort the crate"
        effect do
            local bonus = (query bonus(:wits, ?n))()
            local gain = 3 + (bonus and bonus.n or 0)
            local v_wits = quality.get(:player, :wits)
            set quality(:player, :wits, math.min(100, v_wits + gain))
            local c = quality.get(:player, :coins)
            set quality(:player, :coins, math.min(200, c + 2))
            local t_pell = quality.get(:pell, :trust)
            set quality(:pell, :trust, math.min(5, t_pell + 1))
            local s = quality.get(:player, :stamina)
            set quality(:player, :stamina, math.max(0, s - 1))
            adjust quality(:world, :slot) by 1
            narrative.play(:r_catalog)
        end
    end
end

scene r_catalog {
    {kind=:narration, text="You sort by date, then by hand, then by what you suspect the author was ashamed of. Pell is quietly delighted, and pays you in coins and silence."},
    {kind="return"}
}

storylet riddle(?n, ?need)
    when { at(:player, :archive), free_time(), riddle(?n, ?need) }
    repeatable false
    priority 5
    title "A riddle from the shelves"
    text [[{#select n}{#case 1}Pell slides a card across the desk. It reads: "I have cities, but no houses; mountains, but no trees; water, but no fish."{#case 2}The second card reads: "The more you take, the more you leave behind."{#case 3}The third card reads, in a smaller hand: "What can be broken without being held, and kept only when given?"{#default}A card.{/select}]]

    choice solve
        require { quality(:player, :wits, ?w), ?w >= need }
        because "The words slide around in your head without settling."
        title "Answer it"
        effect do
            local bonus = (query bonus(:wits, ?n))()
            local gain = 3 + (bonus and bonus.n or 0)
            local v_wits = quality.get(:player, :wits)
            set quality(:player, :wits, math.min(100, v_wits + gain))
            local c = quality.get(:player, :coins)
            set quality(:player, :coins, math.min(200, c + 4))
            adjust quality(:world, :slot) by 1
            narrative.play(logic.symbol("r_riddle_" .. n))
        end
    end

    choice guess
        when { quality(:player, :wits, ?w), ?w < need }
        title "Make a guess"
        effect do
            local v_wits = quality.get(:player, :wits)
            set quality(:player, :wits, math.min(100, v_wits + 1))
            adjust quality(:world, :slot) by 1
            narrative.play(logic.symbol("r_riddle_miss_" .. n))
        end
    end
end

scene r_riddle_1 {
    {kind=:narration, text="\"A map,\" you say. Pell's eyebrows go up a fraction. \"The last person to solve that one took a week.\""},
    {kind="return"}
}

scene r_riddle_2 {
    {kind=:narration, text="\"Footsteps.\" Pell breathes out through his nose, which is applause. He gives you four coins from a drawer that is not a till."},
    {kind="return"}
}

scene r_riddle_3 {
    {kind=:narration, text="\"A promise.\" Pell takes off his spectacles to look at you, and you realise that for the first time he is looking at a person."},
    {kind="return"}
}

scene r_riddle_miss_1 {
    {kind=:narration, text="\"A... country?\" Pell sets the card aside with a small, kind, devastating cough."},
    {kind="return"}
}

scene r_riddle_miss_2 {
    {kind=:narration, text="\"Fear?\" you try. Pell considers this with enormous courtesy. \"Not unreasonable. Not correct.\""},
    {kind="return"}
}

scene r_riddle_miss_3 {
    {kind=:narration, text="\"A... window?\" Pell closes his eyes for a moment, as though in prayer, and passes you a biscuit."},
    {kind="return"}
}

storylet forbidden()
    when { at(:player, :archive), free_time(), quality(:pell, :trust, ?t), ?t >= 2, not has(:quarry_map) }
    priority 40
    title "The locked shelf"
    text [[Behind Pell's desk is a glass-fronted cabinet. He has never opened it in front of anyone. Today he has left the key on the blotter and his back turned.]]

    choice read
        require { quality(:player, :wits, ?w), ?w >= 60 }
        because "The old script swims. You can tell it is important and not why."
        title "Read what is inside"
        effect do
            fact has(:quarry_map)
            fact clue(:torn_ledger)
            local v_wits = quality.get(:player, :wits)
            set quality(:player, :wits, math.min(100, v_wits + 4))
            adjust quality(:world, :slot) by 1
            narrative.play(:r_forbidden_read)
        end
    end

    choice plead
        require { quality(:player, :charm, ?c), ?c >= 50 }
        because "Pell has been persuaded by better, and by worse. You have not got it in you yet."
        title "Ask Pell to open it for you"
        effect do
            fact has(:quarry_map)
            fact clue(:torn_ledger)
            local v_charm = quality.get(:player, :charm)
            set quality(:player, :charm, math.min(100, v_charm + 2))
            adjust quality(:world, :slot) by 1
            narrative.play(:r_forbidden_plead)
        end
    end
end

scene r_forbidden_read {
    {kind=:narration, text="A survey of the old quarry, with a bridge pier marked in red and a cache drawn as a small neat X. A page is torn from the ledger beside it; you note the shape of the tear."},
    {kind="return"}
}

scene r_forbidden_plead {
    {kind=:narration, text="You make your case, which is mostly that you would like very much to see a map. Pell regards you for the length of a long breath. \"Copy it,\" he says. \"Do not make me regret it.\""},
    {kind="return"}
}

storylet pell_clue()
    when { at(:player, :archive), flag(:banner_stolen), not clue(:torn_ledger), quality(:pell, :trust, ?t), ?t >= 1 }
    priority 10
    title "Ask Pell about the banner"
    text [[Pell keeps the town's accounts. Nobody has ever asked him whether they are all in order.]]

    choice ask
        title "Ask about the festival ledger"
        effect do
            fact clue(:torn_ledger)
            narrative.play(:r_pell_clue)
        end
    end
end

scene r_pell_clue {
    {kind=:say, character=:pell, attributes={expression=:neutral}, text="A page is missing from the festival ledger. The supplies line. Someone needed to know where the banner was stored, and then someone needed to forget I had written it down."},
    {kind=:say, character=:pell, attributes={expression=:worried}, text="The tear is clean. Tailor's scissors, I would say, or a dyer's."},
    {kind="return"}
}
