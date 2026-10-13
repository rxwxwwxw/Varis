-- Saltmarsh Light: world model.
--
-- build_world() is the single authored source of schemas, rules and the
-- starting state. It is used both for a new game and as the world factory
-- passed to narrative.load(), so saves can be validated against it (§13.2).
-- Every relation an effect writes is declared here, because effects run
-- inside transactions and may not implicitly create relations (§3.5).

local M = {}

M.RULES_VERSION = "saltmarsh-rules-1"

function M.build_world()
    local w = logic.emptyworld()

    logic (w) do
        ---------------------------------------------------------------
        -- Schemas (named columns, keys)                         §2.1-2.2
        ---------------------------------------------------------------
        relation at(entity, room) key(entity)          -- where things are
        relation exit(from, to, dir)
        relation locked(from, to)
        relation unlocks(item, from, to)
        relation outdoors(room)
        relation item(name)
        relation item_weight(item, kg) key(item)
        relation item_price(item, coins) key(item)
        relation carries(person, item)
        relation lit(lamp)                              -- zero-or-one tuple
        relation met(person)
        relation told(topic)                            -- conversation topics heard
        relation knows(topic)                           -- topics unlocked by play
        relation flag(name)                             -- one-off story flags
        relation person(name)
        relation stock(item)                            -- market stock

        ---------------------------------------------------------------
        -- Rules (pure, stratified)                            §6, §8
        ---------------------------------------------------------------
        -- An exit is usable unless locked: negation over a base relation.
        rule open_exit(?a, ?b) :-
            exit(?a, ?b, ?_),
            not locked(?a, ?b)

        -- Recursive reachability over open exits.
        rule reachable(?a, ?b) :- open_exit(?a, ?b)
        rule reachable(?a, ?c) :- reachable(?a, ?b), open_exit(?b, ?c)

        -- Rooms the player cannot currently get to (stratified negation
        -- over a recursive relation).
        rule cut_off(?r) :-
            exit(?r, ?_, ?_),
            at(:player, ?here),
            ?r ~= ?here,
            not reachable(?here, ?r)

        -- Aggregates: how much the player is hauling.                §4
        rule load(?p, ?kg) :-
            person(?p),
            ?kg = sum { ?w : carries(?p, ?i), item_weight(?i, ?w) }

        rule item_count(?p, ?n) :-
            person(?p),
            ?n = count { carries(?p, ?i) }

        -- Things visible in the player's room.
        rule visible(?i) :- at(:player, ?r), at(?i, ?r), item(?i)

        -- Night is derived from the hour quality.
        rule night() :- quality(:world, :hour, ?h), ?h >= 20
        rule night() :- quality(:world, :hour, ?h), ?h < 6

        -- The lamp is in danger when it is night and oil is low.
        rule lamp_danger() :-
            night(),
            lit(:lamp),
            quality(:player, :oil, ?o),
            ?o <= 2

        ---------------------------------------------------------------
        -- Starting state
        ---------------------------------------------------------------
        fact person(:player)
        fact person(:keeper)

        -- map: cottage - shore - village - market ; shore - tower - lamp_room
        local exits = {
            {:cottage,   :shore,     "out"},
            {:shore,     :cottage,   "in"},
            {:shore,     :village,   "north"},
            {:village,   :shore,     "south"},
            {:village,   :market,    "east"},
            {:market,    :village,   "west"},
            {:shore,     :tower,     "up the causeway"},
            {:tower,     :shore,     "down the causeway"},
            {:tower,     :lamp_room, "up the stair"},
            {:lamp_room, :tower,     "down the stair"},
        }
        for _, e in ipairs(exits) do         -- procedural fact generation
            fact exit(e[1], e[2], e[3])
        end
        fact outdoors(:shore)
        fact outdoors(:village)
        fact outdoors(:market)

        fact locked(:tower, :lamp_room)
        fact unlocks(:brass_key, :tower, :lamp_room)

        for name, data in pairs {
            matches   = {kg = 0, price = 1},
            oil_can   = {kg = 4, price = 6},
            brass_key = {kg = 0, price = 0},
            rope      = {kg = 3, price = 3},
            bread     = {kg = 1, price = 1},
            spyglass  = {kg = 2, price = 9},
        } do
            local sym = logic.symbol(name)    -- dynamic symbol construction
            fact item(sym)
            fact item_weight(sym, data.kg)
            fact item_price(sym, data.price)
        end

        fact at(:player, :cottage)
        fact at(:keeper, :cottage)
        fact at(:matches, :cottage)
        fact at(:rope, :shore)
        fact stock(:oil_can)
        fact stock(:bread)
        fact stock(:spyglass)
        fact stock(:rope)
        fact stock(:matches)
    end

    -- Rules above use an aggregate expression callback; portable saves need
    -- an explicit authored program version (persistence decisions, Phase 7).
    narrative.program(w, M.RULES_VERSION)
    return w
end

-- Initial quality values for a fresh game. Runs as one transaction so a
-- failed constraint leaves the world untouched.
function M.initialize(w)
    transaction (w) do
        quality.initialize(:player, :coins, w)
        quality.initialize(:player, :oil, w)
        quality.initialize(:player, :resolve, w)
        quality.initialize(:keeper, :trust, w)
        quality.initialize(:world, :hour, w)
        quality.initialize(:world, :day, w)
        quality.set(:player, :coins, 8, w)
    end
end

return M
