-- Lanternfall: a minimal text host.
--
--   varis main.lua [seed]          play in the terminal
--   varis main.lua [seed] --bot    let the scripted bot play the whole game (a smoke test)
--
-- The real front end is the SDL3 player (`make varis-sdl; bin/varis-sdl sample-td/presentation.json`).
-- Run it from this directory; the battle is the same native simulation either way.

package.path = "./?.lua;" .. package.path

local G = require("game")
local bot = require("tools.bot")
local seed = tonumber(arg and arg[1]) or 1
local automatic = arg and (arg[1] == "--bot" or arg[2] == "--bot")

local KIND_NAMES = {"bolt", "chime", "hoar", "arc", "beacon"}

local function say(...) print(...) end

local function read_number(prompt, low, high)
    while true do
        io.write(prompt)
        local line = io.read("l")
        if line == nil then os.exit(0) end
        local n = tonumber(line)
        if n and n >= low and n <= high then return n end
    end
end

-- Plays the scene beats that are showing, asking at menus.
local function beats(s)
    for _ = 1, 500 do
        local p = s:present()
        if not p.beats then return end
        local b = p.beats[1]
        if b.text then
            local who = b.speaker and b.speaker.name
            say((who and (who .. ": ") or "  ") .. b.text)
        end
        if b.kind == :menu then
            for i, c in ipairs(b.choices) do say(string.format("  %d. %s", i, c.text)) end
            local pick = read_number("> ", 1, #b.choices)
            s:advance(p.token, b.choices[pick].id)
        elseif b.kind == :input then
            s:advance(p.token, "Warden")
        else
            s:advance(p.token)
        end
    end
end

-- The map of what the warden has seen: walls, the road, towers by kind, heroes, the Dim.
local function draw_map(night)
    local h, snap = night.handle, night.handle:snapshot()
    local route = {}
    for source = 1, #night.setup.sources do
        for _, t in ipairs(h:route(source) or {}) do route[t.q .. "," .. t.r] = true end
    end
    local grid = {}
    local maxq, maxr = 0, 0
    for r = 0, snap.height - 1 do
        local row = {}
        for q = 0, snap.width - 1 do
            local t = h:tile(q, r)
            local ch = " "
            if t.revealed then
                ch = t.wall and "#" or (route[q .. "," .. r] and "," or ".")
                maxq = math.max(maxq, q); maxr = math.max(maxr, r)
            end
            row[q] = ch
        end
        grid[r] = row
    end
    for _, sink in ipairs(night.setup.sinks) do grid[sink.r][sink.q] = (sink.q < 20) and "L" or "M" end
    for _, src in ipairs(night.setup.sources) do grid[src.r][src.q] = "S" end
    for _, u in pairs(snap.units) do
        if u.alive then
            local ch = u.hero and "H" or ((u.kind <= 5) and string.sub(KIND_NAMES[u.kind], 1, 1):upper() or "B")
            grid[u.r][u.q] = ch
        end
    end
    for _, e in pairs(snap.enemies) do grid[e.r][e.q] = "e" end
    for r = 0, maxr do
        local line = {}
        for q = 0, maxq do line[#line + 1] = grid[r][q] end
        say(table.concat(line))
    end
    say(string.format("step %d | oil %d | enemies %d | leaks %d/%d | kills %d", snap.step, snap.credits,
        #snap.enemies, snap.leaks, snap.max_leaks, snap.kills))
end

-- The build phase: place, sell, upgrade; "go" starts the night.
local function build(night)
    say("Build phase. Commands: place <kind 1-5> <q> <r> | sell <id> | upgrade <id> | map | go")
    say("Kinds: 1 bolt 10, 2 chime 22, 3 hoar 18, 4 arc 34, 5 beacon 28")
    draw_map(night)
    while true do
        io.write("build> ")
        local line = io.read("l")
        if line == nil then os.exit(0) end
        local cmd, a, b, c = line:match("^(%S+)%s*(%S*)%s*(%S*)%s*(%S*)")
        if cmd == "go" then return
        elseif cmd == "map" then draw_map(night)
        elseif cmd == "place" then
            local ok, why = night.handle:place(tonumber(a), tonumber(b), tonumber(c))
            say(ok and "placed" or ("refused: " .. tostring(why)))
        elseif cmd == "sell" then
            local ok, why = night.handle:sell(tonumber(a))
            say(ok and "sold" or ("refused: " .. tostring(why)))
        elseif cmd == "upgrade" then
            local ok, why = night.handle:upgrade(tonumber(a))
            say(ok and "upgraded" or ("refused: " .. tostring(why)))
        else
            say("?")
        end
    end
end

local function play_night(s)
    local night, problem = G.start_battle(s)
    if not night then
        say("The night could not start: " .. tostring(problem))
        return false
    end
    build(night)
    G.judge(night)
    local last_report = -1
    while true do
        local r = night.handle:pump(20)
        local snap = night.handle:snapshot()
        if snap.step // 100 ~= last_report then
            last_report = snap.step // 100
            say(string.format("  step %d | enemies %d | leaks %d | oil %d", snap.step, #snap.enemies, snap.leaks, snap.credits))
        end
        if r == "moment" then
            say("-- " .. night.handle:scene() .. " --")
            local scene = night.handle:scene()
            s:play(logic.symbol(scene))
            beats(s)
            local mods = G.battle_sync(s, {})
            night.handle:sync(mods)
        elseif r == "won" or r == "lost" or r == "withdrawn" then
            break
        end
    end
    local outcome = G.finish(night)
    say(string.format("The night is %s: %d fell, %d got past.", outcome.result, outcome.kills, outcome.leaks))
    return true
end

if automatic then
    local s, report = bot.play(seed, "ilse", {front = true, towers = 8})
    for n, r in ipairs(report.nights) do
        say(string.format("night %d: %s, %d kills, %d leaks, %d steps", n, r.result, r.kills, r.leaks, r.steps))
    end
    say("ending: " .. tostring(report.ending))
    for _, section in ipairs(G.journal(s)) do
        say(section.title)
        for _, line in ipairs(section.lines) do say("  " .. line) end
    end
    return
end

local s = G.new_session(seed)
beats(s)
while not G.is_over(s) do
    local p = s:present()
    if p.beats then
        beats(s)
    elseif G.battle_request(s) then
        play_night(s)
    elseif #p.storylets == 0 then
        break
    else
        say(string.format("-- night %d | oil %d | morale %d --", G.night(s), G.oil(s), quality.get(:world, :morale, s:world())))
        local options = {}
        for _, st in ipairs(p.storylets) do
            if #st.text > 0 then say(st.title .. ": " .. st.text) end
            for _, c in ipairs(st.choices) do
                options[#options + 1] = c
                say(string.format("  %d. %s%s", #options, c.title, c.enabled == false and (" (" .. tostring(c.because) .. ")") or ""))
            end
        end
        local pick = read_number("> ", 1, #options)
        if options[pick].token then
            s:choose(options[pick].token)
        else
            say("  " .. tostring(options[pick].because))
        end
    end
end
beats(s)
say("The end.")
