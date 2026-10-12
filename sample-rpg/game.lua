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

local function attach(session)
    local previous = {}
    local w = session:world()
    narrative.observe(w, "quality", {
        on_leave = function(t) previous[tostring(t[1]) .. ":" .. tostring(t[2])] = t[3] end,
        on_enter = function(t)
            local key = tostring(t[1]) .. ":" .. tostring(t[2])
            local before = previous[key]
            previous[key] = nil
            if before ~= nil and type(t[3]) == "number" and t[3] ~= before then
                G.toasts[#G.toasts + 1] = {entity = t[1], name = t[2], delta = t[3] - before, value = t[3]}
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
    return s
end

function G.is_over(s)
    local found
    logic (s:world()) do
        found = (query flag(:ended))() ~= nil
    end
    return found
end

return G
