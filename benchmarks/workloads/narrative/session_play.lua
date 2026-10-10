-- bench: scripted session of up to 60 choices (present / choose / period sync) on the sample game
package.path = "./?.lua;" .. package.path
local G = require("game")
local s = G.new_session(7)
local turns = 0
for _ = 1, 60 do
    if G.is_over(s) then break end
    local p = s:present()
    local token
    for _, st in ipairs(p.storylets) do
        if st.choices[1] then token = st.choices[1].token; break end
    end
    if not token then break end
    s:choose(token)
    G.sync_periods(s)
    turns = turns + 1
end
assert(turns > 0)
