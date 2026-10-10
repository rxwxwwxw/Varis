-- bench: play 30 choices, then save, load into a fresh world and compare, and read the replay log
package.path = "./?.lua;" .. package.path
local G = require("game")
local s = G.new_session(11)
for _ = 1, 30 do
    local p = s:present()
    local token
    for _, st in ipairs(p.storylets) do
        if st.choices[1] then token = st.choices[1].token; break end
    end
    if not token then break end
    s:choose(token)
    G.sync_periods(s)
end
local saved = s:save()
local restored = G.load(saved)
assert(restored:save() == saved)
assert(#s:replay_log().inputs > 0)
