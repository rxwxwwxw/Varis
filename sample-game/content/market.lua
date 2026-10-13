-- The market deck: a random, non-repeating draw of wares (§9.3) plus a
-- fixed way out. Choice parameters come from the choice's own query.

storylet wares(?thing)
    when { stock(?thing) }
    deck :market
    priority 0
    weight 2
    title "A stall selling {thing}"
    text [[{#variant 1}The stallholder eyes your purse.{#variant 1}"Best in Saltmarsh," she says.{/variant}]]

    choice buy(?price)
        when {
            item_price(?thing, ?price),
            quality(:player, :coins, ?c),
            ?c >= ?price,
            load(:player, ?kg),
            item_weight(?thing, ?w),
            where(?kg + ?w <= 8)
        }
        title "Buy it for {price} coins"
        effect do
            adjust quality(:player, :coins) by -price
            retract stock(thing)
            fact carries(:player, thing)
            narrative.emit(:bought, thing, price)
        end
    end

    choice haggle
        when { quality(:player, :coins, ?c), ?c < 3, quality(:player, :resolve, ?r), ?r >= 1 }
        title "Plead poverty"
        effect do
            adjust quality(:player, :resolve) by -1
            quality.add(:player, :coins, 1)        -- library path, same constraints
        end
    end
end

-- Spyglass weighted rarely; a separate higher-priority storylet that only
-- appears once per deck entry (replacement = false on :market).
storylet rumour()
    when { stock(:spyglass) }
    deck :market
    priority 5
    title "A sailor muttering about a storm"
    text "\"Glass is falling. Big blow coming in three days, mark me.\""
    choice listen
        title "Listen"
        effect do fact knows(:storm) end
    end
end

storylet leave_market()
    when { at(:player, :market) }
    deck :market
    sticky true         -- always listed, no draw slot, exempt from non-replacement history
    order 100           -- displayed last
    title "Leave the stalls"
    text ""
    choice leave
        title "Back to the street"
        effect do narrative.return_deck() end
    end
end
