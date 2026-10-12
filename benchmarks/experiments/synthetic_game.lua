-- Synthetic narrative game for scale measurements (prototype of ROADMAP milestone 34).
-- Not part of `tools/suite bench`; it is the reproducible source of the numbers in
-- benchmarks/PERFORMANCE_PLAN.md.
--
--   bin/varis benchmarks/experiments/synthetic_game.lua SIDE STORYLETS REACH TURNS ITEMS
--
--   SIDE       grid side; the map has SIDE*SIDE rooms            (default 10)
--   STORYLETS  location-bound, one-shot storylets                (default 200)
--   REACH      1 adds a storylet that reads recursive reachable/2 (default 0)
--   TURNS      present/choose pairs to time                       (default 12)
--   ITEMS      takeable items scattered over the map              (default 50)
--
-- Prints medians and maxima of present() and choose() in CPU milliseconds, content load,
-- world construction and save time, and the collector's heap figure.
local W       = tonumber(arg[1]) or 10     -- grid side; rooms = W*W
local N       = tonumber(arg[2]) or 200    -- location-bound storylets
local REACH   = (arg[3] or "0") == "1"     -- a storylet depends on recursive reachable/2
local TURNS   = tonumber(arg[4]) or 12
local ITEMS   = tonumber(arg[5]) or 50

local function room(x, y) return "r_" .. x .. "_" .. y end
local src = {}
local function add(s) src[#src + 1] = s end

add [[
deck :default { draw = 12, replacement = true }
storylet look(?room)
    when { at(:player, ?room) }
    priority 100
    title "Look around {room}"
    text "You are in {room}. {#if query outdoors(room)}Wind.{/if}"
    choice wait
        title "Wait"
        effect do adjust quality(:player, :resolve) by 0 end
    end
end
storylet walk(?from, ?to)
    when { at(:player, ?from), open_exit(?from, ?to) }
    priority 50
    title "Go to {to}"
    text ""
    choice go
        title "Go"
        effect do set at(:player, to) end
    end
end
storylet take(?item)
    when { at(:player, ?r), at(?item, ?r), item(?item) }
    priority 40
    title "Take {item}"
    text ""
    choice take
        title "Take"
        effect do
            delete at(item)
            fact carries(:player, item)
        end
    end
end
]]
if REACH then add [[
storylet far(?to)
    when { at(:player, ?here), landmark(?to), reachable(?here, ?to), ?to ~= ?here }
    priority 30
    title "Head for {to}"
    text ""
    choice go
        title "Go"
        effect do set at(:player, to) end
    end
end
]] end
for i = 1, N do
    local x, y = (i * 7) % W, (i * 13) % W
    add(string.format([[
storylet scene_%d()
    when { at(:player, :%s), not seen(:s%d), quality(:player, :resolve, ?r), ?r >= %d }
    priority 20
    title "Scene %d"
    text "Something happens here."
    choice ok
        title "Continue"
        effect do
            fact seen(:s%d)
            adjust quality(:player, :resolve) by 1
        end
    end
end
]], i, room(x, y), i, i % 5, i, i))
end

quality.define(:resolve, {initial = 10, minimum = 0, maximum = 100000})
local t0 = os.clock()
assert(load(table.concat(src, "\n"), "=content"))()
narrative.seal("synth-1")
local t_content = os.clock() - t0

t0 = os.clock()
local w = logic.emptyworld()
logic (w) do
    relation at(entity, room) key(entity)
    relation exit(from, to)
    relation locked(from, to)
    relation outdoors(room)
    relation item(name)
    relation carries(person, item)
    relation seen(topic)
    relation landmark(room)
    relation quality(entity, name, value) key(entity, name)
    rule open_exit(?a, ?b) :- exit(?a, ?b), not locked(?a, ?b)
    rule reachable(?a, ?b) :- open_exit(?a, ?b)
    rule reachable(?a, ?c) :- reachable(?a, ?b), open_exit(?b, ?c)
    for x = 0, W - 1 do
        for y = 0, W - 1 do
            local here = logic.symbol(room(x, y))
            if x + 1 < W then
                local e = logic.symbol(room(x + 1, y))
                fact exit(here, e); fact exit(e, here)
            end
            if y + 1 < W then
                local s = logic.symbol(room(x, y + 1))
                fact exit(here, s); fact exit(s, here)
            end
            if (x + y) % 2 == 0 then fact outdoors(here) end
        end
    end
    fact landmark(logic.symbol(room(W - 1, W - 1)))
    fact landmark(logic.symbol(room(0, W - 1)))
    for i = 1, ITEMS do
        local it = logic.symbol("item_" .. i)
        fact item(it)
        fact at(it, logic.symbol(room(i % W, (i * 3) % W)))
    end
    fact at(:player, logic.symbol(room(0, 0)))
end
transaction (w) do quality.initialize(:player, :resolve, w) end
local s = narrative.new(w)
s:seed(7)
s:limits(200, 50)
local t_world = os.clock() - t0

local pres, chos = {}, {}
for turn = 1, TURNS do
    local a = os.clock()
    local p = s:present()
    local b = os.clock()
    pres[#pres + 1] = b - a
    -- prefer a scene, else walk
    local pick
    for _, story in ipairs(p.storylets) do
        for _, c in ipairs(story.choices) do
            if not pick or story.title:find("^Go to") then pick = c end
        end
    end
    if not pick then break end
    a = os.clock()
    s:choose(pick.token)
    chos[#chos + 1] = os.clock() - a
end
table.sort(pres); table.sort(chos)
local function med(t) return t[(#t + 1) // 2] or 0 end
t0 = os.clock()
local saved = s:save()
local t_save = os.clock() - t0
print(string.format("rooms=%d storylets=%d reach=%s  content=%.1fms world=%.1fms  present med=%.1fms max=%.1fms  choose med=%.1fms max=%.1fms  save=%.1fms (%d bytes)  heap=%.0fKB",
    W * W, N, tostring(REACH), t_content * 1e3, t_world * 1e3, med(pres) * 1e3, pres[#pres] * 1e3, med(chos) * 1e3, (chos[#chos] or 0) * 1e3, t_save * 1e3, #saved, collectgarbage("count")))
