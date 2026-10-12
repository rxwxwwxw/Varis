-- Loads all authored content into the state-owned registry and seals it. It runs once per
-- Lua state, before any session is created. Sessions come from new_session / load.

local G = {}
G.CONTENT_VERSION = "hollowbrook-content-1"

local world = require("world")
G.build_world = world.build_world
G.initialize  = world.initialize

-- Host-side, impure, never rolled back: reached only through narrative.defer.
Achievements = Achievements or { got = {}, order = {} }
function Achievements.unlock(name)
    if not Achievements.got[name] then
        Achievements.got[name] = true
        Achievements.order[#Achievements.order + 1] = name
    end
end

-- Stat changes the host shows as toasts. The observer is world-owned and not saved, so it is
-- re-established for every session.
G.toasts = G.toasts or {}

require("qualities")
require("scenes.characters")
require("scenes.prologue")
require("content.decks")
require("content.creation")
require("content.hub")
require("content.home")
require("content.forge")
require("content.archive")
require("content.market")
require("content.tavern")
require("content.docks")
require("content.quarry")
require("content.square")
require("content.events")
require("content.trials")
require("content.endings")

narrative.seal(G.CONTENT_VERSION)

-- Toasts begin with the summer: character creation moves every number and is not news.
function G.started(w)
    local found
    logic (w) do found = (query flag(:started))() ~= nil end
    return found
end

local function attach(session)
    local previous = {}
    local w = session:world()
    narrative.observe(w, "quality", {
        on_leave = function(t) previous[tostring(t[1]) .. ":" .. tostring(t[2])] = t[3] end,
        on_enter = function(t)
            local key = tostring(t[1]) .. ":" .. tostring(t[2])
            local before = previous[key]
            previous[key] = nil
            if before ~= nil and type(t[3]) == "number" and t[3] ~= before and G.started(w) then
                G.toasts[#G.toasts + 1] = {entity = t[1], name = t[2], delta = t[3] - before, value = t[3]}
            end
        end,
    })
end

-- Notes the content emits (narrative.emit(:note, text)) become toasts, in commit order.
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

function G.new_session(seed)
    local w = G.build_world()
    G.initialize(w)
    local s = narrative.new(w)
    s:seed(seed or 1)
    s:limits(200, 50)
    G.sync_periods(s)
    attach(s)
    attach_notes(s)
    return s
end

-- Keep the :day once-per period in step with the day quality. Effects cannot call session
-- methods, so the host does it at idle boundaries (after every choice).
function G.sync_periods(s)
    s:set_period(:day, quality.get(:world, :day, s:world()))
end

function G.load(text)
    local s = narrative.load(text, G.build_world)
    attach(s)
    attach_notes(s)
    return s
end

-- What the player may want to look up: allies, clues, belongings, techniques, goals.
function G.journal(s)
    local w = s:world()
    local sections = {}
    local function names(rows, field)
        local out = {}
        for _, r in ipairs(rows) do out[#out + 1] = narrative.display(r[field]) end
        table.sort(out)
        return out
    end
    local allies, clues, items, skills, goals = {}, {}, {}, {}, {}
    logic (w) do
        for r in query npc(?who) do
            local t = quality.get(r.who, :trust, w)
            if t ~= nil and t >= 1 then
                allies[#allies + 1] = string.format("%s (trust %d)", narrative.display(r.who), t)
            end
        end
        for r in query clue(?c) do clues[#clues + 1] = ({
            purple_dye = "Mara saw a man leave the square with purple-stained hands.",
            torn_ledger = "A page was torn from the festival ledger with a dyer's or tailor's shears.",
            boat_crate = "A lad took the early ferry with a bundle that clinked like brass.",
            tilly_saw = "Tilly saw a young man with the Whitlock walk leave the square at three.",
        })[logic.symbolname(r.c)] or narrative.display(r.c) end
        for r in query has(?i) do items[#items + 1] = narrative.display(r.i) end
        for r in query technique(?t) do skills[#skills + 1] = narrative.display(r.t) end
        local entered = (query flag(:entered))() ~= nil
        goals[#goals + 1] = entered and "You are entered in the Trials." or "Pay the 30-coin entry fee at the square."
        if (query flag(:bridge_fixed))() == nil then goals[#goals + 1] = "The bridge at the docks is broken." end
        if (query flag(:banner_stolen))() ~= nil and (query flag(:banner_solved))() == nil then
            goals[#goals + 1] = "Find who took the festival banner (three clues)."
        end
    end
    table.sort(allies); table.sort(clues); table.sort(items); table.sort(skills)
    sections[#sections + 1] = {title = "Goals", lines = goals}
    sections[#sections + 1] = {title = "Allies", lines = #allies > 0 and allies or {"Nobody yet."}}
    sections[#sections + 1] = {title = "Clues", lines = #clues > 0 and clues or {"None."}}
    sections[#sections + 1] = {title = "Belongings", lines = #items > 0 and items or {"Nothing yet."}}
    sections[#sections + 1] = {title = "Techniques", lines = #skills > 0 and skills or {"None."}}
    return sections
end

function G.achievements()
    return Achievements.order
end

-- Where the player stands and which places can be reached over open roads (a recursive rule).
function G.map_state(s)
    local result = {at = nil, reachable = {}}
    logic (s:world()) do
        local here = (query at(:player, ?p))()
        if here then
            result.at = logic.symbolname(here.p)
            result.reachable[result.at] = true
            for r in query reachable(here.p, ?to) do
                result.reachable[logic.symbolname(r.to)] = true
            end
        end
    end
    return result
end

function G.is_over(s)
    local found
    logic (s:world()) do
        found = (query flag(:ended))() ~= nil
    end
    return found
end

return G
