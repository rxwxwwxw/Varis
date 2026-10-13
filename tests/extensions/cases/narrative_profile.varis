-- Profile (cross-save data) and save headers. The profile is the host's: it is outside session
-- saves, content identity and replay; effect writes apply after commit; reads are refused in
-- effects so content cannot depend on it.
relation ready(0)
fact ready()
storylet gate()
    when { ready() }
    title "Gate"
    choice unlock effect do
        narrative.profile_set("ending.good", true)
    end end
    choice fail effect do
        narrative.profile_set("ending.bad", true)
        error("effect failed")
    end end
    choice peek effect do
        local _ = narrative.profile_get("ending.good")
    end end
end
narrative.seal()
local s = narrative.new(logic.global)
s:seed(3)
local plain = s:save()
-- host-side writes and reads
assert(narrative.profile_get("ending.good") == nil)
reject(function() narrative.profile_set("k", {1, 2}) end, "profile.k")
narrative.profile_set("gallery.cg1", narrative.sequence(1, :seen))
assert(#narrative.profile_get("gallery.cg1") == 2)
narrative.profile_set("gallery.cg1", nil)
assert(narrative.profile_get("gallery.cg1") == nil)
reject(function() narrative.profile_set("", 1) end, "non-empty string")
local p = s:present()
-- a failing effect leaves the profile alone; a committed one writes it afterwards
reject(function() s:choose(p.storylets[1].choices[2].token) end, "effect failed")
assert(narrative.profile_get("ending.bad") == nil)
p = s:present()
local peek
for _, c in ipairs(p.storylets[1].choices) do if c.id == :peek then peek = c end end
reject(function() s:choose(peek.token) end, "not readable")
p = s:present()
local unlock
for _, c in ipairs(p.storylets[1].choices) do if c.id == :unlock then unlock = c end end
s:choose(unlock.token)
assert(narrative.profile_get("ending.good") == true)
-- the session save never mentions the profile
assert(not string.find(s:save(), "ending.good", 1, true))
-- the profile survives a new session and round-trips as text
local text = narrative.profile_save()
narrative.profile_set("ending.good", nil)
assert(narrative.profile_get("ending.good") == nil)
narrative.profile_load(text)
assert(narrative.profile_get("ending.good") == true)
local keys = narrative.profile_keys()
assert(#keys == 1 and keys[1] == "ending.good")
reject(function() narrative.profile_load("{") end, "invalid profile")
reject(function() narrative.profile_load('{"format":"other","values":{}}') end, "incompatible profile")
assert(narrative.profile_get("ending.good") == true, "a failed load keeps the profile")
-- save headers: label and meta are informational
local labelled = s:save({label = "Slot 1", meta = narrative.sequence("2026-10-13", :garden)})
local info = narrative.save_info(labelled)
assert(info.label == "Slot 1" and info.turn == 1 and info.in_scene == false)
assert(info.format == "varis-session-2" and info.meta[1] == "2026-10-13" and info.meta[2] == :garden)
assert(narrative.save_info(s:save()).label == nil)
local restored = narrative.load(labelled, function() return logic.world() end)
assert(restored:turn() == 1)
assert(s:save() == s:save())
reject(function() s:save({bogus = 1}) end, "unknown save option")
reject(function() narrative.save_info("{") end, "invalid narrative save")
