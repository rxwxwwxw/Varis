-- The hub: the dusk before each night, and the dawn after it. The warden talks to the heroes,
-- looks after what the last night broke, and goes up to the terraces. Going up writes the battle
-- request the host reads (pending(night)); the host runs the night and writes the result back.

storylet look(?n)
    when { clock(:phase, :dusk), quality(:world, :night, ?n) }
    sticky true
    order -50
    title "Dusk on Marrow Hill"
    text [[{#select n}{#case 1}The lamps are cold, and the first Dim are a rumour on the switchbacks.{#case 2}The second dusk. Ilse has oil on her sleeves and a question about the armoured ones.{#case 3}The third dusk. The east road is open, and the militia wants an answer.{#default}The last dusk. Every lamp in Marrow Hill is lit, and the Lantern is bright enough to read by.{/select}
{#if query bell_ruined()}The Bellfrey is a black shape against the sky; its bell is on the ground.{#else}Up in the Bellfrey the bell is being oiled for the night.{/if}
{#if query any_injured()}Somebody is missing from the lamp racks.{/if}
{#if query any_weak()}Corvin has walked the terraces and says a lamp or two will not last the night as things stand.{/if}]]

    choice look
        title "Look out over the terraces"
        effect do
            narrative.emit(:note, "The fog is thicker tonight.")
        end
    end
end

storylet go_up(?n)
    when { clock(:phase, :dusk), quality(:world, :night, ?n) }
    sticky true
    order 100
    title "The night comes"
    text ""

    choice go
        title "Go up to the terraces"
        effect do
            fact pending(n)
            set clock(:phase, :build)
        end
    end
end

-- Only ever seen after a battle was abandoned from a saved start (the host cannot go back before
-- the choice): the way back down. A battle that is running shows no hub at all.
storylet stand_down(?n)
    when { clock(:phase, :build), pending(?n) }
    sticky true
    order 100
    title "The terraces are quiet"
    text [[Nothing has come up the road yet. The lamps are where you left them.]]

    choice down
        title "Come down to the village"
        effect do
            retract pending(n)
            set clock(:phase, :dusk)
        end
    end
end

-- Dawn: the result, in exactly the words the night earned.
storylet report(?n, ?outcome, ?kills, ?leaks)
    when { clock(:phase, :dawn), result(?n, ?outcome, ?kills, ?leaks) }
    sticky true
    order -10
    title "Dawn after night {n}"
    text [[{#select outcome}{#case won}The terraces held.{#case withdrawn}You sounded the retreat, and the flame went down the hill in a lantern.{#default}The line broke before dawn.{/select} {#plural kills}{#one}One of the Dim fell on the road.{#other}{kills} of the Dim fell on the road.{/plural} {#select leaks}{#case 0}None got past the last lamp.{#default}{#plural leaks}{#one}One got past the last lamp.{#other}{leaks} got past the last lamp.{/plural}{/select}
{#if query mill_ruined()}The Mill is a ruin, and its people are sleeping in the barn.{/if}{#if query any_ruin()} There is mending to do.{/if}{#if query told(n)} Corvin does not say "I told you so". That is how you know he is thinking it.{/if}]]

    choice rest
        title "Rest until dusk"
        effect do
            local night = quality.get(:world, :night)
            if night >= 4 or (query flag(:lantern_out))() or (query decided(:sound_retreat))() then
                set clock(:phase, :over)
                if (query ending(:dimmed))() then
                    narrative.play(:ending_dimmed)
                elseif (query ending(:withdrawal))() then
                    narrative.play(:ending_withdrawal)
                elseif (query ending(:kept_at_cost))() then
                    narrative.play(:ending_cost)
                else
                    narrative.play(:ending_kept)
                end
            else
                set quality(:world, :night, night + 1)
                set clock(:phase, :dusk)
                narrative.play(logic.symbol("dawn_" .. (night + 1)))
            end
        end
    end
end

-- The bridge below the Mill ford: cut it and the road below it is longer (a wall edit);
-- leave it and the Dim take the short way.
storylet cut_bridge(?n)
    when { clock(:phase, :dawn), quality(:world, :night, ?n), ?n == 2, not flag(:bridge_cut), not flag(:bridge_kept) }
    sticky true
    title "The footbridge at the ford"
    text [[Ilse says the footbridge at the ford is rotten through. The Dim would cross it in a line and arrive in a lump. Corvin says a bridge is a bridge until the day you need one.]]

    choice cut
        title "Cut it down"
        effect do
            fact flag(:bridge_cut)
            set terrain_edit(46, 24, true)
            set terrain_edit(45, 24, true)
            set terrain_edit(44, 24, true)
        end
    end
    choice keep
        title "Leave it"
        effect do
            fact flag(:bridge_kept)
        end
    end
end

-- The scree on the left: clear it and the second cliff has a second gap, and the village earns
-- salvage; the Dim use the gap too.
storylet clear_scree(?n)
    when { clock(:phase, :dawn), quality(:world, :night, ?n), ?n == 3, not flag(:scree_cleared), not flag(:scree_left) }
    sticky true
    title "The scree path"
    text [[The rockfall under the second cliff has left a path of loose stone. Ilse wants the iron out of it. Corvin points out that a path is a path in both directions.]]

    choice clear
        title "Clear it for the iron"
        effect do
            fact flag(:scree_cleared)
            set terrain_edit(20, 27, false)
            set terrain_edit(21, 27, false)
            local oil = quality.get(:world, :oil)
            set quality(:world, :oil, math.min(400, oil + 30))
        end
    end
    choice leave
        title "Leave the scree"
        effect do
            fact flag(:scree_left)
        end
    end
end

storylet rebuild(?id, ?kind, ?q, ?r)
    when { clock(:phase, :dusk), ruin(?id), structure(?id, ?kind, ?q, ?r, ?l, ?h) }
    sticky true
    title "A ruin on the terraces"
    text [[{#select kind}{#case 12}The Bellfrey's frame is standing; the bell is not.{#case 13}The Mill's wheel is split. The people need it.{#default}A lamp lies in pieces where it burned.{/select}]]

    choice mend
        require { quality(:world, :oil, ?o), ?o >= 20 }
        because "Rebuilding takes 20 lamp-oil."
        title "Rebuild it"
        effect do
            retract ruin(id)
            set structure(id, kind, q, r, 1, 0)
            local oil = quality.get(:world, :oil)
            set quality(:world, :oil, oil - 20)
            local m = quality.get(:world, :morale)
            set quality(:world, :morale, math.min(10, m + 1))
        end
    end
end
