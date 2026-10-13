-- sticky storylets: always listed, no draw slot, exempt from non-replacement
-- history; `order` controls display order independently of priority.
relation stock(1)
relation always(1)
fact always(1)
fact stock(:a) fact stock(:b) fact stock(:c)
deck :default {draw = 1, replacement = false}
storylet ware(?x)
    when { stock(?x) }
    title "Ware {x}"
    choice take effect do retract stock(x) end end
end
storylet leave()
    when { always(1) }
    sticky true
    order 100
    priority 100
    title "Leave"
    choice go effect do end end
end
narrative.seal()
local s = narrative.new(logic.global)
s:seed(1)
local p = s:present()
assert(#p.storylets == 2, "one draw plus the sticky exit")
assert(p.storylets[1].id == :ware and p.storylets[2].id == :leave, "order puts the exit last")
s:choose(p.storylets[2].choices[1].token)
local r = s:present()
local leave_seen = false
for _, st in ipairs(r.storylets) do if st.id == :leave then leave_seen = true end end
assert(leave_seen, "sticky exit survives non-replacement history")
