-- The people on the hill. Each conversation is once a night; the choices move trust, and trust is
-- what the battle reads: who obeys, who wards, who rallies (the rules in world.lua).

storylet talk_ilse(?n, ?t)
    when { clock(:phase, :dusk), deployed(:ilse), quality(:world, :night, ?n), quality(:ilse, :trust, ?t), not did(:ilse, ?n) }
    sticky true
    order 10
    title "Ilse at the lamp racks"
    text [[{#select t}{#case 0}Ilse keeps her back to you and her hands on the wick.{#case 1}Ilse says what the lamps need without looking up.{#case 2}Ilse nods you over to the rack and hands you a rag.{#case 3}Ilse is humming, which she does not usually.{#default}Ilse has already laid out your lamps in the order you will want them.{/select}]]

    choice let_her
        title "Let Ilse choose where the lamps go"
        effect do
            fact did(:ilse, n)
            local v = quality.get(:ilse, :trust)
            set quality(:ilse, :trust, math.min(5, v + 1))
        end
    end
    choice back_her
        require { deployed(:corvin) }
        because "Corvin is not here to be overruled."
        title "Back Ilse over Corvin's objection"
        effect do
            fact did(:ilse, n)
            local v = quality.get(:ilse, :trust)
            set quality(:ilse, :trust, math.min(5, v + 1))
            local c = quality.get(:corvin, :trust)
            set quality(:corvin, :trust, math.max(0, c - 1))
        end
    end
    choice leave
        title "Leave her to her work"
        effect do
            fact did(:ilse, n)
        end
    end
end

storylet talk_corvin(?n, ?t)
    when { clock(:phase, :dusk), deployed(:corvin), quality(:world, :night, ?n), quality(:corvin, :trust, ?t), not did(:corvin, ?n) }
    sticky true
    order 11
    title "Corvin on the wall"
    text [[{#select t}{#case 0}Corvin stands on the wall as if he were deciding whether to push you off it.{#case 1}Corvin points out the road without being asked, which is a start.{#case 2}Corvin makes room beside him on the wall.{#case 3}Corvin tells you which lamp he would have built first.{#default}Corvin hands you his own map of the switchbacks, the one with the real notes on it.{/select}]]

    choice road
        title "Ask about the road"
        effect do
            fact did(:corvin, n)
            local v = quality.get(:corvin, :trust)
            set quality(:corvin, :trust, math.min(5, v + 1))
        end
    end
    choice guard_wren
        require { deployed(:wren) }
        because "Wren has not joined the watch yet."
        title "Promise to keep Wren off the road"
        effect do
            fact did(:corvin, n)
            local v = quality.get(:corvin, :trust)
            set quality(:corvin, :trust, math.min(5, v + 1))
        end
    end
    choice leave
        title "Nod and move on"
        effect do
            fact did(:corvin, n)
        end
    end
end

storylet talk_wren(?n, ?t)
    when { clock(:phase, :dusk), deployed(:wren), quality(:world, :night, ?n), quality(:wren, :trust, ?t), not did(:wren, ?n) }
    sticky true
    order 12
    title "Wren on the rooftop"
    text [[{#select t}{#case 0}Wren is sitting on the roof where nobody can reach her.{#case 1}Wren waves, then pretends she was stretching.{#case 2}Wren has saved you the good end of the roof.{#default}Wren is drawing the valley from memory, and the lines are all pointing at one place.{/select}]]

    choice valley
        title "Ask her about the valley"
        effect do
            fact did(:wren, n)
            fact flag(:asked_about_valley)
            local v = quality.get(:wren, :trust)
            set quality(:wren, :trust, math.min(5, v + 1))
        end
    end
    choice leave
        title "Let her be"
        effect do
            fact did(:wren, n)
        end
    end
end

-- The infirmary: the hero an earlier night downed is out of the road, and says so.
storylet infirmary(?hero, ?through, ?n)
    when { clock(:phase, :dusk), injured(?hero, ?through), quality(:world, :night, ?n), ?through >= ?n, not did(?hero, ?n) }
    sticky true
    order 20
    title "{hero} in the infirmary"
    text [[{hero} is propped up with a blanket and a bad temper. The lamps, {hero} says, can wait. They cannot, of course, and {hero} knows it.]]

    choice sit
        title "Sit with {hero}"
        effect do
            fact did(hero, n)
            local v = quality.get(hero, :trust)
            set quality(hero, :trust, math.min(5, v + 1))
        end
    end
    choice leave
        title "Let {hero} rest"
        effect do
            fact did(hero, n)
        end
    end
end

-- Remembrance: a place at the table.
storylet remembrance(?hero, ?n)
    when { clock(:phase, :dusk), dead(?hero), quality(:world, :night, ?n), not did(?hero, ?n) }
    sticky true
    order 21
    title "A place at the table"
    text [[Nobody sits in {hero}'s place at the table. Someone has put a lamp there, unlit.]]

    choice light
        title "Light it"
        effect do
            fact did(hero, n)
            local m = quality.get(:world, :morale)
            set quality(:world, :morale, math.min(10, m + 1))
        end
    end
end

-- The Valley Overlook: a new place once the fog has been shown to the warden.
storylet overlook(?n)
    when { clock(:phase, :dusk), opened(36), quality(:world, :night, ?n), not did(:overlook, ?n) }
    sticky true
    order 30
    title "The Valley Overlook"
    text [[From the overlook the valley is laid out like a map nobody drew. The fog is still there. It looks smaller.]]

    choice look
        title "Stand there a while"
        effect do
            fact did(:overlook, n)
            local m = quality.get(:world, :morale)
            set quality(:world, :morale, math.min(10, m + 1))
        end
    end
end
