-- What the story's decisions do to a running battle (the `battle_sync` hook's data). Each entry is
-- named by a decision a moment's scene records; `game.battle_sync` merges the entries of every
-- decision taken so far.
--
-- Persistent keys are re-sent at every sync, so they hold for the rest of the battle:
--   hero_mods = {{hero, radius, damage, obedience, rate}}   bonds = {{a, b, within, damage}}
--   global = {damage, bounty}
-- Event keys are sent once, when the decision is first taken:
--   orders = {{hero, order = "hold"|"move"|"follow", q, r, target}}
--   reinforce = {{kind, q, r}}   heal = {{lantern}|{hero, amount}|{near_hero, radius, amount}}
--   damage = {{hero, amount}}    reveal = {sector, ...}    end_with = "withdrawn"
-- A hero is named (:ilse, :corvin, :wren) or "downed" (the hero a moment found fallen).

return {
    -- night 2, the husks
    focus_fire     = {hero_mods = {{hero = :corvin, radius = 1}}, global = {damage = 15}},
    lamps_work     = {global = {damage = 20}},
    -- night 2, Wren cut off
    cover_wren     = {orders = {{hero = :corvin, order = "follow", target = :wren}},
                      hero_mods = {{hero = :corvin, radius = 1}}},
    hold_the_line  = {global = {damage = 10}},
    -- night 3
    side_by_side   = {bonds = {{a = :ilse, b = :corvin, within = 4, damage = 20}}},
    call_militia   = {reinforce = {{kind = 14, q = 70, r = 9}, {kind = 14, q = 74, r = 10}}},
    evacuate_mill  = {heal = {{lantern = 2}}, global = {bounty = -40}},
    give_minute    = {heal = {{near_hero = :ilse, radius = 4, amount = 25}}, hero_mods = {{hero = :ilse, rate = 40}}},
    no_time        = {},
    -- night 4
    rescue         = {heal = {{hero = "downed", amount = 20}}, orders = {{hero = :corvin, order = "hold"}}},
    leave_them     = {damage = {{hero = "downed", amount = 99}}},
    flare_valley   = {reveal = {6, 12, 18, 24, 30, 31, 32, 33, 34, 35, 36}},
    rally_lantern  = {orders = {{hero = :ilse, order = "move", q = 11, r = 4},
                                {hero = :corvin, order = "move", q = 11, r = 2},
                                {hero = :wren, order = "move", q = 12, r = 3}}},
    sound_retreat  = {end_with = "withdrawn"},
    stand          = {global = {damage = 25}},
}
