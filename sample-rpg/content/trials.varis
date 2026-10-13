-- The Trials: three contests on Midsummer night, each passed by whichever strength of yours you brought.

storylet trial_strength()
    when { at(:player, :green), not tried(:strength) }
    deck :trials
    priority 30
    sticky true
    title "The Lifting"
    text [[A cart wheel taller than you, an axle, and a rope. The judge calls it "the Lifting": raise the wheel to the pegs. Mara is watching, arms folded.]]

    choice heave
        require { quality(:player, :strength, ?s), ?s >= 60 }
        because "The wheel does not feel your effort. It would take a stronger back."
        title "Lift it with your back"
        effect do
            set trial(:strength, :pass)
            local v_strength = quality.get(:player, :strength)
            set quality(:player, :strength, math.min(100, v_strength + 2))
            local f = quality.get(:player, :fame)
            set quality(:player, :fame, math.min(10, f + 1))
            narrative.play(:r_ts_heave)
            if (query { trial(:strength, ?a), trial(:wits, ?b), trial(:charm, ?c) })() then
                narrative.replace_deck(:ending)
            end
        end
    end

    choice lever
        require { technique(:leverage) }
        because "You have not been shown how to make a lever do the lifting."
        title "Use Mara's leverage"
        effect do
            set trial(:strength, :pass)
            local f = quality.get(:player, :fame)
            set quality(:player, :fame, math.min(10, f + 1))
            narrative.play(:r_ts_lever)
            if (query { trial(:strength, ?a), trial(:wits, ?b), trial(:charm, ?c) })() then
                narrative.replace_deck(:ending)
            end
        end
    end

    choice endure
        require { quality(:player, :grit, ?g), ?g >= 50 }
        because "You do not have the stubbornness to hold it for that long."
        title "Grind it up"
        effect do
            set trial(:strength, :pass)
            local v_grit = quality.get(:player, :grit)
            set quality(:player, :grit, math.min(100, v_grit + 2))
            narrative.play(:r_ts_endure)
            if (query { trial(:strength, ?a), trial(:wits, ?b), trial(:charm, ?c) })() then
                narrative.replace_deck(:ending)
            end
        end
    end

    choice stumble
        when { quality(:player, :strength, ?s), ?s < 60, not technique(:leverage), quality(:player, :grit, ?g), ?g < 50 }
        title "Try your best"
        effect do
            set trial(:strength, :fail)
            narrative.play(:r_ts_fail)
            if (query { trial(:strength, ?a), trial(:wits, ?b), trial(:charm, ?c) })() then
                narrative.replace_deck(:ending)
            end
        end
    end
end

scene r_ts_heave {
    {kind=:narration, text="The wheel comes up in one long pull and you set it on the pegs without a sound. The crowd's roar is the best weather you have ever stood in."},
    {kind="return"}
}

scene r_ts_lever {
    {kind=:narration, text="A block, a bar, a place to stand. The wheel lifts as if it had been waiting to. Mara's mouth does something unfamiliar at one corner."},
    {kind="return"}
}

scene r_ts_endure {
    {kind=:narration, text="It takes you a minute and a half and you do not breathe for most of it. The crowd counts with you. When the wheel clicks into the pegs, you do not move for a while."},
    {kind="return"}
}

scene r_ts_fail {
    {kind=:narration, text="The wheel moves a hand and sags back. The crowd is kind about it. Somewhere, Mara is looking at her own boots."},
    {kind="return"}
}

storylet trial_wits()
    when { at(:player, :green), not tried(:wits) }
    deck :trials
    priority 20
    sticky true
    title "The Reckoning"
    text [[A table with three locked boxes, a ledger and a single sentence on a card: "One of these lies. Which, and how can you tell?" The judge turns the hourglass.]]

    choice solve
        require { quality(:player, :wits, ?w), ?w >= 60 }
        because "The sentences twist when you try to hold them."
        title "Work it out"
        effect do
            set trial(:wits, :pass)
            local v_wits = quality.get(:player, :wits)
            set quality(:player, :wits, math.min(100, v_wits + 2))
            local f = quality.get(:player, :fame)
            set quality(:player, :fame, math.min(10, f + 1))
            narrative.play(:r_tw_solve)
            if (query { trial(:strength, ?a), trial(:wits, ?b), trial(:charm, ?c) })() then
                narrative.replace_deck(:ending)
            end
        end
    end

    choice deduce
        require { clue_count(?n), ?n >= 3 }
        because "You haven't got enough threads to pull on yet."
        title "Reason from what you've learned this week"
        effect do
            set trial(:wits, :pass)
            local f = quality.get(:player, :fame)
            set quality(:player, :fame, math.min(10, f + 1))
            narrative.play(:r_tw_deduce)
            if (query { trial(:strength, ?a), trial(:wits, ?b), trial(:charm, ?c) })() then
                narrative.replace_deck(:ending)
            end
        end
    end

    choice bluff
        require { quality(:player, :charm, ?c), ?c >= 55 }
        because "The judge is not a person who is susceptible to flattery."
        title "Charm the judge into a hint"
        effect do
            set trial(:wits, :pass)
            local v_charm = quality.get(:player, :charm)
            set quality(:player, :charm, math.min(100, v_charm + 2))
            narrative.play(:r_tw_bluff)
            if (query { trial(:strength, ?a), trial(:wits, ?b), trial(:charm, ?c) })() then
                narrative.replace_deck(:ending)
            end
        end
    end

    choice guess
        when { quality(:player, :wits, ?w), ?w < 60, clue_count(?n), ?n < 3, quality(:player, :charm, ?c), ?c < 55 }
        title "Guess"
        effect do
            set trial(:wits, :fail)
            narrative.play(:r_tw_fail)
            if (query { trial(:strength, ?a), trial(:wits, ?b), trial(:charm, ?c) })() then
                narrative.replace_deck(:ending)
            end
        end
    end
end

scene r_tw_solve {
    {kind=:narration, text="Two of the boxes cannot both be telling the truth. The third has a grammatical tell, a small one, that only you and the dead man who wrote it would notice. You say which, and why, and the judge writes it down."},
    {kind="return"}
}

scene r_tw_deduce {
    {kind=:narration, text="You have spent a week learning how this town lies. It turns out that this is exactly the skill. Three questions, one answer, and the judge puts down her pen."},
    {kind="return"}
}

scene r_tw_bluff {
    {kind=:narration, text="You do not know the answer, but you know that the judge wants you to. You say a sentence that sounds like the answer and watch her face to learn if it was, and adjust. She is almost grateful."},
    {kind="return"}
}

scene r_tw_fail {
    {kind=:narration, text="You choose. You are wrong. You look at the sand in the glass and wonder how it was ever so slow."},
    {kind="return"}
}

storylet trial_charm()
    when { at(:player, :green), not tried(:charm) }
    deck :trials
    priority 10
    sticky true
    title "The Address"
    text [[A raised stage, a lantern, and a thousand faces. The judge announces: "The Address. Say something worth the town's attention." The crowd settles like a flock.]]

    choice speech
        require { quality(:player, :charm, ?c), ?c >= 60 }
        because "You do not yet have the voice to carry across the whole Green."
        title "Speak from the heart"
        effect do
            set trial(:charm, :pass)
            local v_charm = quality.get(:player, :charm)
            set quality(:player, :charm, math.min(100, v_charm + 2))
            local f = quality.get(:player, :fame)
            set quality(:player, :fame, math.min(10, f + 2))
            narrative.play(:r_tc_speech)
            if (query { trial(:strength, ?a), trial(:wits, ?b), trial(:charm, ?c) })() then
                narrative.replace_deck(:ending)
            end
        end
    end

    choice song
        require { flag(:sang) }
        because "You have never sung in front of anyone in Hollowbrook, and they will notice."
        title "Sing the song from the Heron"
        effect do
            set trial(:charm, :pass)
            local f = quality.get(:player, :fame)
            set quality(:player, :fame, math.min(10, f + 1))
            narrative.play(:r_tc_song)
            if (query { trial(:strength, ?a), trial(:wits, ?b), trial(:charm, ?c) })() then
                narrative.replace_deck(:ending)
            end
        end
    end

    choice allies
        require { allies(?n), ?n >= 2 }
        because "Not enough people in town would stand up and say a word for you."
        title "Let your friends speak for you"
        effect do
            set trial(:charm, :pass)
            local f = quality.get(:player, :fame)
            set quality(:player, :fame, math.min(10, f + 1))
            narrative.play(:r_tc_allies)
            if (query { trial(:strength, ?a), trial(:wits, ?b), trial(:charm, ?c) })() then
                narrative.replace_deck(:ending)
            end
        end
    end

    choice mumble
        when { quality(:player, :charm, ?c), ?c < 60, not flag(:sang), allies(?n), ?n < 2 }
        title "Say a few words"
        effect do
            set trial(:charm, :fail)
            narrative.play(:r_tc_fail)
            if (query { trial(:strength, ?a), trial(:wits, ?b), trial(:charm, ?c) })() then
                narrative.replace_deck(:ending)
            end
        end
    end
end

scene r_tc_speech {
    {kind=:narration, text="You talk about arriving, and not knowing a soul, and being fed. You do not remember the end of it. The Green does."},
    {kind="return"}
}

scene r_tc_song {
    {kind=:narration, text="The first note wobbles and then the fiddler from the Heron finds you in the dark, and a thousand people sing the goose-and-bishop chorus back at you."},
    {kind="return"}
}

scene r_tc_allies {
    {kind=:narration, text="Tilly stands first. Then Mara, with her arms folded. Then Hask, who has not done this in his life. By the end half the Green has stood up and you have not said anything at all."},
    {kind="return"}
}

scene r_tc_fail {
    {kind=:narration, text="You say \"thank you\" and \"I am glad to be here\" and then a thing about weather. Polite applause, like rain on a tent."},
    {kind="return"}
}

storylet verdict()
    when { at(:player, :green), flag(:started), not flag(:ended) }
    deck :ending
    priority 100
    title "The judges confer"
    text [[The judges put their heads together under the lanterns. When they look up, the whole Green holds its breath. "The guilds," says the oldest of them, "offer you the following."]]

    choice accept(?e)
        when { ending(?e) }
        title "Accept: {e}"
        effect do
            fact flag(:ended)
            narrative.play(logic.symbol("end_" .. logic.symbolname(e)))
            narrative.defer(function() Achievements.unlock("Finished the summer") end)
        end
    end
end

storylet watch_trials()
    when { at(:player, :green), not flag(:entered), not flag(:ended) }
    deck :ending
    priority 99
    title "You cannot enter"
    text [[You did not pay the fee, and the clerk has already put away the ledger. You are not one of the people in the square.]]

    choice watch
        title "Watch from the crowd"
        effect do
            fact flag(:ended)
            narrative.play(:end_spectator)
        end
    end
end

scene trials_open {
    {kind=:background, tag=:green},
    {kind=:audio, channel=:music, tag=:trial_theme},
    {kind=:hide, character=:player},
    {kind=:narration, text="Lanterns on every pole, trestle tables and a stage of planks. Hollowbrook has put on its second-best clothes. A drum starts somewhere to your left and you feel it in your teeth."},
    {kind=:show, character=:hask, slot=:right, attributes={expression=:neutral}},
    {kind=:say, character=:hask, id="trials.hask", text="Order. Order. Three Trials: the Lifting, the Reckoning, the Address. Do them in any order you like. The town will be watching."},
    {kind=:show, character=:dane, slot=:left, attributes={expression=:happy}},
    {kind=:say, character=:dane, id="trials.dane", text="Try not to fall over. Or do. I would find it very instructive."},
    {kind="return"}
}
scene trials_watch {
    {kind=:background, tag=:green},
    {kind=:narration, text="You have a perfectly good view from the back of the Green, and nobody to blame for it."},
    {kind="return"}
}
