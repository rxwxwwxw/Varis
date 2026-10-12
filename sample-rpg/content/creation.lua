-- Character creation: a chain of storylets, each shown while the stage relation names its step.
-- Choices write facts and qualities; the final step starts the summer.

storylet family()
    when { stage(:creation, :family) }
    sticky true
    order -100
    title "Where do you come from?"
    text [[Aunt Odile pours the tea and waits. "Tell me about home," she says. "Properly, now. Who raised you?"]]

    choice farm
        title "Farming folk: long days, strong backs"
        effect do
            fact trait(:family, :farm)
            adjust quality(:player, :strength) by 15
            adjust quality(:player, :grit) by 8
            adjust quality(:player, :coins) by 3
            set stage(:creation, :temper)
        end
    end
    choice merchant
        title "Merchants: a ledger in every pocket"
        effect do
            fact trait(:family, :merchant)
            adjust quality(:player, :charm) by 12
            adjust quality(:player, :wits) by 5
            adjust quality(:player, :coins) by 15
            set stage(:creation, :temper)
        end
    end
    choice scholar
        title "Scholars: more books than furniture"
        effect do
            fact trait(:family, :scholar)
            adjust quality(:player, :wits) by 18
            adjust quality(:player, :coins) by 2
            adjust quality(:pell, :trust) by 1
            set stage(:creation, :temper)
        end
    end
    choice dock
        title "Dock folk: salt, rope and stubbornness"
        effect do
            fact trait(:family, :dock)
            adjust quality(:player, :strength) by 8
            adjust quality(:player, :grit) by 12
            adjust quality(:player, :charm) by 3
            set stage(:creation, :temper)
        end
    end
    choice gentry
        title "Gentry fallen on hard times: manners, no money"
        effect do
            fact trait(:family, :gentry)
            adjust quality(:player, :charm) by 10
            adjust quality(:player, :wits) by 10
            adjust quality(:dane, :trust) by -1
            set stage(:creation, :temper)
        end
    end
end

storylet temper()
    when { stage(:creation, :temper) }
    sticky true
    order -100
    title "What were you like as a child?"
    text [[Odile studies you over the rim of her cup. "And what were you like? Not what you were told. What you were."]]

    choice nerdy
        title "The bookish one: always reading, always asking why"
        effect do
            fact trait(:temper, :nerdy)
            adjust quality(:player, :wits) by 12
            set stage(:creation, :quirk1)
        end
    end
    choice athletic
        title "The athletic one: always climbing something"
        effect do
            fact trait(:temper, :athletic)
            adjust quality(:player, :strength) by 12
            set stage(:creation, :quirk1)
        end
    end
    choice charming
        title "The charmer: always talking your way out"
        effect do
            fact trait(:temper, :charming)
            adjust quality(:player, :charm) by 12
            set stage(:creation, :quirk1)
        end
    end
    choice loner
        title "The scrappy loner: you managed fine alone"
        effect do
            fact trait(:temper, :loner)
            adjust quality(:player, :grit) by 12
            set stage(:creation, :quirk1)
        end
    end
end

-- Two quirks, picked in two steps from one list; a quirk already chosen is not offered again.
storylet quirk_first()
    when { stage(:creation, :quirk1) }
    sticky true
    order -100
    title "What is your first quirk?"
    text [[“Everyone has a habit,” says Odile. “What is yours?”]]

    choice pick(?q)
        when { quirk_option(?q), not trait(:quirk, ?q) }
        title "{q}"
        effect do
            fact trait(:quirk, q)
            set stage(:creation, :quirk2)
        end
    end
end

storylet quirk_second()
    when { stage(:creation, :quirk2) }
    sticky true
    order -100
    title "And a second quirk?"
    text [[“And another,” says Odile. “One is a habit. Two is a personality.”]]

    choice pick(?q)
        when { quirk_option(?q), not trait(:quirk, ?q) }
        title "{q}"
        effect do
            fact trait(:quirk, q)
            set stage(:creation, :points)
        end
    end
end

-- Spare points: spent one at a time; the points quality is bounded below by zero, so an
-- overspend is impossible and a choice shows why it is unavailable.
storylet points(?left)
    when { stage(:creation, :points), quality(:player, :points, ?left) }
    sticky true
    order -100
    title "Spare effort"
    text [[You have {#plural left}{#one}one point{#other}{left} points{/plural} of spare effort to spend before the summer starts.]]

    choice strength
        require { quality(:player, :points, ?p), ?p >= 1 }
        because "You have no points left to spend."
        title "+5 Strength"
        effect do
            adjust quality(:player, :points) by -1
            adjust quality(:player, :strength) by 5
        end
    end
    choice wits
        require { quality(:player, :points, ?p), ?p >= 1 }
        because "You have no points left to spend."
        title "+5 Wits"
        effect do
            adjust quality(:player, :points) by -1
            adjust quality(:player, :wits) by 5
        end
    end
    choice charm
        require { quality(:player, :points, ?p), ?p >= 1 }
        because "You have no points left to spend."
        title "+5 Charm"
        effect do
            adjust quality(:player, :points) by -1
            adjust quality(:player, :charm) by 5
        end
    end
    choice grit
        require { quality(:player, :points, ?p), ?p >= 1 }
        because "You have no points left to spend."
        title "+5 Grit"
        effect do
            adjust quality(:player, :points) by -1
            adjust quality(:player, :grit) by 5
        end
    end
    choice done
        require { quality(:player, :points, 0) }
        because "Spend all of your points first."
        title "That is everything"
        effect do
            set stage(:creation, :look)
        end
    end
end

storylet look_choice()
    when { stage(:creation, :look) }
    sticky true
    order -100
    title "How do you dress?"
    text [[Odile finds you a mirror. "Well? What will they see when you walk into the square?"]]

    choice casual
        title "Plain and comfortable"
        effect do
            set stage(:creation, :confirm)
            narrative.play(:look_casual)
        end
    end
    choice sporty
        title "Practical: sleeves rolled, boots laced"
        effect do
            set stage(:creation, :confirm)
            narrative.play(:look_sporty)
        end
    end
    choice scholarly
        title "Neat: collar, waistcoat, a pen in the pocket"
        effect do
            set stage(:creation, :confirm)
            narrative.play(:look_scholarly)
        end
    end
end

storylet confirm()
    when { stage(:creation, :confirm) }
    sticky true
    order -100
    title "Ready?"
    text [[“There you are,” says Odile. “That is who is going to the Trials.”]]

    choice begin
        title "Begin the summer"
        effect do
            fact flag(:started)
            set stage(:creation, :done)
            narrative.play(:begin_summer)
        end
    end
    choice again
        title "Start over"
        effect do
            -- A transaction inside the effect: the reset is all or nothing.
            transaction do
                for _, f in ipairs {:farm, :merchant, :scholar, :dock, :gentry} do
                    retract trait(:family, f)
                end
                for _, t in ipairs {:nerdy, :athletic, :charming, :loner} do
                    retract trait(:temper, t)
                end
                for _, q in ipairs {:night_owl, :early_riser, :stubborn, :animal_friend, :light_sleeper, :sweet_tooth} do
                    retract trait(:quirk, q)
                end
                for _, s in ipairs {:strength, :wits, :charm, :grit} do
                    set quality(:player, s, 15)
                end
                set quality(:player, :coins, 5)
                set quality(:player, :points, 6)
                set quality(:pell, :trust, 0)
                set quality(:dane, :trust, 0)
            end
            set stage(:creation, :family)
        end
    end
end
