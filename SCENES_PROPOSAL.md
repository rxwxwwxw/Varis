# Scenes, lines and the stage: a proposal for milestone 29

Status: **historical syntax proposal**, October 12, 2026. A first declarative scene
implementation now exists; [manual §6.11](docs/narrative.md#611--scenes-beats-and-stage-state)
defines its actual syntax and semantics. The compact speaker/menu syntax below is still a
proposal and is not accepted by the parser.

Current scenes use `scene Name { ... }` tables of immutable beat records, `character`
declarations, scalar locals, jump/call/return, menu/input boundaries, authored line `id`
fields, and saved engine stage. `session:play`, `present` and `advance` drive them;
format 3 saves restore the scene stack and stage. The index, checker and localization
catalog recognize literal scene declarations and lines. The [linear sample](sample-vn/README.md)
and [SDL3 player](docs/presentation.md) demonstrate this slice. Procedural statements
between beats, compact syntax, beat undo and full presentation parity remain planned.
The rest of this file preserves the original design for future syntax discussion.

## 1. What a writer types

```lua
scene arrival(?who)
    when { here(?who) }                 -- optional: scenes may also be entered by `jump`
    stage { background = :shore_dawn, music = :tide }

    keeper "The light failed again last night."          -- a line: speaker, then text
    keeper:worried "Did you see it go out?"              -- attribute change: expression
    show keeper at :left with { outfit = :coat }
    narrator "You shake your head."                       -- the narrator is the empty speaker

    menu
        option "Yes, it went dark at midnight."           -- a choice inside a scene
            fact told(:lamp)
            jump topic_lamp
        option "No."
            keeper "Then it was only me."
    end
end
```

- A **line** is `speaker "text"`, text in the template grammar (`{name}`, `{#plural}`, ...).
- `speaker:attribute` changes an attribute of a declared character (expression, outfit).
- `show`, `hide`, `stage`, `music`, `sfx` are **structured beats**, not strings: the engine
  records them, the front end interprets them. The engine holds no pixels, times or files.
- `menu`/`option`, `jump`, `call`/`return`, `if`/`else` over a query, and `fact`/`retract`/
  `set`/`adjust` statements are the only other things in a scene body. No Lua blocks.

## 2. Original line-id proposal (not implemented; localization plan §3.2)

Default of the localization plan (§12), taken until decided otherwise: **a short tag written
onto the line by a tool the first time the line is extracted**:

```lua
    keeper "The light failed again last night."     #a7f3
```

`varis l10n extract` appends `#a7f3` to a line that has none (the only time a tool edits a
content file), the checker reports a duplicate or missing id, and the message key is
`arrival.a7f3`. The tag survives editing the text and inserting lines; it never derives from
position or wording. Until a line is tagged, the checker reports `line-id-missing` as a warning
and the extractor refuses to write the catalog entry without one.

## 3. What it compiles to

A scene is **not a coroutine**. It compiles to a numbered sequence of beats (a table of
instructions with portable operands). The session's position is *(scene id, beat index, portable
locals)*; the beat stream is what `present()` returns for a scene (`beats = {...}`), and
`choose` of a menu option moves the position. Saves record the position and the stage state
(who is on stage in which named slot, attributes, background, audio channels), so load and
rollback restore the picture.

## 4. Open choices (owner)

| Choice | Proposed default |
| --- | --- |
| Keyword set (`scene`, `menu`, `option`, `jump`, `call`, `show`, `hide`, `stage`) | Contextual words, as `storylet` is today |
| Speaker syntax | A declared character name before the string; `narrator` reserved |
| Character declaration | `character keeper { name = "Hesketh", attributes = { expression = {:calm, :worried} } }` |
| Whether scenes may be entered from storylets | Yes: an effect does `jump scene`, a scene may `jump` to a storylet hub |
| Line id tag form | `#xxxx` after the string, written by the extractor |

## 5. What it would add to the tools

Index rows for scenes, characters and lines (kind `line`, key `scene.tag`); checks for unknown
character/attribute/slot, duplicate line ids, unreachable beats; `varis play` as a beat player;
`l10n extract` context from scene order (the neighbouring lines in each kit message).
