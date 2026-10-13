-- A novelty-seeking bot plays whole summers. It checks what no single case can: that a run ends,
-- is neither stranded nor padded, does not repeat itself, and takes about a quarter of an hour
-- to read (a brisk 200 words a minute, plus a few seconds per decision).

local function words(text)
    local n = 0
    for _ in tostring(text):gmatch("%S+") do n = n + 1 end
    return n
end

local ROADS = {
    house = {:square}, square = {:house, :market, :forge, :archive, :tavern, :green},
    market = {:square, :docks}, forge = {:square}, archive = {:square}, tavern = {:square},
    docks = {:market, :quarry}, quarry = {:docks}, green = {:square},
}

-- One run. `style` picks the build; the bot is deterministic for a seed.
local function play(seed, style)
    math.randomseed(seed)
    local t = test.play { seed = seed }
    local s = t.session
    s:play(:prologue)
    local stats = { words = 0, decisions = 0, scenes = {}, repeats = 0, turns = 0, distinct = 0, ending = nil }
    local function name(v) return logic.symbolname(v) end
    local chosen, visits = {}, {}
    local function read_scene(p)
        local b = p.beats[1]
        local key = logic.symbolname(p.scene) .. "#" .. p.beat_index
        if b.text then
            stats.words = stats.words + words(b.text)
            if stats.scenes[key] then stats.repeats = stats.repeats + 1 else stats.distinct = stats.distinct + 1 end
            stats.scenes[key] = (stats.scenes[key] or 0) + 1
        end
    end
    local creation = {
        strength = { family = :farm, temper = :athletic, points = :strength },
        wits = { family = :scholar, temper = :nerdy, points = :wits },
        charm = { family = :merchant, temper = :charming, points = :charm },
    }
    local plan = creation[style]
    local quirks = { :stubborn, :night_owl }
    for _ = 1, 3000 do
        local p = s:present()
        if p.beats then
            local b = p.beats[1]
            read_scene(p)
            if b.kind == :input then
                s:advance(p.token, "Rowan")
            elseif b.kind == :menu then
                s:advance(p.token, b.choices[math.random(#b.choices)].id)
            else
                s:advance(p.token)
                if b.kind == :ended and t:is_over() then break end
            end
        else
            local best, bestscore
            local place
            logic (s:world()) do place = name((query at(:player, ?p))().p) end
            local slot = quality.get(:world, :slot, s:world())
            local coins = quality.get(:player, :coins, s:world())
            for _, st in ipairs(p.storylets) do
                local sid = name(st.id)
                for _, c in ipairs(st.choices) do
                    if c.enabled ~= false then
                        local cid = name(c.id)
                        local key = sid .. "/" .. cid
                        local score
                        -- Character creation follows the plan.
                        if sid == "family" then score = c.id == plan.family and 100 or 0
                        elseif sid == "temper" then score = c.id == plan.temper and 100 or 0
                        elseif sid == "quirk_first" or sid == "quirk_second" then
                            local want = false
                            for _, q in ipairs(quirks) do if c.bindings.q == q then want = true end end
                            score = want and 100 or 0
                        elseif sid == "points" then
                            if cid == "done" then score = 100 elseif c.id == plan.points then score = 50 else score = 0 end
                        elseif sid == "look_choice" or sid == "confirm" then
                            score = cid == "again" and 0 or 100
                        elseif sid == "verdict" then score = 100 + math.random()
                        elseif sid == "to_trials" or sid:match("^trial_") then score = 90 + math.random()
                        elseif sid == "walk" then
                            local to = name(c.bindings.to)
                            score = 5 - (visits[to] or 0) + math.random()
                            if slot >= 4 then score = (to == "house" or (place ~= "square" and to == "square")) and 80 or -1 end
                            if place == "house" and slot >= 4 then score = to == "square" and -1 or 80 end
                        elseif sid == "sleep" then score = slot >= 4 and 95 or 0.5
                        elseif sid == "look" or sid == "barred" then score = -1
                        elseif sid == "fee" then score = 60
                        else
                            score = 30 - (chosen[key] or 0) * 12 + math.random() * 3
                            if sid == "board" then score = score + 6 end
                            if coins < 30 and (sid == "unload" or sid == "stall_work" or sid == "haggle" or sid == "board") then
                                score = score + 8
                            end
                            if slot >= 4 then score = -1 end
                        end
                        if not bestscore or score > bestscore then best, bestscore, stats.last = c, score, key end
                    end
                end
                -- A storylet's text is read once, however often the hub shows it again.
                local seen_key = sid .. tostring(st.instance_key)
                if #st.text > 0 and sid ~= "look" and not stats.scenes[seen_key] then
                    stats.scenes[seen_key] = 1
                    stats.words = stats.words + words(st.text)
                end
            end
            assert(best, "stranded: no enabled choice at seed " .. seed)
            chosen[stats.last] = (chosen[stats.last] or 0) + 1
            if stats.last:match("^walk/") then
                for to, _ in pairs(ROADS) do
                    for _, st in ipairs(p.storylets) do
                        if name(st.id) == "walk" and best.token and st.choices[1] == best then visits[name(st.bindings.to)] = (visits[name(st.bindings.to)] or 0) + 1 end
                    end
                end
            end
            s:choose(best.token)
            stats.decisions = stats.decisions + 1
            if t.after_choose then t.after_choose(s) end
        end
        if t:is_over() and not s:present().beats then break end
    end
    stats.over = t:is_over()
    stats.turns = s:turn()
    return stats
end

local function report(label, stats)
    local minutes = stats.words / 200 + stats.decisions * 0.1
    print(string.format("%s: %d decisions, %d turns, %d words, %d distinct passages, %d repeats, about %.1f minutes",
        label, stats.decisions, stats.turns, stats.words, stats.distinct, stats.repeats, minutes))
    return minutes
end

test.case("a novelty-seeking summer ends, without stranding, repeating itself or dragging", function()
    for _, style in ipairs { :strength, :wits, :charm } do
        for seed = 1, 3 do
            local stats = play(seed, logic.symbolname(style))
            local minutes = report(logic.symbolname(style) .. " " .. seed, stats)
            assert(stats.over, "the summer ended")
            assert(stats.repeats <= 4, "too many repeated passages: " .. stats.repeats)
            assert(minutes >= 10 and minutes <= 22, "run length out of range: " .. minutes)
        end
    end
end)
