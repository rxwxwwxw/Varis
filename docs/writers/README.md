# Writer's guide

For people who write stories and dialogue in Varis and do not want to read the language
reference first. You need no programming background; you do need a text editor and a
terminal.

| Read | When |
| --- | --- |
| [Tutorial](tutorial.md) | You are new. Eight short steps from an empty folder to a story with choices, numbers, a cast, saves and a release checklist. |
| [Cookbook](cookbook.md) | You know the basics and want "how do I..." answers: once-only scenes, shops, relationships, scheduled events, asking the player's name, icons, rich text, achievements. |
| [Reference manual](../README.md) | You need the exact rule. Section 6 is narrative programming; section 8 covers the tools (`check`, `play`, `test`, `serve`, `l10n`). |

## The three tools you will use all day

```sh
varis check        # reads every file, reports mistakes with file, line and a code
varis test         # plays the story through the tests in tests/
varis play         # a text player: number to choose, `why NAME`, `save`, `quit`
```

`varis serve` opens the same project in a browser with an editor and a story panel, if you
prefer that to a terminal and your own editor.

## How these pages stay true

Every program in the tutorial and cookbook is run by the project's test suite
(`python3 tools/suite test --suite writers-docs`): the files are written to a scratch project,
checked with `varis check`, and exercised with `varis test`. If a page here stops working,
the build fails, so report it as a bug.

## Words used in the guides

- **Storylet**: something the player can be offered, with a condition, text and choices.
- **Choice**: a button on a storylet; its **effect** changes the world.
- **Fact / relation**: a true statement, and the kind of statement it is.
- **Quality**: a named number with limits (coins, trust).
- **Scene**: a fixed run of lines, one beat at a time, with a cast of **characters**.
- **Session**: one playthrough; it can be saved and loaded.
- **Symbol**: a name beginning with a colon, such as `:harbour`.
