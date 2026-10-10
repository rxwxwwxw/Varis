-- bench: bounded choice analysis plus a goal explanation on a fresh session
package.path = "./?.lua;" .. package.path
local G = require("game")
local s = G.new_session(3)
local report = narrative.analyze(s, { depth = 3, max_nodes = 120 })
assert(report.nodes > 0)
local why = narrative.explain(s, :lamp)
assert(why ~= nil)
