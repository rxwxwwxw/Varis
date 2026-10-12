-- Author tests for The Hollowbrook Summer: creation, gating, time, saves, language.
--
--   cd sample-rpg && varis test

-- The scenes the test does not care about are acknowledged: input gets a name, menus the first answer.
local function settle(t)
    for _ = 1, 500 do
        local p = t.session:present()
        if not p.beats then break end
        local b = p.beats[1]
        if b.kind == :input then
            t.session:advance(p.token, "Rowan")
        elseif b.kind == :menu then
            t.session:advance(p.token, b.choices[1].id)
        else
            t.session:advance(p.token)
        end
    end
    t._presentation = nil
    return t
end

local function pick(t, story, choice, bindings)
    t:choose(story, choice, bindings)
    return settle(t)
end

-- A choice with its own parameter (?q, ?who, ?e) is picked by that binding.
local function pick_with(t, story, choice, bindings)
    local shown = t:shown(story)
    assert(shown, story .. " is not shown")
    for _, c in ipairs(shown.choices) do
        local ok = c.id == choice
        for k, v in pairs(bindings) do ok = ok and c.bindings[k] == v end
        if ok then
            assert(c.token, "choice is disabled: " .. tostring(c.because))
            t.session:choose(c.token)
            if t.after_choose then t.after_choose(t.session) end
            return settle(t)
        end
    end
    error("no choice " .. tostring(choice) .. " with those bindings in " .. story)
end

local function start(seed)
    local t = test.play { seed = seed or 7 }
    t.session:play(:prologue)
    return settle(t)
end

-- A strong, farm-raised character: STR 15 + 15 (farm) + 12 (athletic) + 20 (four points) = 62.
local function strong(t)
    pick(t, "family", "farm")
    pick(t, "temper", "athletic")
    pick_with(t, "quirk_first", :pick, { q = :stubborn })
    pick_with(t, "quirk_second", :pick, { q = :night_owl })
    for _ = 1, 4 do pick(t, "points", "strength") end
    pick(t, "points", "grit")
    pick(t, "points", "grit")
    pick(t, "points", "done")
    pick(t, "look_choice", "sporty")
    pick(t, "confirm", "begin")
    return t
end

local function scholarly(t)
    pick(t, "family", "scholar")
    pick(t, "temper", "nerdy")
    pick_with(t, "quirk_first", :pick, { q = :early_riser })
    pick_with(t, "quirk_second", :pick, { q = :sweet_tooth })
    for _ = 1, 6 do pick(t, "points", "wits") end
    pick(t, "points", "done")
    pick(t, "look_choice", "scholarly")
    pick(t, "confirm", "begin")
    return t
end

local function walk(t, to) return pick(t, "walk", "go", { to = to }) end

test.case("the name typed in the scene reaches the world, and creation sets the stats", function()
    local t = strong(start())
    t:expect_fact "player_name(:player, \"Rowan\")"
    t:expect_fact "flag(:started)"
    t:expect_quality(:player, :strength, 62)
    t:expect_quality(:player, :grit, 15 + 8 + 10)  -- base, farm, two points of five
end)

test.case("starting over resets the build", function()
    local t = start()
    pick(t, "family", "dock")
    pick(t, "temper", "loner")
    pick_with(t, "quirk_first", :pick, { q = :stubborn })
    pick_with(t, "quirk_second", :pick, { q = :light_sleeper })
    pick(t, "points", "strength")
    pick(t, "points", "strength")
    pick(t, "points", "charm")
    pick(t, "points", "charm")
    pick(t, "points", "grit")
    pick(t, "points", "grit")
    pick(t, "points", "done")
    pick(t, "look_choice", "casual")
    pick(t, "confirm", "again")
    t:expect_quality(:player, :strength, 15)
    t:expect_quality(:player, :points, 6)
    t:expect_no_fact "trait(:family, ?f)"
    t:expect_shown "family"
end)

test.case("a disabled choice shows its reason and has no token", function()
    local t = scholarly(start())
    walk(t, :square)
    walk(t, :forge)
    local story = t:shown("anvil")
    assert(story, "the anvil is shown")
    for _, c in ipairs(story.choices) do
        if c.id == :lift then
            assert(c.enabled == false, "a scholar cannot lift the anvil")
            assert(c.token == nil and #c.because > 0)
        end
    end
    local ok = pcall(function() t:choose("anvil", "lift") end)
    assert(not ok, "a disabled choice cannot be chosen")
    pick(t, "anvil", "strain")
    t:expect_no_fact "flag(:anvil_lifted)"
end)

test.case("a strong build lifts the anvil and wins Mara's trust; word reaches the constable", function()
    local t = strong(start())
    walk(t, :square)
    walk(t, :forge)
    pick(t, "anvil", "lift")
    t:expect_fact "flag(:anvil_lifted)"
    t:expect_quality(:mara, :trust, 2)
    -- Rumour spreads over friendships (a recursive rule): Mara knows Hask.
    t:expect_fact "knows_of(:hask, :deed)"
    walk(t, :square)
    t:expect_shown "hask_heard"
end)

test.case("the broken bridge opens a way to the quarry, three ways", function()
    local t = strong(start())
    walk(t, :square)
    walk(t, :market)
    walk(t, :docks)
    t:expect_fact "isolated(:quarry)"
    t:expect_fact "broken(:docks, :quarry)"
    -- The strong build has neither the wits nor the charm nor the coin; it can only ask again later.
    local story = t:shown("bridge")
    for _, c in ipairs(story.choices) do assert(c.enabled == false, tostring(c.id)) end
end)

test.case("the day ends when the slots are spent; sleeping starts a new morning", function()
    local t = strong(start())
    pick(t, "chores", "work")
    pick(t, "read_books", "read")
    pick(t, "cook", "cook")     -- the evening: derived from the slot by a zero-arity rule
    t:expect_quality(:world, :slot, 4)
    t:expect_hidden "chores"
    t:expect_shown "sleep"
    pick(t, "sleep", "sleep")
    t:expect_quality(:world, :day, 2)
    t:expect_quality(:world, :slot, 1)
end)

test.case("a game saves and loads byte for byte, mid-day and mid-scene", function()
    local t = strong(start())
    pick(t, "chores", "work")
    local saved = t:save()
    local again = test.play { seed = 7 }
    again:load(saved)
    assert(again:save() == saved, "the save did not round trip")
    -- Mid-scene: the prologue is a saveable position too.
    local u = test.play { seed = 7 }
    u.session:play(:prologue)
    local p = u.session:present()
    u.session:advance(p.token)
    local mid = u:save()
    local v = test.play { seed = 7 }
    v:load(mid)
    assert(v:save() == mid)
end)

test.case("the French pack changes the words and nothing else", function()
    local t = start()
    t.session:set_language("fr")
    t._presentation = nil
    local p = t:present()
    assert(p.storylets[1].title == "D'où venez-vous ?", p.storylets[1].title)
    t.session:set_language(nil)
    t._presentation = nil
    assert(t:present().storylets[1].title == "Where do you come from?")
end)

-- The verdict is a derived relation of the trial results and the people who trust you; each
-- ending is reachable by a state a game can arrive at.
local function with_results(t, results, build)
    local w = t.session:world()
    logic (w) do
        fact flag(:entered)
        for name, result in pairs(results) do set trial(name, result) end
    end
    for name, value in pairs(build or {}) do quality.set(:player, name, value, w) end
    return w
end

test.case("each ending follows from the results and the people who trust you", function()
    local t = strong(start())
    local w = with_results(t, { [:strength] = :pass, [:wits] = :pass, [:charm] = :pass }, { [:strength] = 80 })
    logic (w) do
        fact flag(:bridge_fixed)
        fact flag(:banner_solved)
    end
    t:expect_fact "ending(:hero)"
    t:expect_no_fact "ending(:quiet)"

    t = strong(start())
    w = with_results(t, { [:strength] = :pass, [:wits] = :pass, [:charm] = :fail }, { [:strength] = 80 })
    quality.set(:mara, :trust, 3, w)
    t:expect_fact "ending(:smith)"
    t:expect_no_fact "ending(:hero)"

    t = strong(start())
    with_results(t, { [:strength] = :pass, [:wits] = :fail, [:charm] = :fail }, { [:strength] = 80 })
    t:expect_fact "ending(:quiet)"

    t = strong(start())
    t:expect_fact "ending(:spectator)"
end)

test.case("the Trials end the game: three contests, then the verdict", function()
    local t = strong(start())
    local w = t.session:world()
    logic (w) do fact flag(:entered) end
    quality.set(:world, :day, 10, w)
    quality.set(:world, :slot, 3, w)
    t:expect_shown "to_trials"
    pick(t, "to_trials", "go")
    pick(t, "trial_strength", "heave")
    pick(t, "trial_wits", "guess")
    pick(t, "trial_charm", "mumble")
    t:expect_shown "verdict"
    pick_with(t, "verdict", :accept, { e = :quiet })
    assert(t:is_over(), "the summer is over")
end)

test.case("a loss never takes more than you have", function()
    local t = strong(start())
    local w = t.session:world()
    quality.set(:player, :coins, 3, w)
    walk(t, :square)
    walk(t, :market)
    t:expect_shown "thief"
    pick(t, "thief", "let_go")
    t:expect_quality(:player, :coins, 0)
end)
