# SDL3 scene player and D host adapter

Varis has an optional native visual-novel player. It presents the engine's declarative
scenes with backgrounds, transparent character sprites in named slots, expression/outfit
variants, side portraits, dialogue, menus, text input and independent audio channels.
The engine owns the story position and stage; the presentation manifest owns media paths
and layout. Asset edits do not change the content fingerprint or save format.

Build and run from the repository root:

```sh
# macOS dependencies (other platforms need equivalent development packages)
brew install sdl3 sdl3_image sdl3_ttf sdl3_mixer pkgconf
make varis-sdl
bin/varis-sdl sample-vn/presentation.json
```

The normal `varis` CLI and its tests do not require SDL. The optional player uses a small C
bridge compiled against the installed SDL headers, avoiding handwritten SDL event layouts
and dependency bindings inside the language runtime. SDL3_ttf supplies UTF-8 text shaping
and wrapping; SDL3_image supplies image decoding; SDL3_mixer supplies audio tracks. The
player runs SDL on the main OS thread. This build has been tested on macOS arm64;
Windows/Linux packaging is not yet verified.

## Author a scene

Use the [scene syntax](narrative.md#611--scenes-beats-and-stage-state) and keep file paths in
the manifest. For example:

```lua
character mira {
    name = "Mira",
    attributes = { expression = {:quiet, :smile} },
    defaults = { expression = :quiet }
}
scene greeting {
    {kind=:background, tag=:harbour},
    {kind=:show, character=:mira, slot=:left},
    {kind=:say, character=:mira, attributes={expression=:smile},
     id="greeting.hello", text="Welcome back."},
    {kind=:hide, character=:mira},
    {kind=:ended}
}
```

A line changes the character's attributes in the engine stage. The player selects a matching
image at the next beat boundary. `hide`, `background`, scene calls, jumps and menus use the
existing engine semantics. The player automatically acknowledges background/show/hide/audio
beats, so readers click through dialogue rather than each media directive.

## Manifest

[The sample manifest](../sample-vn/presentation.json) is a complete example. Paths are relative
to the manifest; content module `require` paths still follow the process working directory.

| Field | Meaning |
| --- | --- |
| `content`, `scene` | Content entry file to execute, then initial scene id (required). The player creates an empty session world. |
| `title` | Window title. |
| `font` | TTF/OTF font file, relative or absolute. Omission tries Arial on macOS/Windows or DejaVu Sans on Linux. Supply a font covering the language's characters for released games. |
| `font_size` | Text size, 8–96, default 28. |
| `save` | Quicksave path, default `quicksave.json` beside the manifest. |
| `panel_color`, `accent_color` | Decimal unsigned RGBA colors (`0xRRGGBBAA` represented as a JSON number). |
| `backgrounds` | Array of `{ "id": "harbour", "file": "assets/harbour.png" }`. Backgrounds fill the logical canvas. |
| `sprites`, `portraits` | Arrays with `character`, `file`, and optional `attributes` object. Attribute values are symbol/string names. |
| `slots` | Ordered array of `{ "id": "left", "x": 80, "y": 0, "width": 400, "height": 670 }`. |
| `audio` | Array of `{ "id": "theme", "file": "assets/theme.wav" }`. |
| `channels` | Array of `{ "id": "music", "loop": 1 }`. `loop: 0` plays once. |

Sprites match all listed attributes; the most specific match wins, with manifest order breaking
ties. An entry without attributes is a fallback. Sprite art preserves aspect ratio and anchors
to the bottom center of its slot. Slots draw in manifest order, later slots on top. Default
slots are `left`, `center`, `right` on a letterboxed 1280×720 canvas. Portraits are optional and
appear beside the speaker's text. All images/audio load once at startup; text textures rebuild
at beat or UI boundaries. Rendering between boundaries does not call the engine.

Unmapped active backgrounds, slots, characters and audio produce explicit errors. The sample
SVG artwork and synthesized WAV are original project assets under the repository license.
PNG with alpha is suitable for finished sprite and portrait artwork.

## Controls and current limits

- Enter, Space or left click advances dialogue; Escape closes the window (scene-only manifests; whole
  games, below, open a menu instead).
- Up/Down selects a menu item; Enter or a click chooses it. Menus page in groups of six.
- Type a name and press Enter at an input beat. Backspace removes a UTF-8 code point.
- Up/Down scrolls long dialogue. H shows the five most recent lines.
- A toggles automatic dialogue advancement; S toggles skipping. Neither chooses menus nor
  submits text input. H pauses both modes.
- F5 saves; F9 loads and reconstructs the complete stage from the engine save; B takes back the last choice or beat (session undo, 64 steps in a game, 256 in a scene player; not during a battle).

`transition` currently fades in from black over 300 ms and `pause` waits 300 ms. These are
player defaults; authored timing/effect parameters are not implemented. `picture` and `screen`
beats fail explicitly. In this scene-only player, typewriter effects, arbitrary transforms,
advanced transitions, voice synchronization, ruby, IME composition
feedback and full history navigation remain future work. SDL3_ttf renders UTF-8 but the supplied
font must cover the script; full CJK typography/localization stage T5 is not claimed. This is
an initial usable scene player, not completion of the entire milestone 36 parity checklist.

## D embedding boundary

`varis.services.presentation.SceneHost` adapts the existing scene runtime to return statuses:

```d
auto host = new SceneHost;
if (!host.loadContent(source, filename, "greeting")) {
    // Show host.error.
}
auto view = host.view; // SceneView: text, speaker, background, characters, choices, audio.
// Draw without engine calls, then acknowledge a user action:
bool ok = host.advance();
// Menus pass view.choices[index].id; input beats pass LuaValue(userText).
string bytes;
ok = host.save(bytes);
ok = host.restore(bytes);
```

`refresh()` produces a read-only view without advancing or consuming randomness. The adapter
retains the exact presentation token; callers do not construct tokens. Failed menu choices and
invalid saves leave the session intact. `view.finished` marks return to the hub or scene end;
this player closes there. The adapter catches legacy runtime exceptions at the boundary and
reports `false` plus `error`. It does not change VM error handling. The current convenience
loader serves scene-only games with an empty world; hosts requiring authored relational worlds
can use `GameHost` (below), which loads a manifest-backed project and its factory.
See the [D embedding contract](embedding.md) for both adapters. `GameHost` translates
character display names; `SceneHost` currently uses authored names.

## Validation

```sh
make test                    # includes host status/atomicity/save tests, no SDL needed
make test-sdl                # optional software-rendered integration checks
```

`test-sdl` exercises the illustrated sample, input/menu flow, asset failure diagnostics,
UTF-8 rendering, and byte-identical mid-scene save/load. It writes `build/sdl/harbour.bmp`
using SDL's dummy video/audio drivers and software renderer. The screenshot is captured
from the actual SDL render target. No display or audio hardware is required.

## Whole games: the game host and its player

A manifest with a `"project"` key (a directory with a project manifest, `project.varis` or `project.lua`, that names
`entry`, `session`, `load` and optionally `after_choose` and `finished`) is a whole game rather than a
scene-only one: the project builds its own world and content, and the player presents its storylet
hub, scenes, stage and a status panel. The adapter is `varis.services.gamehost.GameHost`:

```d
auto host = new GameHost;
if (!host.loadProject("sample-rpg", "prologue")) { /* host.error */ }
host.newGame(seed);            // session from the project's `session` function, first scene played
auto view = host.view;         // inScene / beat, stories[] with choices (enabled, because, token), hud[], values
host.advance(input);           // acknowledge a scene beat (input text or a menu choice id)
host.choose(story, choice);    // take a hub choice; a disabled one is refused with its reason
host.takeToasts();             // stat changes and notes since the last boundary
host.save(bytes); host.restore(bytes);
host.setLanguage("fr");        // a view: re-renders the same boundary, draws nothing
```

Statuses, not exceptions. `view` is read-only; the engine runs only inside `newGame`, `advance`,
`choose`, `restore` and `refresh`. Optional hook functions of the entry module add to the view:
`take_toasts()` (list of `{entity, name, delta}` or `{text}`), `journal(session)` (list of
`{title, lines}`), `achievements()`, `map_state(session)` (`{at, reachable}`).

Extra manifest fields of a whole game:

| Field | Meaning |
| --- | --- |
| `project` | Directory of the project, relative to the manifest. |
| `scene` | Scene started for a new game. |
| `seed` | Fixed seed; omitted: derived from the clock. |
| `autosave`, `settings` | Files written beside the manifest: the autosave after each choice (the title's Continue) and `{volume, fullscreen, language}`. |
| `languages` | `[{ "tag": "fr", "name": "Français" }]`; an empty tag is the source language. Packs are loaded by the project. A language may add `"font"` (body font file; headings follow it) and `"heading_font"`, so a script the default font lacks is drawn with a font that covers it; the switch happens with the language and drops cached text. `varis l10n fonts --manifest FILE` checks that each language's font covers its messages. |
| `clock` | Names of the four times of day, shown from the `slot` quality. |
| `map` | `{ "places": [{id,x,y}], "roads": [[a,b]] }` for the map overlay; clicking a reachable place chooses the `walk` storylet bound to it. |
| `choice_labels` | Storylets whose hub rows are labelled by their choice rather than the storylet title. |

Controls: Up/Down, 1–9, Enter or the mouse choose; C character sheet, J journal, M map, H history,
F1 help, F5/F9 quicksave/load, F11 fullscreen, Esc the pause menu (resume, save, load, language,
volume, text size, layout, fullscreen, quit to title); Tab opens the drawer in the compact layout. A choice with an unmet requirement is listed greyed out as
"locked", and hovering it shows why. Time of day is drawn as a tint; sprites, backgrounds, music and
one-shot sounds (`click`, `stat_up`, `fail` on the `sfx` channel) come from the manifest as above.
`make test-sdl` plays *The Hollowbrook Summer* headlessly (hub, every overlay, name input, a save
round trip) and captures a frame. See [sample-rpg/README.md](../sample-rpg/README.md).

## Layout, text and style

The player has no fixed canvas: it lays widgets out for the window it has (`tools/sdl/ui.d`).

- **One root owns the screen.** Every widget lives in a tree whose root is the whole window, and
  a child is only laid out inside the rectangle its parent gives it, so nothing draws outside its
  box.
- **Text belongs to a box.** A label measures its text for the width it is offered. If the box is
  smaller: a title or a choice is cut with "…" and slides sideways while the pointer rests on it; a
  paragraph is clipped and scrolls with the wheel, and on its own while hovered. Boxes give up room
  to such labels before anything else is squeezed.
- **Size classes.** Judged in design units (pixels at the 1280x720 design, scaled by display
  density, the text-size setting and a mild automatic fit): *compact* (under about 900x560) puts the
  stage over one scrolling panel and moves the status and menu into a drawer; *regular* is stage over
  a text-and-choices panel; *wide* (about 1500x820 units and up) has a status sidebar, the stage and
  text in the middle and the choices in a column of their own. The pause menu sets text size
  (80–175%) and can force a layout.
- **Style is data.** A manifest `theme` overrides colours (`"colors": {"accent": "#ffcc66"}` with
  `#rrggbb` or `#rrggbbaa`), the type scale (`font_size`, `font_small`, `font_heading`,
  `font_title`), spacing (`padding`, `gap`, `row_padding`, `border_width`) and the breakpoints
  (`compact_width`, `compact_height`, `wide_width`, `wide_height`). `heading_font` names a second
  font file for headings; `window` sets the initial size. Backgrounds fill the window (cover), and
  sprite slots (written in the 1280-wide design) are kept as fractions of the stage rectangle.

For testing, `--smoke` honours `VARIS_SMOKE_SIZE=WxH`, `VARIS_SMOKE_SCALE` (a text size index),
`VARIS_SMOKE_LAYOUT=compact|regular|wide`, `VARIS_SMOKE_OVERLAY`, `VARIS_SMOKE_DRAWER=1` and
`VARIS_SMOKE_SCREEN=title|scene`. `VARIS_SMOKE_PLAY=ui` plays a whole game by pointer and keyboard
events alone, through the widget tree the window shows (`VARIS_SMOKE_BUILD=strength|wits|charm`,
`VARIS_SMOKE_STOP_AT=<storylet id>` captures that screen, `VARIS_SMOKE_VERBOSE=1` logs each click); it fails
when a click does not change the game.
