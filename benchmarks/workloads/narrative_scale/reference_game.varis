-- bench: the reference game of benchmarks/PERFORMANCE_PLAN.md section 3.1.
--   varis reference_game.lua [TURNS]
-- About 100 rooms, 1000 one-shot storylets, 50 items, a recursive rule (reachable/2) and an
-- aggregate (burden/2 counts what the player carries), played for a 500-turn scripted session
-- the way the reference host plays it: present, hand the presentation over, idle, choose.
-- The measures of section 3.1 are printed to stderr and checked against the stand-in budgets;
-- a miss is an error, so the benchmark gate fails with the measure named. Peak RSS is the
-- process's, bounded by gate.rss_mb in targets.toml.
local TURNS = tonumber(arg and arg[1]) or 500
local W, N, ITEMS = 10, 1000, 50

local BUDGET = {            -- stand-in column of section 3.1 (development machine)
    turn_p95_ms = 5,
    load_ms = 100,
    save_ms = 5,
    collections_in_turns = 0,
}

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
storylet pack(?n)
    when { burden(:player, ?n), ?n >= 1 }
    priority 35
    title "Check the pack ({n})"
    text "You carry {n} things."
    choice look
        title "Look"
        effect do adjust quality(:player, :resolve) by 0 end
    end
end
]]
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
narrative.seal("reference-1")

local w = logic.emptyworld()
logic (w) do
    relation at(entity, room) key(entity)
    relation exit(from, to)
    relation locked(from, to)
    relation outdoors(room)
    relation item(name)
    relation holder(person)
    relation carries(person, item)
    relation seen(topic)
    relation landmark(room)
    relation quality(entity, name, value) key(entity, name)
    rule open_exit(?a, ?b) :- exit(?a, ?b), not locked(?a, ?b)
    rule reachable(?a, ?b) :- open_exit(?a, ?b)
    rule reachable(?a, ?c) :- reachable(?a, ?b), open_exit(?b, ?c)
    rule burden(?who, ?n) :- holder(?who), ?n = count { carries(?who, ?thing) }
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
    fact holder(:player)
    fact at(:player, logic.symbol(room(0, 0)))
end
transaction (w) do quality.initialize(:player, :resolve, w) end
local s = narrative.new(w)
s:seed(7)
s:limits(200, 50)
local load_ms = (os.clock() - t0) * 1e3

-- The script: play a scene if one is offered, else pick something up, else walk; the walk
-- rotates through the exits by turn number so the session crosses the whole map.
local function pick(p, turn)
    local scene, take, walks = nil, nil, {}
    for _, story in ipairs(p.storylets) do
        local c = story.choices[1]
        if c then
            if story.title:find("^Scene") then scene = scene or c
            elseif story.title:find("^Take") then take = take or c
            elseif story.title:find("^Go to") then walks[#walks + 1] = {story.title, c}
            end
        end
    end
    if scene then return scene end
    if take then return take end
    if #walks == 0 then return nil end
    table.sort(walks, function(a, b) return a[1] < b[1] end)
    return walks[turn % #walks + 1][2]
end

local turns, in_turn, scenes, carried = {}, 0, 0, 0
local p = s:present()
local before = logic.counters()
for turn = 1, TURNS do
    s:idle()                                   -- the host's idle call, after "drawing"
    local choice = pick(p, turn)
    if not choice then break end
    local c0 = logic.counters().collections
    local a = os.clock()
    s:choose(choice.token)
    p = s:present()
    turns[#turns + 1] = os.clock() - a
    in_turn = in_turn + (logic.counters().collections - c0)
end
local after = logic.counters()
assert(#turns == TURNS, "the scripted session stopped early at turn " .. #turns)

table.sort(turns)
local function pct(q) return turns[math.max(1, math.ceil(#turns * q))] * 1e3 end
t0 = os.clock()
local saved = s:save()
local save_ms = (os.clock() - t0) * 1e3

local n = #turns
io.stderr:write(string.format(
    "reference game: load %.1f ms; turn p50 %.2f p95 %.2f max %.2f ms; save %.1f ms (%d bytes); " ..
    "collections inside turns %d; per turn: %.1f queries, %.1f rule firings, %.1f tuples derived, " ..
    "%.1f facts copied, %.0f KB allocated\n",
    load_ms, pct(0.5), pct(0.95), turns[n] * 1e3, save_ms, #saved, in_turn,
    (after.queries - before.queries) / n, (after.rule_firings - before.rule_firings) / n,
    (after.tuples_derived - before.tuples_derived) / n, (after.facts_copied - before.facts_copied) / n,
    (after.allocated_bytes - before.allocated_bytes) / n / 1024))

local function within(name, value)
    if value > BUDGET[name] then
        error(string.format("reference game over budget: %s = %.2f, budget %s", name, value, BUDGET[name]), 0)
    end
end
within("load_ms", load_ms)
within("turn_p95_ms", pct(0.95))
within("save_ms", save_ms)
within("collections_in_turns", in_turn)
-- A stable line for the output hash: what the session did, not how long it took.
local seen = 0
logic (w) do
    for _ in query { seen(?t) } do seen = seen + 1 end
end
print(string.format("turns=%d scenes=%d save_bytes=%d", n, seen, #saved))
