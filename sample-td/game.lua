-- Lanternfall: content loading, sessions, and the four battle hooks (battle_request, battle_setup,
-- battle_sync, battle_result) with the host loop that drives a night from the world's request to
-- the world's result (TOWER_DEFENSE_PLAN.md §5). The world decides what a battle means; the
-- battle simulates; this file is the narrow bridge between them.
--
-- A night, as the host runs it:
--   1. the hub's "Go up" choice writes pending(n) and the phase :build
--   2. battle_request reads it; battle_setup builds the setup from the world (heroes and what
--      they grant, the fortress, the fog, edits); the session is saved (the snapshot a retry or an
--      abandon restores)
--   3. build: the warden places, upgrades and sells; the silent judge then runs a raid and a
--      forecast on copies and writes what they showed (attrition on towers, weak(...) facts)
--   4. night: the battle runs to a boundary; a moment plays its scene through the session and
--      battle_sync turns the decision into modifiers; at the end battle_result writes the world

local world = require("world")
local setups = require("battle.setup")
local sync_table = require("battle.sync")

local G = {}
G.CONTENT_VERSION = "lanternfall-content-1"
G.build_world = world.build_world
G.initialize = world.initialize

require("qualities")
require("scenes.characters")
require("scenes.prologue")
require("scenes.moments")
require("scenes.dawn")
require("scenes.endings")
require("content.hub")
require("content.heroes")

for _, tag in ipairs {"fr"} do
    pcall(narrative.load_pack, (__varis_root or ".") .. "/packs/" .. tag)
end

narrative.seal(G.CONTENT_VERSION)

-- The story flags the content writes (scenes, procedures and hub effects). Listed once so tools
-- and the journal can see them all; a flag outside this list is a mistake `varis check` reports.
G.FLAGS = {
    :started, :ended, :wren_joined, :asked_about_valley, :bridge_cut, :bridge_kept, :scree_cleared,
    :scree_left, :held_the_line, :evacuated_mill, :left_behind, :retreated, :valley_seen, :lantern_out,
    :won_night_4, :bonded,
}

-- Notes the content emits (narrative.emit(:note, text)) become toasts, in commit order.
G.toasts = G.toasts or {}
local function attach_notes(session)
    narrative.observe(session:world(), "narrative_event", {
        on_enter = function(t)
            if t[3] == :note then
                G.toasts[#G.toasts + 1] = {text = t[4][1]}
            end
        end,
    })
end

function G.take_toasts()
    local out = G.toasts
    G.toasts = {}
    return out
end

-- Host state, never saved: a battle is in progress. Saves are refused while it is (plan B3).
local active = 0
function G.battle_active() return active > 0 end

-- Hero table: ids, the weapon and ability kinds (positions in battle/kinds.lua), starting hp.
local HEROES = {
    ilse   = {id = 9001, weapon = 6, ability = 7, hp = 70, passive = 10},
    corvin = {id = 9002, weapon = 6, ability = 8, hp = 110, passive = 11},
    wren   = {id = 9003, weapon = 6, ability = 9, hp = 50},
}
local ORDER = {"ilse", "corvin", "wren"}
G.HEROES = HEROES
local by_id = {}
for name, h in pairs(HEROES) do by_id[h.id] = name end

local function name_of(sym) return logic.symbolname(sym) end

function G.new_session(seed)
    local w = G.build_world()
    G.initialize(w)
    local s = narrative.new(w)
    s:seed(seed or 1)
    s:limits(200, 50)
    s:play(:prologue)
    attach_notes(s)
    return s
end

function G.load(text)
    local s = narrative.load(text, G.build_world)
    attach_notes(s)
    return s
end

function G.is_over(s)
    local found
    logic (s:world()) do found = (query flag(:ended))() ~= nil end
    return found
end

function G.save(s)
    if active > 0 then
        error("a battle is in progress: the game cannot be saved until it ends")
    end
    return s:save()
end

-- ---- reading the world --------------------------------------------------------------------

function G.has_flag(s, name)
    local found = false
    logic (s:world()) do found = (query flag(name))() ~= nil end
    return found
end

function G.trust(s, hero)
    return quality.get(logic.symbol(hero), :trust, s:world())
end

function G.night(s)
    return quality.get(:world, :night, s:world())
end

function G.phase(s)
    local p
    logic (s:world()) do p = (query clock(:phase, ?v))().v end
    return name_of(p)
end

function G.oil(s) return quality.get(:world, :oil, s:world()) end

function G.hero_status(s, hero)
    local sym = logic.symbol(hero)
    local status = {injured_through = 0, injuries = 0, dead = false, deployed = false, joined = false}
    logic (s:world()) do
        for r in query injured(sym, ?u) do status.injured_through = r.u end
        for r in query injuries(sym, ?c) do status.injuries = r.c end
        status.dead = (query dead(sym))() ~= nil
        status.deployed = (query deployed(sym))() ~= nil
        status.joined = (query joined(sym))() ~= nil
    end
    return status
end

function G.ruin_count(s)
    local n = 0
    logic (s:world()) do for _ in query ruin(?id) do n = n + 1 end end
    return n
end

function G.dead_count(s)
    local n = 0
    logic (s:world()) do for _ in query dead(?h) do n = n + 1 end end
    return n
end

function G.ending(s)
    local e
    logic (s:world()) do
        local row = (query ending(?e))()
        if row then e = name_of(row.e) end
    end
    return e
end

function G.result_of(s, night)
    local out
    logic (s:world()) do
        local r = (query result(night, ?o, ?k, ?l))()
        if r then out = {outcome = name_of(r.o), kills = r.k, leaks = r.l} end
    end
    return out
end

-- ---- the four hooks -----------------------------------------------------------------------

-- battle_request: the battle the story has asked for, or nil. An ordinary choice sets
-- pending(night); the host reads it at a boundary.
function G.battle_request(s)
    local night
    logic (s:world()) do
        local r = (query pending(?n))()
        if r then night = r.n end
    end
    if night then return {night = night} end
    return nil
end

local function tile_edits(s)
    local list = {}
    logic (s:world()) do
        for r in query terrain_edit(?q, ?r, ?w) do list[#list + 1] = {q = r.q, r = r.r, wall = r.w} end
    end
    return list
end

local function opened_sectors(s)
    local set = {}
    logic (s:world()) do for r in query opened(?x) do set[r.x] = true end end
    return set
end

-- battle_setup: the setup of the requested night, derived from the world: the heroes on the road
-- with the obedience and passives the relationships earn, the fortress, the fog, the edits.
function G.battle_setup(s, request)
    local n = request.night
    local w = s:world()
    local credits = G.oil(s)
    local structures, ruined, max_id = {}, {}, 0
    logic (w) do
        for r in query ruin(?id) do ruined[r.id] = true end
        for r in query structure(?id, ?kind, ?q, ?r, ?l, ?h) do
            if r.id > max_id then max_id = r.id end
            if not ruined[r.id] then
                structures[#structures + 1] = {id = r.id, kind = r.kind, q = r.q, r = r.r, level = r.l, hp = r.h}
            end
        end
    end
    -- the Mill from the night the east road opens, unless the world already has it
    local has_mill = false
    for _, st in ipairs(structures) do if st.id == 2 then has_mill = true end end
    if n >= 3 and not has_mill and not ruined[2] then
        structures[#structures + 1] = {id = 2, kind = 13, q = setups.MILL_HOUSE.q, r = setups.MILL_HOUSE.r, level = 1, hp = 0}
        if max_id < 2 then max_id = 2 end
    end
    table.sort(structures, function(a, b) return a.id < b.id end)
    local heroes = {}
    local obeys, ward, rally, wide, repair = {}, {}, {}, {}, {}
    logic (w) do
        for r in query obeys(?h) do obeys[name_of(r.h)] = true end
        for r in query ward(?h) do ward[name_of(r.h)] = true end
        for r in query rally(?h) do rally[name_of(r.h)] = true end
        for r in query wide_flare(?h) do wide[name_of(r.h)] = true end
        for r in query reliable_repair(?h) do repair[name_of(r.h)] = true end
    end
    for _, name in ipairs(ORDER) do
        local info = G.hero_status(s, name)
        if info.deployed then
            local h = HEROES[name]
            local start = setups.START[name]
            local trust = G.trust(s, name)
            local ability = h.ability
            if name == "wren" and wide[name] then ability = 15 end
            if name == "ilse" and repair[name] and trust >= 3 then ability = 16 end
            local passive
            if ward[name] then passive = h.passive end
            if rally[name] then passive = h.passive end
            heroes[#heroes + 1] = {
                id = h.id, kind = h.weapon, q = start.q, r = start.r,
                hp = h.hp + (trust >= 3 and 10 or 0),
                ability = ability, passive = passive,
                obedience = obeys[name] and 100 or 55,
            }
        end
    end
    local revealed_set = {}
    for _, sector in ipairs(setups.sectors(math.min(n + 2, 5))) do revealed_set[sector] = true end
    for sector in pairs(opened_sectors(s)) do revealed_set[sector] = true end
    local revealed = {}
    for sector in pairs(revealed_set) do revealed[#revealed + 1] = sector end
    table.sort(revealed)
    return setups.night(n, {
        credits = credits, structures = structures, heroes = heroes, edits = tile_edits(s),
        revealed = revealed, next_id = max_id + 1,
    })
end

-- battle_sync: the modifiers the decisions of this battle give it. Persistent entries are sent
-- again at each sync; event entries once. `context.downed` names the hero a moment found fallen.
local PERSISTENT = {hero_mods = true, bonds = true, global = true}
local EVENT = {orders = true, reinforce = true, heal = true, damage = true, reveal = true, end_with = true}

local function hero_id(who, context)
    if who == "downed" then return context and context.downed or nil end
    return HEROES[name_of(who)] and HEROES[name_of(who)].id or nil
end

function G.battle_sync(s, context)
    local out = {hero_mods = {}, bonds = {}, global = {damage = 0, bounty = 0}}
    local fresh = {}
    local names, sent = {}, {}
    logic (s:world()) do
        for r in query mod(?m) do names[#names + 1] = name_of(r.m) end
        for r in query sent(?m) do sent[name_of(r.m)] = true end
    end
    table.sort(names)
    for _, name in ipairs(names) do
        local entry = sync_table[name]
        if entry then
            for _, m in ipairs(entry.hero_mods or {}) do
                local id = hero_id(m.hero, context)
                if id then
                    out.hero_mods[#out.hero_mods + 1] = {
                        hero = id, radius = m.radius, damage = m.damage, obedience = m.obedience, rate = m.rate,
                    }
                end
            end
            for _, b in ipairs(entry.bonds or {}) do
                out.bonds[#out.bonds + 1] = {a = hero_id(b.a), b = hero_id(b.b), within = b.within, damage = b.damage}
            end
            if entry.global then
                out.global.damage = out.global.damage + (entry.global.damage or 0)
                out.global.bounty = out.global.bounty + (entry.global.bounty or 0)
            end
            if not sent[name] then
                fresh[#fresh + 1] = name
                for _, key in ipairs {"orders", "reinforce", "heal", "damage"} do
                    for _, e in ipairs(entry[key] or {}) do
                        out[key] = out[key] or {}
                        local row = {}
                        for k, v in pairs(e) do row[k] = v end
                        if row.hero then row.hero = hero_id(row.hero, context) end
                        if row.near_hero then row.near_hero = hero_id(row.near_hero, context) end
                        if row.target then row.target = hero_id(row.target, context) end
                        out[key][#out[key] + 1] = row
                    end
                end
                if entry.reveal then
                    out.reveal = out.reveal or {}
                    for _, sector in ipairs(entry.reveal) do out.reveal[#out.reveal + 1] = sector end
                end
                if entry.end_with then out.end_with = entry.end_with end
            end
        end
    end
    -- orders and rules name heroes by symbol; the bridge wants ids and plain strings
    for _, o in ipairs(out.orders or {}) do
        if o.order then o.order = tostring(o.order) end
    end
    for _, name in ipairs(fresh) do
        local sym = logic.symbol(name)
        logic (s:world()) do fact sent(sym) end
    end
    return out
end

-- battle_result: the outcome written to the world in one place (plan §5.3).
function G.battle_result(s, outcome, info)
    -- the host passes {request, setup}; the Lua driver passes {night, setup}
    local n = info.night or info.request.night
    local setup = info.setup
    s:record_input(:battle, n .. ":" .. outcome.result .. ":" .. outcome.digest)
    local result = logic.symbol(outcome.result)
    local kills, leaks = outcome.kills, outcome.leaks
    local won = outcome.result == "won"
    local morale = quality.get(:world, :morale, s:world())
    local food = quality.get(:world, :food, s:world())

    -- structures: ruins, damage, new towers; sold ones are forgotten
    for _, st in pairs(outcome.structures) do
        if st.sold then
            logic (s:world()) do delete structure(st.id) end
        else
            logic (s:world()) do
                set structure(st.id, st.kind, st.q, st.r, st.level, st.destroyed and 0 or st.hp)
            end
            if st.destroyed then
                logic (s:world()) do fact ruin(st.id) end
                morale = morale - (st.id == 1 and 2 or 1)
                local told_you = false
                logic (s:world()) do told_you = (query weak(st.id))() ~= nil end
                if told_you then
                    logic (s:world()) do fact told(n) end
                end
            end
        end
    end
    -- leaks: at the Mill they eat the village's food; any leak cuts morale
    local mill_leaks = (outcome.sink_leaks or {})[2] or 0
    food = math.max(0, food - mill_leaks)
    if leaks >= 3 then morale = morale - 1 end
    if won and leaks == 0 then morale = morale + 1 end

    -- heroes: downed means injured through the next night; downed twice (or left behind on the
    -- last night) means dead. Only battle_result writes these facts.
    for _, row in pairs(outcome.heroes or {}) do
        local name = by_id[row.id]
        local sym = logic.symbol(name)
        local status = G.hero_status(s, name)
        if row.downed then
            local fatal = status.injuries >= 1 or (n == 4 and G.has_flag(s, :left_behind))
            logic (s:world()) do
                set injuries(sym, status.injuries + 1)
                if fatal then
                    fact dead(sym)
                else
                    set injured(sym, n + 1)
                end
            end
            morale = morale - 1
        elseif won then
            logic (s:world()) do fact proud(sym, n) end
        end
    end
    -- the fog and the bestiary
    for sector, seen in pairs(outcome.revealed or {}) do
        if seen then
            local x = sector
            logic (s:world()) do fact opened(x) end
        end
    end
    for _, kind in pairs(outcome.seen or {}) do
        local k = kind
        logic (s:world()) do fact seen(k) end
    end
    if won then
        local grow = math.min(n + 3, 6)
        for _, sector in ipairs(setups.sectors(grow)) do
            local x = sector
            logic (s:world()) do fact opened(x) end
        end
        local flag = logic.symbol("won_night_" .. n)
        logic (s:world()) do fact flag(flag) end
    end
    if outcome.result == "lost" and n == 4 then
        logic (s:world()) do fact flag(:lantern_out) end
    end
    -- the village's income for the next night
    morale = math.max(0, math.min(10, morale))
    local income = 25 + morale * 3 + (food >= 5 and 10 or 0)
    local oil = math.min(400, outcome.credits + income)
    logic (s:world()) do
        set quality(:world, :morale, morale)
        set quality(:world, :food, food)
        set quality(:world, :oil, oil)
        fact result(n, result, kills, leaks)
        set clock(:phase, :dawn)
        retract pending(n)
    end
    -- the battle's decisions stop modifying: the next night starts clean
    local names = {}
    logic (s:world()) do
        for r in query mod(?m) do names[#names + 1] = r.m end
    end
    for _, m in ipairs(names) do
        logic (s:world()) do
            retract mod(m)
            retract sent(m)
        end
    end
    -- the silent days before the next night: the judge's forecast, shown at dusk
    if n < 4 and not G.has_flag(s, :lantern_out) then
        G.forecast(s, n + 1)
    end
end

-- ---- the host loop ------------------------------------------------------------------------

-- Plays a scene to its end through the session. `choose(beat)` returns a menu choice id (the first
-- by default).
function G.play_scene(s, scene, choose)
    s:play(scene)
    for _ = 1, 500 do
        local p = s:present()
        if not p.beats then return end
        local b = p.beats[1]
        if b.kind == :menu then
            local id = choose and choose(name_of(scene), b.choices) or b.choices[1].id
            s:advance(p.token, id)
        elseif b.kind == :input then
            s:advance(p.token, "Warden")
        else
            s:advance(p.token)
        end
    end
    error("scene " .. tostring(scene) .. " did not end")
end

-- Acknowledges scene beats until the hub is back (menus take `choose` or the first answer).
function G.settle(s, choose)
    for _ = 1, 500 do
        local p = s:present()
        if not p.beats then return end
        local b = p.beats[1]
        if b.kind == :menu then
            s:advance(p.token, (choose and choose("", b.choices)) or b.choices[1].id)
        elseif b.kind == :input then
            s:advance(p.token, "Warden")
        else
            s:advance(p.token)
        end
    end
    error("a scene did not end")
end

-- Takes the choice `choice` of the hub storylet `story`; the optional `bindings` pick one
-- instance of a parameterised storylet (e.g. {hero = :wren}). Returns false when it is not shown.
function G.choose(s, story, choice, bindings)
    local p = s:present()
    for _, st in ipairs(p.storylets) do
        if name_of(st.id) == story then
            for _, c in ipairs(st.choices) do
                local ok = name_of(c.id) == choice and c.token ~= nil
                for k, v in pairs(bindings or {}) do ok = ok and st.bindings[k] == v end
                if ok then
                    s:choose(c.token)
                    G.settle(s)
                    return true
                end
            end
        end
    end
    return false
end

-- Starts the requested battle: the setup from the world, the snapshot a retry restores. Returns a
-- `night` record, or nil (and the problem) when nothing was asked or the setup was refused.
function G.start_battle(s, tweak)
    local request = G.battle_request(s)
    if not request then return nil, "no battle was requested" end
    local setup = G.battle_setup(s, request)
    if tweak then tweak(setup) end
    -- the bridge cannot know the story's scenes: a moment that names none is refused here, with
    -- the world untouched (nothing has been started or written)
    for i, m in ipairs(setup.moments or {}) do
        if not narrative.has_scene(logic.symbol(m.scene)) then
            return nil, "moments.scene: moment " .. i .. " names the unknown scene '" .. tostring(m.scene) .. "'"
        end
    end
    local snapshot = s:save()
    local h, problem = battle.new(setup)
    if not h then return nil, problem end
    active = active + 1
    return {session = s, handle = h, setup = setup, night = request.night, snapshot = snapshot, over = false}
end

-- The silent days (plan §6.5): a raid on a copy chips the thinnest tower. Nothing is shown; the
-- battle starts with the consequence. (The forecast is `G.forecast`, made at dawn.)
function G.judge(night)
    local h, s = night.handle, night.session
    local raid = h:fork {moments = false, scale = 30}
    local chipped = 0
    if raid then
        local before = {}
        local snap = h:snapshot()
        for _, u in pairs(snap.units) do before[u.id] = u.hp end
        local r = raid:pump(20000)
        local lost_most, lost_id = 0, nil
        for _, row in pairs(raid:outcome().structures) do
            local lost = (before[row.id] or row.hp) - row.hp
            if lost > lost_most and before[row.id] and before[row.id] > 1 then
                lost_most, lost_id = lost, row.id
            end
        end
        if lost_id then
            local to = math.max(1, before[lost_id] - lost_most)
            h:set_hp(lost_id, to)
            chipped = chipped + 1
        end
    end
    return {chipped = chipped}
end

-- The forecast for night n: the night is simulated on a copy as the fortress stands, with no
-- moments and nobody giving orders, and the structures that would fall are recorded as weak(id).
-- It replaces the previous forecast and changes no structure.
function G.forecast(s, n)
    local names = {}
    logic (s:world()) do for r in query weak(?x) do names[#names + 1] = r.x end end
    for _, id in ipairs(names) do
        logic (s:world()) do retract weak(id) end
    end
    if n > 4 then return {weak = 0} end
    local setup = G.battle_setup(s, {night = n})
    setup.moments = {}
    local h = battle.new(setup)
    if not h then return {weak = 0} end
    h:pump(60000)
    local out = h:outcome()
    local weak = 0
    for _, row in pairs(out.structures) do
        if row.destroyed then
            local id = row.id
            logic (s:world()) do fact weak(id) end
            weak = weak + 1
        end
    end
    local leaks = out.leaks
    logic (s:world()) do set forecast(:leaks, leaks) end
    return {weak = weak, leaks = out.leaks}
end

-- Pumps the battle to its next boundary. Returns the state name, and for "moment" the scene.
function G.pump(night, limit)
    return night.handle:pump(limit or 400)
end

-- A moment: the scene plays through the session, its decisions become modifiers, and the
-- battle receives them. Returns what the battle applied and refused.
function G.play_moment(night, choose)
    local h, s = night.handle, night.session
    local scene = h:scene()
    G.play_scene(s, symbol(scene), choose)
    local context = {}
    for _, u in pairs(h:snapshot().units) do
        if u.hero and u.downed and not u.alive then context.downed = u.id end
    end
    local mods = G.battle_sync(s, context)
    local applied, refused = h:sync(mods)
    return {scene = scene, applied = applied, refused = refused, mods = mods}
end

-- Ends the battle: writes the result, releases the host flag. Returns the outcome.
function G.finish(night)
    local outcome = night.handle:outcome()
    active = math.max(0, active - 1)
    night.over = true
    G.battle_result(night.session, outcome, {night = night.night, setup = night.setup})
    return outcome
end

-- Abandon (plan B3): the world returns to the snapshot taken at the start and the battle is gone.
function G.abandon(night)
    if not night.over then active = math.max(0, active - 1) end
    night.over = true
    return G.load(night.snapshot)
end

-- Plays a whole night from the world's request with a policy:
--   policy.build(night)            place, upgrade, sell (the battle view, paused)
--   policy.choose(scene, choices)  the menu answer of a moment (default: the first)
--   policy.act(night, snapshot)    called every `policy.every` steps: orders and abilities
-- Returns the outcome and the night record (finished, the world written).
function G.run_night(s, policy)
    policy = policy or {}
    local night, problem = G.start_battle(s, policy.tweak)
    assert(night, problem)
    if policy.build then policy.build(night) end
    G.judge(night)
    local every = policy.every or 20
    for _ = 1, 10000 do
        local r = night.handle:pump(every)
        if r == "moment" then
            local m = G.play_moment(night, policy.choose)
            night.moments = night.moments or {}
            night.moments[#night.moments + 1] = m.scene
        elseif r == "won" or r == "lost" or r == "withdrawn" then
            break
        elseif policy.act then
            policy.act(night, night.handle:snapshot())
        end
    end
    local result = night.handle:outcome()
    if result.result == "running" then error("the battle did not end") end
    local outcome = G.finish(night)
    return outcome, night
end

-- A night with retries: each attempt starts from the snapshot; a lost attempt is abandoned and
-- the next policy tried. Returns the outcome, the session that holds the final world, attempts.
function G.run_night_with_retries(s, policies)
    local attempts, outcome = 0, nil
    for _, policy in ipairs(policies) do
        attempts = attempts + 1
        local saved = s:save()
        local o, night = G.run_night(s, policy)
        outcome = o
        if o.result ~= "lost" then return o, s, attempts end
        s = G.load(saved)
    end
    return outcome, s, attempts
end

-- ---- journal and hero lines ---------------------------------------------------------------

function G.journal(s)
    local sections = {}
    local w = s:world()
    local people, notes, bestiary = {}, {}, {}
    for _, name in ipairs(ORDER) do
        local st = G.hero_status(s, name)
        if st.joined then
            local label = narrative.display(logic.symbol(name))
            local t = G.trust(s, name)
            local line
            if st.dead then line = label .. ": gone. A place is kept."
            elseif st.injured_through >= G.night(s) then line = label .. ": in the infirmary (trust " .. t .. ")."
            else line = label .. ": trust " .. t .. " of 5." end
            people[#people + 1] = line
        end
    end
    local kindnames = {"Dimling: the Dim's foot soldiers.", "Hound: fast, fragile.",
        "Husk: armoured; hit it where it stops.", "Wraith: shielded, calls dimlings.", "Maw: where they come from."}
    logic (w) do
        for r in query seen(?k) do bestiary[#bestiary + 1] = kindnames[r.k] or ("Kind " .. r.k) end
    end
    table.sort(bestiary)
    local flags = {
        {:wren_joined, "Wren joined the watch on the first night."},
        {:held_the_line, "You held the line while Wren was cut off."},
        {:bonded, "Two of the heroes have fought side by side."},
        {:evacuated_mill, "You emptied the Mill and let the Dim have the building."},
        {:left_behind, "You left a fallen hero on the road."},
        {:valley_seen, "Wren's flare lit the valley."},
        {:retreated, "You sounded the retreat and carried the flame down."},
        {:asked_about_valley, "Wren has told you what she knows of the valley."},
        {:bridge_cut, "You cut the footbridge at the ford."},
        {:scree_cleared, "You cleared the scree path for its iron."},
    }
    for _, f in ipairs(flags) do
        if G.has_flag(s, f[1]) then notes[#notes + 1] = f[2] end
    end
    for n = 1, 4 do
        local r = G.result_of(s, n)
        if r then notes[#notes + 1] = "Night " .. n .. ": " .. r.outcome .. ", " .. r.kills .. " fell, " .. r.leaks .. " leaked." end
    end
    local ruins = G.ruin_count(s)
    if ruins > 0 then notes[#notes + 1] = ruins .. " structure(s) lie in ruins." end
    sections[#sections + 1] = {title = "The watch", lines = #people > 0 and people or {"Nobody yet."}}
    sections[#sections + 1] = {title = "Nights", lines = #notes > 0 and notes or {"Nothing yet."}}
    sections[#sections + 1] = {title = "Bestiary", lines = #bestiary > 0 and bestiary or {"None met."}}
    return sections
end

return G
