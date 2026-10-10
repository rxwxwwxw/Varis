-- The lamp room: lighting and refuelling.

storylet lamp()
    when { at(:player, :lamp_room) }
    priority 60
    title "The great lamp"
    text [[
The lens is taller than you are.
{#if query lit(:lamp)}It burns, throwing its beam across the marsh.{#else}It is cold and dark.{/if}]]

    choice light
        when {
            not lit(:lamp),
            carries(:player, :matches),
            quality(:player, :oil, ?o), ?o > 0
        }
        title "Strike a match and light it"
        effect do
            fact lit(:lamp)
            narrative.emit(:lit)
            -- External effects run only after commit (§12.4).
            narrative.defer(function() Achievements.unlock("first_light") end)
        end
    end

    choice refill
        when { carries(:player, :oil_can), quality(:player, :oil, ?o), ?o <= 2 }
        title "Pour in the can of oil"
        effect do
            retract carries(:player, :oil_can)
            adjust quality(:player, :oil) by 4
        end
    end

    choice snuff
        when { lit(:lamp) }
        title "Snuff it to save oil"
        effect do retract lit(:lamp) end
    end
end
