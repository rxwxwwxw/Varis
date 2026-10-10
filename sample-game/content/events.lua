-- Automatic actions (§8), scheduled events and handlers (§12).
-- Actions are effectful commands chosen by the scheduler, not Datalog rules.

------------------------------------------------------------------------
-- Pre-choice phase
------------------------------------------------------------------------
action intro()
    when { not flag(:intro) }
    phase :pre
    once_per :game
    effect do
        fact flag(:intro)
        narrative.emit(:say, "Hesketh's lamp has lit the Saltmarsh channel for forty years. Tonight his knees have failed him.")
    end
end

------------------------------------------------------------------------
-- Post-choice phase: the clock. Priorities fix the order each turn.
------------------------------------------------------------------------
action clock()
    when { quality(:world, :hour, ?h), ?h < 24 }
    priority 100
    once_per :turn
    effect do
        adjust quality(:world, :hour) by 1
    end
end

action midnight()
    when { quality(:world, :hour, 24), quality(:world, :day, ?d), ?d < 9 }
    priority 90
    once_per :turn
    effect do
        set quality(:world, :hour, 0)
        adjust quality(:world, :day) by 1
        narrative.emit(:new_day)
    end
end

action lamp_burns()
    when { lit(:lamp), night(), quality(:player, :oil, ?o), ?o > 0 }
    priority 80
    once_per :turn
    effect do
        adjust quality(:player, :oil) by -1
    end
end

-- once_per :always is safe because the effect makes the action ineligible.
action lamp_out()
    when { lit(:lamp), quality(:player, :oil, 0) }
    priority 70
    once_per :always
    effect do
        retract lit(:lamp)
        narrative.emit(:say, "The lamp sputters and dies.")
    end
end

action dawn()
    when { lit(:lamp), not night() }
    priority 70
    once_per :always
    effect do
        retract lit(:lamp)
        narrative.emit(:say, "Dawn. You let the lamp go out.")
    end
end

-- A wage once per in-game day: a custom period (§8.3). The host must keep
-- the :day period in step with the :day quality (needed_extensions.md §3.1).
action daily_wage()
    when { told(:lamp), quality(:player, :coins, ?c), ?c <= 97 }
    priority 10
    once_per :day
    effect do
        quality.add(:player, :coins, 2)
        narrative.emit(:say, "Hesketh presses two coins into your hand.")
    end
end

------------------------------------------------------------------------
-- The storm: scheduled from an action parameter, resolved by a handler.
------------------------------------------------------------------------
action storm_brews(?h)
    when { quality(:world, :day, ?d), ?d >= 2, quality(:world, :hour, ?h), ?h >= 12, ?h < 20 }
    priority 60
    once_per :game
    effect do
        narrative.schedule(:storm, narrative.sequence(:ellen_may), 22 - h)
        narrative.emit(:say, "The sky to the west turns the colour of a bruise.")
    end
end

-- Handlers run in their own transaction and receive the session world.
-- Unqualified relations in an ordinary closure would use the lexical
-- default world, so the handler opens a world block explicitly.
narrative.on(:storm, function(world, kind, args)
    logic (world) do
        local ship = args[1]
        if (query lit(:lamp))() then
            fact flag(:ship_saved)
        else
            fact flag(:ship_wrecked)
        end
        narrative.emit(:storm_struck, ship)
    end
end)

------------------------------------------------------------------------
-- Endings: switch decks from an action.
------------------------------------------------------------------------
action to_ending()
    when { flag(?how), where(?how == :ship_saved or ?how == :ship_wrecked) }
    priority 200
    once_per :game
    effect do
        narrative.replace_deck(:ending)
    end
end

action broken()
    when { quality(:player, :resolve, 0), not flag(:ship_saved) }
    priority 199
    once_per :game
    effect do
        fact flag(:broken)
        narrative.replace_deck(:ending)
    end
end
