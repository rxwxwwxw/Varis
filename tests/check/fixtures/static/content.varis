storylet lamp(?room)
    when { at(:player, ?room), carries(:player) }
    deck :marktet
    title "The lamp in {rom}"
    text "Oil is {room} and {thing}."
    choice light
        when { quality(:player, :oyl, ?o), hunted(:player) }
        title "Light it"
        effect do fact at(:lamp, :room) end
    end
    choice light
        title "Light it again"
        effect do fact carries(:player, :lamp) end
    end
end

storylet lamp()
    when { at(:player, :tower) }
    title "Another lamp"
    choice go
        title "Go"
        effect do fact at(:player, :tower) end
    end
end
