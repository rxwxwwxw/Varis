-- PROPOSED SYNTAX ONLY. This file is not loaded by game.lua and will not
-- parse with the current interpreter. It shows how parts of Saltmarsh Light
-- would read with the extensions in ../needed_extensions.md (section refs
-- in brackets). Each block lists the current-spec workaround it replaces.

------------------------------------------------------------------------
-- [1.5] Binding arithmetic in rule bodies.
-- Replaces: load() via an aggregate, and night() as two rules.
------------------------------------------------------------------------
rule effective_resolve(?p, ?r) :-
    quality(?p, :resolve, ?base),
    bonus(?p, ?b),
    ?r := ?base + ?b                   -- inputs bound, result newly bound

rule night() :- quality(:world, :hour, ?h), ?h >= 20 or ?h < 6   -- [1.5] disjunctive comparison

------------------------------------------------------------------------
-- [1.1][1.2][1.3][1.6] Storylet fields and effect helpers.
------------------------------------------------------------------------
storylet talk_keeper()
    when { at(:player, ?room), at(:keeper, ?room) }
    expose ?room                       -- [1.6] existential usable in text, not identity
    title "Talk to Hesketh in {room}"
    leads :talk                        -- [1.2] Wordgrind-style push; `return` pops
    choice talk title "Sit down" effect do fact met(:keeper) end end
end

storylet leave_market()
    when { at(:player, :market) }
    deck :market
    sticky true                        -- [1.2] always shown, never drawn, ordered last
    order 100
    title "Leave the stalls"
    choice leave effect do narrative.return_deck() end end
end

action midnight()
    when { quality(:world, :hour, 24) }
    effect do
        set quality(:world, :hour, 0)
        adjust quality(:world, :day) by 1 clamp   -- [1.3] explicit clamping
        narrative.set_period(:day, quality.get(:world, :day))  -- [1.1] transactional
    end
end

choice buy(?price)
    when { item_price(?thing, ?price) }
    require { quality(:player, :coins, ?c), ?c >= ?price }   -- [4.3] shown disabled when false
        because "You can't afford it."
    title "Buy it for {price} coins"
    effect do adjust quality(:player, :coins) by -price end
end

------------------------------------------------------------------------
-- [3] Ren'Py-style linear scene: a coroutine yielding beats between
-- transactions. Each `say`/`menu` is a beat; state changes between beats
-- commit as their own transaction, so saves/rollback work at any beat.
------------------------------------------------------------------------
character hesketh { name = "Hesketh", color = "#c8a060", image = :hesketh }

scene first_night()
    show hesketh :tired at :left with :dissolve          -- [3.3] media beat
    hesketh "Forty years I've climbed that stair."        -- [3.2] say beat, stable line id
    hesketh "Tonight I can't."
    pause 0.5
    menu                                                  -- [3.1] inline menu
        "I'll do it."
            adjust quality(:keeper, :trust) by 1
            hesketh "Good lad."
        "Why me?" when quality(:player, :resolve, ?r), ?r >= 3
            hesketh "Because there's no one else."
            call explain_lamp()                           -- [3.1] call/return
    end
    local name = input "What do they call you?" default "lad"   -- [4.6]
    set player_name(:player, name)
    jump hub                                              -- [3.1] return to storylet hub
end

-- Storylets can start scenes; scenes can end in the hub.
storylet arrival()
    when { not flag(:intro) }
    priority 1000
    title "Evening"
    choice begin effect do fact flag(:intro); narrative.play(first_night) end end
end

------------------------------------------------------------------------
-- [2] Twine-style passages and links.
------------------------------------------------------------------------
passage "Shore" [[
The shingle crunches underfoot. [[Climb the causeway->Tower]] or
[[go back inside|Cottage]].
<% if visited("Tower") then %>The tower looks less frightening now.<% end %>
]]
