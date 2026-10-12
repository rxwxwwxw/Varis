-- The market: coin, haggling, a thief, and a shop with limited pockets.

storylet haggle()
    when { at(:player, :market), free_time() }
    cooldown 3
    title "The fishmonger's scales"
    text [[The fishmonger's thumb has been on the scale for thirty years. He sees you notice, and does not lift it.]]

    choice bargain
        require { quality(:player, :charm, ?c), ?c >= 45 }
        because "The fishmonger has heard better patter from his own parrot."
        title "Out-talk him"
        effect do
            local c = quality.get(:player, :coins)
            set quality(:player, :coins, math.min(200, c + 14))
            local v_charm = quality.get(:player, :charm)
            set quality(:player, :charm, math.min(100, v_charm + 3))
            local t_tilly = quality.get(:tilly, :trust)
            set quality(:tilly, :trust, math.min(5, t_tilly + 1))
            adjust quality(:world, :slot) by 1
            narrative.play(:r_haggle_win)
        end
    end

    choice try
        when { quality(:player, :charm, ?c), ?c < 45 }
        title "Try to haggle"
        effect do
            local c = quality.get(:player, :coins)
            set quality(:player, :coins, math.min(200, c + 3))
            local v_charm = quality.get(:player, :charm)
            set quality(:player, :charm, math.min(100, v_charm + 1))
            adjust quality(:world, :slot) by 1
            narrative.play(:r_haggle_try)
        end
    end
end

scene r_haggle_win {
    {kind=:narration, text="You talk about the weather, his daughter, the price of salt and the injustice of a thumb. By the end he is paying you to stop, and you have fourteen coins and an enemy for life."},
    {kind="return"}
}

scene r_haggle_try {
    {kind=:narration, text="He gives you three coins and a fish you did not ask for, and you leave unsure whether that was winning."},
    {kind="return"}
}

storylet stall_work()
    when { at(:player, :market), free_time() }
    cooldown 2
    title "Mind a stall"
    text [[A cheese seller needs her stall minded while she "checks on a cousin". The cousin is apparently the tavern.]]

    choice mind
        require { quality(:player, :stamina, ?st), ?st >= 1 }
        because "You are too tired for that. Sleep, eat, or sit down for a while."
        title "Mind the stall"
        effect do
            local bonus = (query bonus(:charm, ?n))()
            local gain = 2 + (bonus and bonus.n or 0)
            local v_charm = quality.get(:player, :charm)
            set quality(:player, :charm, math.min(100, v_charm + gain))
            local c = quality.get(:player, :coins)
            set quality(:player, :coins, math.min(200, c + 6))
            local s = quality.get(:player, :stamina)
            set quality(:player, :stamina, math.max(0, s - 1))
            adjust quality(:world, :slot) by 1
            local seen = (query times(:stall, ?k))()
            local k = seen and seen.k or 0
            set times(:stall, k + 1)
            narrative.play(logic.symbol("r_stall_" .. math.min(k + 1, 3)))
        end
    end
end

scene r_stall_2 {
    {kind=:narration, text="A man buys a cheese for the sole purpose of telling you it was not very good. You thank him for his custom and he is moved to buy another."},
    {kind="return"}
}

scene r_stall_3 {
    {kind=:narration, text="By noon you have regulars. By two, a small queue. The seller returns to find you with the till, a joke and nobody worried."},
    {kind="return"}
}

scene r_stall_1 {
    {kind=:narration, text="You sell eleven wedges, one wheel and an opinion of the cheese that is entirely yours. The seller returns pink and cheerful and pays you six coins."},
    {kind="return"}
}

storylet thief()
    when { at(:player, :market), free_time(), not flag(:thief_done) }
    priority 15
    weight 3
    title "A hand in a pocket"
    text [[A quick shape slides through the crowd, and the weight of your purse changes in a way you notice a second too late.]]

    choice chase
        require { quality(:player, :grit, ?g), ?g >= 40, quality(:player, :stamina, ?s), ?s >= 2 }
        because "You do not have the legs, or the nerve, for a chase through that crowd."
        title "Run the thief down"
        effect do
            fact flag(:thief_done)
            local v_grit = quality.get(:player, :grit)
            set quality(:player, :grit, math.min(100, v_grit + 2))
            local t_hask = quality.get(:hask, :trust)
            set quality(:hask, :trust, math.min(5, t_hask + 1))
            local c = quality.get(:player, :coins)
            set quality(:player, :coins, math.min(200, c + 5))
            local s = quality.get(:player, :stamina)
            set quality(:player, :stamina, math.max(0, s - 2))
            adjust quality(:world, :slot) by 1
            narrative.play(:r_thief_chase)
        end
    end

    choice shout
        require { quality(:player, :charm, ?c), ?c >= 35 }
        because "You open your mouth. The market is much too loud."
        title "Shout for the constable"
        effect do
            fact flag(:thief_done)
            local t_hask = quality.get(:hask, :trust)
            set quality(:hask, :trust, math.min(5, t_hask + 1))
            local v_charm = quality.get(:player, :charm)
            set quality(:player, :charm, math.min(100, v_charm + 1))
            adjust quality(:world, :slot) by 1
            narrative.play(:r_thief_shout)
        end
    end

    choice let_go
        title "Let it go"
        effect do
            fact flag(:thief_done)
            local c = quality.get(:player, :coins)
            set quality(:player, :coins, math.max(0, c - 5))
            adjust quality(:world, :slot) by 1
            narrative.play(:r_thief_let)
        end
    end
end

scene r_thief_chase {
    {kind=:narration, text="Three stalls, a barrow, a flight of steps and a very surprised goose. You catch the thief by the collar at the fountain, and take back more than he took. Constable Hask arrives to find the matter entirely concluded."},
    {kind="return"}
}

scene r_thief_shout {
    {kind=:narration, text="\"STOP, THIEF!\" turns the whole market into a net. The thief is caught by a cheese seller with a shovel. Hask takes your name down, with approval."},
    {kind="return"}
}

scene r_thief_let {
    {kind=:narration, text="You decide that whatever he took is the price of not running. Your purse is lighter and your feet are unhurt, and you learn a thing about the market that is worth more than the coins."},
    {kind="return"}
}

storylet lost_child()
    when { at(:player, :market), free_time(), not flag(:child_found) }
    priority 12
    title "A crying child by the well"
    text [[A small child in a stolen hat is sitting by the well, being very brave in the loudest way possible.]]

    choice help
        title "Find her family"
        effect do
            fact flag(:child_found)
            local v_charm = quality.get(:player, :charm)
            set quality(:player, :charm, math.min(100, v_charm + 3))
            local t_tilly = quality.get(:tilly, :trust)
            set quality(:tilly, :trust, math.min(5, t_tilly + 2))
            local f = quality.get(:player, :fame)
            set quality(:player, :fame, math.min(10, f + 1))
            adjust quality(:world, :slot) by 1
            narrative.play(:r_child)
        end
    end
end

scene r_child {
    {kind=:narration, text="Her cousin is Tilly Marsh, who runs the tavern, and who hugs the child so hard the hat flies off. Tilly looks at you for a moment longer than she needs to. \"I owe you,\" she says. In Hollowbrook that is a currency."},
    {kind="return"}
}

storylet shop(?item, ?cost)
    when { at(:player, :market), sale(?item, ?cost), not has(?item) }
    order 30
    title "For sale: {item}"
    text [[The stallholder holds it up so the light catches it. "{cost} coins," she says, "and you will not find better."]]

    choice buy
        require { quality(:player, :coins, ?c), ?c >= cost, carried(?n), ?n <= 2 }
        because "You cannot afford it, or your pockets are full (three things at most)."
        title "Buy it"
        effect do
            -- A transaction: the purchase is all or nothing.
            transaction do
                local c = quality.get(:player, :coins)
                set quality(:player, :coins, c - cost)
                fact has(item)
                local carried = (query carried(?n))()
                if carried.n > 3 then rollback end
            end
            narrative.play(:r_bought)
        end
    end
end

scene r_bought {
    {kind=:narration, text="The coins change hands and so does a little of your attention. You tuck it away and the stallholder is already looking at someone else."},
    {kind="return"}
}
