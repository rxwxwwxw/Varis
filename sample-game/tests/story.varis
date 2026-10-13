-- Author tests for Saltmarsh Light: the walkthrough of tools/check.lua, written as a writer would.
--
--   cd sample-game && varis test

local function fetch_the_key(t)
    t:choose("take", "take", { thing = :matches })
    t:choose("walk", "go", { to = :shore })
    t:choose("walk", "go", { to = :cottage })
    t:choose("talk_keeper", "talk")
    t:choose("topic_lamp", "nod")
    t:choose("topic_key", "accept")
    t:choose("end_talk", "bye")
    t:choose("walk", "go", { to = :shore })
    t:choose("walk", "go", { to = :tower })
end

test.case("the lamp is out of reach before the door is open", function()
    local t = test.play { seed = 42 }
    t:choose("take", "take", { thing = :matches })
    t:choose("walk", "go", { to = :shore })
    t:choose("walk", "go", { to = :tower })
    t:expect_fact "at(:player, :tower)"
    t:expect_hidden "lamp"
end)

test.case("the keeper's key opens the lamp room, and the lamp can be lit", function()
    local t = test.play { seed = 42 }
    fetch_the_key(t)
    t:choose("locked_door", "unlock", { to = :lamp_room })
    t:choose("walk", "go", { to = :lamp_room })
    t:expect_fact "at(:player, :lamp_room)"
    t:expect_shown "lamp"
    t:choose("lamp", "light")
    t:expect_fact "narrative_event(?seq, ?turn, :lit, ?args)"
end)

test.case("a save loads back byte for byte", function()
    local t = test.play { seed = 42 }
    t:choose("take", "take", { thing = :matches })
    local saved = t:save()
    local again = test.play { seed = 42 }
    again:load(saved)
    assert(again:save() == saved, "the save did not round trip")
end)
