-- Readable scene statements (milestone 29): say/narrate/show/hide, input, set, menu with option
-- bodies, `if` on a local, `effect name(...)`, `effect using … do … end`, jump/call/return.
quality.define(:str, {initial = 10, minimum = 0, maximum = 20, label = "Strength"})
procedure set_name(?name)
    effect do set player_name(:player, name) end
end
character mira {
    name = "Mira", tag = :mira,
    attributes = {expression = {:quiet, :smile}},
    defaults = {expression = :quiet}
}
scene greeting()
    background :harbour
    show mira at :left with expression = :smile
    input visitor id ask_name "Your name?" with min_length = 1, max_length = 12
    effect set_name(name = visitor)
    say mira id hello "Welcome, {visitor}."
    set mood = 1
    menu
        option tea "Ask for tea" do
            narrate id tea_line "She pours the tea."
            set mood = 3
        end
        option leave "Say goodbye" do
            set mood = 0
        end
    end
    if mood >= 3 then
        say mira with expression = :smile id warm "Stay as long as you like."
    elseif mood == 1 then
        narrate id neutral "Nothing happens."
    else
        say mira id cool "Another time, then."
    end
    effect using visitor, mood do
        set player_name(:player, visitor)
        adjust quality(:player, :str) by mood
    end
    call farewell
    narrate id after_call "Back in the greeting."
    hide mira
end
scene farewell()
    narrate id bye "Goodbye."
    return
end
local latest
local function factory()
    local w = logic.emptyworld()
    logic (w) do relation player_name(who, name) key(who) end
    quality.initialize(:player, :str, w)
    return w
end
local function run(choice)
    latest = factory()
    local s = narrative.new(latest)
    s:seed(1)
    s:play(:greeting)
    local p = s:present()
    assert(p.beats[1].kind == "background" or p.beats[1].kind == :background)
    p = (function() s:advance(p.token); return s:present() end)()   -- show
    p = (function() s:advance(p.token); return s:present() end)()   -- input
    assert(p.beats[1].text == "Your name?")
    assert(not pcall(s.advance, s, p.token, ""))                   -- min_length
    s:advance(p.token, "Rowan")
    p = s:present()
    assert(p.beats[1].text == "Welcome, Rowan.")
    assert(p.beats[1].id == "greeting.hello")
    s:advance(p.token)
    p = s:present()
    assert(p.beats[1].kind == :menu)
    -- mid-menu save and load (the loaded session builds its own world, so keep driving s)
    local loaded = narrative.load(s:save(), factory)
    assert(loaded:save() == s:save())
    p = s:present()
    assert(loaded:present().beats[1].kind == :menu)
    assert(p.beats[1].choices[1].text == "Ask for tea")
    -- Option labels are catalog text, keyed scene.<scene>.<option id>.label
    narrative.translate("fr", {["scene.greeting.tea.label"] = "Demander du thé"})
    local french = s:render(p, "fr")
    assert(french.beats[1].choices[1].text == "Demander du thé")
    assert(french.beats[1].choices[2].text == "Say goodbye")   -- untranslated: source wording
    assert(french.token == p.token)
    s:advance(p.token, choice)
    return s
end
local s = run("tea")
local p = s:present()
assert(p.beats[1].text == "She pours the tea.")
s:advance(p.token)
p = s:present()
assert(p.beats[1].text == "Stay as long as you like.")
assert(p.stage.characters.mira.attributes.expression == :smile)
s:advance(p.token)
p = s:present()                                  -- effects ran, call entered
assert(p.beats[1].text == "Goodbye." and p.scene == :farewell)
assert(quality.get(:player, :str, latest) == 13)
s:advance(p.token)
p = s:present()
assert(p.beats[1].text == "Back in the greeting.")

s = run("leave")
p = s:present()
assert(p.beats[1].text == "Another time, then.")
s:advance(p.token)
assert(quality.get(:player, :str, latest) == 10)
print("readable scene checks passed")
