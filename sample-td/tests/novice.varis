-- The novice bot builds nothing: it loses night 2, is offered a retry, and the retry restores the
-- snapshot bytes exactly (SAMPLE_TD_PLAN.md §7). Then a defence wins the same night.
--
--   bin/varis sample-td/tests/novice.lua        (from the repository root)

package.path = "sample-td/?.lua;" .. package.path
local G = require("game")
local bot = require("tools.bot")

local s = G.new_session(1)
G.settle(s)
assert(G.choose(s, "go_up", "go"))
local o1 = G.run_night(s, {build = function() end, choose = bot.chooser("ilse"), every = 10})
assert(o1.result == "won", "night 1 is forgiving: the gate and the heroes hold it, was " .. o1.result)
assert(G.choose(s, "report", "rest"))
assert(G.night(s) == 2)

-- night 2, nobody builds: the Dim win
assert(G.choose(s, "go_up", "go"))
local night = assert(G.start_battle(s))
local r
repeat
    r = night.handle:pump(100)
    if r == "moment" then G.play_moment(night) end
until r == "won" or r == "lost"
assert(r == "lost", "an undefended night 2 should be lost, was " .. r)
local outcome = night.handle:outcome()
assert(outcome.leaks >= 6 and outcome.kills < 56)

-- a retry: the world returns to the snapshot, byte for byte, with the request still pending
local retry = G.abandon(night)
assert(retry:save() == night.snapshot, "the retry did not restore the snapshot")
assert(G.battle_request(retry).night == 2 and G.phase(retry) == "build")
assert(not G.battle_active())

-- the second attempt, with lamps, wins and writes its result
local o2 = G.run_night(retry, {build = bot.builder({}), choose = bot.chooser("ilse"), act = bot.actor(), every = 10})
assert(o2.result == "won", "a defended night 2 should be won, was " .. o2.result)
local second = G.result_of(retry, 2)
assert(second and second.outcome == "won")

-- accepting a loss is also allowed: the result is written and the story goes on (night 3 comes)
local s3 = G.new_session(1)
G.settle(s3)
G.choose(s3, "go_up", "go")
G.run_night(s3, {build = function() end, every = 10})
G.choose(s3, "report", "rest")
G.choose(s3, "go_up", "go")
local lost = G.run_night(s3, {build = function() end, every = 10})
assert(lost.result == "lost")
assert(G.result_of(s3, 2).outcome == "lost")
assert(G.choose(s3, "report", "rest"), "the dawn after a lost night still has its rest")
assert(G.night(s3) == 3 and G.phase(s3) == "dusk")
print("novice: night 2 lost with no defence, retry restored the snapshot, defended retry won")
print("checks passed")
