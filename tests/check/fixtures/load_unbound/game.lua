relation at(entity, room)
fact at(:player, :tower)

storylet lamp(?room)
    when { at(:player, :tower) }
    title "The lamp in {room}"
    choice go
        title "Go"
        effect do fact at(:player, :tower) end
    end
end

narrative.seal()
