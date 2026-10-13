# Cookbook: common story needs

[Writer's guide](README.md) · [Tutorial](tutorial.md) · [Reference manual](../README.md)

Short answers to "how do I...". Each recipe is a whole `story.lua` you can drop into a
project like the one built in the [tutorial](tutorial.md), plus a test that shows it does what
it says. The test files go in `tests/`. Run them with `varis test`.

<!-- docs-test: fresh -->

A note on names: `?x` is a variable, `:x` is a symbol (a name the story uses), and `{x}` in
a text shows the value of a parameter called `x`. A fact is written `fact name(args)`;
`retract` removes one.

## Show something only once

`repeatable false` hides a storylet after one of its choices has been taken.

```lua file=story.lua
relation at(1)
fact at(:harbour)

deck :default { draw = 4 }

storylet find_coin()
    when { at(:harbour) }
    repeatable false
    title "A coin in the gutter"
    choice take
        title "Pick it up"
        effect do end
    end
end

storylet wander()
    when { at(:harbour) }
    title "Wander the quay"
    choice go
        title "Wander"
        effect do end
    end
end
```

```lua file=tests/once.lua
test.case("the coin is found once", function()
    local t = test.play{ seed = 1 }
    t:expect_shown("find_coin")
    t:choose("find_coin", "take")
    t:expect_hidden("find_coin")
end)
```

## Come back to something later

`cooldown N` keeps a storylet away for N turns after one of its choices was taken. A turn
passes each time the player makes a choice.

```lua file=story.lua
relation at(1)
fact at(:market)

deck :default { draw = 4 }

storylet haggle()
    when { at(:market) }
    cooldown 2
    title "Haggle with the fishwife"
    choice go
        title "Haggle"
        effect do end
    end
end

storylet browse()
    when { at(:market) }
    title "Browse"
    choice go
        title "Browse the stalls"
        effect do end
    end
end
```

```lua file=tests/cooldown.lua
test.case("haggling needs a rest", function()
    local t = test.play{ seed = 1 }
    t:choose("haggle", "go")
    t:expect_hidden("haggle")
    t:choose("browse", "go")
    t:expect_hidden("haggle")
    t:choose("browse", "go")
    t:expect_shown("haggle")
end)
```

## Keep a score and react to it

Qualities are numbers with limits. Declare and initialize them at the top of the story
file; each game starts with the initial value.

```lua file=story.lua
quality.define(:trust, { initial = 0, minimum = 0, maximum = 5, label = "Trust" })
quality.initialize(:keeper, :trust)

storylet gossip()
    when { quality(:keeper, :trust, ?t), ?t < 3 }
    title "Gossip at the pump"
    choice chat
        title "Listen to the village"
        effect do adjust quality(:keeper, :trust) by 1 end
    end
end

storylet invitation()
    when { quality(:keeper, :trust, ?t), ?t >= 3 }
    title "An invitation to supper"
    choice accept
        title "Accept"
        effect do end
    end
end
```

```lua file=tests/trust.lua
test.case("trust opens a door", function()
    local t = test.play{ seed = 1 }
    t:expect_hidden("invitation")
    for _ = 1, 3 do t:choose("gossip", "chat") end
    t:expect_shown("invitation")
    t:expect_hidden("gossip")
    t:expect_quality(:keeper, :trust, 3)
end)
```

`adjust quality(...) by n` stops with an error if the result would leave the limits, so a
choice that would push trust below zero should say so in its `when` or `require`.

## Show a choice the player cannot take yet

`require` keeps the choice on screen and explains itself with `because`.

```lua file=story.lua
relation open(0)
fact open()

quality.define(:strength, { initial = 4, minimum = 0, maximum = 10, label = "Strength" })
quality.initialize(:keeper, :strength)

storylet boulder()
    when { open() }
    title "A boulder blocks the path"
    choice lift
        require { quality(:keeper, :strength, ?s), ?s >= 6 }
        because "You are not strong enough to lift it."
        title "Lift it"
        effect do end
    end
    choice walk_round
        title "Walk round"
        effect do end
    end
end
```

```lua file=tests/boulder.lua
test.case("the boulder", function()
    local t = test.play{ seed = 1 }
    local shown = t.session:present().storylets[1]
    local lift
    for _, c in ipairs(shown.choices) do if c.id == :lift then lift = c end end
    assert(lift.enabled == false)
    assert(lift.because == "You are not strong enough to lift it.")
    assert(lift.token == nil)
end)
```

## Sell things

A storylet can take a parameter from a relation, one instance per row. A choice can add a
parameter of its own, with its own `when`, to look up a price.

```lua file=story.lua
relation for_sale(2)
relation owns(1)
quality.define(:coins, { initial = 5, minimum = 0, maximum = 99, label = "Coins" })
quality.initialize(:player, :coins)
fact for_sale(:rope, 3)
fact for_sale(:lantern, 9)

storylet stall(?item)
    when { for_sale(?item, ?cost) }
    title "A stall selling {item}"
    choice buy(?cost)
        when { for_sale(?item, ?cost), quality(:player, :coins, ?c), ?c >= ?cost }
        title "Buy it for {cost}"
        effect do
            adjust quality(:player, :coins) by -cost
            retract for_sale(item, cost)
            fact owns(item)
        end
    end
end
```

```lua file=tests/shop.lua
test.case("buying rope", function()
    local t = test.play{ seed = 1 }
    t:expect_shown("stall", { item = :rope })
    t:choose("stall", "buy", { item = :rope })
    t:expect_fact("owns(:rope)")
    t:expect_quality(:player, :coins, 2)
    t:expect_hidden("stall", { item = :rope })
    t:expect_shown("stall", { item = :lantern })   -- too dear for now, but on show
end)
```

## Say something different the first time

`narrative.visited(:storylet)` counts how many times a storylet's choices were taken.
Inside an effect it does not yet count the choice being made.

```lua file=story.lua
relation open(0)
fact open()

relation told(1)

storylet cave()
    when { open() }
    title "The sea cave"
    choice enter
        title "Go in"
        effect do
            if narrative.visited(:cave) == 0 then
                fact told(:first_time)
            else
                fact told(:again)
            end
        end
    end
end
```

```lua file=tests/cave.lua
test.case("first time and after", function()
    local t = test.play{ seed = 1 }
    t:choose("cave", "enter")
    t:expect_fact("told(:first_time)")
    t:choose("cave", "enter")
    t:expect_fact("told(:again)")
end)
```

To make a *storylet* depend on a visit, have the effect record a fact (`fact seen_cave()`)
and write `when { seen_cave() }`. Facts are the thing storylets can ask about.

## Make something happen by itself

An **action** runs on its own, between choices, as soon as its conditions hold. It is how
you write "when the third clue is found, the detective arrives".

```lua file=story.lua
relation open(0)
fact open()

relation clue(1)
relation arrived(0)

storylet search()
    when { open() }
    title "Search the study"
    choice dig
        title "Look through the drawers"
        effect do
            fact clue(narrative.visited(:search) + 1)
        end
    end
end

action detective_arrives()
    when { clue(3), not arrived() }
    once_per :game
    effect do
        fact arrived()
        narrative.emit(:note, "The detective is at the door.")
    end
end
```

```lua file=tests/action.lua
test.case("the detective", function()
    local t = test.play{ seed = 1 }
    t:choose("search", "dig")
    t:choose("search", "dig")
    t:expect_no_fact("arrived()")
    t:choose("search", "dig")
    t:expect_fact("arrived()")
end)
```

## Make something happen later

Schedule an event a number of turns ahead and handle it when it comes due. The handler runs
in its own transaction.

```lua file=story.lua
relation storm(0)

narrative.on(:storm_breaks, function(world)
    logic (world) do
        fact storm()
    end
end)

storylet moor_boat()
    when { not storm() }
    title "Moor the boat"
    choice tie
        title "Tie her up"
        effect do
            narrative.schedule(:storm_breaks, narrative.sequence(), 2)
        end
    end
end
```

```lua file=tests/storm.lua
test.case("the storm breaks two turns later", function()
    local t = test.play{ seed = 1 }
    t:choose("moor_boat", "tie")
    t:expect_no_fact("storm()")
    t:choose("moor_boat", "tie")
    t:expect_fact("storm()")
end)
```

## Keep track of how much someone likes you

A relation with a `key` holds one value per key, so `set` replaces the old value:

```lua file=story.lua
relation affection(who, level) key(who)
set affection(:mira, 0)

storylet mira_chat(?level)
    when { affection(:mira, ?level), ?level < 3 }
    title "Talk to Mira"
    text "{#select level}{#case 0}She nods, guarded.{#case 1}She smiles a little.{#default}She waves you over.{/select}"
    choice kind
        title "Be kind"
        effect do adjust affection(:mira) by 1 end
    end
end

storylet mira_friend()
    when { affection(:mira, 3) }
    title "Mira saves you a seat"
    choice sit
        title "Sit"
        effect do end
    end
end
```

```lua file=tests/mira.lua
test.case("kindness adds up", function()
    local t = test.play{ seed = 1 }
    t:choose("mira_chat", "kind")
    t:choose("mira_chat", "kind")
    t:choose("mira_chat", "kind")
    t:expect_shown("mira_friend")
    t:expect_hidden("mira_chat")
end)
```

`{#select level}` picks wording by the value of a parameter, and `{#plural n}` by a number.
Both need a fallback branch (`{#default}`, `{#other}`).

## Ask the player's name

A scene can ask a question and remember the answer in a *local*. A **procedure** carries it
into the world, where storylets can use it:

```lua file=story.lua
relation player_name(name) key(name)
relation named(0)
character narrator { name = "Narrator", tag = :narrator }

procedure remember_name(?name)
    effect do
        set player_name(name)
        fact named()
    end
end

scene arrival {
    { kind = :narration, id = "arrival.horn", text = "The ferry horn sounds." },
    { kind = :input, ["local"] = "who", text = "Who are you?",
      default = "Traveller", min_length = 1, max_length = 16 },
    { kind = :effect, name = :remember_name, locals = { name = "who" } },
    { kind = :narration, id = "arrival.welcome", text = "Welcome, {who}." },
}

storylet start()
    when { not named() }
    title "The ferry"
    choice step
        title "Step off"
        effect do narrative.play(:arrival) end
    end
end

storylet greeted(?n)
    when { player_name(?n) }
    title "Welcome, {n}"
    choice ok
        title "Thank you"
        effect do end
    end
end
```

```lua file=tests/name.lua
test.case("the name is remembered", function()
    local t = test.play{ seed = 1 }
    t:choose("start", "step")
    local s = t.session
    local beat = s:present()
    s:advance(beat.token)                 -- the narration
    beat = s:present()
    s:advance(beat.token, "Wren")        -- the question
    beat = s:present()
    s:advance(beat.token)                 -- the closing line
    t:expect_shown("greeted", { n = "Wren" })
end)
```

`min_length` and `max_length` count characters; `min` and `max` bound numbers. Input that
breaks them is refused and the beat stays where it is.

## Freshen repeated text

Weighted variants break up wording that the player sees many times. The draw is made once
per presentation from the game's own dice, so a replay shows the same words.

```lua file=story.lua
relation open(0)
fact open()

storylet pier()
    when { open() }
    title "The pier"
    text "{#variant 3}Gulls wheel overhead.{#variant 2}The planks are slick with spray.{#variant 1 rare}A seal watches from the rocks.{/variant}"
    choice go
        title "Walk to the end"
        effect do end
    end
end
```

```lua file=tests/pier.lua
test.case("some wording is shown", function()
    local t = test.play{ seed = 3 }
    local text = t.session:present().storylets[1].text
    assert(text == "Gulls wheel overhead."
        or text == "The planks are slick with spray."
        or text == "A seal watches from the rocks.")
end)
```

A variant may carry a name after its weight (`rare` above). Translators can reorder named
variants without losing which is which.

## Give the interface hints: icons, tags, shortcuts

`narrative.meta` attaches presentation data to a storylet or a choice. The game does not
use it for decisions and a save does not record it; the front end reads it from the
presentation's `meta` field.

```lua file=story.lua
relation open(0)
fact open()

storylet inn()
    when { open() }
    title "The Salted Anchor"
    choice rest
        title "Take a room"
        effect do end
    end
end

narrative.meta(:inn, { icon = "bed", tags = { "rest", "town" } })
narrative.meta(:inn, :rest, { shortcut = "r" })
```

```lua file=tests/meta.lua
test.case("meta reaches the presentation", function()
    local t = test.play{ seed = 1 }
    local story = t.session:present().storylets[1]
    assert(story.meta.icon == "bed" and story.meta.tags[2] == "town")
    assert(story.choices[1].meta.shortcut == "r")
end)
```

Metadata must be registered in the same file or one loaded before the story is sealed.
Naming a storylet that does not exist is an error when the game starts.

## Bold, italic and links in text

Write `**strong**`, `*emphasis*` and `[link text](target)` in a text. The front end asks
for spans instead of parsing the markup itself:

```lua file=story.lua
relation open(0)
fact open()

storylet notice()
    when { open() }
    title "The notice board"
    text "**Lost:** one *very* small dog. See [the harbourmaster](harbourmaster)."
    choice read
        title "Read on"
        effect do end
    end
end
```

```lua file=tests/spans.lua
test.case("spans", function()
    local t = test.play{ seed = 1 }
    local spans = narrative.spans(t.session:present().storylets[1].text)
    assert(spans[1].text == "Lost:" and spans[1].strong)
    assert(spans[3].text == "very" and spans[3].emphasis)
    assert(spans[5].link == "harbourmaster")
end)
```

A name or number you insert into a text is just text. If the player typed it, pass it
through `narrative.escape_markup(name)` first so a stray `*` cannot become bold.

## Achievements that survive a new game

The profile is for things that outlive one playthrough. It belongs to the game's front end,
which stores it; the story only writes to it.

```lua file=story.lua
relation open(0)
fact open()

storylet lighthouse_top()
    when { open() }
    title "The top of the lighthouse"
    choice look
        title "Look at the sea"
        effect do
            narrative.profile_set("achievement.view", true)
        end
    end
end
```

```lua file=tests/profile.lua
test.case("the achievement is written when the choice commits", function()
    local t = test.play{ seed = 1 }
    assert(narrative.profile_get("achievement.view") == nil)
    t:choose("lighthouse_top", "look")
    assert(narrative.profile_get("achievement.view") == true)
end)
```

Reading the profile is not allowed inside a story's own conditions and effects, so a story
cannot behave differently depending on it. That keeps replays and saves honest. If an
achievement should change the story, record the fact in the game as well.

## Keep a variable and show it in text

`var` declares a story variable with a starting value. Show it with `{$name}`; change it with
`set` or `adjust` on the relation `var`.

```lua file=story.lua
relation open(0)
fact open()
var gold = 5

storylet purse()
    when { open() }
    title "Your purse"
    text "You carry {$gold} coins."
    choice spend
        title "Buy a pie"
        effect do adjust var(:gold) by -1 end
    end
end
```

```lua file=tests/var.lua
test.case("the variable changes", function()
    local t = test.play{ seed = 1 }
    assert(t.session:present().storylets[1].text == "You carry 5 coins.")
    t:choose("purse", "spend")
    assert(t.session:present().storylets[1].text == "You carry 4 coins.")
    t:expect_fact("var(:gold, 4)")
end)
```

## Reuse a piece of text

`narrative.fragment` names a piece of text; `{>name}` includes it. Define fragments before the
storylets and scenes that use them.

```lua file=story.lua
relation open(0)
fact open()
narrative.fragment(:sign_off, "Fair winds, and mind the tide.")

storylet quay()
    when { open() }
    title "The quay"
    text "The ferryman nods. {>sign_off}"
    choice go
        title "Go"
        effect do end
    end
end
```

```lua file=tests/fragment.lua
test.case("the fragment is included", function()
    local t = test.play{ seed = 1 }
    assert(t.session:present().storylets[1].text == "The ferryman nods. Fair winds, and mind the tide.")
end)
```

## Wording that depends on a number, in plain Lua

`{#if query ...}` asks the world. `{#if lua ...}` evaluates a read-only Lua expression over
the storylet's parameters, for tests like "three or more":

```lua file=story.lua
relation load(1)
fact load(4)

storylet barrow(?n)
    when { load(?n) }
    title "The barrow"
    text "{#if lua n >= 3}The barrow is heavy.{#else}The barrow is light.{/if}"
    choice push
        title "Push"
        effect do end
    end
end
```

```lua file=tests/lua_if.lua
test.case("lua condition", function()
    local t = test.play{ seed = 1 }
    assert(t.session:present().storylets[1].text == "The barrow is heavy.")
end)
```

## Passage-style links

Twine-style `[[text->choice]]` (or `[[choice]]`) in a storylet's text is a link that
**compiles to that choice**. The target must be the id of one of the storylet's choices; a
typo is an error when the game starts. The presentation lists each link, in text order, with
the choice's token, so a front end can draw the words as a link and choose on click:

```lua file=story.lua
relation open(0)
fact open()

storylet crossroads()
    when { open() }
    title "Crossroads"
    text "Take the [[left road->left]] or the [[right road->right]]."
    choice left
        title "Left"
        effect do end
    end
    choice right
        title "Right"
        effect do end
    end
end
```

```lua file=tests/links.lua
test.case("links are choices", function()
    local t = test.play{ seed = 1 }
    local story = t.session:present().storylets[1]
    assert(#story.links == 2)
    assert(story.links[1].text == "left road" and story.links[1].choice == :left)
    assert(story.links[1].enabled and story.links[1].token ~= nil)
    assert(story.links[2].choice == :right)
    -- clicking a link is choosing its token
    t.session:choose(story.links[2].token)
    assert(t.session:turn() == 1)
end)
```

## Save automatically, and keep slots

`session:set_autosave(function(text) ... end)` is called with the save text after every
committed choice or beat. `narrative.save_slot(session, dir, name [, {label=...}])`,
`narrative.list_slots(dir)`, `narrative.load_slot(dir, name, world_factory)` and
`narrative.delete_slot(dir, name)` keep one file per slot:

```lua file=story.lua
relation open(0)
fact open()

storylet rest()
    when { open() }
    title "Rest"
    choice sleep
        title "Sleep"
        effect do end
    end
end
```

```lua file=tests/slots.lua
test.case("autosave and slots", function()
    local t = test.play{ seed = 1 }
    local last
    t.session:set_autosave(function(text) last = text end)
    t:choose("rest", "sleep")
    assert(narrative.save_info(last).turn == 1)
    local dir = os.tmpname() .. "-slots"
    narrative.save_slot(t.session, dir, "evening", { label = "Evening" })
    assert(narrative.list_slots(dir)[1].label == "Evening")
    narrative.delete_slot(dir, "evening")
end)
```

## Find out why something is not showing

In a test, `t:why("storylet_name")` returns an explanation of what failed. In the text
player type `why name`. In a test it also appears in the failure message of
`expect_shown`:

```lua file=story.lua
relation key_found(0)

storylet vault()
    when { key_found() }
    title "The vault"
    choice open
        title "Open"
        effect do end
    end
end
```

```lua file=tests/why.lua
test.case("the vault is hidden without the key", function()
    local t = test.play{ seed = 1 }
    t:expect_hidden("vault")
    local why = t:why("vault")
    assert(why ~= nil)
end)
```

## When something is wrong

- **"unknown placeholder"**: a `{word}` in a text that is not a parameter of the storylet
  or choice. Add `?word` to the header, or fix the typo.
- **"unbound parameter"**: a header parameter that `when` never gives a value. Every
  `?name` in the header must appear in a positive goal of `when`.
- **A storylet never shows**: `varis check --analyze` lists storylets that exploration
  could not reach, and `why name` tells you the failing goal.
- **`STALE_CHOICE`**: a choice was taken twice or after the world changed. A front end
  must take choices from the latest presentation.

The [manual](../README.md) has the complete rules; section 6 covers everything on this page.
