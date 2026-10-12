-- Authoring checks for Saltmarsh Light, written as author tests (AUTHORING_TOOLS_PLAN §5): a
-- scripted walkthrough with assertions, plus explain / analyze / save-load / replay.
--
--   cd sample-game && varis tools/check.lua       (or `varis test`, which also runs tests/)

package.path = "./?.lua;" .. package.path
local test = require("varis.test")

local function where_is(t, e)
    local r
    logic (t:world()) do r = (query at(e, ?room))() end
    return r and r.room
end

test.case("explanation, and local relations with local rules, before the lamp room is reachable", function()
    local t = test.play { seed = 42 }
    t:choose("take", "take", { thing = :matches })
    t:choose("walk", "go", { to = :shore })
    t:choose("walk", "go", { to = :tower })
    local why = narrative.explain(t.session, :lamp)
    print("explain :lamp ->", #why.instances, "instances")
    t:expect_hidden "lamp"
    logic (t:world()) do
        local here = where_is(t, :player)
        local relation next_door(1)
        rule next_door(?r) :- open_exit(here, ?r)
        local n = 0
        for _ in query next_door(?r) do n = n + 1 end
        assert(n == 1, "only the shore is open from the tower")
        local cut = 0
        for _ in query cut_off(?r) do cut = cut + 1 end
        assert(cut == 1, "lamp room is cut off while locked")
    end
end)

test.case("the key opens the door; save, transactions, analysis and replay log", function()
    local t = test.play { seed = 42 }
    t:choose("take", "take", { thing = :matches })
    t:choose("walk", "go", { to = :shore })
    t:choose("walk", "go", { to = :tower })
    t:choose("walk", "go", { to = :shore })
    t:choose("walk", "go", { to = :cottage })
    t:choose("talk_keeper", "talk")
    t:choose("topic_lamp", "nod")
    t:choose("topic_key", "accept")
    t:choose("end_talk", "bye")
    t:choose("walk", "go", { to = :shore })
    t:choose("walk", "go", { to = :tower })
    t:choose("locked_door", "unlock", { to = :lamp_room })
    t:choose("walk", "go", { to = :lamp_room })
    assert(where_is(t, :player) == :lamp_room)

    -- Save, load into a fresh session, compare.
    local saved = t:save()
    local restored = test.play { seed = 1 }
    restored:load(saved)
    assert(restored:save() == saved, "round trip must be byte-identical")

    -- A tentative purchase rolled back (transactions outside effects).
    local w = t:world()
    local before = quality.get(:player, :coins, w)
    transaction (w) do
        quality.add(:player, :coins, -5, w)
        assert(quality.get(:player, :coins, w) == before - 5)
        rollback
    end
    assert(quality.get(:player, :coins, w) == before)

    -- Bounded analysis from here (isolated clones; the live session is untouched).
    local report = narrative.analyze(t.session, { depth = 4, max_nodes = 300 })
    print("analyze: nodes", report.nodes, "complete", report.complete, "dead ends", #report.dead_ends)
    assert(t:save() == saved, "analysis must not change the session")

    -- The replay log is available for bug reports.
    print("replay records:", #t.session:replay_log().inputs)
end)

test.run()
