-- Scenes are serializable positions and immutable beats, never suspended Lua frames.
local function scene(x) return x end
local function character(x) return x end
assert(scene(3) == 3 and character(4) == 4)
character guide {
    name="Guide", tag=:guide,
    attributes={expression={:calm,:happy}}, defaults={expression=:calm}
}
local mutable = {kind=:say, character=:guide, id="intro.line", text="Hello {who}."}
narrative.scene(:intro, {
    {kind=:set, ["local"]="who", value="Reader"},
    {kind=:show, character=:guide, slot=:left},
    mutable,
    {kind=:menu, choices={{id=:finish, text="Finish", target=:outro}}}
})
mutable.text = "Mutated"
scene outro {
    {kind=:say, character=:guide, attributes={expression=:happy}, text="Goodbye."},
    {kind="return"}
}
scene loop { {kind=:jump,target=:loop} }
scene recursive { {kind=:call,target=:recursive} }
local function factory() return logic.emptyworld() end
local s = narrative.new(factory())
s:play(:intro)
local p = s:present()
assert(p.beat_index == 2 and p.stage.characters.guide.slot == :left)
assert(s:save() == s:save())
reject(function() p.stage.characters.guide.slot = :right end, "immutable")
reject(function() s:advance({}, nil) end, "STALE_BEAT")
local other = narrative.new(factory())
other:play(:intro)
reject(function() other:advance(p.token) end, "STALE_BEAT")
s:advance(p.token)
reject(function() s:advance(p.token) end, "STALE_BEAT")
p = s:present()
assert(p.beats[1].text == "Hello Reader.")
narrative.translate("fr", {["scene.intro.line.text"]="Bonjour {who}."})
local french = s:render(p, "fr")
assert(french.beats[1].text == "Bonjour Reader." and french.token == p.token)
local saved = s:save()
local log = #s:replay_log().inputs
local again = s:present()
assert(s:save() == saved and #s:replay_log().inputs == log)
assert(again.beats[1].id == "intro.line")
local loaded = narrative.load(saved, factory)
assert(loaded:save() == saved)
reject(function() loaded:advance(p.token) end, "STALE_BEAT")
reject(function() s:play(:loop) end, "control-flow limit")
assert(s:save() == saved) -- failed jump loop did not publish a partial position/stage
reject(function() s:play(:recursive) end, "call stack limit")
assert(s:save() == saved)
s:advance(p.token)
p = s:present()
local before = s:save()
reject(function() s:advance(p.token, :wrong) end, "menu choice")
assert(s:save() == before)
s:advance(p.token, :finish)
p = s:present()
assert(p.scene == :outro and p.stage.characters.guide.attributes.expression == :happy)
s:advance(p.token)
assert(s:present().scene == nil)
