# Harbour Window

A linear visual-novel sample with a character, expressions, an outfit, a named
stage slot, a background and a music channel. Its text host needs no media files. An optional SDL3 host includes illustrated assets.

Run from the repository root:

```sh
make varis
bin/varis sample-vn/main.lua
```

The sample asks for a visitor name through a structured input beat (the test host
supplies `Rowan`), saves on a dialogue beat, restores the complete stage and name,
then saves again inside a called scene. It returns to the caller's next dialogue,
hides the character, stops music, and ends. Expected output:

```text
Welcome back, Rowan.
Then I will see you tomorrow.
Leave the lantern burning.
mid-scene save/load checks passed
```

`content.lua` holds writer-authored declarations; `main.lua` is the small text host
and round-trip check. The `sample-game` test suite also runs
`tests/sample_game/scene_save_test.py`: it loads the save in a fresh process,
accepts wording edits, rejects structural edits and corrupted positions/stage,
and checks static unknown-character/attribute diagnostics. No media directive is
replayed while loading, and no Lua coroutine or suspended frame is saved.

For the graphical version:

```sh
make varis-sdl
bin/varis-sdl sample-vn/presentation.json
```

See [the presentation guide](../docs/presentation.md) for dependencies, controls,
asset matching, fonts and current limits. `make test-sdl` renders and tests it headlessly.

The first scene implementation uses declarative beat records. Procedural blocks
between beats, rollback history, and full RPG Maker/Ren'Py presentation parity
remain later work. The semantics are in the reference manual, section 6.11.
