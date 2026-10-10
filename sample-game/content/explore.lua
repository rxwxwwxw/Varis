-- Exploration hub: parameterized storylets in the :default deck.
-- Parameters ground from `when` queries; each binding is an instance (§6.3).

storylet look(?room)
    when { at(:player, ?room) }
    priority 100                       -- always listed first
    title "Look around {room}"
    text [[
You are in {room}.
{#if query outdoors(room)}{#variant 3}A cold wind comes off the marsh.{#variant 1}Gulls wheel and scream overhead.{#variant 1}Fog lies flat on the water.{/variant}{/if}
{#if query night()}It is dark.{#else}It is daytime.{/if}
{#if query lamp_danger()}The lamp gutters. The oil is nearly gone.{/if}]]

    choice wait
        when { quality(:player, :resolve, ?r), ?r >= 1 }
        title "Wait a while"
        effect do
            adjust quality(:player, :resolve) by -1
        end
    end
end

storylet walk(?from, ?to)
    when { at(:player, ?from), open_exit(?from, ?to) }
    priority 50
    title "Go to {to}"
    text ""

    choice go
        title "Go"
        effect do
            set at(:player, to)
            narrative.emit(:moved, from, to)
        end
    end
end

-- A locked way the player can see but not take: the absence of a key
-- is expressed by negation; the presence of one by a choice `when`.
storylet locked_door(?from, ?to)
    when { at(:player, ?from), locked(?from, ?to) }
    priority 40
    title "A locked door leads to {to}"
    text "The door is iron-banded and locked."

    choice unlock(?key)
        when { unlocks(?key, ?from, ?to), carries(:player, ?key) }
        title "Unlock it with {key}"
        effect do
            retract locked(from, to)
            narrative.emit(:unlocked, from, to)
        end
    end

    choice force
        when { quality(:player, :resolve, ?r), ?r >= 8 }
        title "Put your shoulder to it"
        effect do
            adjust quality(:player, :resolve) by -3
            retract locked(from, to)
        end
    end
end

-- Picking things up uses an aggregate-derived load and a procedural guard.
storylet take(?thing, ?room)
    when { at(:player, ?room), at(?thing, ?room), item(?thing) }
    priority 30
    title "Pick up {thing}"
    text ""

    choice take
        when {
            load(:player, ?kg),
            item_weight(?thing, ?w),
            where(?kg + ?w <= 8)
        }
        title "Take it"
        effect do
            delete at(thing)
            fact carries(:player, thing)
        end
    end
end

storylet drop(?thing, ?room)
    when { at(:player, ?room), carries(:player, ?thing) }
    priority 10
    weight 1
    title "Put down {thing}"
    text ""

    choice drop
        title "Put it down"
        effect do
            retract carries(:player, thing)
            set at(thing, room)
        end
    end
end

-- A resting option with a cooldown (§6.2).
storylet rest()
    when { at(:player, :cottage), not night() }
    priority 5
    cooldown 4
    title "Sleep by the stove"
    text "An hour's sleep would steady you."

    choice sleep
        title "Sleep"
        effect do
            local r = quality.get(:player, :resolve)
            quality.set(:player, :resolve, math.min(10, r + 3))
            adjust quality(:world, :hour) by 1
        end
    end
end

-- Entering the market pushes a deck (Wordgrind's "leads to").
storylet go_shopping()
    when { at(:player, :market) }
    priority 45
    title "Browse the stalls"
    text "Fishwives and chandlers call their wares."

    choice browse
        title "Browse"
        effect do narrative.push_deck(:market) end
    end
end

storylet talk_keeper()
    when { at(:player, ?room), at(:keeper, ?room) }
    priority 45
    title "Talk to old Hesketh"
    text "Old Hesketh looks up from his pipe."

    choice talk
        title "Sit down beside him"
        effect do
            narrative.push_deck(:talk)
            fact met(:keeper)              -- duplicate facts are no-ops
        end
    end
end
