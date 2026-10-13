-- session:undo() takes back the last committed choice or beat advance in place: facts, turn,
-- decks, random state, periods and scene position return to the moment the command started,
-- and the presentation shown then comes back with usable tokens.
relation coins(1)
relation visited(1)
fact coins(0)
deck :default {draw = 1, replacement = true}
storylet market()
    when { coins(?c) }
    title "Market"
    choice earn effect do
        fact coins(5)
        fact visited(:market)
    end end
end
character guide { name="Guide", tag=:guide }
scene tale {
    {kind=:say, character=:guide, id="a", text="One."},
    {kind=:say, character=:guide, id="b", text="Two."},
    {kind=:say, character=:guide, id="c", text="Three."},
}
narrative.seal()
local s = narrative.new(logic.global)
s:seed(7)
reject(function() s:undo() end, "nothing to undo")
assert(s:undo_depth() == 0)
s:set_undo_limit(3)
local p = s:present()
local saved = s:save()
local replay = #s:replay_log().inputs
s:choose(p.storylets[1].choices[1].token)
assert(s:turn() == 1 and s:undo_depth() == 1)
assert(count(query coins(5)) == 1)
local back = s:undo()
assert(back == p, "undo returns the presentation that was current")
assert(s:turn() == 0 and s:undo_depth() == 0)
assert(count(query coins(0)) == 1 and count(query coins(5)) == 0)
assert(count(query visited(:market)) == 0)
assert(#s:replay_log().inputs == replay, "the replay log is the undone timeline")
-- the old token works again, once
s:choose(back.storylets[1].choices[1].token)
assert(s:turn() == 1)
reject(function() s:choose(back.storylets[1].choices[1].token) end, "STALE_CHOICE")
-- tokens issued by a presentation of the undone future are void
local future = s:present()
s:undo()
reject(function() s:choose(future.storylets[1].choices[1].token) end, "STALE_CHOICE")
-- scene beats: advance, undo, advance again
s:play(:tale)
local beat = s:present()
assert(beat.beat_index == 1)
s:advance(beat.token)
local second = s:present()
assert(second.beat_index == 2)
s:advance(second.token)
assert(s:present().beat_index == 3)
local again = s:undo()
assert(again.beat_index == 2 and again.token == second.token)
s:advance(again.token)
assert(s:present().beat_index == 3)
-- the ring is bounded
s:undo()
s:undo()
assert(s:undo_depth() >= 0)
for i = 1, 5 do
    local ok = pcall(function() s:advance(s:present().token) end)
    if not ok then break end
end
assert(s:undo_depth() <= 3)
-- off by default; a limit of zero clears it
local fresh = narrative.new(logic.emptyworld())
reject(function() fresh:undo() end, "nothing to undo")
reject(function() fresh:set_undo_limit(-1) end, "nonnegative")
s:set_undo_limit(0)
assert(s:undo_depth() == 0)
