# Tutorial: write a story with Varis

[Writer's guide](README.md) · [Cookbook](cookbook.md) · [Reference manual](../README.md)

You will write a small story, *The Lighthouse*, in eight short steps. You do not need to
know how to program. Every step is a few lines you can paste into a file, and every
program in this tutorial is run by the project's test suite, so what you read here
works.

<!-- docs-test: accumulate -->

You need the `varis` program (build it once with `make varis`; it appears as `bin/varis`).
Make an empty folder for the story and keep everything below inside it.

## 1. The smallest story

A Varis project is a folder with three files. `story.lua` is where **you** write. The other
two are plumbing you copy once and rarely touch.

`project.lua` tells the tools where things are. It is read, never run:

```lua file=project.lua
return {
    id       = "lighthouse",
    language = "en",
    entry    = "game",
    content  = { "story.lua" },
    scripts  = { "game.lua" },
    session  = "game.new_session",
    tests    = { "tests/*.lua" },
}
```

`game.lua` loads your story and starts a game. A *session* is one playthrough: it
remembers what has happened.

```lua file=game.lua
require("story")
narrative.seal()

local M = {}
function M.new_session(seed)
    local world = logic.world()
    logic (world) do
        fact at(:foot)
    end
    local session = narrative.new(world)
    session:seed(seed or 1)
    return session
end
return M
```

Now the story itself. Three ideas are all you need to start:

- A **fact** is something that is true: `at(:foot)` says the player is at the foot of the
  lighthouse. Words that start with a colon, like `:foot`, are *symbols*: names the story uses.
- A **storylet** is a scene the player can be offered. It says *when* it applies, what the
  player reads, and what they can choose.
- A **choice** has an **effect**: what changes when the player picks it.

```lua file=story.lua
relation at(1)
relation lamp_lit(0)

storylet stairs()
    when { at(:foot) }
    title "The stairs"
    text "A hundred and twelve steps wind up into the dark."
    choice climb
        title "Climb to the lamp room"
        effect do
            retract at(:foot)
            fact at(:lamp_room)
        end
    end
end

storylet lamp_room()
    when { at(:lamp_room), not lamp_lit() }
    title "The lamp room"
    text "The great lamp is cold."
    choice light
        title "Light the lamp"
        effect do
            fact lamp_lit()
        end
    end
end

storylet done()
    when { lamp_lit() }
    title "The sea is safe"
    text "Ships steer by your light."
    choice rest
        title "Rest"
        effect do end
    end
end
```

`relation at(1)` declares a kind of fact and how many values it holds. `when { ... }` lists
what must be true; `not` means "this must not be true". Play it with the text player:

```text play seed=1 input=1,1
The stairs
A hundred and twelve steps wind up into the dark.
1) Climb to the lamp room
The lamp room
The great lamp is cold.
1) Light the lamp
The sea is safe
Ships steer by your light.
1) Rest
```

Run it yourself with `varis play`. Type a number to choose, `quit` to leave.

## 2. Checking and testing

Two commands save you from most mistakes. `varis check` reads every file and reports
problems with a file name, a line and a name for the kind of problem, without running the
story. Here a typo in a placeholder (the `{...}` in a text) is caught:

```lua file=typo.lua check-error=unknown-placeholder
relation at(1)
storylet stairs(?place)
    when { at(?place) }
    title "Stairs in {plce}"
    choice climb
        effect do end
    end
end
```

`varis test` plays the story for you. A test says what should be shown or hidden after
which choices. Put it in `tests/walk.lua`:

```lua file=tests/walk.lua
test.case("lighting the lamp", function()
    local t = test.play{ seed = 1 }
    t:expect_shown("stairs")
    t:expect_hidden("lamp_room")
    t:choose("stairs", "climb")
    t:expect_shown("lamp_room")
    t:choose("lamp_room", "light")
    t:expect_fact("lamp_lit()")
    t:expect_shown("done")
end)
```

When a story gets big, tests are how you know that a change did not break an ending.
If a storylet you expected is missing, `t:why("name")` tells you which condition failed, and
in `varis play` you can type `why name`.

## 3. Numbers: qualities

Facts say *whether*. A **quality** says *how much*: lamp oil, coins, trust. Declare it once,
with limits and a label for the status line:

```lua file=qualities.lua
quality.define(:oil, { initial = 2, minimum = 0, maximum = 5, label = "Lamp oil" })
```

A quality needs a starting value in each new game. Add that to `game.lua`, and load the
new file from `story.lua`:

```lua file=game.lua
require("story")
narrative.seal()

local M = {}
function M.new_session(seed)
    local world = logic.world()
    logic (world) do
        fact at(:foot)
    end
    quality.initialize(:keeper, :oil, world)
    local session = narrative.new(world)
    session:seed(seed or 1)
    return session
end
return M
```

Now the lamp needs oil, and lighting it uses one. A storylet can ask about a quality in
`when`, and a choice changes it with `adjust ... by`. List the new file as content in
`project.lua` so the tools read it:

```lua file=project.lua
return {
    id       = "lighthouse",
    language = "en",
    entry    = "game",
    content  = { "story.lua", "qualities.lua" },
    scripts  = { "game.lua" },
    session  = "game.new_session",
    tests    = { "tests/*.lua" },
}
```

Read `?oil` as "some value, call it oil". A name in the storylet's parentheses is a
*parameter*: it can be used in the text (`{oil}`) and in effects, and each different value
is a separate instance of the storylet. A name used only inside `when` is just a name for
the query.

```lua file=story.lua
require("qualities")

relation at(1)
relation lamp_lit(0)

storylet stairs()
    when { at(:foot) }
    title "The stairs"
    text "A hundred and twelve steps wind up into the dark."
    choice climb
        title "Climb to the lamp room"
        effect do
            retract at(:foot)
            fact at(:lamp_room)
        end
    end
end

storylet lamp_room(?oil)
    when { at(:lamp_room), not lamp_lit(), quality(:keeper, :oil, ?oil), ?oil > 0 }
    title "The lamp room"
    text "The great lamp is cold. There is oil for {oil} more nights."
    choice light
        title "Light the lamp"
        effect do
            adjust quality(:keeper, :oil) by -1
            fact lamp_lit()
        end
    end
end

storylet no_oil()
    when { at(:lamp_room), quality(:keeper, :oil, ?oil), ?oil == 0 }
    title "The lamp room"
    text "The lamp is cold and the oil can is empty."
    choice wait
        title "Wait for morning"
        effect do end
    end
end

storylet done()
    when { lamp_lit() }
    title "The sea is safe"
    text "Ships steer by your light."
    choice rest
        title "Rest"
        effect do end
    end
end
```

Add `t:expect_quality(:keeper, :oil, 1)` to `tests/walk.lua` after lighting the lamp when
you get there (the next step does it for you).

## 4. Choices the player cannot take yet

Hiding a choice teaches the player nothing. Often it is better to show it greyed out, with
a reason. That is `require ... because`:

```lua file=story.lua
require("qualities")

relation at(1)
relation lamp_lit(0)
relation has_key(0)

storylet stairs()
    when { at(:foot) }
    title "The stairs"
    text "A hundred and twelve steps wind up into the dark. A door at the top is locked."
    choice climb
        title "Climb to the lamp room"
        effect do
            retract at(:foot)
            fact at(:lamp_room)
        end
    end
    choice search
        when { not has_key() }
        title "Look under the mat"
        effect do fact has_key() end
    end
end

storylet lamp_room(?oil)
    when { at(:lamp_room), not lamp_lit(), quality(:keeper, :oil, ?oil), ?oil > 0 }
    title "The lamp room"
    text "The great lamp is cold. There is oil for {oil} more nights."
    choice light
        require { has_key() }
        because "The lamp is locked, and you have no key."
        title "Light the lamp"
        effect do
            adjust quality(:keeper, :oil) by -1
            fact lamp_lit()
        end
    end
end

storylet done()
    when { lamp_lit() }
    title "The sea is safe"
    text "Ships steer by your light."
    choice rest
        title "Rest"
        effect do end
    end
end
```

A choice with `when` appears only when it holds; a choice with `require` always appears,
and when the requirement fails the game gets the `because` text instead of a button.
Use `require` for things the player should know are possible.

Update the test to match: add the key before lighting.

```lua file=tests/walk.lua
test.case("lighting the lamp needs the key", function()
    local t = test.play{ seed = 1 }
    t:choose("stairs", "search")
    t:choose("stairs", "climb")
    t:choose("lamp_room", "light")
    t:expect_fact("lamp_lit()")
    t:expect_quality(:keeper, :oil, 1)
    t:expect_shown("done")
end)
```

## 5. Text that varies

Texts can change with the state of the story or with a little chance. Conditions ask a
question of the world; variants pick one of several wordings, and the same seed always
picks the same one, so a replay matches:

```lua file=story.lua
require("qualities")

relation at(1)
relation lamp_lit(0)
relation has_key(0)

storylet stairs()
    when { at(:foot) }
    title "The stairs"
    text [[{#variant 3}A hundred and twelve steps wind up into the dark.{#variant 1}The stairs are wet again.{/variant}
{#if query has_key()}The key is warm in your pocket.{#else}A door at the top is locked.{/if}]]
    choice climb
        title "Climb to the lamp room"
        effect do
            retract at(:foot)
            fact at(:lamp_room)
        end
    end
    choice search
        when { not has_key() }
        title "Look under the mat"
        effect do fact has_key() end
    end
end

storylet lamp_room(?oil)
    when { at(:lamp_room), not lamp_lit(), quality(:keeper, :oil, ?oil), ?oil > 0 }
    title "The lamp room"
    text "The great lamp is cold. {#plural oil}{#one}One night of oil is left.{#other}There is oil for {oil} nights.{/plural}"
    choice light
        require { has_key() }
        because "The lamp is locked, and you have no key."
        title "Light the lamp"
        effect do
            adjust quality(:keeper, :oil) by -1
            fact lamp_lit()
        end
    end
end

storylet done()
    when { lamp_lit() }
    title "The sea is safe"
    text "Ships steer by your light."
    choice rest
        title "Rest"
        effect do end
    end
end
```

`{#variant 3}...{#variant 1}...{/variant}` chooses the first about three times in four.
`{#plural oil}` picks wording by a number; it is how you avoid "1 nights", and it is also
what a translator uses to follow another language's rules. A literal brace is written `{{`.

## 6. A cast and conversations: scenes

For a stretch of dialogue, a storylet is the wrong tool. A **scene** is a fixed run of
lines. A **character** is a name the scenes can use, with attributes such as an expression
that a front end can draw. Scenes live in their own file:

```lua file=scenes.lua
character gull {
    name = "The gull", tag = :gull,
    attributes = { mood = { :sly, :smug } },
    defaults   = { mood = :sly },
}

scene gull_talk {
    { kind = :say, character = :gull, id = "gull.hello",
      text = "You are late with the lamp, keeper." },
    { kind = :input, ["local"] = "name", text = "What do you tell the gull?",
      default = "Keeper", min_length = 2, max_length = 12 },
    { kind = :say, character = :gull, attributes = { mood = :smug },
      id = "gull.reply", text = "Hmph, {name}. The sea is watching." },
    { kind = :menu, choices = {
        { id = :shoo, text = "Shoo it away", target = :gull_end },
        { id = :bread, text = "Offer bread", target = :gull_end },
    } },
}
scene gull_end {
    { kind = :narration, id = "gull.end", text = "The gull leaves, offended or fed." },
}
```

A choice starts the scene with `narrative.play`. Add this storylet to `story.lua` (and
`require("scenes")` at its top; the project file lists `scenes.lua` as content):

```lua file=project.lua
return {
    id       = "lighthouse",
    language = "en",
    entry    = "game",
    content  = { "story.lua", "scenes.lua", "qualities.lua" },
    scripts  = { "game.lua" },
    session  = "game.new_session",
    tests    = { "tests/*.lua" },
}
```

```lua file=story.lua
require("qualities")
require("scenes")

relation at(1)
relation lamp_lit(0)
relation has_key(0)
relation met_gull(0)

storylet stairs()
    when { at(:foot) }
    title "The stairs"
    text "A hundred and twelve steps wind up into the dark."
    choice climb
        title "Climb to the lamp room"
        effect do
            retract at(:foot)
            fact at(:lamp_room)
        end
    end
    choice search
        when { not has_key() }
        title "Look under the mat"
        effect do fact has_key() end
    end
    choice gull
        when { not met_gull() }
        title "Talk to the gull on the rail"
        effect do
            fact met_gull()
            narrative.play(:gull_talk)
        end
    end
end

storylet lamp_room(?oil)
    when { at(:lamp_room), not lamp_lit(), quality(:keeper, :oil, ?oil), ?oil > 0 }
    title "The lamp room"
    text "The great lamp is cold."
    choice light
        require { has_key() }
        because "The lamp is locked, and you have no key."
        title "Light the lamp"
        effect do
            adjust quality(:keeper, :oil) by -1
            fact lamp_lit()
        end
    end
end

storylet done()
    when { lamp_lit() }
    title "The sea is safe"
    text "Ships steer by your light."
    choice rest
        title "Rest"
        effect do end
    end
end
```

While a scene runs, the game shows one *beat* at a time (a line, a menu, a question) and
moves on when the player does. When the scene runs out, the storylets come back. Beat
fields are listed in the manual, section 6.11. The `input` beat above refuses a name that
is too short or too long, and uses `default` when the player just presses enter.

## 7. Saving, going back, and keeping a profile

Saving needs no work from you: the game state is facts, numbers and a position, so a save
is just text. Hosts call `session:save()`, and `session:save{ label = "Slot 1" }` adds a
label you can list without loading. Three more things come with the engine:

- **Going back.** `session:set_undo_limit(20)` lets the front end offer "back": `session:undo()`
  takes back the last choice or the last scene beat, with the dice, the turn counter and the
  scene position. The SDL player binds it to the B key.
- **Visits.** `narrative.visited(:stairs)` counts how many times a storylet's choices were
  taken, from inside an effect; use it for "the third time you climb, you are out of breath".
- **A profile.** Things that outlive a game (endings seen, a gallery) go in
  `narrative.profile_set("ending.lamp", true)`. It is stored by the front end, not in saves.

Here is a probe that exercises all three. It is a plain script you can run with
`varis probe.lua`:

```lua file=probe.lua run
local session = require("game").new_session(7)
session:set_undo_limit(5)
local p = session:present()
assert(p.storylets[1].id == :stairs)
session:choose(p.storylets[1].choices[1].token)       -- climb
assert(session:visited(:stairs) == 1)
local back = session:undo()
assert(session:turn() == 0 and session:visited(:stairs) == 0)
assert(back.storylets[1].id == :stairs)               -- the same choices, usable again
narrative.profile_set("seen.intro", true)
assert(narrative.profile_get("seen.intro") == true)
local text = session:save{ label = "Before the climb" }
assert(narrative.save_info(text).label == "Before the climb")
```

## 8. Releasing it to the world

Three habits keep a story shippable.

- **Run `varis check` and `varis test` before every commit.** `tools/project_ci.sh` in the
  repository does both, plus a translation freshness check, in one command; put it in your
  CI.
- **Give lines names.** An `id` on a scene line (`id = "gull.hello"`) keeps translators'
  work attached to the line when you reorder the scene. Storylet titles and texts are named
  after their storylet and choice automatically.
- **Hand translators a kit.** `varis l10n extract` writes the catalog of every message;
  `varis l10n export --locale fr --format xliff --kit kit/` writes a hand-off kit for a
  translator or a publisher; `varis l10n build` makes a pack the game loads with
  `narrative.load_pack`. See section 8.4 of the manual.

Where next: the [cookbook](cookbook.md) has short answers for common story needs, and the
[reference manual](../README.md) is the complete definition. If a message from the tools
puzzles you, `varis check --json` prints the same findings with a code you can search for.
