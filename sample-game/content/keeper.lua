-- Conversation with the keeper in the :talk deck. Topics are storylets that
-- are non-repeatable; trust gates deeper topics. This is how a Twine/Ren'Py
-- dialogue tree has to be expressed today: one storylet per node.

storylet topic_lamp()
    when { not told(:lamp) }
    deck :talk
    priority 10
    repeatable false
    title "Ask about the lamp"
    text [["Six measures of oil a night, lad. Less and she goes dark before dawn."]]
    choice nod
        title "Nod"
        effect do
            fact told(:lamp)
            adjust quality(:keeper, :trust) by 1
        end
    end
end

storylet topic_key()
    when { told(:lamp), not told(:key), quality(:keeper, :trust, ?t), ?t >= 1 }
    deck :talk
    priority 9
    repeatable false
    title "Ask why the lamp room is locked"
    text [[He fishes in his coat. "My knees can't manage the stair. Take this."]]
    choice accept
        title "Take the key"
        effect do
            fact told(:key)
            fact carries(:player, :brass_key)
            narrative.emit(:given, :keeper, :brass_key)
        end
    end
    choice refuse
        title "\"I'm not ready.\""
        effect do
            adjust quality(:keeper, :trust) by -1
        end
    end
end

storylet topic_storm()
    when { knows(:storm), not told(:storm), quality(:player, :resolve, ?r), ?r <= 8 }
    deck :talk
    priority 8
    repeatable false
    title "Tell him about the falling glass"
    text [[His face goes grey. "Then the lamp must burn all that night, whatever it costs."]]
    choice promise
        title "\"It will.\""
        effect do
            fact told(:storm)
            adjust quality(:player, :resolve) by 2
        end
    end
end

storylet small_talk()
    when { met(:keeper), quality(:keeper, :trust, ?t), ?t < 5 }  -- no clamping: guard the bound
    deck :talk
    priority 0
    cooldown 2
    title "Pass the time"
    text [[{#variant 1}He talks about wrecks.{#variant 1}He talks about his late wife.{#variant 1}He says nothing, and that is fine.{/variant}]]
    choice listen
        title "Listen"
        effect do adjust quality(:keeper, :trust) by 1 end
    end
end

storylet end_talk()
    when { met(:keeper) }
    deck :talk
    priority 100        -- top tier so the exit is always drawn (see needed_extensions.md §4.2)
    title "Get up"
    text ""
    choice bye
        title "Leave him to his pipe"
        effect do narrative.pop_deck() end
    end
end
