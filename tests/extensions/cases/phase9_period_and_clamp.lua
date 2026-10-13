-- Milestone 28: `adjust ... clamp`, `quality.add(..., {clamp = true})`, `quality.metadata`,
-- `narrative.set_period` and `narrative.return_deck`.
quality.define(:hp, {initial = 5, minimum = 0, maximum = 10})
quality.define(:gold, {initial = 0})
quality.initialize(:keeper, :hp)
quality.initialize(:keeper, :gold)
adjust quality(:keeper, :hp) by 20 clamp
assert(quality.get(:keeper, :hp) == 10)
adjust quality(:keeper, :hp) by -50 clamp
assert(quality.get(:keeper, :hp) == 0)
adjust quality(:keeper, :hp) by 3
assert(quality.get(:keeper, :hp) == 3)
-- ordinary adjustment keeps its bounds error and leaves the value alone
reject(function() adjust quality(:keeper, :hp) by 50 end, "above maximum")
assert(quality.get(:keeper, :hp) == 3)
-- an absent bound leaves that side unrestricted
adjust quality(:keeper, :gold) by -5 clamp
assert(quality.get(:keeper, :gold) == -5)
-- an absent value still errors; relations without bounds reject clamp
reject(function() adjust quality(:nobody, :hp) by 1 clamp end, "absent")
relation tally(who, n) key(who)
fact tally(:a, 1)
reject(function() adjust tally(:a) by 1 clamp end, "no declared bounds")
-- the function form
quality.add(:keeper, :hp, 100, {clamp = true})
assert(quality.get(:keeper, :hp) == 10)
reject(function() quality.add(:keeper, :hp, 1, {clamp = true, extra = 1}) end, "unknown quality.add option")
reject(function() quality.add(:keeper, :hp, 1) end, "above maximum")
-- clamp inside a rolled-back transaction leaves nothing
transaction do
    quality.add(:keeper, :hp, -100, {clamp = true})
    assert(quality.get(:keeper, :hp) == 0)
    rollback
end
assert(quality.get(:keeper, :hp) == 10)
-- metadata is read only and keeps absent bounds absent
local m = quality.metadata(:hp)
assert(m.minimum == 0 and m.maximum == 10 and m.initial == 5 and m.label == "hp" and m.visible == true)
assert(quality.metadata(:gold).minimum == nil and quality.metadata(:gold).maximum == nil)
reject(function() m.minimum = 3 end, "")
reject(function() quality.metadata(:missing) end, "unknown quality")
-- `clamp` stays an ordinary name elsewhere
local function clamp(x) return x end
assert(clamp(4) == 4)

-- narrative.set_period and narrative.return_deck, from effects
relation open(1)
fact open(:x)
deck :default {draw = 1, replacement = true}
deck :cellar {draw = 1, replacement = true}
storylet go_down()
    when { open(:x) }
    title "Stairs"
    choice descend effect do
        narrative.set_period(:chapter, 2)
        narrative.push_deck(:cellar)
    end end
end
storylet cellar_up()
    when { open(:x) }
    deck :cellar
    title "Cellar"
    choice up effect do narrative.return_deck() end end
    choice bad effect do narrative.set_period(:chapter, narrative) end end
end
narrative.seal()
local s = narrative.new(logic.global)
s:seed(1)
s:set_period(:chapter, 1)
reject(function() narrative.set_period(:chapter, 3) end, "effect")
reject(function() narrative.return_deck() end, "effect")
local p = s:present()
s:choose(p.storylets[1].choices[1].token)
assert(s:active_deck() == :cellar)
local q = s:present()
local bad
for i = 1, #q.storylets[1].choices do if q.storylets[1].choices[i].id == :bad then bad = q.storylets[1].choices[i] end end
-- a failing effect discards its period change
reject(function() s:choose(bad.token) end, "")
assert(s:active_deck() == :cellar)
s:choose(q.storylets[1].choices[1].token)
assert(s:active_deck() == :default)
