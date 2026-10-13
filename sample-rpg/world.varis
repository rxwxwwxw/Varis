-- The Hollowbrook Summer: world model. build_world() is the one authored source of
-- schemas, rules and starting facts; it is both the new-game world and the factory that
-- narrative.load validates saves against.

local M = {}
M.RULES_VERSION = "hollowbrook-rules-1"

function M.build_world()
    local w = logic.emptyworld()
    logic (w) do
        relation at(entity, place) key(entity)
        relation place(name)
        relation road(from, to)
        relation broken(from, to)
        relation npc(name)
        relation stat(name)
        relation stage(key, value) key(key)           -- character creation step
        relation trait(kind, value)                    -- family, temper, quirk
        relation quirk_option(name)
        relation has(item)
        relation flag(name)
        relation clue(name)
        relation grants(source, stat, amount)
        relation trial(name, result) key(name)
        relation player_name(who, name) key(who)
        relation friend(a, b)
        relation heard(person, rumor)
        relation suspect(who)
        relation job(id, stat, coins)
        relation sale(item, cost)
        relation riddle(n, need)
        relation technique(name)
        relation times(name, n) key(name)           -- how often an activity has been done

        -- Roads that are open: negation over a base relation.
        rule open_road(?a, ?b) :- road(?a, ?b), not broken(?a, ?b)
        -- Recursive reachability over open roads.
        rule reachable(?a, ?b) :- open_road(?a, ?b)
        rule reachable(?a, ?c) :- reachable(?a, ?b), open_road(?b, ?c)
        -- Stratified negation over a recursive relation.
        rule isolated(?p) :- place(?p), at(:player, ?here), ?p ~= ?here, not reachable(?here, ?p)

        -- Gossip travels along friendships, from the first friend to the second (recursion).
        rule knows_of(?p, ?r) :- heard(?p, ?r)
        rule knows_of(?p, ?r) :- friend(?q, ?p), knows_of(?q, ?r)

        -- What the player's background and belongings add to training.
        rule owns(?s) :- trait(?k, ?s)
        rule owns(?s) :- has(?s)
        rule owns(?s) :- technique(?s)
        rule bonus(?stat, ?n) :- stat(?stat), ?n = sum { ?b : grants(?s, ?stat, ?b), owns(?s) }

        -- Aggregates over the story so far.
        rule clue_count(?n) :- place(:square), ?n = count { clue(?c) }
        rule passed(?n) :- place(:square), ?n = count { trial(?t, :pass) }
        rule allies(?n) :- place(:square), ?n = count { npc(?p), quality(?p, :trust, ?t), ?t >= 3 }
        rule best_stat(?v) :- place(:square), ?v = max { ?x : stat(?s), quality(:player, ?s, ?x) }

        -- Things carried (techniques are not things).
        rule carried(?n) :- place(:square), ?n = count { has(?i) }
        rule nearly_solved() :- clue_count(?n), ?n >= 3

        -- Which of your strengths leads, and which endings that opens (stratified negation).
        rule leading(?s) :- best_stat(?v), stat(?s), quality(:player, ?s, ?v)
        rule patron(:hero) :- flag(:entered), passed(3), flag(:banner_solved), flag(:bridge_fixed)
        rule patron(:smith) :- flag(:entered), passed(?n), ?n >= 2, leading(:strength), quality(:mara, :trust, ?t), ?t >= 2
        rule patron(:scribe) :- flag(:entered), passed(?n), ?n >= 2, leading(:wits), quality(:pell, :trust, ?t), ?t >= 2
        rule patron(:troupe) :- flag(:entered), passed(?n), ?n >= 2, leading(:charm), quality(:tilly, :trust, ?t), ?t >= 2
        rule patron(:warden) :- flag(:entered), passed(?n), ?n >= 2, leading(:grit), quality(:hask, :trust, ?t), ?t >= 2
        rule tried(?name) :- trial(?name, ?_)
        rule any_patron() :- patron(?e)
        rule ending(?e) :- patron(?e)
        rule ending(:quiet) :- flag(:entered), place(:square), not any_patron()
        rule ending(:spectator) :- place(:square), not flag(:entered)

        -- Training is offered a little short of the cap, so no gain can overshoot a bound.
        rule trainable(?s) :- stat(?s), quality(:player, ?s, ?v), ?v <= 90

        -- Free time: slots remain today and the Trials have not begun.
        rule trials_time() :- quality(:world, :day, 10), quality(:world, :slot, ?t), ?t >= 3
        rule free_time() :- flag(:started), quality(:world, :slot, ?t), ?t <= 3, not trials_time()

        -- Zero-arity: derived time of day and the festival eve.
        rule evening() :- quality(:world, :slot, 3)
        rule spent() :- quality(:world, :slot, 4)
        rule festival_eve() :- quality(:world, :day, 10)

        ------------------------------------------------------------------
        -- Starting state
        ------------------------------------------------------------------
        for _, p in ipairs {:house, :square, :market, :forge, :archive, :tavern, :docks, :quarry, :green} do
            fact place(p)
        end
        local roads = {
            {:house, :square}, {:square, :market}, {:square, :forge}, {:square, :archive},
            {:square, :tavern}, {:market, :docks}, {:docks, :quarry}, {:square, :green},
        }
        for _, r in ipairs(roads) do
            fact road(r[1], r[2])
            fact road(r[2], r[1])
        end
        fact broken(:docks, :quarry)      -- the bridge
        fact broken(:quarry, :docks)
        fact broken(:square, :green)      -- opens on the festival eve
        fact broken(:green, :square)
        fact at(:player, :house)
        for _, n in ipairs {:mara, :pell, :odile, :tilly, :hask, :dane} do fact npc(n) end
        for _, s in ipairs {:strength, :wits, :charm, :grit} do fact stat(s) end
        fact quirk_option(:night_owl)
        fact quirk_option(:early_riser)
        fact quirk_option(:stubborn)
        fact quirk_option(:animal_friend)
        fact quirk_option(:light_sleeper)
        fact quirk_option(:sweet_tooth)
        -- Friendships that carry gossip.
        fact friend(:tilly, :mara)
        fact friend(:mara, :hask)
        fact friend(:hask, :pell)
        fact friend(:odile, :tilly)
        fact friend(:dane, :tilly)
        -- What each background or possession adds to training.
        fact grants(:stubborn, :strength, 1)
        fact grants(:stubborn, :grit, 1)
        fact grants(:farm, :strength, 1)
        fact grants(:scholar, :wits, 1)
        fact grants(:merchant, :charm, 1)
        fact grants(:dock, :grit, 1)
        fact grants(:whetstone, :strength, 1)
        fact grants(:spectacles, :wits, 1)
        fact grants(:ribbon, :charm, 1)
        fact grants(:leverage, :strength, 2)
        fact grants(:sweet_tooth, :charm, 0)
        -- Who might have taken the festival banner.
        fact suspect(:brewer)
        fact suspect(:tailor)
        fact suspect(:dane_cousin)
        -- The notice board.
        fact job(:carry_barrels, :strength, 7)
        fact job(:copy_ledgers, :wits, 7)
        fact job(:greet_visitors, :charm, 7)
        fact job(:mind_the_ferry, :grit, 7)
        -- The market's stock.
        fact sale(:whetstone, 8)
        fact sale(:tonic, 5)
        fact sale(:ribbon, 6)
        fact sale(:spectacles, 12)
        fact riddle(1, 25)
        fact riddle(2, 40)
        fact riddle(3, 55)
    end
    narrative.program(w, M.RULES_VERSION)
    return w
end

function M.initialize(w)
    for _, s in ipairs {:strength, :wits, :charm, :grit, :coins, :stamina, :points, :fame} do
        quality.initialize(:player, s, w)
    end
    quality.initialize(:world, :day, w)
    quality.initialize(:world, :slot, w)
    for _, n in ipairs {:mara, :pell, :odile, :tilly, :hask, :dane} do
        quality.initialize(n, :trust, w)
    end
    logic (w) do
        set stage(:creation, :family)
    end
end

return M
