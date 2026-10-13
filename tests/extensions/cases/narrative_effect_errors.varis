-- Contextual spellings remain ordinary identifiers, calls, fields and labels.
local function storylet(x) return x end
local function action(x) return x end
local function deck(x) return x end
assert(storylet("plain") == "plain" and action(2) == 2 and deck(3) == 3)
local fields = {choice=1, when=2, effect=3, phase=4, priority=5, weight=6,
    cooldown=7, repeatable=8, title=9, text=10, key=11, by=12,
    count=13, sum=14, min=15, max=16}
assert(fields.when + fields.sum + fields.max == 32)
local object = {choice=function(self, value) return value end}
assert(object:choice(9) == 9)
::storylet::
::transaction::
relation ready(0)
relation value(id, n) key(id)
fact ready()
fact value(:p, 0)
local foreign = logic.world()
local session
storylet invalid()
    when {ready()} title "Invalid effects"
    choice yield_child effect do
        adjust value(:p) by 1
        local child = coroutine.create(function()
            assert(not coroutine.isyieldable())
            coroutine.yield("forbidden")
        end)
        local ok, err = coroutine.resume(child)
        assert(not ok)
        error(err)
    end end
    choice recursive effect do
        adjust value(:p) by 1
        session:present()
    end end
    choice registration effect do
        adjust value(:p) by 1
        rule inferred() :- ready()
    end end
    choice cross_world effect do
        adjust value(:p) by 1
        set foreign.value(:p, 9)
    end end
    choice schedule effect do
        adjust value(:p) by 1
        narrative.schedule(:bad, narrative.sequence(), -1)
    end end
    choice good effect do
        transaction do narrative.push_deck(:default) rollback end
        narrative.reset_deck()
        adjust value(:p) by 1
    end end
end
deck :default {draw=1, replacement=false}
session = narrative.new(logic.global)
session:seed(1)
local p = session:present()
assert(#p.storylets == 1 and #session:present().storylets == 0)
local messages = {"yield", "recursive", "registration prohibited", "cross-world mutation", "nonnegative"}
for i = 1, #messages do
    reject(function() session:choose(p.storylets[1].choices[i].token) end, messages[i])
    assert(session:turn() == 0 and (query value(:p, ?n))().n == 0)
end
reject(function() session:choose({}) end, "STALE_CHOICE")
reject(function() return (query inferred())() end, "unknown relation")
session:choose(p.storylets[1].choices[6].token)
assert(session:turn() == 1 and session:active_deck() == :default)
assert(#session:present().storylets == 1 and (query value(:p, ?n))().n == 1)
local child = coroutine.create(function()
    assert(coroutine.isyieldable())
    coroutine.yield("restored")
end)
local ok, value = coroutine.resume(child)
assert(ok and value == "restored")
