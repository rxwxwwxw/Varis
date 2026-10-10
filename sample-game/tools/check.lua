-- Authoring checks for Saltmarsh Light: a scripted walkthrough with
-- assertions, plus explain / analyze / save-load / replay.
--
--   cd sample-game && dlua tools/check.lua

package.path = "./?.lua;" .. package.path
local G = require("game")
local s = G.new_session(42)

-- Choose by content id and choice id rather than by position or text.
local function pick(story_id, choice_id, bindings)
    local p = s:present()
    for _, st in ipairs(p.storylets) do
        local match = st.id == story_id
        if match and bindings then
            for k, v in pairs(bindings) do
                if st.bindings[k] ~= v then match = false end
            end
        end
        if match then
            for _, c in ipairs(st.choices) do
                if c.id == choice_id then
                    s:choose(c.token)
                    G.sync_periods(s)
                    return
                end
            end
        end
    end
    error("not offered: " .. tostring(story_id) .. "/" .. tostring(choice_id))
end

local function where_is(e)
    local r
    logic (s:world()) do r = (query at(e, ?room))() end
    return r and r.room
end

local function talk_until_key()
    pick(:talk_keeper, :talk)
    pick(:topic_lamp, :nod)
    pick(:topic_key, :accept)
    pick(:end_talk, :bye)
end

-- 1. Explanation before the lamp room is reachable.
pick(:take, :take, {thing = :matches})
pick(:walk, :go, {to = :shore})
pick(:walk, :go, {to = :tower})
local why = narrative.explain(s, :lamp)
print("explain :lamp ->", #why.instances, "instances")

-- local relation + local rule: rooms one hop from here (§10)
logic (s:world()) do
    local here = where_is(:player)
    local relation next_door(1)
    rule next_door(?r) :- open_exit(here, ?r)
    local n = 0
    for _ in query next_door(?r) do n = n + 1 end
    assert(n == 1, "only the shore is open from the tower")
    local cut = 0
    for _ in query cut_off(?r) do cut = cut + 1 end
    assert(cut == 1, "lamp room is cut off while locked")
end

-- 2. Get the key and open the door.
pick(:walk, :go, {to = :shore})
pick(:walk, :go, {to = :cottage})
talk_until_key()
pick(:walk, :go, {to = :shore})
pick(:walk, :go, {to = :tower})
pick(:locked_door, :unlock, {to = :lamp_room})
pick(:walk, :go, {to = :lamp_room})
assert(where_is(:player) == :lamp_room)

-- 3. Save, load into a fresh session, compare.
local saved = s:save()
local restored = G.load(saved)
assert(restored:save() == saved, "round trip must be byte-identical")

-- 4. Transactions outside effects: a tentative purchase rolled back.
local w = s:world()
local before = quality.get(:player, :coins, w)
transaction (w) do
    quality.add(:player, :coins, -5, w)
    assert(quality.get(:player, :coins, w) == before - 5)
    rollback
end
assert(quality.get(:player, :coins, w) == before)

-- 5. Bounded analysis from here (isolated clones; the live session is untouched).
local report = narrative.analyze(s, { depth = 4, max_nodes = 300 })
print("analyze: nodes", report.nodes, "complete", report.complete, "dead ends", #report.dead_ends)
assert(s:save() == saved, "analysis must not change the session")

-- 6. Replay log is available for bug reports.
local log = s:replay_log()
print("replay records:", #log.inputs)

print("checks passed")
