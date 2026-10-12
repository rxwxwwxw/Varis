-- Events: automatic actions, gossip handlers and the scheduled rumour.

-- A packed lunch: once per day, Odile's lunch lifts the spirits.
action packed_lunch()
    when { at(:player, :house), quality(:player, :stamina, ?s), ?s < 10, quality(:world, :slot, ?t), ?t <= 3, flag(:started) }
    once_per :day
    priority 10
    effect do
        local s = quality.get(:player, :stamina)
        set quality(:player, :stamina, math.min(10, s + 1))
        narrative.emit(:note, "Odile pushes a packed lunch into your hands.")
    end
end

-- Exhaustion costs a slot: at zero stamina you doze off where you stand.
action collapse()
    when { quality(:player, :stamina, 0), quality(:world, :slot, ?t), ?t <= 3, flag(:started) }
    once_per :turn
    priority 100
    effect do
        adjust quality(:world, :slot) by 1
        set quality(:player, :stamina, 2)
        narrative.emit(:note, "You are so tired you doze off where you sit, and lose a slot of the day.")
    end
end

-- A scheduled rumour: the mended bridge is talked about two turns later, everywhere at once.
narrative.on(:town_talk, function(world, kind, args)
    logic (world) do
        fact heard(:tilly, :bridge)
        local f = quality.get(:player, :fame)
        if f < 10 then
            set quality(:player, :fame, f + 1)
        end
        narrative.emit(:note, "Word of the bridge is all over town.")
    end
end)
