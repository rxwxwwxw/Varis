-- Ending deck. Each ending sets :game_over, which the host watches.

storylet saved()
    when { flag(:ship_saved) }
    deck :ending
    title "The Ellen May"
    text [[
At dawn a battered schooner limps into the channel, her crew waving at the tower.
{#if query told(:storm)}Hesketh weeps openly. You kept your promise.{/if}]]
    choice fin title "The end" effect do fact flag(:game_over) end end
end

storylet wrecked()
    when { flag(:ship_wrecked) }
    deck :ending
    title "Wreckage"
    text "In the morning the shore is strewn with timber. The lamp was dark."
    choice fin title "The end" effect do fact flag(:game_over) end end
end

storylet gave_up()
    when { flag(:broken), not flag(:ship_saved), not flag(:ship_wrecked) }
    deck :ending
    title "Too much"
    text "You walk inland and do not look back at the tower."
    choice fin title "The end" effect do fact flag(:game_over) end end
end
