-- Both directions (SAMPLE_TD_PLAN.md §5.3, §7): the world shapes the battle, and the battle
-- changes the world. One assertion per row of the plan's table, each with the fact it writes and
-- the hub or scene text that depends on it.
--
--   bin/varis sample-td/tests/both_directions.lua        (from the repository root)

package.path = "sample-td/?.lua;" .. package.path
local G = require("game")
local bot = require("tools.bot")

local function new_game()
    local s = G.new_session(1)
    G.settle(s)
    return s
end

-- Plays night n (the hub's "go up", then the battle with `policy`), then the rest of the dawn.
local function night(s, policy, rest)
    assert(G.choose(s, "go_up", "go"), "no way up")
    local outcome, record = G.run_night(s, policy)
    if rest then assert(G.choose(s, "report", "rest")) end
    return outcome, record
end

local function hub_text(s)
    local out = {}
    for _, st in ipairs(s:present().storylets) do out[#out + 1] = st.text end
    return table.concat(out, "\n")
end

local function shown(s, story)
    for _, st in ipairs(s:present().storylets) do
        if logic.symbolname(st.id) == story then return st end
    end
    return nil
end

-- A scene's beats as text (the host reads them from the presentation).
local function scene_text(s, scene)
    s:play(scene)
    local out = {}
    for _ = 1, 100 do
        local p = s:present()
        if not p.beats then break end
        local b = p.beats[1]
        if b.text then out[#out + 1] = b.text end
        if b.kind == :menu then s:advance(p.token, b.choices[1].id) else s:advance(p.token) end
    end
    return table.concat(out, "\n")
end

-- ---- the world shapes the battle ----------------------------------------------------------
do
    local function setup_with(ilse, corvin, wren)
        local s = new_game()
        quality.set(:ilse, :trust, ilse, s:world())
        quality.set(:corvin, :trust, corvin, s:world())
        quality.set(:wren, :trust, wren, s:world())
        logic (s:world()) do fact joined(:wren) end
        return G.battle_setup(s, {night = 2})
    end
    local function hero(setup, id)
        for _, h in ipairs(setup.heroes) do if h.id == id then return h end end
    end
    local low, high = setup_with(1, 1, 0), setup_with(4, 4, 3)
    -- obedience: trust below 2 means a hero sometimes ignores orders
    assert(hero(low, 9002).obedience == 55 and hero(high, 9002).obedience == 100, "trust sets obedience")
    -- ward and rally: trust 4 earns the passives; a stronger repair and a wider flare come with trust
    assert(hero(low, 9001).passive == nil and hero(high, 9001).passive == 10, "Ilse's ward at trust 4")
    assert(hero(low, 9002).passive == nil and hero(high, 9002).passive == 11, "Corvin's rally at trust 4")
    assert(hero(low, 9003).ability == 9 and hero(high, 9003).ability == 15, "Wren's wider flare at trust 3")
    assert(hero(high, 9001).hp > hero(low, 9001).hp, "trust adds hit points")
    print("direction 1: trust derives obedience, ward, rally, flare and hit points")
end

-- ---- the battle changes the world ---------------------------------------------------------
-- Rows: ruins, leaks at the Mill, a downed hero, trust moves, edits, fog, first sightings,
-- forecasts, decisions.

-- 1. A destroyed structure: ruin fact, morale falls, the dusk text and a Rebuild storylet follow.
do
    local s = new_game()
    night(s, {build = function() end, every = 10}, true)                  -- night 1: the gate holds
    local morale_before = quality.get(:world, :morale, s:world())
    night(s, {build = function() end, every = 10}, true)                  -- night 2: nobody builds
    assert(G.ruin_count(s) >= 1, "the undefended night ruined something")
    assert(quality.get(:world, :morale, s:world()) < morale_before, "morale fell with the ruins")
    local rebuild = shown(s, "rebuild")
    assert(rebuild, "the Rebuild storylet is offered")
    local oil = G.oil(s)
    local ruins = G.ruin_count(s)
    assert(G.choose(s, "rebuild", "mend", {id = rebuild.bindings.id}))
    assert(G.ruin_count(s) == ruins - 1 and G.oil(s) == oil - 20, "rebuilding costs 20 lamp-oil")
    print("row 1: ruins, morale, rebuild")
end

-- 2. Leaks at the Mill cost food and income.
do
    local control = new_game()
    local starved = new_game()
    for _, s in ipairs {control, starved} do
        for n = 1, 2 do night(s, {build = bot.builder({}), act = bot.actor(), every = 10}, true) end
    end
    night(control, {build = bot.builder({}), act = bot.actor(), every = 10}, false)
    -- the east road is left undefended: the Dim reach the Mill
    local outcome = night(starved, {build = bot.builder({only_route = 1, sell_all = false, towers = 6}), every = 10}, false)
    local c_food, s_food = quality.get(:world, :food, control:world()), quality.get(:world, :food, starved:world())
    assert((outcome.sink_leaks[2] or 0) > 0, "the Mill leaked")
    assert(s_food < c_food, "the Mill's leaks cost food")
    print("row 2: leaks at the Mill cost food (" .. c_food .. " -> " .. s_food .. ")")
end

-- 3. A downed hero is injured, missing from the next battle and the talk list, present in the
--    infirmary; downed twice, the hero is dead and a place is kept.
do
    local s = new_game()
    -- heroes alone, far forward: the Dim fall on them
    local policy = {build = bot.builder({towers = 3, front = true, front_at = 67, front_gap = 8}),
        choose = bot.chooser("ilse"), every = 10}
    night(s, policy, true)
    night(s, policy, false)
    local hurt
    for _, who in ipairs {"ilse", "corvin", "wren"} do
        local st = G.hero_status(s, who)
        if st.injured_through >= 3 or st.dead then hurt = who end
    end
    assert(hurt, "some hero was downed on the forward road")
    assert(G.choose(s, "report", "rest"))
    local st = G.hero_status(s, hurt)
    if not st.dead then
        assert(not st.deployed, hurt .. " is not on the road while injured")
        local setup = G.battle_setup(s, {night = G.night(s)})
        for _, h in ipairs(setup.heroes) do
            assert(h.id ~= G.HEROES[hurt].id, "an injured hero was deployed")
        end
        assert(shown(s, "infirmary") ~= nil, "the infirmary scene is offered")
        assert(shown(s, "talk_" .. hurt) == nil, hurt .. " is missing from the talk list")
    else
        assert(shown(s, "remembrance") ~= nil)
    end
    print("row 3: " .. hurt .. " downed: injured or dead, missing from the road and the talk list")
end

-- 4. A decision in a moment moves trust, which moves the next night's obedience.
do
    local s = new_game()
    quality.set(:corvin, :trust, 2, s:world())
    logic (s:world()) do fact joined(:wren) end
    G.play_scene(s, :m2_wren, function() return :cover end)
    assert(quality.get(:corvin, :trust, s:world()) == 1 and quality.get(:wren, :trust, s:world()) == 2)
    assert(G.has_flag(s, :bonded), "the bond between Wren and Corvin is recorded")
    local setup = G.battle_setup(s, {night = 2})
    local corvin
    for _, h in ipairs(setup.heroes) do if h.id == 9002 then corvin = h end end
    assert(corvin and corvin.obedience == 55, "Corvin, no longer trusting, sometimes ignores an order")
    print("row 4: trust deltas change the next setup")
end

-- 5. A map edit: the cut bridge is written, persists and changes the map the next night.
do
    local s = new_game()
    night(s, {build = bot.builder({}), act = bot.actor(), every = 10}, false)
    assert(G.choose(s, "report", "rest"))
    night(s, {build = bot.builder({}), act = bot.actor(), every = 10}, false)
    assert(shown(s, "cut_bridge"), "the bridge decision is offered at the second dawn")
    assert(G.choose(s, "cut_bridge", "cut"))
    assert(G.has_flag(s, :bridge_cut))
    assert(G.choose(s, "report", "rest"))
    assert(G.choose(s, "go_up", "go"))
    local setup = G.battle_setup(s, {night = G.night(s)})
    local found = false
    for _, e in ipairs(setup.edits) do
        if e.q == 46 and e.r == 24 and e.wall then found = true end
    end
    assert(found, "the edit is in the next night's setup")
    local night3 = assert(G.start_battle(s))
    local tile = night3.handle:tile(46, 24)
    assert(tile.wall, "the tile is a wall in the next battle")
    print("row 5: a map edit persists")
end

-- 6. Fog: winning a night shows the next ring; a revealed valley opens the Overlook.
do
    local s = new_game()
    local opened = 0
    logic (s:world()) do for _ in query opened(?x) do opened = opened + 1 end end
    night(s, {build = bot.builder({}), act = bot.actor(), every = 10}, false)
    local after = 0
    logic (s:world()) do for _ in query opened(?x) do after = after + 1 end end
    assert(after > opened + 8, "the fog grew after the night (" .. opened .. " -> " .. after .. ")")
    assert(G.choose(s, "report", "rest"))
    assert(shown(s, "overlook") == nil, "no overlook before the valley is seen")
    logic (s:world()) do fact opened(36) end
    assert(shown(s, "overlook") ~= nil, "the Valley Overlook is a new place once the valley is seen")
    print("row 6: fog growth and the overlook")
end

-- 7. First sightings: the bestiary lists the husk after the husks came.
do
    local s = new_game()
    night(s, {build = bot.builder({}), act = bot.actor(), every = 10}, true)
    night(s, {build = bot.builder({}), act = bot.actor(), every = 10}, false)
    local lines = G.journal(s)
    local found = false
    for _, section in ipairs(lines) do
        for _, l in ipairs(section.lines) do if l:find("Husk") then found = true end end
    end
    assert(found, "the bestiary has the husk")
    print("row 7: first sighting of a kind enters the journal")
end

-- 8. The forecast and "I told you": weak(...) facts show in Corvin's dusk line.
do
    local s = new_game()
    night(s, {build = bot.builder({towers = 1}), every = 10}, true)
    local weak = 0
    logic (s:world()) do for _ in query weak(?x) do weak = weak + 1 end end
    local text = hub_text(s)
    if weak > 0 then
        assert(text:find("will not last the night"), "Corvin's forecast line: " .. text)
    end
    print("row 8: forecast facts: " .. weak .. " weak structure(s)")
end

-- 9. Decisions change the next scene's words and flags.
do
    local a, b = new_game(), new_game()
    G.play_scene(a, :m2_husks, function() return :focus end)
    G.play_scene(b, :m2_husks, function() return :lamps end)
    assert(not G.has_flag(a, :wren_joined))        -- a decision is `decided`, not a flag
    local ta, tb = scene_text(a, :dawn_3), scene_text(b, :dawn_3)
    assert(ta:find("Corvin has painted a mark"), ta)
    assert(tb:find("Ilse has hung a husk"), tb)
    assert(ta ~= tb)
    print("row 9: decisions change the words of the dawn")
end

print("checks passed")
