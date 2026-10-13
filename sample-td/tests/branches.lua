-- The branch coverage bot (SAMPLE_TD_PLAN.md §7): plays the game under scripted defences and
-- every combination of the moments' choices, and checks that nothing gets stuck, every ending is
-- reachable, and every trigger (10) and every modifier entry (9) of the plan's tables is observed.
--
--   bin/varis sample-td/tests/branches.lua        (from the repository root)

package.path = "sample-td/?.lua;" .. package.path
local G = require("game")
local bot = require("tools.bot")

local seen_trigger, seen_entry = {}, {}
local function nonempty(key, v)
    if key == "global" then return v.damage ~= 0 or v.bounty ~= 0 end
    if type(v) == "table" then return next(v) ~= nil end
    return v ~= nil
end

local play_moment = G.play_moment
G.play_moment = function(night, choose)
    local m = night.handle:moment()
    seen_trigger[m.trigger] = (seen_trigger[m.trigger] or 0) + 1
    local r = play_moment(night, choose)
    for key, v in pairs(r.mods) do
        if nonempty(key, v) then seen_entry[key] = (seen_entry[key] or 0) + 1 end
    end
    return r
end

local endings = {}
local games = 0
local function game(style_or_chooser, opts, label)
    games = games + 1
    local _, report = bot.play(1, style_or_chooser, opts)
    assert(#report.nights >= 1 and report.ending ~= nil, label .. ": the game did not end")
    endings[report.ending] = (endings[report.ending] or 0) + 1
    return report
end

-- Scripted defences chosen to reach the moments that need a hero in danger, a leak, a ruin:
local SCENARIOS = {
    {"corvin", {towers = 6, front = true, front_at = 67, front_gap = 2}, "heroes fight forward"},
    {"ilse",   {towers = 3, front = true, front_at = 62, front_gap = 8}, "thin line, heroes alone"},
    {"corvin", {towers = 3, front = true, front_at = 18, front_gap = 2}, "heroes side by side"},
    {"corvin", {towers = 10, by_night = {[4] = {towers = 8, sell_all = true, only_route = 2}}}, "the bell falls"},
    {"ilse",   {towers = 10, by_night = {[4] = {towers = 8, sell_all = true, only_route = 2}}}, "the line is held"},
    {"ilse",   {towers = 12}, "a full defence"},
}
for _, sc in ipairs(SCENARIOS) do game(sc[1], sc[2], sc[3]) end

-- Every combination of the five scripted choices, under one defence.
local CHOICES = {
    {"m2_husks", {:focus, :lamps}}, {"m2_wren", {:cover, :hold}}, {"m3_mill", {:militia, :evacuate}},
    {"m3_east_light", {:minute, :notime}}, {"m4_line", {:retreat, :stand}},
}
local combos = 0
for mask = 0, 31 do
    local answers = {}
    for i, c in ipairs(CHOICES) do
        answers[c[1]] = c[2][((mask >> (i - 1)) & 1) + 1]
    end
    answers.m4_fallen = mask % 3 == 0 and :leave or :rescue
    answers.m4_bell = mask % 2 == 0 and :flare or :rally
    local chooser = function(scene, choices)
        local want = answers[scene]
        for _, c in ipairs(choices) do if c.id == want then return c.id end end
        return choices[1].id
    end
    -- the defence is thin enough that heroes and the line are in play
    game(chooser, {towers = 4, front = true, front_at = 55, front_gap = 3,
        by_night = {[4] = {towers = 6, front = true, front_at = 55, front_gap = 3, sell_all = mask % 4 == 0, only_route = mask % 4 == 0 and 2 or nil}}},
        "combination " .. mask)
    combos = combos + 1
end

local ALL_TRIGGERS = {"step", "wave_start", "structure_destroyed", "leak_count", "battle_won", "battle_lost",
    "hero_downed", "hero_hp_below", "heroes_near", "enemy_kind_seen"}
local ALL_ENTRIES = {"hero_mods", "bonds", "global", "orders", "reinforce", "heal", "damage", "reveal", "end_with"}
for _, t in ipairs(ALL_TRIGGERS) do assert(seen_trigger[t], "trigger never fired: " .. t) end
for _, e in ipairs(ALL_ENTRIES) do assert(seen_entry[e], "modifier entry never used: " .. e) end
for _, e in ipairs {"kept", "kept_at_cost", "withdrawal", "dimmed"} do assert(endings[e], "ending never reached: " .. e) end

local names = {}
for t in pairs(seen_trigger) do names[#names + 1] = t end
table.sort(names)
print(games .. " games, " .. combos .. " choice combinations; triggers: " .. table.concat(names, " "))
print("endings:", "kept " .. (endings.kept or 0), "cost " .. (endings.kept_at_cost or 0),
    "withdrawal " .. (endings.withdrawal or 0), "dimmed " .. (endings.dimmed or 0))
print("checks passed")
