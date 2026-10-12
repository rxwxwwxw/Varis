-- The town square: the notice board, the constable, the entry fee, and the stolen banner.

storylet board(?job, ?stat, ?pay)
    when { at(:player, :square), free_time(), job(?job, ?stat, ?pay) }
    repeatable false
    weight 2
    title "Notice: {job}"
    text [[A strip of paper pinned to the board, in a neat hand: {#select job}{#case carry_barrels}barrels to the cooper's, hands wanted.{#case copy_ledgers}ledgers to be copied fair, steady hand required.{#case greet_visitors}visitors to be greeted and shown to their rooms, pleasant manner required.{#case mind_the_ferry}ferry to be minded while the ferryman sleeps off a wedding.{#default}work.{/select}]]

    choice take
        require { quality(:player, :stamina, ?st), ?st >= 1 }
        because "You are too tired to take on work today."
        title "Take the job"
        effect do
            local v = quality.get(:player, stat)
            set quality(:player, stat, math.min(100, v + 3))
            local c = quality.get(:player, :coins)
            set quality(:player, :coins, math.min(200, c + 7))
            adjust quality(:world, :slot) by 1
            narrative.play(logic.symbol("r_job_" .. logic.symbolname(job)))
        end
    end
end

scene r_job_carry_barrels {
    {kind=:narration, text="Forty barrels, one hill and a cooper who counts every one twice. By the end your hands know the shape of oak."},
    {kind="return"}
}

scene r_job_copy_ledgers {
    {kind=:narration, text="You copy three ledgers and find two errors in the original, one of them theft. You decide it is not your business and then spend an hour worrying."},
    {kind="return"}
}

scene r_job_greet_visitors {
    {kind=:narration, text="You greet nineteen visitors by name, and by the third you have begun to mean it. The innkeeper tips you and tells you that you have a gift."},
    {kind="return"}
}

scene r_job_mind_the_ferry {
    {kind=:narration, text="You pole the ferry across forty times and talk to nobody. The river tells you a great deal, but it is not interested in your answers."},
    {kind="return"}
}

storylet gossip()
    when { at(:player, :square), free_time() }
    cooldown 2
    title "The gossip circle"
    text [[Five people on a bench have the air of a jury that never quite delivers a verdict.]]

    choice join
        title "Join the circle"
        effect do
            fact heard(:odile, :deed)
            local v_charm = quality.get(:player, :charm)
            set quality(:player, :charm, math.min(100, v_charm + 2))
            local f = quality.get(:player, :fame)
            set quality(:player, :fame, math.min(10, f + 1))
            adjust quality(:world, :slot) by 1
            narrative.play(:r_gossip)
        end
    end
end

scene r_gossip {
    {kind=:narration, text="You learn a great deal about a woman's marriage and one useful thing about a man's debts. By the end, you are being invited to a funeral, and you are going."},
    {kind="return"}
}

storylet hask_heard()
    when { at(:player, :square), knows_of(:hask, :deed), not flag(:hask_praised) }
    priority 50
    sticky true
    title "The constable has heard"
    text [[Constable Hask is waiting under the lamp-post with the air of a man about to say something he has rehearsed.]]

    choice meet
        title "Meet his eye"
        effect do
            fact flag(:hask_praised)
            local t_hask = quality.get(:hask, :trust)
            set quality(:hask, :trust, math.min(5, t_hask + 2))
            local c = quality.get(:player, :coins)
            set quality(:player, :coins, math.min(200, c + 5))
            narrative.play(:r_hask_heard)
        end
    end
end

scene r_hask_heard {
    {kind=:say, character=:hask, attributes={expression=:happy}, text="Word gets round, as you will learn. Everyone I trust has told me something good about you before noon."},
    {kind=:say, character=:hask, attributes={expression=:neutral}, text="This is five coins from the town purse. It is not a payment. It is a thank-you in a form I am allowed to give."},
    {kind="return"}
}

storylet banner_theft()
    when { at(:player, :square), quality(:world, :day, ?d), ?d >= 6, not flag(:banner_stolen), flag(:started) }
    priority 90
    sticky true
    title "A crowd around the festival pole"
    text [[A knot of people stands around the empty pole where the festival banner should hang. Nobody is talking above a murmur.]]

    choice push
        title "Push to the front"
        effect do
            fact flag(:banner_stolen)
            narrative.play(:r_banner_theft)
        end
    end
end

scene r_banner_theft {
    {kind=:say, character=:hask, attributes={expression=:worried}, text="It was here at midnight and not at dawn. The banner has hung on that pole for two hundred years and nobody has ever taken it. Until now."},
    {kind=:say, character=:hask, attributes={expression=:neutral}, text="I am short of men and short of time. If you have eyes or a good word, use them, and tell me. Three things, mind. I will not accuse on a hunch."},
    {kind="return"}
}

storylet accuse()
    when { at(:player, :square), flag(:banner_stolen), not flag(:banner_solved), not flag(:accused_wrong) }
    priority 45
    sticky true
    title "Tell the constable who took it"
    text [[Hask has set up a desk by the pole and a ledger for names. "Say it plain," he says, "and be sure."]]

    choice name(?who)
        when { suspect(?who) }
        require { clue_count(?n), ?n >= 3 }
        because "You have suspicions, not evidence. Hask wants three things he can write down."
        title "Accuse {who}"
        effect do
            fact flag(:accused)
            if who == :dane_cousin then
                fact flag(:banner_solved)
                local t = quality.get(:hask, :trust)
                set quality(:hask, :trust, math.min(5, t + 2))
                local f = quality.get(:player, :fame)
                set quality(:player, :fame, math.min(10, f + 3))
                narrative.play(:r_accuse_right)
                narrative.defer(function() Achievements.unlock("Solved the banner theft") end)
            else
                fact flag(:accused_wrong)
                local t = quality.get(:hask, :trust)
                set quality(:hask, :trust, math.max(-5, t - 1))
                narrative.play(:r_accuse_wrong)
            end
        end
    end
end

scene r_accuse_right {
    {kind=:say, character=:hask, attributes={expression=:happy}, text="A dyer's apprentice, a Whitlock cousin, and a grudge about a disqualification three Trials ago. Of course. It is always something that small."},
    {kind=:say, character=:hask, attributes={expression=:neutral}, text="The banner is recovered, folded in the cousin's own sock drawer. The town owes you a drink. I owe you a better opinion."},
    {kind="return"}
}

scene r_accuse_wrong {
    {kind=:say, character=:hask, attributes={expression=:worried}, text="I will make enquiries. I will make them quietly, because you have just told me something that was not true in front of a whole square."},
    {kind=:narration, text="People find somewhere else to look."},
    {kind="return"}
}

storylet fee()
    when { at(:player, :square), not flag(:entered), flag(:started) }
    priority 8
    order 40
    title "The Trials entry table"
    text [[A trestle table by the town hall steps, a clerk with a quill, and a sign: ENTRY FEE THIRTY COINS. NO CREDIT. NO EXCEPTIONS. NO, NOT EVEN YOU.]]

    choice pay
        require { quality(:player, :coins, ?c), ?c >= 30 }
        because "The fee is thirty coins, and you do not have thirty coins."
        title "Pay the thirty coins"
        effect do
            fact flag(:entered)
            local c = quality.get(:player, :coins)
            set quality(:player, :coins, math.max(0, c - 30))
            local f = quality.get(:player, :fame)
            set quality(:player, :fame, math.min(10, f + 1))
            narrative.play(:r_fee)
        end
    end
end

scene r_fee {
    {kind=:narration, text="The clerk counts the coins twice, writes your name in a ledger and gives you a wooden token on a string. It weighs almost nothing, and you will feel it all summer."},
    {kind="return"}
}
