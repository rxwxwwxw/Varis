-- The hub: choices that are not available say why (`because`), the talk ladders move with trust,
-- and the dusk never strands the warden (there is always a way up).
--
--   bin/varis sample-td/tests/hub.lua        (from the repository root)

package.path = "sample-td/?.lua;" .. package.path
local G = require("game")

local s = G.new_session(1)
G.settle(s)

local function find(story)
    for _, st in ipairs(s:present().storylets) do
        if logic.symbolname(st.id) == story then return st end
    end
end

-- a disabled choice carries its reason and no token
local corvin = find("talk_corvin")
assert(corvin, "Corvin is on the wall at the first dusk")
local guard
for _, c in ipairs(corvin.choices) do
    if logic.symbolname(c.id) == "guard_wren" then guard = c end
end
assert(guard and guard.enabled == false and guard.token == nil)
assert(guard.because == "Wren has not joined the watch yet.", tostring(guard.because))

-- Wren is not on the list until she has joined
assert(find("talk_wren") == nil)
logic (s:world()) do fact joined(:wren) end
assert(find("talk_wren") ~= nil, "Wren appears when she has joined")

-- the talk ladder: the line changes with trust
local function line(story) return find(story).text end
local low = line("talk_ilse")
quality.set(:ilse, :trust, 5, s:world())
assert(line("talk_ilse") ~= low, "Ilse's line follows her trust")

-- each conversation is once a night, and trust moves with the choice
local t0 = G.trust(s, "wren")
assert(G.choose(s, "talk_wren", "valley"))
assert(G.trust(s, "wren") == t0 + 1)
assert(find("talk_wren") == nil, "a conversation is once a night")

-- rebuilding explains its price when the warden cannot pay
logic (s:world()) do
    fact ruin(1)
end
local rebuild = find("rebuild")
assert(rebuild and rebuild.choices[1].enabled ~= false, "the warden has the oil")
quality.set(:world, :oil, 5, s:world())
rebuild = find("rebuild")
assert(rebuild.choices[1].enabled == false)
assert(rebuild.choices[1].because == "Rebuilding takes 20 lamp-oil.", tostring(rebuild.choices[1].because))

-- there is always a way up
assert(find("go_up") ~= nil)

-- a world saved at the start of a battle and then abandoned has a way back down
assert(G.choose(s, "go_up", "go"))
assert(G.phase(s) == "build" and G.battle_request(s).night == 1)
assert(find("go_up") == nil and find("stand_down") ~= nil)
assert(G.choose(s, "stand_down", "down"))
assert(G.phase(s) == "dusk" and G.battle_request(s) == nil and find("go_up") ~= nil)
print("checks passed")
