-- Golden digests and determinism (SAMPLE_TD_PLAN.md §7). A scripted bot plays each night with
-- fixed commands and fixed moment choices; the battle digest must equal the pinned value. The
-- same game twice gives the same digests, a run to step N equals a rerun to step N, and a
-- command log replays to the same outcome.
--
--   bin/varis sample-td/tests/determinism.lua        (from the repository root)

package.path = "sample-td/?.lua;" .. package.path
local G = require("game")
local bot = require("tools.bot")

-- Pinned battle digests of the scripted game (seed 1, six towers a night, heroes forward). They
-- change only with the content (kinds, waves, maps) or the simulation; a change is reviewed and
-- re-pinned in its own commit, never to make a failure go away.
local GOLDEN = {
    ilse   = {[1] = 8632402059747371068, [2] = 1470566735589209932, [3] = 8471985370325855461, [4] = 1745908265439247140},
    corvin = {[1] = 8632402059747371068, [2] = 8458188809380360672, [3] = -8866166377093174019, [4] = 1745908265439247140},
}

local function digests(style)
    local _, report = bot.play(1, style, {front = true, towers = 6})
    local out = {}
    for n, r in ipairs(report.nights) do out[n] = r.digest end
    return out, report
end

for _, style in ipairs {"ilse", "corvin"} do
    local first, report = digests(style)
    local second = digests(style)
    for n = 1, #first do
        assert(first[n] == second[n], style .. " night " .. n .. " is not deterministic")
    end
    assert(#first == #report.nights and #first >= 3, "the game played " .. #first .. " nights")
    local pinned = GOLDEN[style]
    for n = 1, #first do
        assert(pinned[n] == first[n], string.format("%s night %d digest %d (pinned %s)", style, n, first[n], tostring(pinned[n])))
    end
    print(style .. ": " .. #first .. " nights, ending " .. tostring(report.ending))
end

-- A run to step N equals a rerun to step N; a command log replays to the same outcome.
local function night_one()
    local s = G.new_session(1)
    G.settle(s)
    assert(G.choose(s, "go_up", "go"))
    local night = assert(G.start_battle(s))
    bot.builder({})(night)
    return night
end

local a, b = night_one(), night_one()
local N = 137
for _ = 1, N do a.handle:pump(1) end
b.handle:pump(1)                       -- a moment may stop it early; keep going to step N
while b.handle:steps() < N do b.handle:pump(N - b.handle:steps()) end
assert(a.handle:steps() == N and b.handle:steps() == N)
assert(a.handle:digest() == b.handle:digest(), "a rerun to step N differs")

-- run a to its end, then replay its command log from the same setup
local result
repeat result = a.handle:pump(500) until result == "won" or result == "lost"
local outcome = a.handle:outcome()
local replayed = battle.replay(a.setup, a.handle:log())
assert(replayed.digest == outcome.digest, "the command log did not replay to the same battle")
assert(replayed.steps == outcome.steps and replayed.kills == outcome.kills)
print("replay: " .. outcome.steps .. " steps, digest " .. outcome.digest)
print("checks passed")
