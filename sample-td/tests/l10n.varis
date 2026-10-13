-- Localisation (SAMPLE_TD_PLAN.md §7): a moment scene renders in French and keeps its position
-- when the language is switched in the middle of it; the hub follows the language and comes back.
--
--   bin/varis sample-td/tests/l10n.lua        (from the repository root; needs packs/fr)

package.path = "sample-td/?.lua;" .. package.path
__varis_root = "sample-td"
local G = require("game")

local s = G.new_session(1)
G.settle(s)
local english = s:present().storylets[1].title
assert(english == "Dusk on Marrow Hill", english)
s:set_language("fr")
assert(s:present().storylets[1].title == "Crépuscule sur Marrow Hill")
assert(s:present().storylets[2].text:find("Ilse") ~= nil)
s:set_language("")
assert(s:present().storylets[1].title == english, "back to the source language")

-- a moment scene, switched mid-way: the beat index and the token's position are kept
local t = G.new_session(2)
G.settle(t)
t:play(:m2_husks)
local p = t:present()
assert(p.beat_index == 1 or p.beat_index > 0)
while not p.beats[1].text do       -- up to the first line of speech
    t:advance(p.token)
    p = t:present()
end
local index_before = p.beat_index
local text_before = p.beats[1].text
t:set_language("fr")
local q = t:present()
assert(q.beat_index == index_before, "the position changed with the language")
assert(q.scene == p.scene)
assert(q.beats[1].text ~= text_before and q.beats[1].text:find("carapaces"), q.beats[1].text)
t:set_language("")
assert(t:present().beats[1].text == text_before)
-- the scene can still be played to its end in either language, and the decision still lands
t:set_language("fr")
G.settle(t, function() return :focus end)
logic (t:world()) do assert((query decided(:focus_fire))() ~= nil) end
print("l10n: hub, scene and position switch with the language")
print("checks passed")
