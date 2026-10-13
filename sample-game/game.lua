-- Loads all authored content into the state-owned registry and seals it.
-- Must run exactly once per Lua state, before any session is created.

local G = {}
G.CONTENT_VERSION = "saltmarsh-content-1"

local world = require("world")
G.build_world = world.build_world
G.initialize  = world.initialize

-- Host-side, impure, never rolled back: reached only via narrative.defer.
Achievements = Achievements or { got = {} }
function Achievements.unlock(name)
    if not Achievements.got[name] then
        Achievements.got[name] = true
        print("[achievement] " .. name)
    end
end
-- Content files run in a restricted environment (milestone 26); this is the one engine global
-- they may call, exposed by name.
narrative.helper("Achievements", Achievements)

require("qualities")
require("content.decks")
require("content.explore")
require("content.lamp")
require("content.market")
require("content.keeper")
require("content.events")
require("content.endings")

-- Explicit authored version: also asserts that content captures (the
-- Achievements closure above) are reconstructible by this code (§13.2).
narrative.seal(G.CONTENT_VERSION)

function G.new_session(seed)
    local w = G.build_world()
    G.initialize(w)
    local s = narrative.new(w)
    s:seed(seed)
    s:limits(200, 50)
    s:set_period(:day, quality.get(:world, :day, w))   -- the first day; midnight moves it on
    return s
end

function G.load(text)
    return narrative.load(text, G.build_world)
end

function G.is_over(s)
    return G.query_flag(s, :game_over)
end

function G.query_flag(s, name)
    local found
    logic (s:world()) do
        found = (query flag(name))() ~= nil
    end
    return found
end

return G
