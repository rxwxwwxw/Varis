-- The Hollowbrook Summer: a minimal text host.
--
--   varis main.lua [seed]          play in the terminal
--   varis main.lua [seed] --bot    let a random bot play to the end (a smoke test)
--
-- The real front end is the SDL3 player (`make varis-sdl; bin/varis-sdl sample-rpg/presentation.json`).

package.path = "./?.lua;" .. package.path

local G = require("game")
local seed = tonumber(arg and arg[1]) or 1
local bot = arg and (arg[1] == "--bot" or arg[2] == "--bot")
local session = G.new_session(seed)
session:play(:prologue)

local last_seq = 0
local function show_events()
    local new = {}
    logic (session:world()) do
        for e in query narrative_event(?seq, ?turn, ?kind, ?args) do
            if e.seq > last_seq then new[#new + 1] = e end
        end
    end
    table.sort(new, function(a, b) return a.seq < b.seq end)
    for _, e in ipairs(new) do
        if e.kind == :note then print("  * " .. e.args[1]) end
        last_seq = e.seq
    end
end

local function status()
    local w = session:world()
    local function q(name) return quality.get(:player, name, w) end
    print(string.format("-- day %d slot %d | STR %d WIT %d CHA %d GRT %d | coins %d stamina %d fame %d --",
        quality.get(:world, :day, w), quality.get(:world, :slot, w),
        q(:strength), q(:wits), q(:charm), q(:grit), q(:coins), q(:stamina), q(:fame)))
end

local function pick(options)
    if bot then return math.random(#options) end
    io.write("> ")
    return tonumber(io.read("l"))
end

local steps = 0
while not G.is_over(session) or session:present().beats do
    steps = steps + 1
    if steps > 4000 then error("bot did not finish") end
    local p = session:present()
    if p.beats then
        local b = p.beats[1]
        if b.kind == :menu then
            local labels = {}
            for i = 1, #b.choices do labels[i] = b.choices[i].text; print(string.format("  %d. %s", i, b.choices[i].text)) end
            local n = pick(labels)
            session:advance(p.token, b.choices[n].id)
        elseif b.kind == :input then
            session:advance(p.token, bot and "Rowan" or (io.read("l") or "Rowan"))
        else
            if b.text then print((b.speaker and (b.speaker.name .. ": ") or "") .. b.text) end
            local ended = b.kind == :ended
            session:advance(p.token)
            if ended and G.is_over(session) then break end
        end
    else
        show_events()
        local options = {}
        for _, s in ipairs(p.storylets) do
            print("[" .. s.title .. "]")
            if #s.text > 0 then print(s.text) end
            for _, c in ipairs(s.choices) do
                if c.enabled ~= false then
                    options[#options + 1] = c
                    print(string.format("  %d. %s", #options, c.title))
                else
                    print(string.format("  -  %s  [%s]", c.title, c.because))
                end
            end
        end
        if #options == 0 then error("stranded: no choices") end
        status()
        local n = pick(options)
        session:choose(options[n].token)
    end
end
print("The summer is over.")
for _, a in ipairs(Achievements.order) do print("achievement: " .. a) end
