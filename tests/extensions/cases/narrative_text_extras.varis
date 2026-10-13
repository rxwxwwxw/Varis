-- {#if lua}, fragments {>name}, story variables (var / {$name}), passage links, autosave
-- hooks and save slots.
relation ready(0)
fact ready()
var gold = 3
narrative.fragment(:greeting, "Welcome{#if query var(:gold, 3)}, rich one{/if}")
narrative.fragment(:signoff, "{>greeting}!")
storylet shop(?n)
    when { ready(), var(:gold, ?n) }
    title "Shop"
    text "{>signoff} You hold {$gold} coins ({n}). {#if lua n >= 3}Plenty.{#else}Few.{/if}"
    choice spend
        title "Spend"
        effect do adjust var(:gold) by -1 end
    end
end
character guide { name="Guide", tag=:guide }
scene tale {
    {kind=:say, character=:guide, id="t1", text="{>greeting}, friend."},
    {kind=:ended},
}
reject(function() narrative.fragment(:greeting, "x") end, "duplicate template fragment")
reject(function() storylet bad() when { ready() } title "{>missing}" choice c effect do end end end end, "unknown template fragment")
narrative.seal()
local s = narrative.new(logic.world())
s:seed(1)
local p = s:present()
assert(p.storylets[1].text == "Welcome, rich one! You hold 3 coins (3). Plenty.", p.storylets[1].text)
-- autosave hook: called with the save text after each committed command
local saves = {}
s:set_autosave(function(text) saves[#saves + 1] = text end)
s:choose(p.storylets[1].choices[1].token)
assert(#saves == 1 and narrative.save_info(saves[1]).turn == 1)
p = s:present()
assert(p.storylets[1].text == "Welcome! You hold 2 coins (2). Few.", p.storylets[1].text)
s:set_autosave(nil)
s:choose(p.storylets[1].choices[1].token)
assert(#saves == 1)
reject(function() s:set_autosave(5) end, "set_autosave")
-- variables survive a save (they are facts)
local copy = narrative.load(s:save(), function() return logic.world() end)
assert(copy:present().storylets[1].text:find("You hold 1 coins", 1, true))
-- save slots
local dir = os.tmpname() .. "-slots"
narrative.save_slot(s, dir, "one", {label = "Slot one"})
narrative.save_slot(s, dir, "two")
local slots = narrative.list_slots(dir)
assert(#slots == 2 and slots[1].name == "one" and slots[1].label == "Slot one" and slots[2].name == "two")
local back = narrative.load_slot(dir, "one", function() return logic.world() end)
assert(back:turn() == s:turn())
reject(function() narrative.save_slot(s, dir, "../escape") end, "slot name")
narrative.delete_slot(dir, "one")
narrative.delete_slot(dir, "two")
assert(#narrative.list_slots(dir) == 0)
-- passage links
local spans = narrative.spans("Go [[to the door->door]] or [[hall]].")
assert(spans[2].text == "to the door" and spans[2].link == "door")
assert(spans[4].text == "hall" and spans[4].link == "hall")
