-- Lanternfall: the world model. build_world() is the one authored source of schemas, rules and
-- starting facts; narrative.load validates saves against the same factory.
--
-- The world decides what a battle means: which heroes stand on the road, how far they obey, what
-- they grant, and how the story ends. The battle itself is simulated natively (TOWER_DEFENSE_PLAN.md).

local M = {}
M.RULES_VERSION = "lanternfall-rules-1"

function M.build_world()
    local w = logic.emptyworld()
    logic (w) do
        relation flag(name)                       -- story flags: wren_joined, husks_seen, ...
        relation clock(key, value) key(key)       -- phase: prologue, dusk, build, night, dawn
        relation joined(hero)                     -- heroes who stand with the warden
        relation structure(id, kind, q, r, level, hp) key(id)   -- the fortress, between nights
        relation ruin(id)                         -- a structure a battle destroyed
        relation injured(hero, through) key(hero) -- out of the road through the given night
        relation injuries(hero, count) key(hero)
        relation dead(hero)
        relation bond(a, b)                       -- heroes who have fought side by side
        relation seen(kind)                       -- enemy kinds the warden has met (journal)
        relation opened(sector)                   -- fog the warden has seen
        relation terrain_edit(q, r, wall) key(q, r)  -- a collapsed bridge, a cleared scree path
        relation weak(structure)                  -- the judge's forecast: it would fall
        relation told(night)                      -- a night in which a forecast came true
        relation forecast(name, value) key(name)  -- the judge's other numbers
        relation pending(night)                   -- a battle the story has asked for
        relation result(night, outcome, kills, leaks) key(night)
        relation decided(name)                    -- decisions taken in moments
        relation mod(name)                        -- decisions that modify the battle in progress
        relation sent(name)                       -- ...whose one-time effects were already sent
        relation did(hero, night)                 -- talked to this night
        relation proud(hero, night)               -- stood through a won night unhurt

        -- Who is on the road tonight: has joined, is not dead, is not still injured.
        rule unavailable(?h) :- injured(?h, ?t), quality(:world, :night, ?n), ?t >= ?n
        rule deployed(?h) :- joined(?h), not dead(?h), not unavailable(?h)

        -- Relationships turn into battle parameters (plan §4): obedience, ward, rally, flare.
        rule obeys(?h) :- deployed(?h), quality(?h, :trust, ?v), ?v >= 2
        rule ward(:ilse) :- deployed(:ilse), quality(:ilse, :trust, ?v), ?v >= 4
        rule rally(:corvin) :- deployed(:corvin), quality(:corvin, :trust, ?v), ?v >= 4
        rule wide_flare(:wren) :- deployed(:wren), quality(:wren, :trust, ?v), ?v >= 3
        rule reliable_repair(:ilse) :- deployed(:ilse), quality(:ilse, :trust, ?v), ?v >= 2
        rule bonded(?a, ?b) :- bond(?a, ?b), deployed(?a), deployed(?b)

        -- Trust in three bands (endings and the hero lines read them).
        rule trust_high(?h) :- quality(?h, :trust, ?v), ?v >= 4
        rule trust_mid(?h) :- quality(?h, :trust, ?v), ?v >= 2, ?v < 4
        rule trust_low(?h) :- quality(?h, :trust, ?v), ?v < 2

        -- The village: money for the Rebuild, morale shown at the hub.
        rule ruined(?kind) :- ruin(?id), structure(?id, ?kind, ?q, ?r, ?l, ?h)
        rule bell_ruined() :- ruin(1)
        rule mill_ruined() :- ruin(2)
        rule any_ruin() :- ruin(?id)
        rule any_weak() :- weak(?id)
        rule any_dead() :- dead(?h)
        rule any_injured() :- unavailable(?h)
        rule low_morale() :- quality(:world, :morale, ?m), ?m <= 3

        -- Endings (plan §6), from what was decided and what was lost.
        rule cost_paid() :- any_dead()
        rule cost_paid() :- bell_ruined(), low_morale()
        rule ending(:withdrawal) :- decided(:sound_retreat)
        rule ending(:dimmed) :- flag(:lantern_out)
        rule ending(:kept_at_cost) :- flag(:won_night_4), not decided(:sound_retreat), cost_paid()
        rule ending(:kept) :- flag(:won_night_4), not decided(:sound_retreat), not cost_paid()

        -- Starting state
        fact clock(:phase, :prologue)
        for _, h in ipairs {:ilse, :corvin} do fact joined(h) end
        fact structure(1, 12, 9, 3, 1, 160)    -- the Bellfrey: it rings through every night
        fact opened(1)
    end
    narrative.program(w, M.RULES_VERSION)
    return w
end

function M.initialize(w)
    quality.initialize(:world, :night, w)
    quality.initialize(:world, :morale, w)
    quality.initialize(:world, :food, w)
    quality.initialize(:world, :oil, w)
    for _, n in ipairs {:ilse, :corvin, :wren} do
        quality.initialize(n, :trust, w)
    end
    quality.set(:ilse, :trust, 2, w)
    quality.set(:corvin, :trust, 2, w)
    quality.set(:wren, :trust, 1, w)
end

return M
